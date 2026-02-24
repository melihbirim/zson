#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  ZSON Benchmark Suite${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if data file exists
DATA_FILE="bench/bench_data.ndjson"
if [ ! -f "$DATA_FILE" ]; then
    echo -e "${YELLOW}Benchmark data not found. Generating...${NC}"
    zig build-exe bench/generate_data.zig
    ./generate_data "$DATA_FILE" 1000000
    rm ./generate_data
    echo ""
fi

# Get file size
FILE_SIZE=$(du -h "$DATA_FILE" | cut -f1)
LINE_COUNT=$(wc -l < "$DATA_FILE" | tr -d ' ')
echo -e "${GREEN}Data file: $DATA_FILE${NC}"
echo -e "${GREEN}Size: $FILE_SIZE${NC}"
echo -e "${GREEN}Rows: $LINE_COUNT${NC}"
echo ""

# Build zson in release mode
echo -e "${YELLOW}Building zson (release mode)...${NC}"
zig build -Doptimize=ReleaseFast
echo ""

# Test queries
QUERIES=(
    '{"age":{"$gt":30}}'
    '{"city":"NYC"}'
    '{"$and":[{"age":{"$gte":30}},{"salary":{"$gte":50000}}]}'
    '{"$or":[{"city":"NYC"},{"city":"LA"}]}'
    '{"department":"Engineering","active":true}'
)

QUERY_NAMES=(
    "Simple comparison (age > 30)"
    "Equality filter (city = NYC)"
    "AND with two conditions"
    "OR with two cities"
    "Multiple fields (implicit AND)"
)

# Function to run benchmark
run_benchmark() {
    local tool=$1
    local query=$2
    local output=$3
    
    case $tool in
        zson)
            /usr/bin/time -p ./zig-out/bin/zson "$query" "$DATA_FILE" > "$output" 2>&1
            ;;
        jq)
            # Convert MongoDB query to jq syntax (simplified)
            if [[ "$query" == *'"age":{"$gt":30}'* ]]; then
                /usr/bin/time -p jq -c 'select(.age > 30)' "$DATA_FILE" > "$output" 2>&1
            elif [[ "$query" == *'"city":"NYC"'* ]]; then
                /usr/bin/time -p jq -c 'select(.city == "NYC")' "$DATA_FILE" > "$output" 2>&1
            else
                echo "jq: query not implemented" > "$output"
                return 1
            fi
            ;;
        *)
            echo "Unknown tool: $tool"
            return 1
            ;;
    esac
}

# Extract timing from output
get_timing() {
    local file=$1
    grep "^real" "$file" | awk '{print $2}' || echo "0"
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Running Benchmarks${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Run benchmarks for each query
for i in "${!QUERIES[@]}"; do
    query="${QUERIES[$i]}"
    name="${QUERY_NAMES[$i]}"
    
    echo -e "${GREEN}Query $((i+1)): $name${NC}"
    echo -e "  MongoDB: $query"
    echo ""
    
    # Warm up
    ./zig-out/bin/zson --count "$query" "$DATA_FILE" > /dev/null 2>&1 || true
    
    # Run zson
    echo -n "  zson:  "
    if /usr/bin/time -l ./zig-out/bin/zson "$query" "$DATA_FILE" > /tmp/zson_out.ndjson 2> /tmp/zson_time.txt; then
        TIME=$(grep "user" /tmp/zson_time.txt | awk '{print $1}' || echo "N/A")
        COUNT=$(wc -l < /tmp/zson_out.ndjson | tr -d ' ')
        echo -e "${GREEN}${TIME}s${NC} (${COUNT} matches)"
        
        # Extract max resident memory
        MEM=$(grep "maximum resident set size" /tmp/zson_time.txt | awk '{print $1}' || echo "0")
        MEM_MB=$(echo "scale=2; $MEM / 1048576" | bc 2>/dev/null || echo "N/A")
        echo "         Memory: ${MEM_MB} MB"
    else
        echo -e "${RED}FAILED${NC}"
    fi
    
    # Run jq if available and query is simple
    if command -v jq &> /dev/null && [[ "$i" -lt 2 ]]; then
        echo -n "  jq:    "
        case $i in
            0)
                if /usr/bin/time -l jq -c 'select(.age > 30)' "$DATA_FILE" > /tmp/jq_out.ndjson 2> /tmp/jq_time.txt; then
                    TIME=$(grep "user" /tmp/jq_time.txt | awk '{print $1}' || echo "N/A")
                    COUNT=$(wc -l < /tmp/jq_out.ndjson | tr -d ' ')
                    echo -e "${YELLOW}${TIME}s${NC} (${COUNT} matches)"
                else
                    echo -e "${RED}FAILED${NC}"
                fi
                ;;
            1)
                if /usr/bin/time -l jq -c 'select(.city == "NYC")' "$DATA_FILE" > /tmp/jq_out.ndjson 2> /tmp/jq_time.txt; then
                    TIME=$(grep "user" /tmp/jq_time.txt | awk '{print $1}' || echo "N/A")
                    COUNT=$(wc -l < /tmp/jq_out.ndjson | tr -d ' ')
                    echo -e "${YELLOW}${TIME}s${NC} (${COUNT} matches)"
                else
                    echo -e "${RED}FAILED${NC}"
                fi
                ;;
        esac
    fi
    
    echo ""
done

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Benchmark Complete${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Cleanup
rm -f /tmp/zson_out.ndjson /tmp/zson_time.txt /tmp/jq_out.ndjson /tmp/jq_time.txt

echo -e "${GREEN}Results saved. Run with different data sizes to test scalability.${NC}"
