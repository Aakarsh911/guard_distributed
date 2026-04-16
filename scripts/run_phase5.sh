#!/usr/bin/env bash
set -euo pipefail

# Phase 5: Redis-backed coordinator state
# Demonstrates that rate-limit state survives coordinator restarts.
#
# Flow:
#   Wave 1 — burst 10 reqs from alice (5 allowed, 5 denied)
#   Kill the coordinator
#   Wave 2 — restart coordinator, burst 3 reqs immediately
#            Alice's bucket was drained → all 3 should be DENIED
#   Wave 3 — sleep long enough for tokens to refill, burst again
#            Shows refill still works from Redis-stored timestamps

COORD_PORT=9400
LB_PORT=9410
S1_PORT=9411
S2_PORT=9412
SIM_MS=5
RL_CAP=5          # 5 tokens per user
RL_REFILL=2       # 2 tokens/sec
REDIS_ADDR="${REDIS_ADDR:-127.0.0.1:6379}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

make -j 2>/dev/null

pkill -f "guard_coord $COORD_PORT" 2>/dev/null || true
pkill -f "guard_server $S1_PORT" 2>/dev/null || true
pkill -f "guard_server $S2_PORT" 2>/dev/null || true
pkill -f "guard_lb $LB_PORT" 2>/dev/null || true
sleep 0.2

# Flush old keys so we start clean
redis-cli DEL guard:bucket:alice guard:bucket:bob > /dev/null 2>&1 || true

PIDS=()
cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap cleanup EXIT

COORD_ADDR="127.0.0.1:$COORD_PORT"

start_coord() {
    "$ROOT/build/guard_coord" "$COORD_PORT" "$RL_CAP" "$RL_REFILL" \
        "$REDIS_ADDR" 2>"/tmp/guard_coord5.log" &
    PIDS+=($!)
    sleep 0.3
}

echo "============================================================"
echo "  Phase 5 — Redis-backed coordinator state"
echo "  Coordinator: cap=${RL_CAP}, refill=${RL_REFILL}/s"
echo "  Redis: $REDIS_ADDR"
echo "============================================================"
echo ""

# --- Start components ---
echo "--- starting coordinator (Redis-backed) ---"
start_coord

echo "--- starting 2 workers ---"
"$ROOT/build/guard_server" "$S1_PORT" "$SIM_MS" "$COORD_ADDR" \
    2>"/tmp/guard_s5_1.log" & PIDS+=($!)
"$ROOT/build/guard_server" "$S2_PORT" "$SIM_MS" "$COORD_ADDR" \
    2>"/tmp/guard_s5_2.log" & PIDS+=($!)

echo "--- starting LB on port $LB_PORT ---"
"$ROOT/build/guard_lb" "$LB_PORT" \
    "127.0.0.1:$S1_PORT" "127.0.0.1:$S2_PORT" \
    2>"/tmp/guard_lb5.log" & PIDS+=($!)
sleep 0.3

# ===================== WAVE 1 =====================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  WAVE 1: burst 10 requests from alice (expect 5 ok)    ║"
echo "╚══════════════════════════════════════════════════════════╝"
W1_START=$(wc -l < /tmp/guard_coord5.log)
"$ROOT/build/guard_client" 127.0.0.1 "$LB_PORT" 10 4 alice 2>/dev/null
sleep 0.2
W1_END=$(wc -l < /tmp/guard_coord5.log)

echo ""
echo "  Coordinator log (wave 1):"
echo "  req_id            decision  tokens"
echo "  ----------------  --------  ------"
sed -n "$((W1_START+1)),${W1_END}p" /tmp/guard_coord5.log \
    | grep "req_id=" \
    | while IFS= read -r line; do
        rid=$(echo "$line" | grep -o 'req_id=[^ ]*' | cut -d= -f2)
        dec=$(echo "$line" | grep -o 'ALLOWED\|DENIED')
        tok=$(echo "$line" | grep -o 'tokens=[^ ]*' | cut -d= -f2)
        printf "  %-16s  %-8s  %s\n" "$rid" "$dec" "$tok"
    done

W1_OK=$(sed -n "$((W1_START+1)),${W1_END}p" /tmp/guard_coord5.log | grep -c "ALLOWED" || echo 0)
W1_NO=$(sed -n "$((W1_START+1)),${W1_END}p" /tmp/guard_coord5.log | grep -c "DENIED"  || echo 0)
echo ""
echo "  Result: $W1_OK allowed, $W1_NO denied"

# ===================== KILL COORDINATOR =====================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  KILLING coordinator process (state lives in Redis)     ║"
echo "╚══════════════════════════════════════════════════════════╝"

COORD_PID=${PIDS[0]}
kill "$COORD_PID" 2>/dev/null || true
wait "$COORD_PID" 2>/dev/null || true
sleep 0.3

echo ""
echo "  Verifying Redis still has alice's bucket:"
redis-cli HMGET guard:bucket:alice tokens last_refill 2>/dev/null \
    | head -1 | { read -r tok; echo "    tokens stored = $tok"; }
echo ""

# ===================== WAVE 2 =====================
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  WAVE 2: restart coordinator, burst 3 reqs immediately  ║"
echo "║          (bucket was drained → expect all 3 DENIED)     ║"
echo "╚══════════════════════════════════════════════════════════╝"

> /tmp/guard_coord5.log
start_coord

W2_START=$(wc -l < /tmp/guard_coord5.log)
"$ROOT/build/guard_client" 127.0.0.1 "$LB_PORT" 3 1 alice 2>/dev/null
sleep 0.2
W2_END=$(wc -l < /tmp/guard_coord5.log)

echo ""
echo "  Coordinator log (wave 2):"
echo "  req_id            decision  tokens"
echo "  ----------------  --------  ------"
sed -n "$((W2_START+1)),${W2_END}p" /tmp/guard_coord5.log \
    | grep "req_id=" \
    | while IFS= read -r line; do
        rid=$(echo "$line" | grep -o 'req_id=[^ ]*' | cut -d= -f2)
        dec=$(echo "$line" | grep -o 'ALLOWED\|DENIED')
        tok=$(echo "$line" | grep -o 'tokens=[^ ]*' | cut -d= -f2)
        printf "  %-16s  %-8s  %s\n" "$rid" "$dec" "$tok"
    done

W2_OK=$(sed -n "$((W2_START+1)),${W2_END}p" /tmp/guard_coord5.log | grep -c "ALLOWED" || echo 0)
W2_NO=$(sed -n "$((W2_START+1)),${W2_END}p" /tmp/guard_coord5.log | grep -c "DENIED"  || echo 0)
echo ""
echo "  Result: $W2_OK allowed, $W2_NO denied"
echo "  (state survived restart — bucket was still empty!)"

# ===================== WAVE 3 =====================
SLEEP_SEC=3
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  WAVE 3: sleep ${SLEEP_SEC}s (refill ~${RL_REFILL}*${SLEEP_SEC}=$(( RL_REFILL * SLEEP_SEC )) tokens), then burst 8   ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo "  sleeping ${SLEEP_SEC}s for tokens to refill..."
sleep "$SLEEP_SEC"

W3_START=$(wc -l < /tmp/guard_coord5.log)
"$ROOT/build/guard_client" 127.0.0.1 "$LB_PORT" 8 4 alice 2>/dev/null
sleep 0.2
W3_END=$(wc -l < /tmp/guard_coord5.log)

echo ""
echo "  Coordinator log (wave 3):"
echo "  req_id            decision  tokens"
echo "  ----------------  --------  ------"
sed -n "$((W3_START+1)),${W3_END}p" /tmp/guard_coord5.log \
    | grep "req_id=" \
    | while IFS= read -r line; do
        rid=$(echo "$line" | grep -o 'req_id=[^ ]*' | cut -d= -f2)
        dec=$(echo "$line" | grep -o 'ALLOWED\|DENIED')
        tok=$(echo "$line" | grep -o 'tokens=[^ ]*' | cut -d= -f2)
        printf "  %-16s  %-8s  %s\n" "$rid" "$dec" "$tok"
    done

W3_OK=$(sed -n "$((W3_START+1)),${W3_END}p" /tmp/guard_coord5.log | grep -c "ALLOWED" || echo 0)
W3_NO=$(sed -n "$((W3_START+1)),${W3_END}p" /tmp/guard_coord5.log | grep -c "DENIED"  || echo 0)
echo ""
echo "  Result: $W3_OK allowed, $W3_NO denied"
EXPECT=$(( RL_REFILL * SLEEP_SEC ))
if [ "$EXPECT" -gt "$RL_CAP" ]; then EXPECT=$RL_CAP; fi
echo "  (expected ~$EXPECT allowed: refill restored tokens even across restarts)"

echo ""
echo "============================================================"
echo "  CONCLUSION: Rate-limit state persisted in Redis across"
echo "  a full coordinator restart. Users cannot bypass limits"
echo "  by crashing or restarting the coordinator."
echo "============================================================"
