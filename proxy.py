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

Then open http://127.0.0.1:9098/ and switch the visualizer to Live mode.
Point guard_client at the proxy instead of the real server/LB, e.g.:
  ./build/guard_client 127.0.0.1 9099 100 4 alice
"""

import asyncio
import json
import re
import struct
import sys
import time
import queue
import threading
import http.server
import socketserver
import urllib.parse
from pathlib import Path

# ── Config (overridable via CLI) ───────────────────────────────────────────────
LISTEN_HOST = '127.0.0.1'
LISTEN_PORT = 9099
TARGET_HOST = '127.0.0.1'
TARGET_PORT = 9100
HTTP_PORT   = 9098
SCRIPT_DIR  = Path(__file__).parent
COORD_LOG   = Path('/tmp/guard_coord.log')

# ── Shared state ───────────────────────────────────────────────────────────────
_lock = threading.Lock()
_subscribers: list[queue.Queue] = []
_stats: dict = {
    'total': 0, 'ok': 0, 'rl': 0,
    'by_user': {},   # user_id → {'total', 'ok', 'rl'}
    'tokens':  {},   # user_id → float  (from coordinator log)
}
_coord_pos: int = 0
_TOKEN_RE = re.compile(r'user=(\S+).*?(?:ALLOWED|DENIED).*?tokens=([0-9.]+)')


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
    """Background thread: tail /tmp/guard_coord.log for real token levels."""
    global _coord_pos
    while True:
        try:
            if COORD_LOG.exists():
                with COORD_LOG.open() as f:
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
        self.end_headers()

    def do_GET(self) -> None:
        path = urllib.parse.urlparse(self.path).path
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

        # Send current stats snapshot immediately so the UI initialises.
        with _lock:
            snap = dict(_stats)
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


def _run_http() -> None:
    srv = _Server(('127.0.0.1', HTTP_PORT), _Handler)
    print(f'[proxy] HTTP http://127.0.0.1:{HTTP_PORT}/'
          f'  (visualizer · /events SSE · /stats JSON)')
    srv.serve_forever()


# ── CLI ───────────────────────────────────────────────────────────────────────
def _parse_args() -> None:
    global LISTEN_PORT, TARGET_HOST, TARGET_PORT, HTTP_PORT
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
        else:
            i += 1


if __name__ == '__main__':
    _parse_args()
    threading.Thread(target=_tail_coord_log, daemon=True).start()
    threading.Thread(target=_run_http,       daemon=True).start()
    print('[proxy] GUARD Visualizer Proxy  (Ctrl-C to stop)')
    try:
        asyncio.run(_run_proxy())
    except KeyboardInterrupt:
        print('\n[proxy] Shutting down.')
