# zson

A fast command-line tool for querying JSON and NDJSON files using MongoDB query syntax.
Both formats are detected automatically — no flags needed.

```bash
# NDJSON (one object per line)
zson '{ "age": { "$gt": 30 }, "city": "NYC" }' users.ndjson

# JSON array  ([{...},{...}])
zson '{ "age": { "$gt": 30 } }' users.json
```

No custom DSL to learn — if you know MongoDB queries, you already know zson.

## Install

Requires [Zig 0.15](https://ziglang.org/download/).

```bash
git clone https://github.com/melihbirim/zson
cd zson
zig build -Doptimize=ReleaseFast
# binary at: ./zig-out/bin/zson
```

## Usage

```bash
zson [options] '<query>' <file>   # .ndjson or .json — auto-detected
       zson [options] '<query>' -          # read from stdin (both formats)

Options:
  --select <fields>   Comma-separated fields to include in output
  --count             Print match count only
  --limit <n>         Return at most n results
  --threads <n>       Number of worker threads (default: 4)
  --output <fmt>      Output format: ndjson (default), json, csv
  --pretty            Pretty-print JSON output
  --help              Show this help
```

### Examples

```bash
# Works with NDJSON files (one object per line)
zson '{ "status": "active" }' records.ndjson

# Works with JSON array files ([{...},{...}])
zson '{ "status": "active" }' records.json

# Numeric comparison
zson '{ "age": { "$gt": 18, "$lt": 65 } }' users.ndjson

# Select specific fields
zson '{ "active": true }' users.ndjson --select 'id,name,email'

# Count matches
zson '{ "status": "error" }' logs.ndjson --count

# Logical OR
zson '{ "$or": [{ "city": "NYC" }, { "city": "LA" }] }' users.ndjson

# Array membership
zson '{ "role": { "$in": ["admin", "editor"] } }' users.ndjson

# Regex match (POSIX extended, case-insensitive with $options)
zson '{ "name": { "$regex": "^ali", "$options": "i" } }' users.ndjson

# Output as JSON array
zson '{ "score": { "$gte": 90 } }' results.ndjson --output json --pretty

# Output as CSV
zson '{ "active": true }' users.ndjson --select 'id,name,email' --output csv

# Pipe from stdin
cat large.ndjson | zson '{ "level": "error" }' -

# Parallel with more threads
zson '{ "age": { "$gt": 50 } }' big.ndjson --threads 8
```

## Query Operators

### Comparison

| Operator | Description           | Example                                                 |
| -------- | --------------------- | ------------------------------------------------------- |
| `$eq`    | Equal                 | `{ "status": { "$eq": "ok" } }` or `{ "status": "ok" }` |
| `$ne`    | Not equal             | `{ "status": { "$ne": "error" } }`                      |
| `$gt`    | Greater than          | `{ "age": { "$gt": 30 } }`                              |
| `$gte`   | Greater than or equal | `{ "score": { "$gte": 90 } }`                           |
| `$lt`    | Less than             | `{ "price": { "$lt": 100 } }`                           |
| `$lte`   | Less than or equal    | `{ "age": { "$lte": 65 } }`                             |
| `$in`    | Value in array        | `{ "city": { "$in": ["NYC", "LA"] } }`                  |
| `$nin`   | Value not in array    | `{ "role": { "$nin": ["guest"] } }`                     |

### Logical

| Operator | Description            | Example                                                       |
| -------- | ---------------------- | ------------------------------------------------------------- |
| `$and`   | All conditions true    | `{ "$and": [{ "age": { "$gt": 18 } }, { "active": true }] }`  |
| `$or`    | Any condition true     | `{ "$or": [{ "city": "NYC" }, { "city": "LA" }] }`            |
| `$not`   | Inverts condition      | `{ "age": { "$not": { "$lt": 18 } } }`                        |
| `$nor`   | None of the conditions | `{ "$nor": [{ "status": "error" }, { "status": "banned" }] }` |

Multiple conditions on the same field are implicitly `$and`:

```json
{ "age": { "$gt": 18, "$lt": 65 } }
```

### Element

| Operator  | Description      | Example                            |
| --------- | ---------------- | ---------------------------------- |
| `$exists` | Field exists     | `{ "email": { "$exists": true } }` |
| `$type`   | Field type check | `{ "age": { "$type": "number" } }` |

Supported types: `string`, `number`, `bool`, `null`, `array`, `object`

### Array

| Operator | Description            | Example                      |
| -------- | ---------------------- | ---------------------------- |
| `$size`  | Array has exact length | `{ "tags": { "$size": 3 } }` |

### String

| Operator   | Description                          | Example                                            |
| ---------- | ------------------------------------ | -------------------------------------------------- |
| `$regex`   | POSIX extended regex match           | `{ "name": { "$regex": "^Ali" } }`                 |
| `$options` | Regex flags (`i` = case-insensitive) | `{ "name": { "$regex": "ali", "$options": "i" } }` |

## How It Works

zson processes files in parallel:

1. **Memory-maps** the file — zero-copy reads
2. **Auto-detects** format: JSON array `[{...}]` or NDJSON (one object per line)
3. **Splits** chunks at object/line boundaries
4. **Worker threads** parse and filter each chunk independently
5. **Merges** results and writes in a single pass

## jq Comparison

zson covers the **filter-and-extract** use-case that jq is most commonly used for, with a simpler query language and better performance on large files.

### Filtering

| Task                | jq                                                   | zson                                               |
| ------------------- | ---------------------------------------------------- | -------------------------------------------------- |
| Exact match         | `jq 'select(.status == "active")'`                   | `zson '{"status":"active"}'`                       |
| Greater than        | `jq 'select(.age > 30)'`                             | `zson '{"age":{"$gt":30}}'`                        |
| Multiple conditions | `jq 'select(.age > 30 and .city == "NYC")'`          | `zson '{"age":{"$gt":30},"city":"NYC"}'`           |
| OR conditions       | `jq 'select(.city == "NYC" or .city == "LA")'`       | `zson '{"$or":[{"city":"NYC"},{"city":"LA"}]}'`    |
| Field exists        | `jq 'select(.email != null)'`                        | `zson '{"email":{"$exists":true}}'`                |
| Regex               | `jq 'select(.name \| test("^Ali"; "i"))'`            | `zson '{"name":{"$regex":"^Ali","$options":"i"}}'` |
| Value in list       | `jq 'select(.role == "admin" or .role == "editor")'` | `zson '{"role":{"$in":["admin","editor"]}}'`       |
| Negate              | `jq 'select(.status != "error")'`                    | `zson '{"status":{"$ne":"error"}}'`                |

### Field selection

```bash
# jq
jq '{id, name, email}' users.ndjson

# zson
zson '{}' users.ndjson --select 'id,name,email'
```

### Counting

```bash
# jq
jq 'select(.status == "error")' logs.ndjson | wc -l

# zson (no extra process, no wc)
zson '{"status":"error"}' logs.ndjson --count
```

### Output formats

```bash
# Pretty-printed JSON array
jq -s '.' matches.ndjson
zson '{}' matches.ndjson --output json --pretty

# CSV
jq -r '[.id,.name,.email] | @csv' users.ndjson
zson '{}' users.ndjson --select 'id,name,email' --output csv
```

### What zson does not do

jq is a full transformation language. zson is a query tool — it filters and extracts, not transforms. Use jq when you need to:

- Reshape objects (`{newKey: .oldKey}`)
- Arithmetic or string manipulation (`.price * 1.1`)
- Aggregation (`group_by`, `reduce`)
- Recursive descent (`..|`)

For everything else — especially filtering large files — zson is faster and the query syntax is easier to read and write.

### Real-world examples side by side

```bash
# Find all error logs from service "auth" in the last hour
# jq
jq 'select(.level == "error" and .service == "auth")' app.ndjson

# zson
zson '{"level":"error","service":"auth"}' app.ndjson

# ─────────────────────────────────────────────────────────────

# Find users aged 25–40 in NYC or LA, return only id and name
# jq
jq 'select(.age >= 25 and .age <= 40 and (.city == "NYC" or .city == "LA")) | {id, name}' users.ndjson

# zson
zson '{"age":{"$gte":25,"$lte":40},"$or":[{"city":"NYC"},{"city":"LA"}]}' users.ndjson --select 'id,name'

# ─────────────────────────────────────────────────────────────

# Count HTTP 5xx responses
# jq
jq 'select(.status >= 500 and .status < 600)' access.ndjson | wc -l

# zson
zson '{"status":{"$gte":500,"$lt":600}}' access.ndjson --count
```

## License

MIT
