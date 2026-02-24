//! tokenizer_bench.zig
//!
//! Sweeps SIMD chunk sizes (16 / 32 / 64 / 128 bytes) to find the best
//! vector width for simd.zig::findJsonStructureN on the current CPU.
//!
//! On aarch64 (Apple Silicon) the native NEON register is 16 bytes.
//! Larger chunk sizes make the compiler emit multiple NEON instructions
//! per loop iteration, trading register pressure for reduced loop overhead.
//!
//! Usage: zig build bench-tokenizer -- bench/bench_data.ndjson [iterations]

const std = @import("std");
const simd = @import("simd"); // imported via build.zig module alias

const MAX_TOKENS = 64 * 1024 * 1024; // 64 M — enough for 1 M records

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

    const data = try std.posix.mmap(
        null,
        file_size,
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    defer std.posix.munmap(data);

    const gb = @as(f64, @floatFromInt(file_size)) / 1e9;
    const tokens = try alloc.alloc(simd.Token, MAX_TOKENS);

    std.debug.print("File   : {s}  ({d:.3} GB)\n", .{ filename, gb });
    std.debug.print("Iters  : {d}  (best run reported)\n\n", .{iters});

    // ── Sweep chunk sizes ─────────────────────────────────────────────────────
    const sizes = [_]usize{ 16, 32, 64, 128 };
    var best_gbs: [sizes.len]f64 = undefined;
    var tok_counts: [sizes.len]usize = undefined;

    inline for (sizes, 0..) |sz, si| {
        // warm-up
        _ = simd.findJsonStructureN(sz, data, tokens);

        var best: f64 = std.math.inf(f64);
        var total_toks: usize = 0;

        std.debug.print("chunk={d:3}  ", .{sz});
        for (0..iters) |iter| {
            @memset(tokens, std.mem.zeroes(simd.Token));
            const t0 = std.time.nanoTimestamp();
            const n = simd.findJsonStructureN(sz, data, tokens);
            const elapsed = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e9;
            if (iter == 0) total_toks = n;
            if (elapsed < best) best = elapsed;
            std.debug.print("{d:.3}s ", .{elapsed});
        }
        best_gbs[si] = gb / best;
        tok_counts[si] = total_toks;
        std.debug.print(" | best {d:.2} GB/s  tokens={d}\n", .{ best_gbs[si], total_toks });
    }

    // ── Summary table ─────────────────────────────────────────────────────────
    std.debug.print(
        \\
        \\── chunk size sweep ────────────────────────────────
        \\  chunk   GB/s   tokens      vs 16-byte
        \\  ─────   ────   ──────      ──────────
        \\
    , .{});

    const base = best_gbs[0];
    inline for (sizes, 0..) |sz, si| {
        const ratio = best_gbs[si] / base;
        const marker: []const u8 = if (best_gbs[si] == blk: {
            var m = best_gbs[0];
            for (best_gbs) |v| if (v > m) { m = v; };
            break :blk m;
        }) " ← best" else "";
        std.debug.print("  {d:5}  {d:5.2}  {d:10}  {d:.2}×{s}\n", .{
            sz, best_gbs[si], tok_counts[si], ratio, marker,
        });
    }
    std.debug.print("\n", .{});

    // Machine-readable for compare_tokenizers.sh (uses chunk=16 baseline)
    var out_buf: [256]u8 = undefined;
    const out_line = try std.fmt.bufPrint(
        &out_buf,
        "zson_gb_per_sec={d:.2} zson_best_sec={d:.4} zson_tokens={d}\n",
        .{ best_gbs[0], gb / best_gbs[0], tok_counts[0] },
    );
    _ = try std.posix.write(std.posix.STDOUT_FILENO, out_line);
}

