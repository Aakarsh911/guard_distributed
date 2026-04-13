#!/usr/bin/env bash
set -euo pipefail

# Phase 2 demo: rate limiting (now via coordinator since Phase 4)
PORT=9091
COORD_PORT=9291
SIM_MS=5
RL_CAP=5          # bucket capacity: 5 tokens
RL_REFILL=2       # refill rate: 2 tokens/sec
N_REQUESTS=30
N_THREADS=4
USER_ID="testuser"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

make -j

pkill -f "guard_coord $COORD_PORT" 2>/dev/null || true
pkill -f "guard_server $PORT" 2>/dev/null || true
sleep 0.1

PIDS=()
cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap cleanup EXIT

LOG_COORD="/tmp/guard_coord_phase2.log"
LOG_SERVER="/tmp/guard_server_phase2.log"

echo "--- starting coordinator (cap=${RL_CAP}, refill=${RL_REFILL}/s) ---"
"$ROOT/build/guard_coord" "$COORD_PORT" "$RL_CAP" "$RL_REFILL" 2>"$LOG_COORD" &
PIDS+=($!)

sleep 0.2

echo "--- starting server on port $PORT (coord=127.0.0.1:$COORD_PORT) ---"
"$ROOT/build/guard_server" "$PORT" "$SIM_MS" "127.0.0.1:$COORD_PORT" 2>"$LOG_SERVER" &
PIDS+=($!)

sleep 0.3

echo "--- burst: $N_REQUESTS requests from user '$USER_ID' ($N_THREADS threads) ---"
"$ROOT/build/guard_client" 127.0.0.1 "$PORT" "$N_REQUESTS" "$N_THREADS" "$USER_ID" 2>/dev/null || true

echo ""
echo "--- coordinator log (last 5 lines) ---"
tail -n 5 "$LOG_COORD"
