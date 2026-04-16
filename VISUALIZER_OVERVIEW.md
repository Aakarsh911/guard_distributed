# GUARD Visualizer Overview

## Architecture Diagram

```
guard_client
    │
    │ TCP (JSON framed, 4-byte length prefix)
    ▼
┌─────────────────────────────────────────────────────┐
│                    proxy.py (:9099)                 │
│                                                     │
│  ┌──────────────┐     ┌────────────────────────┐   │
│  │  TCP Proxy   │     │  Background Threads    │   │
│  │  (asyncio)   │     │                        │   │
│  │              │     │  • _tail_coord_log()   │   │
│  │  intercepts  │     │    tails coordinator   │   │
│  │  request /   │     │    log for token data  │   │
│  │  response    │     │                        │   │
│  │  pairs       │     │  • _run_http()         │   │
│  └──────┬───────┘     │    serves HTTP / SSE   │   │
│         │  _emit()    └────────────────────────┘   │
│         └──────────────────────┐                   │
│                                ▼                   │
│                     shared event queue             │
│                     (_subscribers list)            │
└─────────────────────────────────┬───────────────────┘
                                  │
          ┌───────────────────────┼────────────────────┐
          │                       │                    │
          ▼                       ▼                    ▼
   GET /             GET /events (SSE)       GET /stats (JSON)
   serves             streams live                snapshot
 visualizer.html      event feed              of _stats dict
          │                       │
          ▼                       ▼
  ┌───────────────┐    ┌───────────────────────────────────┐
  │  Browser UI   │◄───│  EventSource  (SSE connection)    │
  │ visualizer.html    │  receives typed JSON events:      │
  │               │    │  • snapshot  – initial stats      │
  │  Canvas draw  │    │  • request   – new req seen       │
  │  Sidebar stats│    │  • response  – result + latency   │
  │  Phase tabs   │    │  • tokens    – bucket level update│
  │  Kill/Reboot  │    │  • coord_down / coord_up          │
  │  buttons      │    │  • worker_down / worker_up        │
  └───────┬───────┘    └───────────────────────────────────┘
          │
          │ POST /control  (kill / reboot)
          ▼
       proxy.py  →  os.kill / subprocess.Popen
```

The proxy also forwards each request transparently:

```
guard_client  →  proxy (:9099)  →  guard_lb / guard_server (:9100)
                    │                         │
                    │◄────── response ─────────┘
                    │
                  emits SSE events to all connected browser tabs
```

---

## Proxy (`proxy.py`)

- **TCP interception** — sits between client and backend; parses Guard wire-protocol messages (4-byte length + JSON), records `user_id` / status / latency, then forwards transparently. Emits `request` and `response` SSE events.
- **Coordinator log tail** — background thread reads `/tmp/guard_coord.log` every 150 ms, parses token-bucket levels, emits `tokens` events. Handles log truncation on coordinator restart.
- **Process control** — `POST /control` kills (`SIGKILL`) or reboots (`subprocess.Popen`) any `guard_coord` or `guard_server` found via `ps aux`, then emits `coord_down/up` or `worker_down/up` events.
- **HTTP/SSE server** — `GET /` serves the HTML dashboard; `GET /events` is a persistent SSE stream with an initial `snapshot` and 20 s heartbeats; `GET /stats` returns a JSON stats snapshot.

**CLI flags:** `--listen-port` (9099) · `--target` (127.0.0.1:9100) · `--http-port` (9098) · `--coord-log` · `--capacity`

---

## Visualizer (`visualizer.html`)

- **Phase tabs (1–7)** — each tab shows a different architecture phase (single server → LB → coordinator → Redis → fault tolerance), resetting the canvas layout and hop sequence on switch.
- **Canvas animation** — packet dots travel along request hops (green = allowed, red = rate-limited); red pulses animate on coordinator↔Redis writes; green heartbeat pulses travel from workers to coordinator; yellow rings show in-flight tasks on workers.
- **Simulation mode** — synthetic traffic for alice/bob/carol with adjustable req/s, bucket capacity, and refill rate; simulates fail-closed coordinator, Redis state persistence, and task orphan/reassignment locally.
- **Live mode (Phases 1–4)** — connects to proxy `/events` via `EventSource`; drives all animations from real traffic; shows p50/p95/p99 latency; Kill/Reboot buttons POST to `/control` to act on real processes.
- **Sidebar** — overall stats, per-user token-bucket bars, per-worker counts, coordinator state banner (Phase 5/7), task tracker with progress bars (Phase 6/7), and a rolling request log (last 60 entries).
