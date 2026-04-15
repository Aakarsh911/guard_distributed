# GUARD — Run Instructions

## Prerequisites

```bash
make -j                  # builds all four binaries into build/
```

| Binary | Role |
|--------|------|
| `build/guard_server` | Worker — processes requests, enforces rate limits |
| `build/guard_coord` | Coordinator — single source of truth for token buckets |
| `build/guard_lb` | Load balancer — round-robin proxy to workers |
| `build/guard_client` | Load generator — fires N requests across T threads |

Phase 5 also requires a running Redis instance:
```bash
brew install redis && brew services start redis   # macOS
```

---

## Running with the live visualizer

`sim-proxy` wraps any phase script so that client traffic is intercepted by the proxy and streamed live to the browser visualizer.

```bash
./sim-proxy ./scripts/run_phase4.sh
```

This will:
1. Build the project
2. Start `proxy.py` on `127.0.0.1:9099` (client-facing) → `127.0.0.1:<backend-port>`
3. Open `http://127.0.0.1:9098/` in your browser
4. Run the phase script — servers and coordinator start normally; only `guard_client` is rerouted through the proxy
5. Restore everything and shut down the proxy when the script exits

In the browser, click **Live** → **Connect** to see real packets, stats, and token bucket levels update as requests flow through the system.

---

## Phase-by-phase reference

### Phase 1 — Single server, no rate limiting

**Demonstrates:** baseline throughput with no restrictions. Every request is accepted.

```bash
# Standalone
./scripts/run_phase1.sh

# With visualizer
./sim-proxy ./scripts/run_phase1.sh
```

**Topology:** `guard_client → guard_server:9090`

**Key parameters** (edit the script to change):
| Variable | Default | Meaning |
|----------|---------|---------|
| `PORT` | 9090 | Server listen port |
| `N_REQUESTS` | 50 | Requests per client run |
| `N_THREADS` | 4 | Concurrent client threads |
| `SIM_MS` | 5 | Simulated processing time (ms) |

**Expected output:**
```
--- starting guard_server on port 9090 (sim=5ms) ---
--- running guard_client (50 reqs, 4 threads) ---
sent=50  ok=50  rate_limited=0  errors=0
p50=6µs  p99=12µs
```

---

### Phase 2 — Single server with rate limiting

**Demonstrates:** per-user token bucket enforced by the coordinator. All traffic flows through one server so limits are accurate.

```bash
./scripts/run_phase2.sh
./sim-proxy ./scripts/run_phase2.sh
```

**Topology:** `guard_client → guard_server:9091 ↔ guard_coord:9291`

**Key parameters:**
| Variable | Default | Meaning |
|----------|---------|---------|
| `PORT` | 9091 | Server port |
| `COORD_PORT` | 9291 | Coordinator port |
| `RL_CAP` | 5 | Token bucket capacity |
| `RL_REFILL` | 2 | Tokens refilled per second |
| `N_REQUESTS` | 30 | Requests fired in a burst |

**Expected output:**
```
--- burst: 30 requests from user 'testuser' (4 threads) ---
sent=30  ok=5  rate_limited=25  errors=0

--- coordinator log (last 5 lines) ---
[coord] user=testuser req_id=testuser-4 ALLOWED tokens=0.00
[coord] user=testuser req_id=testuser-5 DENIED  tokens=0.00
```

With a capacity of 5, the first 5 requests consume the full bucket; the remaining 25 are denied.

---

### Phase 3 — Load balancer, local rate limiting (the broken case)

**Demonstrates:** why per-server rate limiting fails at scale. With 3 workers each enforcing their own bucket, a single user can consume up to 3× their intended quota.

```bash
./scripts/run_phase3.sh
./sim-proxy ./scripts/run_phase3.sh
```

**Topology:** `guard_client → guard_lb:9100 → guard_server:{9101,9102,9103}`

**Key parameters:**
| Variable | Default | Meaning |
|----------|---------|---------|
| `LB_PORT` | 9100 | Load balancer port |
| `S1/S2/S3_PORT` | 9101–9103 | Worker ports |
| `N_REQUESTS` | 60 | Total requests from client |
| `N_THREADS` | 6 | Concurrent threads |

**Expected output:**
```
--- requests per backend ---
  :9101  20 requests
  :9102  20 requests
  :9103  20 requests
```

Round-robin distributes evenly. If each worker has a per-user bucket of 5, the user effectively gets 15 requests allowed instead of 5. This is the flaw Phase 4 fixes.

---

### Phase 4 — Central coordinator (correct global rate limiting)

**Demonstrates:** the coordinator as the single source of truth. Every worker checks with the coordinator before processing, so the rate limit is enforced system-wide regardless of how many workers exist.

```bash
./scripts/run_phase4.sh
./sim-proxy ./scripts/run_phase4.sh
```

**Topology:** `guard_client → guard_lb:9100 → guard_server:{9101,9102,9103} ↔ guard_coord:9200`

**Key parameters:**
| Variable | Default | Meaning |
|----------|---------|---------|
| `COORD_PORT` | 9200 | Coordinator port |
| `LB_PORT` | 9100 | Load balancer port |
| `RL_CAP` | 5 | Tokens per user (shared across all workers) |
| `RL_REFILL` | 1 | Tokens/sec |
| `N_REQUESTS` | 15 | Requests per user |

**Expected output:**
```
--- burst: 15 reqs each from 'alice' and 'bob' (concurrent) ---

=== Summary ===
  alice: 5 allowed, 10 denied
  bob:   5 allowed, 10 denied

  :9101 handled 10 requests
  :9102 handled 10 requests
  :9103 handled 10 requests
```

Both users are capped at 5 regardless of which worker each request lands on.

---

### Phase 4 refill — Token refill across timed waves

**Demonstrates:** how the token bucket refills between bursts. Five waves with different sleep gaps show that allowed count tracks the refill rate exactly.

```bash
./scripts/run_phase4_refill.sh
./sim-proxy ./scripts/run_phase4_refill.sh
```

**Topology:** same as Phase 4 (`LB_PORT=9400`, `COORD_PORT=9300`)

**Wave schedule** (`cap=5`, `refill=2/s`):

| Wave | Sleep before | Tokens available | Expected ok |
|------|-------------|-----------------|-------------|
| 1 | — | 5 (full) | 5 |
| 2 | 1s | +2 → 2 | 2 |
| 3 | 2s | +4 → 5 (capped) | 5 |
| 4 | 0.5s | +1 → 1 | 1 |
| 5 | 3s | +6 → 5 (capped) | 5 |

**Expected output:**
```
=== Per-user per-wave summary ===

  user    wave1         wave2         wave3         wave4         wave5
  ------  ------------- ------------- ------------- ------------- -------------
  alice   5ok / 3deny   2ok / 6deny   5ok / 3deny   1ok / 7deny   5ok / 3deny
  bob     5ok / 3deny   2ok / 6deny   5ok / 3deny   1ok / 7deny   5ok / 3deny
```

---

### Phase 5 — Redis-backed coordinator (persistent state)

**Demonstrates:** rate-limit state surviving a coordinator crash. Token counts are stored in Redis so a restarted coordinator picks up exactly where the old one left off — users cannot reset their quota by crashing the coordinator.

**Requires:** Redis running on `127.0.0.1:6379`.

```bash
./scripts/run_phase5.sh
./sim-proxy ./scripts/run_phase5.sh
```

**Topology:** `guard_client → guard_lb:9410 → guard_server:{9411,9412} ↔ guard_coord:9400 ↔ redis:6379`

**Key parameters:**
| Variable | Default | Meaning |
|----------|---------|---------|
| `RL_CAP` | 5 | Bucket capacity |
| `RL_REFILL` | 2 | Tokens/sec |
| `REDIS_ADDR` | `127.0.0.1:6379` | Redis address |

**What the script does:**

1. **Wave 1** — burst 10 requests from alice. Bucket drains: 5 allowed, 5 denied.
2. **Kill the coordinator** mid-run.
3. Verify Redis still holds alice's bucket state: `redis-cli HMGET guard:bucket:alice tokens last_refill`.
4. **Wave 2** — restart coordinator, burst 3 requests immediately. Bucket is still empty → all 3 denied.
5. **Wave 3** — sleep 3s (refill ~6 tokens, capped at 5), burst 8. Should see ~5 allowed.

**Expected output:**
```
╔══════════════════════════════════════════════════════════╗
║  WAVE 2: restart coordinator, burst 3 reqs immediately  ║
║          (bucket was drained → expect all 3 DENIED)     ║
╚══════════════════════════════════════════════════════════╝

  Result: 0 allowed, 3 denied
  (state survived restart — bucket was still empty!)
```

---

### Phase 6 — Fault-tolerant task reassignment

**Demonstrates:** coordinator-level task recovery when a worker dies mid-execution. The coordinator tracks in-flight tasks with deadlines; when a worker's heartbeat times out, orphaned tasks are reassigned to live workers.

```bash
./scripts/run_phase6.sh
./sim-proxy ./scripts/run_phase6.sh
```

**Topology:** `guard_client → guard_server:{9511,9512,9513} ↔ guard_coord:9500`  
(no load balancer — clients connect directly to each worker to control routing exactly)

**Key parameters:**
| Variable | Default | Meaning |
|----------|---------|---------|
| `SIM_MS` | 2000 | Task duration (ms) — kept long so tasks are in-flight when worker dies |
| `RL_CAP` | 100 | Generous limit — rate limiting is not the focus here |

**Timeline:**
```
+0.0s  2 tasks sent to each of w-9511, w-9512, w-9513 (6 total)
+0.5s  w-9511 killed (SIGKILL)
+2.5s  heartbeat timeout (2s since last heartbeat from w-9511)
+4.5s  task deadline expires; scanner detects dead worker
+4.5s  coordinator reassigns w-9511's 2 tasks to live workers
+6.5s  reassigned tasks complete
```

**Expected output:**
```
  --- Task lifecycle ---
  event          task               worker
  -------------- -----------------  --------
  TASK_START     w-9511/alice-0     w-9511
  TASK_START     w-9511/alice-1     w-9511
  TASK_DONE      w-9512/alice-0     w-9512
  TASK_DONE      w-9513/alice-0     w-9513
  TASK_DONE      w-9512/alice-0     w-9512   ← reassigned from w-9511
  TASK_DONE      w-9512/alice-1     w-9512   ← reassigned from w-9511

  --- Reassignment events ---
    task=w-9511/alice-0   w-9511 → w-9512
    task=w-9511/alice-1   w-9511 → w-9513

  Tasks started:    6
  Tasks completed:  6
  Tasks reassigned: 2
```

All 6 tasks complete even though one worker was killed mid-execution.

---

## Running without the visualizer

Every phase script is self-contained and can be run directly:

```bash
bash ./scripts/run_phase4.sh
```

Logs are written to `/tmp/`:
| File | Contents |
|------|---------|
| `/tmp/guard_coord.log` | Coordinator decisions (ALLOWED/DENIED, token counts) |
| `/tmp/guard_s1.log` | Worker :9101 request trace |
| `/tmp/guard_lb.log` | Load balancer connection events |

## Running guard_client manually

```bash
# args: <host> <port> <n_requests> <n_threads> <user_id>
./build/guard_client 127.0.0.1 9100 50 4 alice
```

To send traffic through the proxy instead (when proxy.py is already running):
```bash
./build/guard_client 127.0.0.1 9099 50 4 alice
```
