const std = @import("std");
const json_parser = @import("json_parser.zig");
const query = @import("query.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n🔍 zson - MongoDB Query Engine Demo\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    // Read sample data
    const file = try std.fs.cwd().openFile("examples/sample.ndjson", .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Parse all objects into memory
    var objects = std.ArrayList(json_parser.JsonObject){};
    defer {
        for (objects.items) |*obj| obj.deinit();
        objects.deinit(allocator);
    }

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const obj = try json_parser.parseObject(line, allocator);
        try objects.append(allocator, obj);
    }

    std.debug.print("Loaded {d} objects from sample.ndjson\n\n", .{objects.items.len});

    // Test queries
    const test_queries = [_][]const u8{
        "{\"age\":{\"$gt\":30}}",
        "{\"city\":\"NYC\"}",
        "{\"active\":true}",
        "{\"age\":{\"$gte\":30},\"city\":\"LA\"}",
        "{\"name\":{\"$exists\":true}}",
    };

    const descriptions = [_][]const u8{
        "Find people older than 30",
        "Find people in NYC",
        "Find active users",
        "Find people age >= 30 in LA",
        "Find objects with 'name' field",
    };

    for (test_queries, descriptions, 1..) |query_str, desc, i| {
        std.debug.print("Query {d}: {s}\n", .{ i, desc });
        std.debug.print("MongoDB: {s}\n", .{query_str});
        std.debug.print("-" ** 70 ++ "\n", .{});

        var q = try query.parseQuery(query_str, allocator);
        defer q.deinit(allocator);

        var match_count: usize = 0;
        var results = std.ArrayList(*json_parser.JsonObject){};
        defer results.deinit(allocator);

        for (objects.items) |*obj| {
            if (query.matches(obj, &q.filter)) {
                match_count += 1;
                try results.append(allocator, obj);
            }
        }

        std.debug.print("✓ Found {d} match(es)\n", .{match_count});

        // Show first 3 results
        const show_limit = @min(3, results.items.len);
        if (show_limit > 0) {
            std.debug.print("\nResults:\n", .{});
            for (results.items[0..show_limit], 1..) |obj, j| {
                std.debug.print("  {d}. ", .{j});

                // Print id, name, age, city
                if (obj.get("id")) |id_val| {
                    const id = try json_parser.getInt(id_val);
                    std.debug.print("id={d} ", .{id});
                }
                if (obj.get("name")) |name_val| {
                    const name = try json_parser.getString(name_val);
                    std.debug.print("name=\"{s}\" ", .{name});
                }
                if (obj.get("age")) |age_val| {
                    const age = try json_parser.getInt(age_val);
                    std.debug.print("age={d} ", .{age});
                }
                if (obj.get("city")) |city_val| {
                    const city = try json_parser.getString(city_val);
                    std.debug.print("city=\"{s}\"", .{city});
                }
                std.debug.print("\n", .{});
            }
            if (results.items.len > 3) {
                std.debug.print("  ... and {d} more\n", .{results.items.len - 3});
            }
        }

        std.debug.print("\n", .{});
    }

    // Performance test
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("Performance Test: Execute 1000 queries\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});

    const perf_query_str = "{\"age\":{\"$gt\":25}}";
    var perf_query = try query.parseQuery(perf_query_str, allocator);
    defer perf_query.deinit(allocator);

    const start_time = std.time.milliTimestamp();
    var total_matches: usize = 0;

    for (0..1000) |_| {
        for (objects.items) |*obj| {
            if (query.matches(obj, &perf_query.filter)) {
                total_matches += 1;
            }
        }
    }

    const end_time = std.time.milliTimestamp();
    const elapsed = end_time - start_time;

    const queries_per_sec = (@as(f64, 1000.0) / @as(f64, @floatFromInt(elapsed))) * 1000.0;
    const evals_per_sec = queries_per_sec * @as(f64, @floatFromInt(objects.items.len));

    std.debug.print("✓ Executed 1000 queries over {d} objects in {d}ms\n", .{ objects.items.len, elapsed });
    std.debug.print("✓ Throughput: {d:.0} queries/sec\n", .{queries_per_sec});
    std.debug.print("✓ Evaluations: {d:.0} checks/sec\n", .{evals_per_sec});
    std.debug.print("\n", .{});

    std.debug.print("🎯 Next Steps:\n", .{});
    std.debug.print("  ✓ Phase 1: SIMD tokenization (DONE)\n", .{});
    std.debug.print("  ✓ Phase 2: Zero-copy parsing (DONE)\n", .{});
    std.debug.print("  ✓ Phase 3: MongoDB query engine (DONE) ⭐\n", .{});
    std.debug.print("  → Phase 4: Parallel NDJSON processing (copy from sieswi)\n", .{});
    std.debug.print("  → Phase 5: CLI interface\n", .{});
    std.debug.print("  → Phase 6: Beat jq by 10x!\n", .{});
    std.debug.print("\n", .{});
}
