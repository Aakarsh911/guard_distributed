# GUARD — Global User API Rate Defender

Distributed request-processing system for CS4730.

## Phase 1: Single API Server

A single TCP server that accepts length-prefixed JSON requests and
responds after a configurable simulated-work delay. A companion load
generator fires concurrent requests and reports latency percentiles.

### Build

```bash
make          # produces build/guard_server, build/guard_client, build/guard_lb, build/guard_coord
make clean    # removes build/
```

Requires: g++ with C++17 support, pthreads (Linux/macOS),
hiredis (`brew install hiredis` / `apt install libhiredis-dev`).

### Run manually

```bash
# Terminal 1 — start the server (port 8080, 5 ms simulated work)
./build/guard_server 8080 5

# Terminal 2 — fire 100 requests with 4 threads
./build/guard_client 127.0.0.1 8080 100 4 user1
```

### Run the demo script

```bash
bash scripts/run_phase1.sh
```

Starts the server, runs the client, prints a summary, and tears down
the server automatically.

### Wire protocol

Every message on the wire is:

    [4 bytes: big-endian uint32 payload length N] [N bytes: JSON payload]

**Request:**
```json
{"type":"request","user_id":"alice","req_id":"alice-0","payload":"hello"}
```

**Response:**
```json
{"type":"response","req_id":"alice-0","status":"ok","body":"processed"}
```

### CLI reference

| Binary | Args | Default |
|--------|------|---------|
| `guard_server` | `[port] [sim_ms] [coord_host:port]` | `8080 5` (no coord) |
| `guard_client` | `[host] [port] [n_requests] [n_threads] [user_id]` | `127.0.0.1 8080 100 4 user1` |
| `guard_lb` | `<port> <backend:port> [backend:port ...]` | (required) |
| `guard_coord` | `[port] [rl_capacity] [rl_refill] [redis_host:port]` | `9200 10 5` (in-memory) |

## Phase 2: Rate Limiting

Adds a token-bucket rate limiter keyed by `user_id`. Each user gets a
bucket with a fixed capacity that refills at a steady rate. Requests
that arrive when the bucket is empty receive `"status":"rate_limited"`
instead of being processed.

As of Phase 4, rate limiting is centralized in the coordinator. The
server delegates every check to `guard_coord` via a TCP round-trip.

```bash
./build/guard_coord 9200 10 5      # 10-token bucket, 5 tokens/sec
./build/guard_server 8080 5 127.0.0.1:9200
```

**Rate-limited response:**
```json
{"type":"response","req_id":"alice-7","status":"rate_limited","body":"rate limit exceeded"}
```

### Run the Phase 2 demo

```bash
bash scripts/run_phase2.sh
```

Starts a coordinator with a tight 5-token / 2-per-sec limit, a server
pointing to it, fires a burst of 30 requests, and shows how many get
through vs. rate-limited.

## Phase 3: Load Balancer + Multiple Servers

Introduces `guard_lb`, a stateless round-robin load balancer. The
client connects to the LB, which fans each request out to one of N
backend `guard_server` instances. If a backend is unreachable, the LB
retries on the next backend in the pool before returning an error.

```
client -> guard_lb -> guard_server :9101
                   -> guard_server :9102
                   -> guard_server :9103
```

```bash
# Start 3 servers + 1 LB
./build/guard_server 9101 5 &
./build/guard_server 9102 5 &
./build/guard_server 9103 5 &
./build/guard_lb 9100 127.0.0.1:9101 127.0.0.1:9102 127.0.0.1:9103 &

# Client talks to the LB
./build/guard_client 127.0.0.1 9100 60 6 user1
```

### Run the Phase 3 demo

```bash
bash scripts/run_phase3.sh
```

Starts 3 backend servers, an LB, fires 60 requests, and prints a
per-backend breakdown showing even distribution.

## Phase 4: Central Coordinator for System-Wide Rate Limits

Introduces `guard_coord`, a dedicated coordinator process that holds
the rate limiter. Workers no longer rate-limit locally — on every
request they make a TCP round-trip to the coordinator to ask
"is this user allowed?" This gives a single, system-wide view of
each user's request rate, regardless of which worker handles the
request.

```
client -> LB -> worker ──rate_check──> coordinator
                  |                        |
                  |<────allowed/denied──────|
                  |
           allow: process + respond "ok"
           deny:  respond "rate_limited"
```

The coordinator is **fail-closed**: if a worker can't reach it, the
request is rejected rather than allowed through unmetered.

```bash
./build/guard_coord 9200 10 2 &
./build/guard_server 9101 5 127.0.0.1:9200 &
./build/guard_server 9102 5 127.0.0.1:9200 &
./build/guard_lb 9100 127.0.0.1:9101 127.0.0.1:9102 &
./build/guard_client 127.0.0.1 9100 40 6 user1
```

### Run the Phase 4 demo

```bash
bash scripts/run_phase4.sh
```

Starts a coordinator (10-token / 2-per-sec), 3 workers, an LB, fires
40 requests in a burst, and shows the coordinator's allowed/denied
breakdown proving the limit is enforced globally across all workers.

## Phase 5: Redis-Backed Coordinator State

Adds an optional Redis backend to `guard_coord`. When enabled, all
token-bucket state is stored in Redis via an atomic Lua script, so
rate-limit state **survives coordinator restarts**. Without this, a
coordinator crash would reset every user's bucket to full, letting
them bypass their limit.

```
client -> LB -> worker ──rate_check──> coordinator ──EVALSHA──> Redis
```

The coordinator accepts an optional 4th argument `redis_host:port`.
When omitted, it uses in-memory storage (backward-compatible with
Phase 4).

```bash
# In-memory (Phase 4 behavior)
./build/guard_coord 9200 10 5

# Redis-backed (Phase 5)
./build/guard_coord 9200 10 5 127.0.0.1:6379
```

Requires: Redis server running, `hiredis` library installed
(`brew install hiredis` / `apt install libhiredis-dev`).

### Run the Phase 5 demo

```bash
bash scripts/run_phase5.sh
```

Demonstrates state survival across a coordinator restart in 3 waves:
1. Burst 10 requests → 5 allowed, 5 denied (drains the bucket)
2. Kill coordinator, restart it, burst 3 immediately → all denied
   (bucket was still empty in Redis)
3. Sleep 3 s for refill, burst 8 → ~5 allowed (refill works from
   Redis-stored timestamps)

## Phase 6: MapReduce-Style Task Tracking + Fault-Tolerant Reassignment

Adds task lifecycle tracking, worker heartbeats, and automatic
reassignment of orphaned tasks — the same pattern the Google
MapReduce paper uses for worker failures.

```
client -> LB -> worker ──rate_check──> coordinator
                  |                        |
                  |<────allowed────────────|
                  |                        |
                  |──task_start───────────>|  (register in-flight task)
                  |     ... work ...       |
                  |──task_done────────────>|  (mark complete)
                  |                        |
                  |  ♥ heartbeat (500ms) ──>|  (liveness signal)

    worker crashes → heartbeat stops
                                coordinator detects:
                                  - task deadline expired
                                  - worker heartbeat timeout
                                coordinator ──reassign──> live worker
                                                |  ... work ...
                                                |──task_done──> coordinator
```

### New coordinator message types

| Message | Direction | Purpose |
|---------|-----------|---------|
| `worker_register` | worker → coord | Register worker address for reassignment |
| `heartbeat` | worker → coord | Periodic liveness signal (every 500 ms) |
| `task_start` | worker → coord | Register in-flight task with deadline |
| `task_done` | worker → coord | Mark task as completed |
| `reassign` | coord → worker | Push orphaned task to a live worker |

### How reassignment works

1. Worker registers a task with `task_start` (includes `task_id`,
   `worker_id`, `user_id`, `payload`, `deadline_ms`)
2. Worker sends heartbeats every 500 ms
3. If a worker dies, heartbeats stop
4. Coordinator's scanner thread (runs every 500 ms) checks for tasks
   where: deadline has expired AND worker's heartbeat has timed out
5. Coordinator connects to a live worker and sends `reassign`
6. Live worker executes the task and reports `task_done`

### Run the Phase 6 demo

```bash
bash scripts/run_phase6.sh
```

Starts 3 workers with slow tasks (2 s each), sends requests directly
to each worker, kills one mid-task, and shows the coordinator
detecting the dead worker and reassigning its orphaned tasks to a
live worker.
