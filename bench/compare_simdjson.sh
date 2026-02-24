#!/usr/bin/env bash
# compare_simdjson.sh — zson vs simdjson NDJSON filter benchmark
# Usage: ./bench/compare_simdjson.sh [rows]   (default: 1000000)
set -euo pipefail

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH="$ROOT/bench"
DATA="$BENCH/bench_data.ndjson"
SIMDJSON_BIN="$BENCH/simdjson_bench"
ZSON_BIN="$ROOT/zig-out/bin/zson"
ROWS="${1:-1000000}"

hr() { python3 -c "print('─'*70)"; }

# Measure wall time; stdout discarded; result in $WT (seconds)
wt() {
    local s e
    s=$(python3 -c 'import time; print(time.perf_counter())')
    "$@" > /dev/null
    e=$(python3 -c 'import time; print(time.perf_counter())')
    WT=$(python3 -c "print(f'{$e - $s:.3f}')")
}

echo ""; hr; printf "${BOLD}  zson vs simdjson — NDJSON filter benchmark${NC}\n"; hr

# ── data ──────────────────────────────────────────────────────────────────────
if [ ! -f "$DATA" ]; then
    echo -e "${YELLOW}Generating $ROWS-row test dataset...${NC}"
    cd "$ROOT"; zig build-exe bench/generate_data.zig -O ReleaseFast --name _gen 2>/dev/null
    ./_gen "$DATA" "$ROWS" && rm -f ./_gen
fi
FILE_GB=$(python3 -c "import os; print(f'{os.path.getsize(\"$DATA\")/1e9:.3f}')")
printf "  File: %s  (%.3f GB, %s rows)\n\n" "$DATA" "$FILE_GB" "$(wc -l < "$DATA" | tr -d ' ')"

# ── build ─────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Building...${NC}"; cd "$ROOT"
zig build -Doptimize=ReleaseFast 2>/dev/null
echo -e "  ${GREEN}✓ zson${NC}  (ReleaseFast, 7-thread mmap)"
SIMD_INC="/opt/homebrew/Cellar/simdjson/4.2.4/include"
SIMD_LIB="/opt/homebrew/Cellar/simdjson/4.2.4/lib"
c++ -O3 -std=c++17 -DSIMDJSON_THREADS_ENABLED=1 \
    -I"$SIMD_INC" -L"$SIMD_LIB" -lsimdjson \
    -o "$SIMDJSON_BIN" "$BENCH/simdjson_bench.cpp"
echo -e "  ${GREEN}✓ simdjson_bench${NC}  (O3, single-thread)"
echo ""

# ── benchmark ─────────────────────────────────────────────────────────────────
printf "${BOLD}%-32s  %9s  %9s  %9s  %9s  %s${NC}\n" \
    "Query" "zson(s)" "simd(s)" "zson GB/s" "simd GB/s" "winner"
hr

run_case() {
    local label="$1" zq="$2" sf="$3" sg="$4" mode="$5"
    local SIMD_OUT S_TIME S_GBS S_WALL ZC SC W

    if [ "$mode" = "count" ]; then
        SIMD_OUT=$("$SIMDJSON_BIN" "$DATA" --field "$sf" --gt "$sg" --count 2>&1 > /dev/null || true)
        wt "$ZSON_BIN" "$zq" "$DATA" --count
    else
        SIMD_OUT=$("$SIMDJSON_BIN" "$DATA" --field "$sf" --gt "$sg" --quiet 2>&1 > /dev/null || true)
        wt "$ZSON_BIN" "$zq" "$DATA"
    fi

    Z_TIME="$WT"
    Z_GBS=$(python3 -c "print(f'{$FILE_GB/$Z_TIME:.2f}')")
    S_TIME=$(echo "$SIMD_OUT" | grep -oE 'time=[0-9.]+' | cut -d= -f2 || echo "?")
    S_GBS=$(echo  "$SIMD_OUT" | grep -oE 'throughput=[0-9.]+' | cut -d= -f2 || echo "?")
    # simdjson internal time + estimated file-load overhead (~0.143s for 136MB)
    S_WALL=$(python3 -c "print(f'{float(\"$S_TIME\")+0.143:.3f}')" 2>/dev/null || echo "?")

    if [ "$S_WALL" != "?" ] && python3 -c "import sys; sys.exit(0 if $Z_TIME < $S_WALL else 1)" 2>/dev/null; then
        ZC=$GREEN; SC=$NC; W="zson 🏆"
    else
        ZC=$NC; SC=$GREEN; W="simdjson"
    fi

    printf "%-32s  ${ZC}%9s${NC}  ${SC}%9s${NC}  ${ZC}%9s${NC}  ${SC}%9s*${NC}  %s\n" \
        "$label" "${Z_TIME}s" "${S_WALL}s" "$Z_GBS" "$S_GBS" "$W"
}

run_case "age > 30  (count only)"    '{"age":{"$gt":30}}'        "age"    "30"    "count"
run_case "age > 30  (filter+output)" '{"age":{"$gt":30}}'        "age"    "30"    "output"
run_case "salary > 80000  (count)"   '{"salary":{"$gt":80000}}'  "salary" "80000" "count"

hr
echo ""
echo -e "${CYAN}Notes:${NC}"
echo -e "  zson     : Zig, mmap (zero-copy I/O), 7 parallel threads, lock-free output"
echo -e "  simdjson : C++, padded_string::load (copies file), single thread"
echo -e "  simd(s)  : internal parse time + ~0.143s file-load estimate"
echo -e "  simd GB/s: parser-only throughput (data already resident in RAM)"
echo -e "  Run 2-3x : first run warms OS page cache"
echo ""

