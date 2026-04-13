#!/usr/bin/env bash
set -euo pipefail

LB_PORT=9100
S1_PORT=9101
S2_PORT=9102
S3_PORT=9103
SIM_MS=5
N_REQUESTS=60
N_THREADS=6
USER_ID="testuser"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

make -j

pkill -f "guard_server $S1_PORT" 2>/dev/null || true
pkill -f "guard_server $S2_PORT" 2>/dev/null || true
pkill -f "guard_server $S3_PORT" 2>/dev/null || true
pkill -f "guard_lb $LB_PORT" 2>/dev/null || true
sleep 0.1

PIDS=()
cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap cleanup EXIT

echo "--- starting 3 guard_server instances ---"
"$ROOT/build/guard_server" "$S1_PORT" "$SIM_MS" 2>"/tmp/guard_s1.log" & PIDS+=($!)
"$ROOT/build/guard_server" "$S2_PORT" "$SIM_MS" 2>"/tmp/guard_s2.log" & PIDS+=($!)
"$ROOT/build/guard_server" "$S3_PORT" "$SIM_MS" 2>"/tmp/guard_s3.log" & PIDS+=($!)

echo "--- starting guard_lb on port $LB_PORT -> :$S1_PORT :$S2_PORT :$S3_PORT ---"
"$ROOT/build/guard_lb" "$LB_PORT" \
    "127.0.0.1:$S1_PORT" "127.0.0.1:$S2_PORT" "127.0.0.1:$S3_PORT" \
    2>"/tmp/guard_lb.log" & PIDS+=($!)

sleep 0.3

echo "--- running client ($N_REQUESTS reqs, $N_THREADS threads) through LB ---"
"$ROOT/build/guard_client" 127.0.0.1 "$LB_PORT" "$N_REQUESTS" "$N_THREADS" "$USER_ID" 2>/dev/null

echo ""
echo "--- requests per backend ---"
for P in $S1_PORT $S2_PORT $S3_PORT; do
    COUNT=$(grep -c "req_id=" "/tmp/guard_s${P##910}.log" 2>/dev/null || echo 0)
    echo "  :$P  $COUNT requests"
done
