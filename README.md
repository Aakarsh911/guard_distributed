# GUARD — Global User API Rate Defender

Distributed request-processing system for CS4730.

## Phase 1: Single API Server

A single TCP server that accepts length-prefixed JSON requests and
responds after a configurable simulated-work delay. A companion load
generator fires concurrent requests and reports latency percentiles.

### Build

```bash
make          # produces build/guard_server, build/guard_client, build/guard_lb
make clean    # removes build/
```

Requires: g++ with C++17 support, pthreads (Linux/macOS).

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
| `guard_coord` | `[port] [rl_capacity] [rl_refill]` | `9200 10 5` |

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
