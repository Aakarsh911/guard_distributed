#!/usr/bin/env bash
set -euo pipefail

COORD_PORT=9200
LB_PORT=9100
S1_PORT=9101
S2_PORT=9102
S3_PORT=9103
SIM_MS=5
RL_CAP=5          # 5 tokens per user
RL_REFILL=1       # 1 token/sec
N_REQUESTS=15
N_THREADS=4

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

make -j

# Kill any leftover guard processes from previous runs
pkill -f "guard_coord $COORD_PORT" 2>/dev/null || true
pkill -f "guard_server $S1_PORT" 2>/dev/null || true
pkill -f "guard_server $S2_PORT" 2>/dev/null || true
pkill -f "guard_server $S3_PORT" 2>/dev/null || true
pkill -f "guard_lb $LB_PORT" 2>/dev/null || true
sleep 0.2

PIDS=()
cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap cleanup EXIT

COORD_ADDR="127.0.0.1:$COORD_PORT"

echo "--- starting coordinator (cap=${RL_CAP}/user, refill=${RL_REFILL}/s) ---"
"$ROOT/build/guard_coord" "$COORD_PORT" "$RL_CAP" "$RL_REFILL" \
    2>"/tmp/guard_coord.log" & PIDS+=($!)
sleep 0.2

echo "--- starting 3 workers (all pointing to coordinator) ---"
"$ROOT/build/guard_server" "$S1_PORT" "$SIM_MS" "$COORD_ADDR" \
    2>"/tmp/guard_s1.log" & PIDS+=($!)
"$ROOT/build/guard_server" "$S2_PORT" "$SIM_MS" "$COORD_ADDR" \
    2>"/tmp/guard_s2.log" & PIDS+=($!)
"$ROOT/build/guard_server" "$S3_PORT" "$SIM_MS" "$COORD_ADDR" \
    2>"/tmp/guard_s3.log" & PIDS+=($!)

echo "--- starting LB on port $LB_PORT ---"
"$ROOT/build/guard_lb" "$LB_PORT" \
    "127.0.0.1:$S1_PORT" "127.0.0.1:$S2_PORT" "127.0.0.1:$S3_PORT" \
    2>"/tmp/guard_lb.log" & PIDS+=($!)

sleep 0.3

echo "--- burst: $N_REQUESTS reqs each from 'alice' and 'bob' (concurrent) ---"
echo ""

# Run two users in parallel
"$ROOT/build/guard_client" 127.0.0.1 "$LB_PORT" "$N_REQUESTS" "$N_THREADS" alice 2>/dev/null &
CLIENT1=$!
"$ROOT/build/guard_client" 127.0.0.1 "$LB_PORT" "$N_REQUESTS" "$N_THREADS" bob   2>/dev/null &
CLIENT2=$!

wait "$CLIENT1" || true
wait "$CLIENT2" || true

sleep 0.2

echo ""
echo "=== Per-request trace (coordinator view, grouped by user) ==="
for U in alice bob; do
    echo ""
    echo "  --- $U ---"
    echo "  req_id                decision  tokens_left"
    echo "  --------------------  --------  -----------"
    grep "user=$U " /tmp/guard_coord.log \
        | sed 's/\[coord\] //' \
        | sort -t'-' -k2 -n \
        | while IFS= read -r line; do
            rid=$(echo "$line" | grep -o 'req_id=[^ ]*' | cut -d= -f2)
            decision=$(echo "$line" | grep -o 'ALLOWED\|DENIED')
            tokens=$(echo "$line" | grep -o 'tokens=[^ ]*' | cut -d= -f2)
            printf "  %-20s  %-8s  %s\n" "$rid" "$decision" "$tokens"
        done
done

echo ""
echo "=== Per-request trace (worker view) ==="
echo "  worker  req_id                user    result        tokens_left"
echo "  ------  --------------------  ------  ------------  -----------"
for P in $S1_PORT $S2_PORT $S3_PORT; do
    LOG="/tmp/guard_s${P##910}.log"
    grep "req_id=" "$LOG" 2>/dev/null \
        | grep -v "listening\|coordinator" \
        | while IFS= read -r line; do
            rid=$(echo "$line" | grep -o 'req_id=[^ ]*' | cut -d= -f2)
            user=$(echo "$line" | grep -o 'user=[^ ]*' | cut -d= -f2)
            tokens=$(echo "$line" | grep -o 'tokens=[^ ]*' | cut -d= -f2)
            if echo "$line" | grep -q "RATE_LIMITED"; then
                result="RATE_LIMITED"
            elif echo "$line" | grep -q "COORD_DOWN"; then
                result="COORD_DOWN"
            else
                result="OK"
            fi
            printf "  :%-5s  %-20s  %-6s  %-12s  %s\n" "$P" "$rid" "$user" "$result" "$tokens"
        done
done | sort -k3,3 -k4 -t'-' -k2 -n

echo ""
echo "=== Summary ==="
for U in alice bob; do
    A=$(grep "user=$U " /tmp/guard_coord.log | grep -c "ALLOWED" || echo 0)
    D=$(grep "user=$U " /tmp/guard_coord.log | grep -c "DENIED"  || echo 0)
    echo "  $U: $A allowed, $D denied"
done
echo ""
for P in $S1_PORT $S2_PORT $S3_PORT; do
    COUNT=$(grep -c "req_id=" "/tmp/guard_s${P##910}.log" 2>/dev/null || echo 0)
    echo "  :$P handled $COUNT requests"
done
