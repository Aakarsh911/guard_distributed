#!/usr/bin/env python3
"""
GUARD Visualizer Proxy
======================
Intercepts guard_client ↔ server/LB traffic and streams live events to the
browser dashboard via Server-Sent Events (SSE).

Usage
-----
  # Default: proxy 127.0.0.1:9099 → 127.0.0.1:9100 (LB, Phase 3/4)
  python3 proxy.py

  # Point at a single server (Phase 1/2)
  python3 proxy.py --target 127.0.0.1:8080

  # Custom ports
  python3 proxy.py --listen-port 9099 --target 127.0.0.1:9100 --http-port 9098

  # Phase 5: coordinator writes to guard_coord5.log
  python3 proxy.py --coord-log /tmp/guard_coord5.log

Then open http://127.0.0.1:9098/ and switch the visualizer to Live mode.
Point guard_client at the proxy instead of the real server/LB, e.g.:
  ./build/guard_client 127.0.0.1 9099 100 4 alice
"""

import asyncio
import json
import os
import re
import shlex
import signal
import struct
import subprocess
import sys
import time
import queue
import threading
import http.server
import socketserver
import urllib.parse
from pathlib import Path

# ── Config (overridable via CLI) ───────────────────────────────────────────────
LISTEN_HOST          = '127.0.0.1'
LISTEN_PORT          = 9099
TARGET_HOST          = '127.0.0.1'
TARGET_PORT          = 9100
HTTP_PORT            = 9098
SCRIPT_DIR           = Path(__file__).parent
COORD_LOG            = Path('/tmp/guard_coord.log')
CAPACITY             = None   # real bucket capacity; None means unknown
EXIT_ON_DISCONNECT   = False  # shut down when browser heartbeat stops
DISCONNECT_TIMEOUT   = 12.0   # seconds of silence before exit

# ── Shared state ───────────────────────────────────────────────────────────────
_lock       = threading.Lock()
_last_ping  = time.time()   # updated by GET /ping; watched by _watchdog()
_subscribers: list[queue.Queue] = []
_stats: dict = {
    'total': 0, 'ok': 0, 'rl': 0,
    'by_user': {},   # user_id → {'total', 'ok', 'rl'}
    'tokens':  {},   # user_id → float  (from coordinator log)
}
_coord_pos: int = 0
_TOKEN_RE = re.compile(r'user=(\S+).*?(?:ALLOWED|DENIED).*?tokens=([0-9.]+)')

# ── Process registry (for live kill/reboot) ────────────────────────────────────
# Keyed by port number. Each entry: {pid, role, port, cmd, alive}
_procs: dict = {}   # port → {pid, role, cmd, alive}
BUILD_DIR = Path(__file__).parent / 'build'

_PROC_RE = re.compile(r'(guard_(?:coord|server))\s+(\d+)')


def _scan_procs() -> None:
    """Refresh _procs from running guard_coord / guard_server processes."""
    try:
        out = subprocess.check_output(['ps', 'aux'], text=True)
    except Exception:
        return
    found: set[int] = set()
    for line in out.splitlines()[1:]:
        parts = line.split(None, 10)
        if len(parts) < 11:
            continue
        try:
            pid = int(parts[1])
        except ValueError:
            continue
        cmd = parts[10]
        m = _PROC_RE.search(cmd)
        if not m:
            continue
        binary, port_str = m.group(1), m.group(2)
        port = int(port_str)
        role = 'coord' if 'coord' in binary else 'server'
        found.add(port)
        with _lock:
            existing = _procs.get(port)
            if existing is None or existing['pid'] != pid:
                # New or replaced process — update entry, keep cached cmd for restarts
                _procs[port] = {
                    'pid':   pid,
                    'role':  role,
                    'port':  port,
                    'cmd':   cmd.strip(),
                    'alive': True,
                }
            else:
                existing['alive'] = True
    # Mark anything no longer in ps as dead
    with _lock:
        for port, info in _procs.items():
            if port not in found:
                info['alive'] = False


def _topology() -> dict:
    """Return coord port and ordered worker ports from the current registry."""
    _scan_procs()
    with _lock:
        coords  = sorted([v for v in _procs.values() if v['role'] == 'coord' and v['alive']],
                         key=lambda x: x['port'])
        workers = sorted([v for v in _procs.values() if v['role'] == 'server' and v['alive']],
                         key=lambda x: x['port'])
    return {
        'coord_port':   coords[0]['port']  if coords  else None,
        'worker_ports': [w['port'] for w in workers[:3]],
    }


def _proc_control(action: str, role: str, index: int) -> tuple[bool, int | None]:
    """Kill or reboot a guard process. Returns (success, port)."""
    _scan_procs()

    with _lock:
        if role == 'coord':
            candidates = sorted(
                [v for v in _procs.values() if v['role'] == 'coord'],
                key=lambda x: x['port'])
            target = candidates[0] if candidates else None
        else:
            candidates = sorted(
                [v for v in _procs.values() if v['role'] == 'server'],
                key=lambda x: x['port'])
            target = candidates[index] if index < len(candidates) else None

    if target is None:
        return False, None

    port = target['port']

    if action == 'kill':
        try:
            os.kill(target['pid'], signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass   # already dead
        with _lock:
            if port in _procs:
                _procs[port]['alive'] = False
        return True, port

    elif action == 'reboot':
        # Reconstruct command using the known build dir so relative paths work.
        cmd_str = target.get('cmd', '')
        m = _PROC_RE.search(cmd_str)
        if not m:
            return False, port
        binary   = m.group(1)
        rest     = cmd_str[m.end():].strip()
        full_bin = str(BUILD_DIR / binary)
        if not Path(full_bin).exists():
            return False, port
        args = [full_bin] + shlex.split(rest)
        log  = Path(f'/tmp/guard_{binary}_{port}_restart.log')
        try:
            p = subprocess.Popen(args, stderr=log.open('w'), stdout=subprocess.DEVNULL)
            time.sleep(0.3)   # give it a moment to bind
            with _lock:
                _procs[port] = {
                    'pid':   p.pid,
                    'role':  target['role'],
                    'port':  port,
                    'cmd':   cmd_str,
                    'alive': True,
                }
            return True, port
        except Exception as e:
            print(f'[proxy] reboot failed: {e}', file=sys.stderr)
            return False, port

    return False, None


def _emit(event_type: str, data: dict) -> None:
    msg = 'data: ' + json.dumps({'type': event_type, **data}) + '\n\n'
    with _lock:
        dead = []
        for q in _subscribers:
            try:
                q.put_nowait(msg)
            except queue.Full:
                dead.append(q)
        for d in dead:
            _subscribers.remove(d)


def _record(user_id: str, status: str) -> None:
    ok = status == 'ok'
    with _lock:
        _stats['total'] += 1
        _stats['ok' if ok else 'rl'] += 1
        u = _stats['by_user'].setdefault(user_id, {'total': 0, 'ok': 0, 'rl': 0})
        u['total'] += 1
        u['ok' if ok else 'rl'] += 1


# ── Coordinator log tail ───────────────────────────────────────────────────────
def _tail_coord_log() -> None:
    """Background thread: tail the coordinator log for real token levels."""
    global _coord_pos
    while True:
        try:
            if COORD_LOG.exists():
                with COORD_LOG.open() as f:
                    # Detect truncation (e.g. phase 5 kills coordinator and clears
                    # the log before restart).  If file shrank, restart from 0.
                    f.seek(0, 2)
                    if f.tell() < _coord_pos:
                        _coord_pos = 0
                    f.seek(_coord_pos)
                    for line in f:
                        m = _TOKEN_RE.search(line)
                        if m:
                            user, tokens = m.group(1), float(m.group(2))
                            with _lock:
                                _stats['tokens'][user] = tokens
                            _emit('tokens', {'user_id': user, 'tokens': tokens})
                    _coord_pos = f.tell()
        except Exception:
            pass
        time.sleep(0.15)


# ── Guard wire-protocol helpers ────────────────────────────────────────────────
async def _read_msg(reader: asyncio.StreamReader) -> dict:
    hdr  = await reader.readexactly(4)
    n    = struct.unpack('>I', hdr)[0]
    if n > 16 * 1024 * 1024:
        raise ValueError(f'message too large: {n} bytes')
    body = await reader.readexactly(n)
    return json.loads(body)


async def _write_msg(writer: asyncio.StreamWriter, obj: dict) -> None:
    body = json.dumps(obj).encode()
    writer.write(struct.pack('>I', len(body)) + body)
    await writer.drain()


# ── TCP proxy ─────────────────────────────────────────────────────────────────
async def _handle(cr: asyncio.StreamReader, cw: asyncio.StreamWriter) -> None:
    try:
        br, bw = await asyncio.open_connection(TARGET_HOST, TARGET_PORT)
    except OSError as e:
        print(f'[proxy] Cannot reach backend {TARGET_HOST}:{TARGET_PORT}: {e}')
        cw.close()
        return

    try:
        req     = await _read_msg(cr)
        user_id = req.get('user_id', 'unknown')
        req_id  = req.get('req_id', '')
        t0      = time.time()

        _emit('request', {'user_id': user_id, 'req_id': req_id, 'ts': t0})

        await _write_msg(bw, req)
        resp   = await _read_msg(br)
        status = resp.get('status', 'error')

        _record(user_id, status)
        _emit('response', {
            'user_id':    user_id,
            'req_id':     req_id,
            'status':     status,
            'latency_ms': round((time.time() - t0) * 1000, 2),
        })

        await _write_msg(cw, resp)
    except (asyncio.IncompleteReadError, json.JSONDecodeError, ValueError, OSError):
        pass
    finally:
        for w in (bw, cw):
            try:
                w.close()
                await w.wait_closed()
            except Exception:
                pass


async def _run_proxy() -> None:
    srv = await asyncio.start_server(_handle, LISTEN_HOST, LISTEN_PORT)
    addrs = ', '.join(str(s.getsockname()) for s in srv.sockets)
    print(f'[proxy] TCP  {addrs}  →  {TARGET_HOST}:{TARGET_PORT}')
    async with srv:
        await srv.serve_forever()


# ── HTTP + SSE server ─────────────────────────────────────────────────────────
class _Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args) -> None:
        pass  # suppress per-request noise

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self._cors()
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.end_headers()

    def do_POST(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        if path not in ('/control', '/launch', '/stop'):
            self.send_error(404)
            return
        try:
            length = int(self.headers.get('Content-Length', 0))
            body   = json.loads(self.rfile.read(length)) if length else {}
        except (ValueError, json.JSONDecodeError):
            self.send_error(400, 'bad JSON')
            return

        if path == '/launch':
            phase = int(body.get('phase', 0))
            ok = _launch_phase(phase)   # blocks until services are up
            resp = json.dumps({'ok': ok, 'phase': phase}).encode()

        elif path == '/stop':
            _stop_launch()
            resp = json.dumps({'ok': True}).encode()

        else:  # /control
            action = body.get('action', '')   # 'kill' | 'reboot'
            role   = body.get('role',   '')   # 'coord' | 'worker'
            index  = int(body.get('index', 0))

            ok, port = _proc_control(action, role, index)

            if ok and port is not None:
                _scan_procs()
                with _lock:
                    workers = sorted(
                        [v for v in _procs.values() if v['role'] == 'server'],
                        key=lambda x: x['port'])
                worker_idx = next(
                    (i for i, w in enumerate(workers) if w['port'] == port), 0)

                if action == 'kill':
                    ev = 'coord_down' if role == 'coord' else 'worker_down'
                    _emit(ev, {'port': port, 'worker_index': worker_idx})
                else:
                    ev = 'coord_up' if role == 'coord' else 'worker_up'
                    _emit(ev, {'port': port, 'worker_index': worker_idx})

            resp = json.dumps({'ok': ok, 'port': port}).encode()

        self.send_response(200)
        self._cors()
        self.send_header('Content-Type',   'application/json')
        self.send_header('Content-Length', str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

    def do_GET(self) -> None:
        global _last_ping
        path = urllib.parse.urlparse(self.path).path
        if path == '/ping':
            _last_ping = time.time()
            self.send_response(200)
            self._cors()
            self.send_header('Content-Type',   'text/plain')
            self.send_header('Content-Length', '2')
            self.end_headers()
            self.wfile.write(b'ok')
            return
        if path == '/events':
            self._sse()
        elif path == '/stats':
            self._json_stats()
        elif path in ('/', '/visualizer.html'):
            self._serve_html()
        else:
            self.send_error(404)

    def _cors(self) -> None:
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')

    # SSE stream ---------------------------------------------------------------
    def _sse(self) -> None:
        self.send_response(200)
        self.send_header('Content-Type',  'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection',    'keep-alive')
        self._cors()
        self.end_headers()

        q: queue.Queue = queue.Queue(maxsize=500)
        with _lock:
            _subscribers.append(q)

        # Send current stats + topology snapshot so the UI initialises.
        with _lock:
            snap = dict(_stats)
        snap.update(_topology())
        if CAPACITY is not None:
            snap['bucket_cap'] = CAPACITY
        try:
            self._send_sse(f"data: {json.dumps({'type': 'snapshot', **snap})}\n\n")
            while True:
                try:
                    msg = q.get(timeout=20)
                    self._send_sse(msg)
                except queue.Empty:
                    self._send_sse(': heartbeat\n\n')
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            with _lock:
                try:
                    _subscribers.remove(q)
                except ValueError:
                    pass

    def _send_sse(self, msg: str) -> None:
        self.wfile.write(msg.encode())
        self.wfile.flush()

    # JSON stats snapshot ------------------------------------------------------
    def _json_stats(self) -> None:
        with _lock:
            data = json.dumps(_stats).encode()
        self.send_response(200)
        self.send_header('Content-Type',   'application/json')
        self.send_header('Content-Length', str(len(data)))
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    # Serve visualizer.html ----------------------------------------------------
    def _serve_html(self) -> None:
        html_path = SCRIPT_DIR / 'visualizer.html'
        if not html_path.exists():
            self.send_error(404, 'visualizer.html not found')
            return
        data = html_path.read_bytes()
        self.send_response(200)
        self.send_header('Content-Type',   'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class _Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def _watchdog() -> None:
    """Exit the proxy if no browser heartbeat is received within DISCONNECT_TIMEOUT."""
    while True:
        time.sleep(2.0)
        if not EXIT_ON_DISCONNECT:
            continue
        if time.time() - _last_ping > DISCONNECT_TIMEOUT:
            print('[proxy] browser disconnected — shutting down', file=sys.stderr)
            _stop_launch()
            for pat in ('guard_coord', 'guard_server', 'guard_lb'):
                subprocess.run(['pkill', '-f', pat], capture_output=True, check=False)
            os._exit(0)


def _run_http() -> None:
    srv = _Server(('127.0.0.1', HTTP_PORT), _Handler)
    print(f'[proxy] HTTP http://127.0.0.1:{HTTP_PORT}/'
          f'  (visualizer · /events SSE · /stats JSON)')
    srv.serve_forever()


# ── Phase auto-launcher ───────────────────────────────────────────────────────
SCRIPTS_DIR = SCRIPT_DIR / 'scripts'

_current_script_proc: 'subprocess.Popen | None' = None
_launch_lock = threading.Lock()


def _script_detect_port(script: Path) -> int:
    """Return the backend port a phase script binds its entry-point to."""
    text = script.read_text(errors='replace')
    for var in ('LB_PORT', 'PORT', 'SERVER_PORT', 'S1_PORT'):
        m = re.search(rf'^\s*{var}\s*=\s*(\d+)', text, re.MULTILINE)
        if m:
            return int(m.group(1))
    return 8080


def _script_detect_coord_log(script: Path) -> str:
    text = script.read_text(errors='replace')
    m = re.search(r'^\s*(?:COORD_LOG|LOG_COORD)\s*=\s*["\']?([^"\']+)', text, re.MULTILINE)
    if m:
        return m.group(1).strip().strip('"\'')
    m = re.search(r'(/tmp/guard_coord[^\s"\']*\.log)', text)
    return m.group(1) if m else ''


def _stop_launch() -> None:
    global _current_script_proc
    p = _current_script_proc
    if p and p.poll() is None:
        try:
            p.kill()
        except Exception:
            pass
        try:
            p.wait(timeout=1.0)
        except Exception:
            pass
    _current_script_proc = None


def _launch_phase(phase: int) -> bool:
    global TARGET_PORT, COORD_LOG, _current_script_proc
    script = SCRIPTS_DIR / f'run_phase{phase}.sh'
    if not script.exists():
        print(f'[proxy] script not found: {script}', file=sys.stderr)
        return False

    with _launch_lock:
        _stop_launch()

        # Kill stray guard processes; the phase script also does this, but we
        # need to clean up services from the *previous* phase before the new
        # script's pkill runs (which only knows about its own phase's ports).
        for pat in ('guard_coord', 'guard_server', 'guard_lb'):
            subprocess.run(['pkill', '-f', pat], capture_output=True, check=False)
        time.sleep(0.25)

        new_port   = _script_detect_port(script)
        coord_log  = _script_detect_coord_log(script)
        TARGET_PORT = new_port
        if coord_log:
            COORD_LOG = Path(coord_log)

        _emit('launch', {'phase': phase, 'target_port': new_port})
        print(f'[proxy] phase {phase} → {script.name}  (target :{new_port})')

        _current_script_proc = subprocess.Popen(
            ['bash', str(script)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    return True


# ── CLI ───────────────────────────────────────────────────────────────────────
def _parse_args() -> None:
    global LISTEN_PORT, TARGET_HOST, TARGET_PORT, HTTP_PORT, COORD_LOG, CAPACITY
    global EXIT_ON_DISCONNECT, DISCONNECT_TIMEOUT
    argv, i = sys.argv, 1
    while i < len(argv):
        if argv[i] == '--listen-port' and i + 1 < len(argv):
            LISTEN_PORT = int(argv[i + 1]); i += 2
        elif argv[i] == '--target' and i + 1 < len(argv):
            colon = argv[i + 1].rfind(':')
            TARGET_HOST = argv[i + 1][:colon]
            TARGET_PORT = int(argv[i + 1][colon + 1:])
            i += 2
        elif argv[i] == '--http-port' and i + 1 < len(argv):
            HTTP_PORT = int(argv[i + 1]); i += 2
        elif argv[i] == '--coord-log' and i + 1 < len(argv):
            COORD_LOG = Path(argv[i + 1]); i += 2
        elif argv[i] == '--capacity' and i + 1 < len(argv):
            CAPACITY = float(argv[i + 1]); i += 2
        elif argv[i] == '--exit-on-disconnect':
            EXIT_ON_DISCONNECT = True; i += 1
        elif argv[i] == '--disconnect-timeout' and i + 1 < len(argv):
            DISCONNECT_TIMEOUT = float(argv[i + 1]); i += 2
        else:
            i += 1


if __name__ == '__main__':
    _parse_args()
    threading.Thread(target=_tail_coord_log, daemon=True).start()
    threading.Thread(target=_run_http,       daemon=True).start()
    threading.Thread(target=_watchdog,       daemon=True).start()
    print('[proxy] GUARD Visualizer Proxy  (Ctrl-C to stop)')
    try:
        asyncio.run(_run_proxy())
    except KeyboardInterrupt:
        print('\n[proxy] Shutting down.')
