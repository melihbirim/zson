# zson

A fast command-line tool for querying NDJSON files using MongoDB query syntax.

```bash
zson '{ "age": { "$gt": 30 }, "city": "NYC" }' users.ndjson
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

```
zson [options] '<query>' <file.ndjson>
       zson [options] '<query>' -          # read from stdin

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
# Filter by field value
zson '{ "status": "active" }' records.ndjson

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

| Operator | Description | Example |
|----------|-------------|---------|
| `$eq` | Equal | `{ "status": { "$eq": "ok" } }` or `{ "status": "ok" }` |
| `$ne` | Not equal | `{ "status": { "$ne": "error" } }` |
| `$gt` | Greater than | `{ "age": { "$gt": 30 } }` |
| `$gte` | Greater than or equal | `{ "score": { "$gte": 90 } }` |
| `$lt` | Less than | `{ "price": { "$lt": 100 } }` |
| `$lte` | Less than or equal | `{ "age": { "$lte": 65 } }` |
| `$in` | Value in array | `{ "city": { "$in": ["NYC", "LA"] } }` |
| `$nin` | Value not in array | `{ "role": { "$nin": ["guest"] } }` |

### Logical

| Operator | Description | Example |
|----------|-------------|---------|
| `$and` | All conditions true | `{ "$and": [{ "age": { "$gt": 18 } }, { "active": true }] }` |
| `$or` | Any condition true | `{ "$or": [{ "city": "NYC" }, { "city": "LA" }] }` |
| `$not` | Inverts condition | `{ "age": { "$not": { "$lt": 18 } } }` |
| `$nor` | None of the conditions | `{ "$nor": [{ "status": "error" }, { "status": "banned" }] }` |

Multiple conditions on the same field are implicitly `$and`:
```json
{ "age": { "$gt": 18, "$lt": 65 } }
```

### Element

| Operator | Description | Example |
|----------|-------------|---------|
| `$exists` | Field exists | `{ "email": { "$exists": true } }` |
| `$type` | Field type check | `{ "age": { "$type": "number" } }` |

Supported types: `string`, `number`, `bool`, `null`, `array`, `object`

### Array

| Operator | Description | Example |
|----------|-------------|---------|
| `$size` | Array has exact length | `{ "tags": { "$size": 3 } }` |

### String

| Operator | Description | Example |
|----------|-------------|---------|
| `$regex` | POSIX extended regex match | `{ "name": { "$regex": "^Ali" } }` |
| `$options` | Regex flags (`i` = case-insensitive) | `{ "name": { "$regex": "ali", "$options": "i" } }` |

## How It Works

zson processes NDJSON files in parallel:

1. **Memory-maps** the file — zero-copy reads
2. **Splits** chunks at newline boundaries
3. **Worker threads** parse and filter each chunk
4. **Merges** results and writes in a single pass

## License

MIT

