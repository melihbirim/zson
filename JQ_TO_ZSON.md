# jq → zson Cheatsheet

A side-by-side reference for switching from jq to zson.

> **Key difference:** jq filters transform/reshape JSON. zson filters/selects rows using MongoDB query syntax. For NDJSON filtering, zson is a drop-in replacement with a familiar syntax and 18x better performance.

---

## Basic Filtering

| jq                                      | zson                                     |
| --------------------------------------- | ---------------------------------------- |
| `jq 'select(.age > 30)' f.ndjson`       | `zson '{"age":{"$gt":30}}' f.ndjson`     |
| `jq 'select(.city == "NYC")' f.ndjson`  | `zson '{"city":"NYC"}' f.ndjson`         |
| `jq 'select(.city != "NYC")' f.ndjson`  | `zson '{"city":{"$ne":"NYC"}}' f.ndjson` |
| `jq 'select(.active == true)' f.ndjson` | `zson '{"active":true}' f.ndjson`        |
| `jq 'select(.score == null)' f.ndjson`  | `zson '{"score":null}' f.ndjson`         |
| `jq '.' f.ndjson` (pass-through)        | `zson '{}' f.ndjson`                     |

---

## Comparison Operators

| jq                                | zson                          |
| --------------------------------- | ----------------------------- |
| `select(.age > 30)`               | `{"age":{"$gt":30}}`          |
| `select(.age >= 30)`              | `{"age":{"$gte":30}}`         |
| `select(.age < 30)`               | `{"age":{"$lt":30}}`          |
| `select(.age <= 30)`              | `{"age":{"$lte":30}}`         |
| `select(.age > 18 and .age < 65)` | `{"age":{"$gt":18,"$lt":65}}` |
| `select(.price >= 10.5)`          | `{"price":{"$gte":10.5}}`     |

---

## Logical Operators

| jq                                        | zson                                             |
| ----------------------------------------- | ------------------------------------------------ |
| `select(.age > 30 and .city == "NYC")`    | `{"age":{"$gt":30},"city":"NYC"}`                |
| `select(.city == "NYC" or .city == "LA")` | `{"$or":[{"city":"NYC"},{"city":"LA"}]}`         |
| `select(.age > 18 and .active == true)`   | `{"$and":[{"age":{"$gt":18}},{"active":true}]}`  |
| `select(.age <= 18 or .active == false)`  | `{"$or":[{"age":{"$lte":18}},{"active":false}]}` |
| `select(.age > 30 \| not)`                | `{"age":{"$not":{"$gt":30}}}`                    |

---

## Array / Membership

| jq                                                              | zson                                      |
| --------------------------------------------------------------- | ----------------------------------------- |
| `select(.city == "NYC" or .city == "LA" or .city == "Chicago")` | `{"city":{"$in":["NYC","LA","Chicago"]}}` |
| `select(.city != "NYC" and .city != "LA")`                      | `{"city":{"$nin":["NYC","LA"]}}`          |
| `select(.tags[] == "tech")`                                     | `{"tags":{"$in":["tech"]}}`               |
| `select(any(.tags[]; . == "go" or . == "rust"))`                | `{"tags":{"$in":["go","rust"]}}`          |

---

## Field Existence

| jq                        | zson                            |
| ------------------------- | ------------------------------- |
| `select(.email != null)`  | `{"email":{"$exists":true}}`    |
| `select(.email == null)`  | `{"email":{"$exists":false}}`   |
| `select(has("metadata"))` | `{"metadata":{"$exists":true}}` |

---

## Regex / Pattern Matching

| jq                                           | zson                                      |
| -------------------------------------------- | ----------------------------------------- |
| `select(.name \| test("^Ali"))`              | `{"name":{"$regex":"^Ali"}}`              |
| `select(.email \| test("@gmail\\.com$"))`    | `{"email":{"$regex":"@gmail\\.com$"}}`    |
| `select(.status \| test("active\|pending"))` | `{"status":{"$regex":"active\|pending"}}` |
| `select(.name \| test("alice"; "i"))`        | `{"name":{"$regex":"alice","$options":"i"}}` |

---

## Array Size, Value Type, NOR

| jq                                                     | zson                                            |
| ------------------------------------------------------- | ----------------------------------------------- |
| `select(.tags \| length == 3)`                          | `{"tags":{"$size":3}}`                       |
| `select(.score \| type == "number")`                   | `{"score":{"$type":"number"}}`               |
| `select(.name \| type == "string")`                    | `{"name":{"$type":"string"}}`                |
| `select(.active \| type == "boolean")`                 | `{"active":{"$type":"bool"}}`                |
| `select(.data \| type == "array")`                     | `{"data":{"$type":"array"}}`                 |
| `select(.data \| type == "object")`                    | `{"data":{"$type":"object"}}`                |
| `select(.city != "NYC" and .city != "LA")` (NOR)       | `{"$nor":[{"city":"NYC"},{"city":"LA"}]}`   |

---

## Nested Fields

| jq                               | zson                      |
| -------------------------------- | ------------------------- |
| `select(.address.city == "NYC")` | `{"address.city":"NYC"}`  |
| `select(.user.age > 30)`         | `{"user.age":{"$gt":30}}` |
| `select(.meta.active == true)`   | `{"meta.active":true}`    |
| `select(.a.b.c == "deep")`       | `{"a.b.c":"deep"}`        |

---

## Field Selection (Projection)

| jq                                            | zson                                                     |
| --------------------------------------------- | -------------------------------------------------------- |
| `jq '{name, email}' f.ndjson`                 | `zson '{}' f.ndjson --select 'name,email'`               |
| `jq '{name, city: .address.city}' f.ndjson`   | `zson '{}' f.ndjson --select 'name,address.city'`        |
| `jq 'select(.age>30) \| {name,age}' f.ndjson` | `zson '{"age":{"$gt":30}}' f.ndjson --select 'name,age'` |

---

## Counting

| jq                                                    | zson                                         |
| ----------------------------------------------------- | -------------------------------------------- |
| `jq -s 'length' f.ndjson`                             | `zson '{}' f.ndjson --count`                 |
| `jq -s '[.[] \| select(.age>30)] \| length' f.ndjson` | `zson '{"age":{"$gt":30}}' f.ndjson --count` |

---

## Output Formats

| jq                                        | zson                                                    |
| ----------------------------------------- | ------------------------------------------------------- |
| `jq -c '...'` (compact, default for zson) | `zson '...' f.ndjson`                                   |
| `jq '...'` (pretty-print)                 | `zson '...' f.ndjson --output json --pretty`            |
| `jq -r '[.name,.city] \| @csv'`           | `zson '...' f.ndjson --output csv --select 'name,city'` |
| `jq -s '...'` (JSON array output)         | `zson '...' f.ndjson --output json`                     |

---

## Piping / Stdin

| jq                                               | zson                                           |
| ------------------------------------------------ | ---------------------------------------------- |
| `cat f.ndjson \| jq 'select(.age>30)'`           | `cat f.ndjson \| zson '{"age":{"$gt":30}}' -`  |
| `curl api/events \| jq 'select(.type=="error")'` | `curl api/events \| zson '{"type":"error"}' -` |

---

## Limiting Results

| jq                                            | zson                                            |
| --------------------------------------------- | ----------------------------------------------- |
| `jq -s 'limit(10; .[])'`                      | `zson '{}' f.ndjson --limit 10`                 |
| `jq -s '[limit(10; .[] \| select(.age>30))]'` | `zson '{"age":{"$gt":30}}' f.ndjson --limit 10` |

---

## Not (Yet) in zson

These jq features have no zson equivalent — jq remains the right tool for these:

| jq feature                          | jq example                                    |
| ----------------------------------- | --------------------------------------------- |
| Reshaping / transforming output     | `{name: .name, full: (.first + " " + .last)}` |
| Aggregation                         | `[.[] \| select(.age>30)] \| length`          |
| Arithmetic on fields                | `.price * .qty`                               |
| String interpolation                | `"\(.name) is \(.age)"`                       |
| Recursive descent                   | `.. \| .id? // empty`                         |
| `@base64`, `@uri`, `@html` encoding | `.token \| @base64d`                          |
| `group_by`, `unique_by`, `sort_by`  | `sort_by(.age)`                               |
| `reduce`, `foreach`                 | `reduce .[] as $x (0; . + $x)`                |

For those, pipe zson output into jq:

```bash
# zson filters fast, jq transforms the smaller result set
zson '{"age":{"$gt":30},"dept":"Eng"}' employees.ndjson | jq '.salary * 1.1'
```
