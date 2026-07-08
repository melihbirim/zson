<p align="center">
  <img src="assets/zson-icon.svg" width="112" alt="zson terminal query icon">
</p>

# zson

A fast command-line tool for querying JSON and NDJSON files using MongoDB query syntax.
Both formats are detected automatically — no flags needed.

<p align="center">
  <img src="assets/zson-vhs.gif" width="720" alt="Animated VHS tape showing zson filtering JSON records">
</p>

```bash
# NDJSON (one object per line)
zson '{ "age": { "$gt": 30 }, "city": "NYC" }' users.ndjson

# JSON array  ([{...},{...}])
zson '{ "age": { "$gt": 30 } }' users.json
```

No custom DSL to learn — if you know MongoDB queries, you already know zson.

## Why zson?

Most JSON tools are built around parsing documents or transforming arbitrary
JSON. zson is built for a narrower job: filtering JSON records quickly with
Mongo-style predicates.

Use zson when JSON is already moving through your system and you need to cut it
down before the next step:

- API responses and request bodies
- database JSON/JSONB rows or exports
- event streams and queue payloads
- logs and NDJSON files
- generated test fixtures
- integration-test setup and assertions

For integration tests, zson can replace a database dependency when the test only
needs document-shaped data, not actual database behavior. Instead of starting a
MongoDB container just to prepare fixtures, filter a JSON export directly:

```bash
zson '{ "tenantId": "acme", "active": true }' fixtures/users.ndjson \
  --select 'id,email,role' \
  --output json > /tmp/acme-users.json
```

That keeps CI setup deterministic and avoids database startup cost for tests
that only need filtered fixture data.

zson is not a local MongoDB. It does not provide indexes, collections,
transactions, update operators, BSON compatibility, aggregation pipelines, or
Mongo driver behavior. Use it when you need Mongo-style filtering over JSON
records, not when you need to test MongoDB itself.

## Install

**Homebrew (macOS / Linux):**

```bash
brew tap melihbirim/zson
brew install zson
```

**Linux x86_64:**

```bash
curl -L https://github.com/melihbirim/zson/releases/latest/download/zson-x86_64-linux-gnu.tar.gz | tar xz
sudo install -m 755 zson-x86_64-linux-gnu/zson /usr/local/bin/zson
```

**macOS Apple Silicon:**

```bash
curl -L https://github.com/melihbirim/zson/releases/latest/download/zson-aarch64-macos.tar.gz | tar xz
sudo install -m 755 zson-aarch64-macos/zson /usr/local/bin/zson
```

**macOS Intel:**

```bash
curl -L https://github.com/melihbirim/zson/releases/latest/download/zson-x86_64-macos.tar.gz | tar xz
sudo install -m 755 zson-x86_64-macos/zson /usr/local/bin/zson
```

**Windows x86_64:**

Download `zson-x86_64-windows-gnu.zip` from the
[latest release](https://github.com/melihbirim/zson/releases/latest), unzip it,
and add the folder containing `zson.exe` to your `PATH`.

```powershell
powershell -Command "Invoke-WebRequest https://github.com/melihbirim/zson/releases/latest/download/zson-x86_64-windows-gnu.zip -OutFile zson.zip"
powershell -Command "Expand-Archive zson.zip -DestinationPath ."
.\zson-x86_64-windows-gnu\zson.exe --help
```

**From source** (requires [Zig 0.15](https://ziglang.org/download/)):

```bash
git clone https://github.com/melihbirim/zson
cd zson
zig build -Doptimize=ReleaseFast
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

## Zig Library

Use zson as a Zig module when you want parsed native objects instead of CLI output:

```zig
const std = @import("std");
const zson = @import("zson");

var filters = [_]zson.Filter{
    zson.q.eq("city", zson.q.string("NYC")),
    zson.q.eq("active", zson.q.boolean(true)),
    zson.q.gt("age", zson.q.number(30)),
};

var result = try zson.queryNdjsonWhere(data, zson.q.all(&filters), allocator);
defer result.deinit();

for (result.items()) |obj| {
    const name = obj.get("name").?.string;
    std.debug.print("{s}\n", .{name});
}
```

For files or JSON arrays, use `zson.queryFileWhere` or `zson.queryDataWhere`.
If you need CLI-compatible MongoDB JSON syntax, `zson.queryNdjson`,
`zson.queryFile`, and `zson.queryData` still accept query strings.

Run the full example:

```bash
zig build example-lib
```

## Instead

If your API or worker already has JSON in memory, the slow path often looks like:

```zig
// Parse every row into a general JSON value or typed object.
// Walk fields manually.
// Build a filtered list.
// Serialize the matches again.
```

That works, but it spends business-logic time on generic JSON plumbing. With zson,
you can keep the filtering path focused:

```zig
var filters = [_]zson.Filter{
    zson.q.gte("age", zson.q.number(40)),
    zson.q.eq("active", zson.q.boolean(true)),
};

var result = try zson.queryDataWhere(api_body, zson.q.all(&filters), .{}, allocator);
defer result.deinit();
```

On this repo's generated 100k-record benchmark, the in-memory filter path was:

```text
zson parsed (4 threads)   ~13 ms
std.json typed            ~45 ms
std.json Value            ~92 ms
jq                       ~260 ms
```

That is not a universal latency guarantee, but it shows the intended tradeoff:
when your request, job, or event handler spends time filtering JSON records,
zson can move that work out of generic parse/walk code and into a narrower
predicate engine. Saving tens of milliseconds in a hot API path can mean lower
response latency, more headroom for business logic, and higher request
throughput on the same hardware.

## Benchmarks

Compare zson with Zig `std.json` dynamic and typed parsing. If `jq` or `duckdb`
are installed, the benchmark includes them as optional external comparisons.
The benchmark reports separate sections for in-memory parse/filter work and
parse/filter/serialize/write-to-file round trips.

```bash
zig build bench-json -Doptimize=ReleaseFast
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

# Regex match (supports ^, $, ., *, and case-insensitive $options)
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
| `$regex`   | Regex match (`^`, `$`, `.`, `*`)     | `{ "name": { "$regex": "^Ali" } }`                 |
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
