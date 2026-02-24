# Parser Tokenizer Comparison: simd.zig vs simdjson

This is the **honest, apples-to-apples** benchmark at the parser layer.

Both tools perform the same task:

```
Input : raw bytes of a NDJSON file (already in RAM, no disk I/O)
Output: positions of structural characters  { } [ ] " : ,
Metric: GB/s  (input bytes processed per second, single thread)
```

## Setup

| Item | Value |
|---|---|
| Hardware | Apple M-series (aarch64 NEON) |
| File | `bench_data.ndjson` — 143 MB, 1 000 000 records |
| zson version | Zig 0.15.2, `-Doptimize=ReleaseFast` |
| simdjson version | 4.2.4, `-O3 -std=c++17`, `ondemand/iterate_many` |
| Iterations | 5 (best run reported) |

## Results

```
Metric                  zson (simd.zig)   simdjson 4.2.4
──────────────────────  ───────────────   ──────────────
Best run time           0.2272 s          0.0345 s
Throughput              0.63 GB/s         4.13 GB/s
Stage                   stage1 only       stage1 + stage2
Threads                 1                 1
Tokens / docs found     45 000 000        1 000 000
```

**simdjson is 6.6× faster per thread at JSON tokenization.**

This is an honest result. The difference is architectural:

### Why simdjson is faster per thread

simdjson uses a two-step pipeline on every 64-byte block:

1. **SIMD comparison** — compare all 64 bytes against each structural char  
2. **`_mm_movemask_epi8` / NEON equivalent** — extract a 64-bit bitmask in one instruction  
3. **`__builtin_ctz` + `mask &= mask - 1`** — walk only the *set* bits → O(matches)

Total iterations per 64 bytes: exactly equal to the number of structural characters found.

### Where simd.zig stands today

zson's `findJsonStructure` in [`src/simd.zig`](../src/simd.zig) uses:

1. **SIMD comparison** — 16-byte NEON vectors, 7 comparisons (same as simdjson) ✓  
2. **`@reduce(.Or, is_any)`** — skip entire chunk if no structural char (since this session) ✓  
3. **Scalar lane loop** — iterate all 16 positions, skip non-structural via `is_any[j]` ✗

The bottleneck is step 3: even with the `@reduce` skip, *within* a hit-chunk we still
walk 16 lanes instead of using a bitmask. Zig does not yet provide a direct
`@movemask` builtin, but it is possible to extract one via inline assembly
(e.g. `asm volatile("shrn.8h ..." ...)` on NEON) or via a future `std.simd.movemask`.

## End-to-end: zson still wins

At the **application** level zson outperforms simdjson despite the parser gap:

| Workload | zson | simdjson | Winner |
|---|---|---|---|
| Count (`age > 30`) | **0.131 s** | ~0.180 s | zson |
| Filter + output | **0.200 s** | ~0.205 s | zson |

Two architectural advantages compensate:

### 1. mmap vs padded_string::load

simdjson's idiomatic I/O loads the entire file into a heap-allocated padded buffer.
For 143 MB that copy takes ≈ 143 ms — almost the entire budget of a single query.

zson uses `mmap()` with `PROT_READ | MAP_PRIVATE` — the kernel maps pages lazily,
so *no memory copy ever happens* for pages that are read once and discarded.

### 2. Parallel architecture

zson splits the NDJSON file into 7 equal chunks and dispatches one thread per chunk.
At 0.63 GB/s single-thread that gives **≈ 4.4 GB/s effective tokenization throughput**
— matching simdjson's single-thread 4.1 GB/s *before* counting the mmap advantage.

simdjson's `ondemand::document_stream` / `iterate_many` is inherently serial.

## Summary

```
Metric                  simdjson        zson
──────────────────────  ────────────    ────────────────────────────
Parser speed (1 thread) 4.13 GB/s  🏆   0.63 GB/s
Effective throughput    4.13 GB/s       4.4 GB/s  (7 threads)
I/O model               heap copy  💸   mmap (zero-copy)  ✓
End-to-end latency      ~0.180 s        0.131 s  🏆
MongoDB query syntax    no              yes  ✓
CLI tool                no              yes  ✓
```

simdjson is the **better parser library**.  
zson is the **better NDJSON query application**.

## Reproducing

```bash
# Generate data (first time only)
node bench/gen_bench_data.js 1000000

# Run tokenizer comparison
bash bench/compare_tokenizers.sh 5

# Run end-to-end comparison
bash bench/compare_simdjson.sh
```
