#!/usr/bin/env bash
set -euo pipefail

# Phase 6: MapReduce-style task tracking + fault-tolerant reassignment
#
# Demonstrates coordinator-level task reassignment when a worker dies.
# Requests are sent directly to workers (bypassing LB) so the LB's
# built-in retry doesn't mask the coordinator's reassignment logic.
#
# Flow:
#   1. Start coordinator + 3 workers
#   2. Send 2 requests to each worker (tasks take 2s each)
#   3. Kill worker 1 after 0.5s while its tasks are in-flight
#   4. Coordinator detects dead worker (heartbeat timeout)
#   5. Coordinator reassigns worker 1's orphaned tasks to live workers
#   6. Show the full trace

COORD_PORT=9500
S1_PORT=9511
S2_PORT=9512
S3_PORT=9513
SIM_MS=2000         # 2 seconds per task
RL_CAP=100          # generous limit — rate limiting is not the focus
RL_REFILL=100

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

make -j 2>/dev/null

pkill -f "guard_coord $COORD_PORT" 2>/dev/null || true
pkill -f "guard_server $S1_PORT" 2>/dev/null || true
pkill -f "guard_server $S2_PORT" 2>/dev/null || true
pkill -f "guard_server $S3_PORT" 2>/dev/null || true
sleep 0.3

PIDS=()
S1_PID=""
cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
    exit 0
}
trap cleanup EXIT

COORD_ADDR="127.0.0.1:$COORD_PORT"
COORD_LOG="/tmp/guard_coord6.log"
S1_LOG="/tmp/guard_w1.log"
S2_LOG="/tmp/guard_w2.log"
S3_LOG="/tmp/guard_w3.log"

echo "============================================================"
echo "  Phase 6 — Fault-tolerant task reassignment"
echo "  Workers: sim_ms=${SIM_MS}ms  (slow, keeps tasks in-flight)"
echo "  Deadline: sim_ms + 2000ms = $((SIM_MS + 2000))ms"
echo "  Heartbeat timeout: 2000ms, scanner: every 500ms"
echo "============================================================"
echo ""

# --- start coordinator ---
echo "--- starting coordinator ---"
"$ROOT/build/guard_coord" "$COORD_PORT" "$RL_CAP" "$RL_REFILL" \
    2>"$COORD_LOG" & PIDS+=($!)
sleep 0.3

# --- start 3 workers ---
echo "--- starting 3 workers ---"
"$ROOT/build/guard_server" "$S1_PORT" "$SIM_MS" "$COORD_ADDR" \
    2>"$S1_LOG" & S1_PID=$!; PIDS+=($S1_PID)
"$ROOT/build/guard_server" "$S2_PORT" "$SIM_MS" "$COORD_ADDR" \
    2>"$S2_LOG" & PIDS+=($!)
"$ROOT/build/guard_server" "$S3_PORT" "$SIM_MS" "$COORD_ADDR" \
    2>"$S3_LOG" & PIDS+=($!)
sleep 0.5

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  STEP 1: Send 2 requests directly to EACH worker       ║"
echo "║          (bypassing LB to control routing exactly)      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Send 2 requests to each worker directly — all with user "alice"
# These run concurrently and each task takes 2s
"$ROOT/build/guard_client" 127.0.0.1 "$S1_PORT" 2 2 alice 2>/dev/null &
C1=$!; PIDS+=($C1)
"$ROOT/build/guard_client" 127.0.0.1 "$S2_PORT" 2 2 alice 2>/dev/null &
C2=$!; PIDS+=($C2)
"$ROOT/build/guard_client" 127.0.0.1 "$S3_PORT" 2 2 alice 2>/dev/null &
C3=$!; PIDS+=($C3)

# Wait for tasks to be registered at coordinator
sleep 0.5

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  STEP 2: KILL worker w-${S1_PORT} (tasks are in-flight!)      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Killing PID $S1_PID (w-${S1_PORT})..."
kill -9 "$S1_PID" 2>/dev/null || true
echo "  Worker w-${S1_PORT} is dead. Its heartbeats will stop."
echo ""
echo "  Timeline:"
echo "    +0.0s  tasks started on all 3 workers"
echo "    +0.5s  worker w-${S1_PORT} killed (now)"
echo "    +2.5s  heartbeat timeout (2s since last heartbeat)"
echo "    +4.5s  task deadline expires (sim_ms + 2000ms)"
echo "    +4.5s  scanner detects dead worker + expired tasks"
echo "    +4.5s  coordinator reassigns tasks to live workers"
echo "    +6.5s  reassigned tasks complete (2s work)"
echo ""

# Wait for clients to worker 2 and 3 to finish (they take ~2s)
wait "$C2" 2>/dev/null || true
wait "$C3" 2>/dev/null || true
# Client 1 will error out since worker died
wait "$C1" 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  STEP 3: Waiting for scanner + reassignment...          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Need to wait for:
#   - deadline expiry: ~4s from task start ≈ 3.5s from now
#   - reassigned tasks to execute: +2s
# Wait 7s total from the kill
sleep 7

echo ""
echo "============================================================"
echo "  COORDINATOR LOG"
echo "============================================================"
echo ""

echo "  --- Worker registrations ---"
grep "REGISTER" "$COORD_LOG" 2>/dev/null | while IFS= read -r line; do
    echo "    $line"
done

echo ""
echo "  --- Task lifecycle ---"
echo "  event          task               worker"
echo "  -------------- -----------------  --------"
grep -E "TASK_START|TASK_DONE" "$COORD_LOG" 2>/dev/null \
    | while IFS= read -r line; do
        if echo "$line" | grep -q "TASK_START"; then
            task=$(echo "$line" | grep -o 'task=[^ ]*' | cut -d= -f2)
            wkr=$(echo "$line"  | grep -o 'worker=[^ ]*' | cut -d= -f2)
            printf "  %-14s %-18s %s\n" "TASK_START" "$task" "$wkr"
        elif echo "$line" | grep -q "TASK_DONE"; then
            task=$(echo "$line" | grep -o 'task=[^ ]*' | cut -d= -f2)
            wkr=$(echo "$line"  | grep -o 'worker=[^ ]*' | cut -d= -f2)
            printf "  %-14s %-18s %s\n" "TASK_DONE" "$task" "$wkr"
        fi
    done

echo ""
echo "  --- Reassignment events ---"
REASSIGN_COUNT=$(grep -c "REASSIGNED" "$COORD_LOG" 2>/dev/null || true)
REASSIGN_COUNT=${REASSIGN_COUNT:-0}
if [ "$REASSIGN_COUNT" -gt 0 ] 2>/dev/null; then
    grep "REASSIGNED" "$COORD_LOG" 2>/dev/null | while IFS= read -r line; do
        task=$(echo "$line" | grep -o 'task=[^ ]*' | cut -d= -f2)
        from=$(echo "$line" | grep -o 'from=[^ ]*' | cut -d= -f2)
        to=$(echo "$line"   | grep -o 'to=[^ ]*'   | cut -d= -f2)
        printf "    task=%-14s  %s → %s\n" "$task" "$from" "$to"
    done
else
    echo "    (none)"
fi

echo ""
echo "  --- Worker logs (highlights) ---"
for P in $S1_PORT $S2_PORT $S3_PORT; do
    case $P in
        $S1_PORT) LOG="$S1_LOG" ;;
        $S2_PORT) LOG="$S2_LOG" ;;
        $S3_PORT) LOG="$S3_LOG" ;;
    esac
    echo ""
    echo "    w-${P}:"
    grep -E "REASSIGN|OK|error" "$LOG" 2>/dev/null \
        | head -10 \
        | while IFS= read -r line; do echo "      $line"; done
    if [ "$P" = "$S1_PORT" ]; then
        echo "      *** (killed at +0.5s — tasks orphaned)"
    fi
done

echo ""
echo "============================================================"
echo "  SUMMARY"
echo "============================================================"
TOTAL_STARTS=$(grep -c "TASK_START" "$COORD_LOG" 2>/dev/null || true)
TOTAL_DONE=$(grep -c "TASK_DONE" "$COORD_LOG" 2>/dev/null || true)
TOTAL_REASSIGN=$(grep -c "REASSIGNED" "$COORD_LOG" 2>/dev/null || true)
TOTAL_STARTS=${TOTAL_STARTS:-0}
TOTAL_DONE=${TOTAL_DONE:-0}
TOTAL_REASSIGN=${TOTAL_REASSIGN:-0}

echo "  Tasks started:    $TOTAL_STARTS"
echo "  Tasks completed:  $TOTAL_DONE"
echo "  Tasks reassigned: $TOTAL_REASSIGN"
echo ""
if [ "${TOTAL_REASSIGN:-0}" -gt 0 ] 2>/dev/null; then
    echo "  ✓ Tasks from the dead worker were recovered by live workers."
    echo "    This is the MapReduce-style fault tolerance in action."
else
    echo "  Tasks from w-${S1_PORT} were lost. Check if deadline was"
    echo "  long enough for the scanner to detect and reassign."
fi
echo "============================================================"
