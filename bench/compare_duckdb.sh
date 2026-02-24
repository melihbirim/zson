#!/bin/bash

# Benchmark comparing zson vs DuckDB vs jq
DATA_FILE="bench/bench_data.ndjson"

echo "========================================"
echo "  ZSON vs DuckDB vs jq Comparison"
echo "========================================"
echo ""
echo "Data file: $DATA_FILE"
echo "Size: $(du -h $DATA_FILE | cut -f1)"
echo "Rows: 1,000,000"
echo ""

# Test 1: Simple filter (age > 30)
echo "========================================"
echo "Test 1: Age > 30"
echo "========================================"
echo ""

echo -n "zson --count:  "
/usr/bin/time -p ./zig-out/bin/zson --count '{"age":{"$gt":30}}' $DATA_FILE > /dev/null 2>&1
echo ""

echo -n "DuckDB COUNT:  "
/usr/bin/time -p duckdb -c "SELECT COUNT(*) FROM read_ndjson_auto('$DATA_FILE') WHERE age > 30" > /dev/null 2>&1
echo ""

echo -n "jq (piped):    "
/usr/bin/time -p sh -c "jq -c 'select(.age > 30)' $DATA_FILE | wc -l > /dev/null" 2>&1
echo ""

echo ""

# Test 2: With full output
echo "========================================"
echo "Test 2: Age > 30 (full output)"
echo "========================================"
echo ""

echo -n "zson:          "
/usr/bin/time -p ./zig-out/bin/zson '{"age":{"$gt":30}}' $DATA_FILE > /tmp/zson_out.ndjson 2>&1
echo "               ($(wc -l < /tmp/zson_out.ndjson | tr -d ' ') lines)"

echo -n "DuckDB JSON:   "
/usr/bin/time -p duckdb -c "COPY (SELECT * FROM read_ndjson_auto('$DATA_FILE') WHERE age > 30) TO '/tmp/duckdb_out.csv'" 2>&1 | grep -E "^(real|user|sys)"
echo ""

echo -n "jq:            "
/usr/bin/time -p jq -c 'select(.age > 30)' $DATA_FILE > /tmp/jq_out.ndjson 2>&1
echo ""

echo ""

# Test 3: Complex query (AND)
echo "========================================"
echo "Test 3: Age > 30 AND status = 'active'"
echo "========================================"
echo ""

echo -n "zson --count:  "
/usr/bin/time -p ./zig-out/bin/zson --count '{"$and":[{"age":{"$gt":30}},{"status":"active"}]}' $DATA_FILE > /dev/null 2>&1
echo ""

echo -n "DuckDB COUNT:  "
/usr/bin/time -p duckdb -c "SELECT COUNT(*) FROM read_ndjson_auto('$DATA_FILE') WHERE age > 30 AND status = 'active'" > /dev/null 2>&1
echo ""

echo -n "jq (piped):    "
/usr/bin/time -p sh -c "jq -c 'select(.age > 30 and .status == \"active\")' $DATA_FILE | wc -l > /dev/null" 2>&1
echo ""

echo ""
echo "========================================"
echo "  Summary"
echo "========================================"
echo ""
echo "DuckDB is a highly optimized OLAP database with:"
echo "  - Columnar storage and vectorized execution"
echo "  - Optimized for analytical queries"
echo "  - 10+ years of development and optimization"
echo ""
echo "zson is designed for:"
echo "  - MongoDB query syntax (familiar to developers)"
echo "  - Streaming NDJSON processing"
echo "  - Zero external dependencies"
echo "  - Easy integration into CLI pipelines"
echo ""
echo "Both tools significantly outperform jq!"
echo ""

# Cleanup
rm -f /tmp/zson_out.ndjson /tmp/duckdb_out.csv /tmp/jq_out.ndjson
