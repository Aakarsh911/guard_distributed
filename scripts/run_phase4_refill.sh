#!/usr/bin/env bash
set -euo pipefail

# Test: multiple users, 6 waves with varying sleep gaps to show token refill.
#
#   cap=5, refill=2/s
#   Wave 1: burst 8 reqs  → 5 ok, 3 deny  (drain full bucket)
#   Sleep 1s              → +2 tokens
#   Wave 2: burst 8 reqs  → 2 ok, 6 deny  (partial refill)
#   Sleep 2s              → +4, capped at 5
#   Wave 3: burst 8 reqs  → 5 ok, 3 deny  (full refill)
#   Sleep 0.5s            → +1 token
#   Wave 4: burst 8 reqs  → 1 ok, 7 deny  (tiny refill)
#   Sleep 3s              → +6, capped at 5
#   Wave 5: burst 8 reqs  → 5 ok, 3 deny  (full refill again)

COORD_PORT=9300
LB_PORT=9400
S1_PORT=9401
S2_PORT=9402
S3_PORT=9403
SIM_MS=5
RL_CAP=5
RL_REFILL=2
USERS="alice bob charlie"
REQS_PER_WAVE=8

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

make -j

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
COORD_LOG="/tmp/guard_coord_refill.log"

echo "=== Multi-user token refill test ==="
echo "    bucket cap=$RL_CAP, refill=$RL_REFILL/s, users: $USERS"
echo ""

"$ROOT/build/guard_coord" "$COORD_PORT" "$RL_CAP" "$RL_REFILL" \
    2>"$COORD_LOG" & PIDS+=($!)
sleep 0.2

"$ROOT/build/guard_server" "$S1_PORT" "$SIM_MS" "$COORD_ADDR" 2>/dev/null & PIDS+=($!)
"$ROOT/build/guard_server" "$S2_PORT" "$SIM_MS" "$COORD_ADDR" 2>/dev/null & PIDS+=($!)
"$ROOT/build/guard_server" "$S3_PORT" "$SIM_MS" "$COORD_ADDR" 2>/dev/null & PIDS+=($!)

"$ROOT/build/guard_lb" "$LB_PORT" \
    "127.0.0.1:$S1_PORT" "127.0.0.1:$S2_PORT" "127.0.0.1:$S3_PORT" \
    2>/dev/null & PIDS+=($!)

sleep 0.3

fire_wave() {
    local nreqs=$1
    local cpids=()
    for U in $USERS; do
        "$ROOT/build/guard_client" 127.0.0.1 "$LB_PORT" "$nreqs" 1 "$U" 2>/dev/null &
        cpids+=($!)
    done
    for p in "${cpids[@]}"; do wait "$p" 2>/dev/null || true; done
    sleep 0.1
}

# Wave boundaries (line counts in coord log)
declare -a WEND
NUM_WAVES=5
SLEEPS=(1 2 0.5 3)
EXPECTED_REFILL=("" "+2" "+4→cap5" "+1" "+6→cap5")
EXPECTED_OK=(5 2 5 1 5)

for W in $(seq 1 $NUM_WAVES); do
    if [ "$W" -eq 1 ]; then
        echo "--- Wave $W: $REQS_PER_WAVE reqs/user (fresh bucket=$RL_CAP) ---"
    else
        PREV=$((W-2))
        echo "--- Wave $W: $REQS_PER_WAVE reqs/user (after ${SLEEPS[$PREV]}s sleep, refill ${EXPECTED_REFILL[$((W-1))]}) ---"
    fi
    fire_wave "$REQS_PER_WAVE"
    WEND[$W]=$(wc -l < "$COORD_LOG")

    if [ "$W" -lt "$NUM_WAVES" ]; then
        IDX=$((W-1))
        echo "    ... sleeping ${SLEEPS[$IDX]}s ..."
        echo ""
        sleep "${SLEEPS[$IDX]}"
    fi
done

echo ""
echo "============================================="
echo "=== Coordinator trace (alice only for clarity) ==="
echo "============================================="
echo ""
echo "  wave  req_id                decision  tokens_left"
echo "  ----  --------------------  --------  -----------"

PREV_END=0
for W in $(seq 1 $NUM_WAVES); do
    END=${WEND[$W]}
    sed -n "$((PREV_END+1)),${END}p" "$COORD_LOG" \
        | grep "user=alice " \
        | while IFS= read -r line; do
            rid=$(echo "$line" | grep -o 'req_id=[^ ]*' | cut -d= -f2)
            decision=$(echo "$line" | grep -o 'ALLOWED\|DENIED')
            tokens=$(echo "$line" | grep -o 'tokens=[^ ]*' | cut -d= -f2)
            printf "  %-4s  %-20s  %-8s  %s\n" "$W" "$rid" "$decision" "$tokens"
        done
    PREV_END=$END
done

echo ""
echo "============================================="
echo "=== Per-user per-wave summary ==="
echo "============================================="
echo ""

header="  user    "
for W in $(seq 1 $NUM_WAVES); do header="$header  wave$W        "; done
echo "$header"
dashes="  ------  "
for W in $(seq 1 $NUM_WAVES); do dashes="$dashes  ------------"; done
echo "$dashes"

for U in $USERS; do
    line="  $(printf '%-6s' "$U")  "
    PREV_END=0
    for W in $(seq 1 $NUM_WAVES); do
        END=${WEND[$W]}
        wl=$(sed -n "$((PREV_END+1)),${END}p" "$COORD_LOG" | grep "user=$U " || true)
        A=$(echo "$wl" | grep -c "ALLOWED" 2>/dev/null || echo 0)
        D=$(echo "$wl" | grep -c "DENIED"  2>/dev/null || echo 0)
        line="$line$(printf '  %dok / %ddeny  ' "$A" "$D")"
        PREV_END=$END
    done
    echo "$line"
done

echo ""
echo "  expect  "$(printf '  %dok / %ddeny  ' 5 3)"  "$(printf '  %dok / %ddeny  ' 2 6)"  "$(printf '  %dok / %ddeny  ' 5 3)"  "$(printf '  %dok / %ddeny  ' 1 7)"  "$(printf '  %dok / %ddeny  ' 5 3)
echo "          (full)         (+2 tokens)    (full)         (+1 token)     (full)"
