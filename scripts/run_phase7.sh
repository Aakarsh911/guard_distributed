#!/usr/bin/env bash
set -euo pipefail

# Phase 7: Full system — Redis-backed coordinator + fault-tolerant task reassignment
#
# Combines Phase 5 and Phase 6 into a single demo:
#
#   ACT 1 — Normal operation: rate limiting enforced globally across 3 workers
#   ACT 2 — Worker fault: kill a worker mid-task; coordinator detects via heartbeat
#            timeout and reassigns its orphaned tasks to live workers
#   ACT 3 — Coordinator fault: kill the coordinator; restart it pointing at Redis;
#            show that the drained bucket survived the restart (users still denied)
#
# Topology:
#   guard_client → guard_lb:9610 → guard_server:{9611,9612,9613}
#                                        ↕  rate_check / heartbeat / task lifecycle
#                                   guard_coord:9600 ↔ Redis:6379

COORD_PORT=9600
LB_PORT=9610
S1_PORT=9611
S2_PORT=9612
S3_PORT=9613
FAST_MS=5       # normal request processing time
SLOW_MS=2000    # slow tasks — keeps them in-flight long enough to kill a worker
RL_CAP=5        # tight bucket so rate limiting is clearly visible
RL_REFILL=2     # 2 tokens/sec
REDIS_ADDR="127.0.0.1:6379"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

make -j 2>/dev/null

# Kill any leftover processes from a previous run
pkill -f "guard_coord $COORD_PORT" 2>/dev/null || true
pkill -f "guard_server $S1_PORT"   2>/dev/null || true
pkill -f "guard_server $S2_PORT"   2>/dev/null || true
pkill -f "guard_server $S3_PORT"   2>/dev/null || true
pkill -f "guard_lb $LB_PORT"       2>/dev/null || true
sleep 0.3

# Flush Redis keys from prior runs so we start with full buckets
redis-cli DEL guard:bucket:alice guard:bucket:bob guard:bucket:carol \
    > /dev/null 2>&1 || true

PIDS=()
S1_PID=""
COORD_PID=""

COORD_LOG="/tmp/guard_coord7.log"
S1_LOG="/tmp/guard_w7_1.log"
S2_LOG="/tmp/guard_w7_2.log"
S3_LOG="/tmp/guard_w7_3.log"
LB_LOG="/tmp/guard_lb7.log"

COORD_ADDR="127.0.0.1:$COORD_PORT"

cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
    exit 0
}
trap cleanup EXIT

start_coord() {
    > "$COORD_LOG"
    "$ROOT/build/guard_coord" "$COORD_PORT" "$RL_CAP" "$RL_REFILL" \
        "$REDIS_ADDR" 2>"$COORD_LOG" &
    COORD_PID=$!
    PIDS+=($COORD_PID)
    sleep 0.3
}

echo "============================================================"
echo "  Phase 7 — Full system"
echo "  Redis: $REDIS_ADDR"
echo "  Coordinator: cap=${RL_CAP}, refill=${RL_REFILL}/s"
echo "  Workers: fast=${FAST_MS}ms  slow=${SLOW_MS}ms"
echo "  HB timeout: 2000ms  scanner: 500ms"
echo "============================================================"
echo ""

# ── Start everything ──────────────────────────────────────────────────────────
echo "--- starting Redis-backed coordinator ---"
start_coord

echo "--- starting 3 workers (fast mode) ---"
"$ROOT/build/guard_server" "$S1_PORT" "$FAST_MS" "$COORD_ADDR" \
    2>"$S1_LOG" & S1_PID=$!; PIDS+=($S1_PID)
"$ROOT/build/guard_server" "$S2_PORT" "$FAST_MS" "$COORD_ADDR" \
    2>"$S2_LOG" & PIDS+=($!)
"$ROOT/build/guard_server" "$S3_PORT" "$FAST_MS" "$COORD_ADDR" \
    2>"$S3_LOG" & PIDS+=($!)

echo "--- starting LB on port $LB_PORT ---"
"$ROOT/build/guard_lb" "$LB_PORT" \
    "127.0.0.1:$S1_PORT" "127.0.0.1:$S2_PORT" "127.0.0.1:$S3_PORT" \
    2>"$LB_LOG" & PIDS+=($!)
sleep 0.5

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ACT 1: Normal operation — global rate limiting         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Bursting 12 requests from alice and bob concurrently."
echo "  Bucket cap=${RL_CAP} → expect 5 allowed, 7 denied per user."
echo ""

A1_START=$(wc -l < "$COORD_LOG")

"$ROOT/build/guard_client" 127.0.0.1 "$LB_PORT" 12 4 alice 2>/dev/null &
C_ALICE=$!
"$ROOT/build/guard_client" 127.0.0.1 "$LB_PORT" 12 4 bob   2>/dev/null &
C_BOB=$!
wait "$C_ALICE" "$C_BOB"
sleep 0.2

A1_END=$(wc -l < "$COORD_LOG")

echo "  Coordinator log:"
echo "  user    decision  tokens"
echo "  ------  --------  ------"
sed -n "$((A1_START+1)),${A1_END}p" "$COORD_LOG" \
    | grep "req_id=" \
    | while IFS= read -r line; do
        usr=$(echo "$line" | grep -o 'user=[^ ]*'   | cut -d= -f2)
        dec=$(echo "$line" | grep -o 'ALLOWED\|DENIED')
        tok=$(echo "$line" | grep -o 'tokens=[^ ]*' | cut -d= -f2)
        printf "  %-6s  %-8s  %s\n" "$usr" "$dec" "$tok"
    done

ALICE_OK=$(sed -n "$((A1_START+1)),${A1_END}p" "$COORD_LOG" | grep "user=alice" | grep -c "ALLOWED" || true)
ALICE_NO=$(sed -n "$((A1_START+1)),${A1_END}p" "$COORD_LOG" | grep "user=alice" | grep -c "DENIED"  || true)
BOB_OK=$(  sed -n "$((A1_START+1)),${A1_END}p" "$COORD_LOG" | grep "user=bob"   | grep -c "ALLOWED" || true)
BOB_NO=$(  sed -n "$((A1_START+1)),${A1_END}p" "$COORD_LOG" | grep "user=bob"   | grep -c "DENIED"  || true)
echo ""
echo "  Result: alice ${ALICE_OK}ok/${ALICE_NO}denied  bob ${BOB_OK}ok/${BOB_NO}denied"
echo "  (single coordinator enforces the cap across all 3 workers)"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ACT 2: Worker fault — task reassignment                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Restarting workers in SLOW mode (${SLOW_MS}ms/task) so tasks"
echo "  stay in-flight long enough to kill one mid-execution."
echo ""

# Kill the fast workers and bring up slow ones
kill "$S1_PID" 2>/dev/null || true
for p in "${PIDS[@]:1:3}"; do kill "$p" 2>/dev/null || true; done
sleep 0.3

# Remove old worker PIDs from the array (keep coord and lb)
PIDS=("${PIDS[0]}" "${PIDS[4]}")  # coord + lb

"$ROOT/build/guard_server" "$S1_PORT" "$SLOW_MS" "$COORD_ADDR" \
    2>"$S1_LOG" & S1_PID=$!; PIDS+=($S1_PID)
"$ROOT/build/guard_server" "$S2_PORT" "$SLOW_MS" "$COORD_ADDR" \
    2>"$S2_LOG" & PIDS+=($!)
"$ROOT/build/guard_server" "$S3_PORT" "$SLOW_MS" "$COORD_ADDR" \
    2>"$S3_LOG" & PIDS+=($!)
sleep 0.5

# Refill tokens so requests get through
echo "  Sleeping 3s for token buckets to refill..."
sleep 3

A2_COORD_START=$(wc -l < "$COORD_LOG")

echo "  Sending 2 slow tasks directly to each worker..."
"$ROOT/build/guard_client" 127.0.0.1 "$S1_PORT" 2 2 alice 2>/dev/null &
C1=$!; PIDS+=($C1)
"$ROOT/build/guard_client" 127.0.0.1 "$S2_PORT" 2 2 alice 2>/dev/null &
C2=$!; PIDS+=($C2)
"$ROOT/build/guard_client" 127.0.0.1 "$S3_PORT" 2 2 alice 2>/dev/null &
C3=$!; PIDS+=($C3)

sleep 0.5

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Killing worker w-${S1_PORT} while its tasks are in-flight     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
kill -9 "$S1_PID" 2>/dev/null || true
echo "  w-${S1_PORT} killed. Heartbeats will stop."
echo "  Timeline:"
echo "    now      w-${S1_PORT} dead"
echo "    +2s      heartbeat timeout"
echo "    +4s      task deadline expires → scanner reassigns"
echo "    +6s      reassigned tasks complete"
echo ""

wait "$C2" 2>/dev/null || true
wait "$C3" 2>/dev/null || true
wait "$C1" 2>/dev/null || true

sleep 7  # wait for scanner + reassigned task execution

A2_COORD_END=$(wc -l < "$COORD_LOG")

echo "  Task lifecycle:"
echo "  event          task                worker"
echo "  -------------- ------------------  ----------"
sed -n "$((A2_COORD_START+1)),${A2_COORD_END}p" "$COORD_LOG" \
    | grep -E "TASK_START|TASK_DONE|REASSIGNED" \
    | while IFS= read -r line; do
        if echo "$line" | grep -q "TASK_START"; then
            task=$(echo "$line" | grep -o 'task=[^ ]*'   | cut -d= -f2)
            wkr=$( echo "$line" | grep -o 'worker=[^ ]*' | cut -d= -f2)
            printf "  %-14s %-18s %s\n" "TASK_START" "$task" "$wkr"
        elif echo "$line" | grep -q "TASK_DONE"; then
            task=$(echo "$line" | grep -o 'task=[^ ]*'   | cut -d= -f2)
            wkr=$( echo "$line" | grep -o 'worker=[^ ]*' | cut -d= -f2)
            printf "  %-14s %-18s %s\n" "TASK_DONE" "$task" "$wkr"
        elif echo "$line" | grep -q "REASSIGNED"; then
            task=$(echo "$line" | grep -o 'task=[^ ]*' | cut -d= -f2)
            from=$(echo "$line" | grep -o 'from=[^ ]*' | cut -d= -f2)
            to=$(  echo "$line" | grep -o 'to=[^ ]*'   | cut -d= -f2)
            printf "  %-14s %-18s %s → %s  ← REASSIGNED\n" "" "$task" "$from" "$to"
        fi
    done

TOTAL_REASSIGN=$(grep -c "REASSIGNED" "$COORD_LOG" 2>/dev/null || true)
echo ""
echo "  Tasks reassigned: ${TOTAL_REASSIGN:-0}"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ACT 3: Coordinator fault — Redis state survives        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Drain alice's bucket first (if it refilled during act 2)
echo "  Draining alice's bucket before the kill..."
"$ROOT/build/guard_client" 127.0.0.1 "$LB_PORT" 10 4 alice 2>/dev/null || true
sleep 0.2

# Show Redis state before kill
echo ""
echo "  Redis bucket state (before kill):"
redis-cli HMGET guard:bucket:alice tokens last_refill 2>/dev/null \
    | head -1 | { read -r tok; echo "    guard:bucket:alice tokens = ${tok:-n/a}"; }
echo ""

echo "  Killing coordinator (PID $COORD_PID)..."
kill "$COORD_PID" 2>/dev/null || true
wait "$COORD_PID" 2>/dev/null || true
# Remove coord from PIDS so cleanup doesn't re-kill it
PIDS=("${PIDS[@]/$COORD_PID}")
sleep 0.3

echo "  Redis bucket state (after kill — still there):"
redis-cli HMGET guard:bucket:alice tokens last_refill 2>/dev/null \
    | head -1 | { read -r tok; echo "    guard:bucket:alice tokens = ${tok:-n/a}"; }
echo ""

echo "  Restarting coordinator (still pointing at Redis)..."
> "$COORD_LOG"
"$ROOT/build/guard_coord" "$COORD_PORT" "$RL_CAP" "$RL_REFILL" \
    "$REDIS_ADDR" 2>"$COORD_LOG" &
COORD_PID=$!
PIDS+=($COORD_PID)
sleep 0.3

echo ""
echo "  Bursting 3 requests from alice immediately after restart..."
A3_START=$(wc -l < "$COORD_LOG")
"$ROOT/build/guard_client" 127.0.0.1 "$LB_PORT" 3 1 alice 2>/dev/null
sleep 0.2
A3_END=$(wc -l < "$COORD_LOG")

A3_OK=$(sed -n "$((A3_START+1)),${A3_END}p" "$COORD_LOG" | grep -c "ALLOWED" || true)
A3_NO=$(sed -n "$((A3_START+1)),${A3_END}p" "$COORD_LOG" | grep -c "DENIED"  || true)
echo "  Result: ${A3_OK} allowed, ${A3_NO} denied"
echo "  (bucket was still empty in Redis — state survived the restart)"

SLEEP_SEC=3
echo ""
echo "  Sleeping ${SLEEP_SEC}s for tokens to refill via Redis timestamps..."
sleep "$SLEEP_SEC"

A4_START=$(wc -l < "$COORD_LOG")
"$ROOT/build/guard_client" 127.0.0.1 "$LB_PORT" 8 4 alice 2>/dev/null
sleep 0.2
A4_END=$(wc -l < "$COORD_LOG")

A4_OK=$(sed -n "$((A4_START+1)),${A4_END}p" "$COORD_LOG" | grep -c "ALLOWED" || true)
A4_NO=$(sed -n "$((A4_START+1)),${A4_END}p" "$COORD_LOG" | grep -c "DENIED"  || true)
EXPECT=$(( RL_REFILL * SLEEP_SEC ))
[ "$EXPECT" -gt "$RL_CAP" ] && EXPECT=$RL_CAP
echo "  Result: ${A4_OK} allowed, ${A4_NO} denied  (expected ~${EXPECT} allowed after refill)"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "============================================================"
echo "  SUMMARY"
echo "============================================================"
TOTAL_STARTS=$( grep -c "TASK_START"  "$COORD_LOG" 2>/dev/null || true)
TOTAL_DONE=$(   grep -c "TASK_DONE"   "$COORD_LOG" 2>/dev/null || true)
echo "  ACT 1  Global rate limiting    alice ${ALICE_OK}ok/${ALICE_NO}denied  bob ${BOB_OK}ok/${BOB_NO}denied"
echo "  ACT 2  Worker fault recovery   ${TOTAL_REASSIGN:-0} task(s) reassigned after w-${S1_PORT} died"
echo "  ACT 3  Coordinator fault       bucket survived restart (${A3_NO} denied immediately, ~${A4_OK} after refill)"
echo ""
echo "  Both fault-tolerance mechanisms active simultaneously."
echo "  This is the production-grade GUARD configuration."
echo "============================================================"

# ── Continuous traffic ────────────────────────────────────────────────────────
echo ""
echo "  System is live. Sending continuous traffic — Ctrl-C to stop."
echo ""

USERS=(alice bob carol)
while true; do
    USER=${USERS[$((RANDOM % ${#USERS[@]}))]}
    "$ROOT/build/guard_client" 127.0.0.1 "$LB_PORT" 3 1 "$USER" 2>/dev/null || true
    sleep 0.5
done
