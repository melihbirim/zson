//! Demonstrates parallel NDJSON processing.
//! Generates records in-memory, runs a query with 1 and 4 threads,
//! and prints timing for each.
//!
//!   zig build example-parallel

const std = @import("std");
const zson = @import("zson");
const parallel = zson.parallel_ndjson;
const query = zson.query;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Generate 50 000 records in memory
    const n = 50_000;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    const cities = [_][]const u8{ "NYC", "LA", "Chicago", "Houston", "Phoenix" };
    for (0..n) |i| {
        try w.print(
            "{{\"id\":{d},\"age\":{d},\"city\":\"{s}\",\"active\":{s}}}\n",
            .{ i, 20 + i % 50, cities[i % cities.len], if (i % 3 == 0) "true" else "false" },
        );
    }

    const q_str = "{\"age\":{\"$gte\":40},\"active\":true}";
    var q = try query.parseQuery(q_str, allocator);
    defer q.deinit(allocator);

    std.debug.print("Query: {s}\n", .{q_str});
    std.debug.print("{d} records, {d:.1} KB\n\n", .{ n, @as(f64, @floatFromInt(buf.items.len)) / 1024.0 });

    // Run with 1 and 4 threads, compare
    for ([_]usize{ 1, 4 }) |threads| {
        var result = try parallel.processData(
            buf.items,
            &q.filter,
            .{ .num_threads = threads },
            allocator,
        );
        defer result.deinit();

        const t0 = std.time.nanoTimestamp();
        var r2 = try parallel.processData(buf.items, &q.filter, .{ .num_threads = threads }, allocator);
        const ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1_000_000.0;
        r2.deinit();

        std.debug.print("  threads={d}  matches={d}  {d:.2}ms\n", .{
            threads, result.matches.items.len, ms,
        });
    }
}
