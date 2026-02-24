//! tokenizer_bench.zig
//!
//! Measures the throughput of simd.zig::findJsonStructure.
//! This is the apples-to-apples comparison with simd.cpp (simdjson stage1).
//!
//! What is being measured
//! ──────────────────────
//!   Input : raw bytes of a NDJSON file (already mmap'd — zero-copy into mem)
//!   Output: count of structural tokens found  { } [ ] " : ,
//!   Metric: GB/s
//!
//! The file is mapped once OUTSIDE the timing loop so disk I/O is excluded.
//! Each iteration scans the entire in-memory buffer from scratch.
//!
//! Usage: zig build bench-tokenizer -- bench/bench_data.ndjson [iterations]

const std = @import("std");
const simd = @import("simd"); // imported via build.zig module alias

const MAX_TOKENS = 64 * 1024 * 1024; // 64 M tokens — enough for 1 M records × ~60 tokens each

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // ── Parse args ────────────────────────────────────────────────────────────
    const args = try std.process.argsAlloc(alloc);
    if (args.len < 2) {
        std.debug.print("Usage: {s} <file.ndjson> [iterations]\n", .{args[0]});
        return error.MissingArgument;
    }
    const filename = args[1];
    const iters: usize = if (args.len >= 3) try std.fmt.parseInt(usize, args[2], 10) else 5;

    // ── Open & mmap file ──────────────────────────────────────────────────────
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    const file_size = (try file.stat()).size;

    // Use mmap for zero-copy I/O (same as the application path)
    const data = try std.posix.mmap(
        null,
        file_size,
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    defer std.posix.munmap(data);

    std.debug.print("File loaded : {s}\n", .{filename});
    std.debug.print("File size   : {d:.3} GB  ({d} bytes)\n", .{ @as(f64, @floatFromInt(file_size)) / 1e9, file_size });

    // ── Allocate token buffer (reused across iterations) ──────────────────────
    const tokens = try alloc.alloc(simd.Token, MAX_TOKENS);
    std.debug.print("Token buf   : {d:.1} MB  (max {d} tokens)\n\n", .{ @as(f64, @floatFromInt(tokens.len * @sizeOf(simd.Token))) / 1e6, tokens.len });

    // ── Warm-up (1 pass, not timed) ───────────────────────────────────────────
    _ = simd.findJsonStructure(data, tokens);

    // ── Timed iterations ──────────────────────────────────────────────────────
    std.debug.print("Running {d} timed iteration(s)...\n", .{iters});

    var best_secs: f64 = std.math.inf(f64);
    var total_secs: f64 = 0;
    var total_tokens: usize = 0;
    var run_times = try alloc.alloc(f64, iters);

    for (0..iters) |iter| {
        @memset(tokens, std.mem.zeroes(simd.Token));

        const t0 = std.time.nanoTimestamp();
        const n = simd.findJsonStructure(data, tokens);
        const elapsed = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e9;

        run_times[iter] = elapsed;
        total_secs += elapsed;
        total_tokens += n;

        if (elapsed < best_secs) best_secs = elapsed;

        std.debug.print("  iter {d:2}: {d:.4}s  tokens={d}  {d:.2} GB/s\n", .{ iter + 1, elapsed, n, @as(f64, @floatFromInt(file_size)) / 1e9 / elapsed });
    }

    const avg_secs = total_secs / @as(f64, @floatFromInt(iters));
    const tokens_per_iter = total_tokens / iters;

    const gb = @as(f64, @floatFromInt(file_size)) / 1e9;
    std.debug.print(
        \\
        \\── Summary ──────────────────────────────────────────────────────────
        \\  tokens/iter   : {d}
        \\  best run      : {d:.4}s  →  {d:.2} GB/s
        \\  avg  run      : {d:.4}s  →  {d:.2} GB/s
        \\
    , .{
        tokens_per_iter,
        best_secs,
        gb / best_secs,
        avg_secs,
        gb / avg_secs,
    });

    // Machine-readable line for the comparison script (stdout)
    var out_buf: [256]u8 = undefined;
    const out_line = try std.fmt.bufPrint(
        &out_buf,
        "zson_gb_per_sec={d:.2} zson_best_sec={d:.4} zson_tokens={d}\n",
        .{ gb / best_secs, best_secs, tokens_per_iter },
    );
    _ = try std.posix.write(std.posix.STDOUT_FILENO, out_line);
}
