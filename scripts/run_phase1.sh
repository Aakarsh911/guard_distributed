#!/usr/bin/env bash
set -euo pipefail

PORT=9090
SIM_MS=5
N_REQUESTS=50
N_THREADS=4
USER_ID="testuser"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

make -j

pkill -f "guard_server $PORT" 2>/dev/null || true
sleep 0.1

LOG="/tmp/guard_server_phase1.log"

echo "--- starting guard_server on port $PORT (sim=${SIM_MS}ms) ---"
"$ROOT/build/guard_server" "$PORT" "$SIM_MS" 2>"$LOG" &
SERVER_PID=$!

cleanup() { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT

sleep 0.3

echo "--- running guard_client ($N_REQUESTS reqs, $N_THREADS threads) ---"
"$ROOT/build/guard_client" 127.0.0.1 "$PORT" "$N_REQUESTS" "$N_THREADS" "$USER_ID" 2>/dev/null

echo ""
echo "--- server log (last 5 lines) ---"
tail -n 5 "$LOG"
