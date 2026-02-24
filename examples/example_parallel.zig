const std = @import("std");

// Import from root module
const root = @import("zson");
const parallel = root.parallel_ndjson;
const query = root.query;
const json_parser = root.json_parser;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("🚀 ZSON Phase 5: Parallel NDJSON Engine Demo\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    // Test 1: Single-threaded vs Multi-threaded comparison
    std.debug.print("📊 Performance Comparison: Single vs Multi-threaded\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});

    // Generate test data
    var test_data = std.ArrayList(u8){};
    defer test_data.deinit(allocator);
    const writer = test_data.writer(allocator);

    const num_records = 10000;
    std.debug.print("Generating {d} JSON records...\n", .{num_records});

    for (0..num_records) |i| {
        const age = 20 + (i % 50);
        const cities = [_][]const u8{ "NYC", "LA", "Chicago", "Houston", "Phoenix" };
        const city = cities[i % cities.len];
        try writer.print("{{\"id\": {d}, \"name\": \"User{d}\", \"age\": {d}, \"city\": \"{s}\", \"active\": {s}}}\n", .{
            i,
            i,
            age,
            city,
            if (i % 3 == 0) "true" else "false",
        });
    }

    std.debug.print("Generated {d} bytes of NDJSON data\n\n", .{test_data.items.len});

    // Query: age >= 40 AND active = true
    const query_str = "{\"age\": {\"$gte\": 40}, \"active\": true}";
    std.debug.print("Query: {s}\n\n", .{query_str});

    var parsed_query = try query.parseQuery(query_str, allocator);
    defer parsed_query.deinit(allocator);

    // Test 1: Single-threaded
    {
        const start = std.time.nanoTimestamp();
        var result = try parallel.processData(
            test_data.items,
            &parsed_query.filter,
            .{ .num_threads = 1 },
            allocator,
        );
        defer result.deinit();
        const elapsed = std.time.nanoTimestamp() - start;

        std.debug.print("🔸 Single-threaded:\n", .{});
        std.debug.print("   Processed: {d} lines\n", .{result.lines_processed});
        std.debug.print("   Matches:   {d} records\n", .{result.matches.items.len});
        std.debug.print("   Time:      {d:.2}ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
        std.debug.print("   Throughput: {d:.0} lines/sec\n\n", .{
            @as(f64, @floatFromInt(result.lines_processed)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0),
        });
    }

    // Test 2: Multi-threaded (4 threads)
    {
        const start = std.time.nanoTimestamp();
        var result = try parallel.processData(
            test_data.items,
            &parsed_query.filter,
            .{ .num_threads = 4 },
            allocator,
        );
        defer result.deinit();
        const elapsed = std.time.nanoTimestamp() - start;

        std.debug.print("🔹 Multi-threaded (4 threads):\n", .{});
        std.debug.print("   Processed: {d} lines\n", .{result.lines_processed});
        std.debug.print("   Matches:   {d} records\n", .{result.matches.items.len});
        std.debug.print("   Time:      {d:.2}ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
        std.debug.print("   Throughput: {d:.0} lines/sec\n\n", .{
            @as(f64, @floatFromInt(result.lines_processed)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0),
        });
    }

    // Test 3: Multi-threaded (7 threads)
    {
        const start = std.time.nanoTimestamp();
        var result = try parallel.processData(
            test_data.items,
            &parsed_query.filter,
            .{ .num_threads = 7 },
            allocator,
        );
        defer result.deinit();
        const elapsed = std.time.nanoTimestamp() - start;

        std.debug.print("🔷 Multi-threaded (7 threads):\n", .{});
        std.debug.print("   Processed: {d} lines\n", .{result.lines_processed});
        std.debug.print("   Matches:   {d} records\n", .{result.matches.items.len});
        std.debug.print("   Time:      {d:.2}ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
        std.debug.print("   Throughput: {d:.0} lines/sec\n\n", .{
            @as(f64, @floatFromInt(result.lines_processed)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0),
        });
    }

    // Test 4: Simple query test with inline data
    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("📁 Additional Test: Simple Query\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    const simple_data =
        \\{"name": "Alice", "age": 28, "city": "NYC", "active": true}
        \\{"name": "Bob", "age": 35, "city": "LA", "active": true}
        \\{"name": "Charlie", "age": 42, "city": "Chicago", "active": false}
        \\{"name": "Diana", "age": 31, "city": "Houston", "active": true}
        \\{"name": "Eve", "age": 26, "city": "Phoenix", "active": false}
        \\{"name": "Frank", "age": 45, "city": "NYC", "active": true}
        \\{"name": "Grace", "age": 38, "city": "LA", "active": true}
        \\{"name": "Henry", "age": 29, "city": "Chicago", "active": false}
        \\
    ;

    const simple_query = "{\"age\": {\"$gt\": 30}}";
    std.debug.print("Query: {s}\n\n", .{simple_query});

    var simple_parsed = try query.parseQuery(simple_query, allocator);
    defer simple_parsed.deinit(allocator);

    var file_result = try parallel.processData(
        simple_data,
        &simple_parsed.filter,
        .{ .num_threads = 4 },
        allocator,
    );
    defer file_result.deinit();

    std.debug.print("Results:\n", .{});
    std.debug.print("  Lines processed: {d}\n", .{file_result.lines_processed});
    std.debug.print("  Matches found:   {d}\n\n", .{file_result.matches.items.len});

    std.debug.print("Matching records:\n", .{});
    for (file_result.matches.items) |obj| {
        const name_val = obj.get("name");
        const age_val = obj.get("age");
        const city_val = obj.get("city");
        
        const name = if (name_val) |v| json_parser.getString(v) catch "unknown" else "unknown";
        const age = if (age_val) |v| json_parser.getInt(v) catch 0 else 0;
        const city = if (city_val) |v| json_parser.getString(v) catch "unknown" else "unknown";
        
        std.debug.print("  - {s}, age {d}, from {s}\n", .{ name, age, city });
    }

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("✅ Phase 5: Parallel NDJSON Engine (COMPLETE!)\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("\nNext Steps:\n", .{});
    std.debug.print("  • Phase 6: CLI Interface\n", .{});
    std.debug.print("  • Phase 7: Output Formatters (JSON/CSV)\n", .{});
    std.debug.print("  • Phase 8: Benchmarking vs jq/jaq/DuckDB\n", .{});
    std.debug.print("\n", .{});
}
