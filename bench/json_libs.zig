//! Compare zson's parsed-object query path with Zig std.json parsing.
//! Optional rows for jq and DuckDB are included when those commands are present.
//!
//!   zig build bench-json

const std = @import("std");
const zson = @import("zson");

const Record = struct {
    id: usize,
    age: usize,
    city: []const u8,
    active: bool,
    salary: usize,
};

const BenchResult = struct {
    name: []const u8,
    matches: usize,
    ms: f64,
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const records: usize = 100_000;

    var data = try generateNdjson(allocator, records);
    defer data.deinit(allocator);
    const data_path = ".zig-cache/bench/json_libs.ndjson";
    try writeBenchData(data_path, data.items);

    std.debug.print("Dataset: {d} records, {d:.2} MB\n", .{
        records,
        @as(f64, @floatFromInt(data.items.len)) / (1024.0 * 1024.0),
    });
    std.debug.print("Filter: age >= 40 AND active == true\n\n", .{});

    var results = std.ArrayList(BenchResult).empty;
    defer results.deinit(allocator);

    try results.append(allocator, try benchZson(data.items, allocator, 1));
    try results.append(allocator, try benchZson(data.items, allocator, 4));
    try results.append(allocator, try benchStdJsonValue(data.items, allocator));
    try results.append(allocator, try benchStdJsonTyped(data.items, allocator));
    if (try benchJq(data_path, allocator)) |result| try results.append(allocator, result);
    if (try benchDuckDb(data_path, allocator)) |result| try results.append(allocator, result);

    std.debug.print("{s:<24} {s:>10} {s:>12}\n", .{ "library", "matches", "time" });
    std.debug.print("{s:-<24} {s:->10} {s:->12}\n", .{ "", "", "" });
    for (results.items) |r| {
        std.debug.print("{s:<24} {d:>10} {d:>9.2} ms\n", .{ r.name, r.matches, r.ms });
    }
}

fn writeBenchData(path: []const u8, data: []const u8) !void {
    try std.fs.cwd().makePath(".zig-cache/bench");
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

fn generateNdjson(allocator: std.mem.Allocator, count: usize) !std.ArrayList(u8) {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    const cities = [_][]const u8{ "NYC", "LA", "Chicago", "Houston", "Phoenix" };
    const writer = buf.writer(allocator);
    for (0..count) |i| {
        try writer.print(
            "{{\"id\":{d},\"age\":{d},\"city\":\"{s}\",\"active\":{s},\"salary\":{d}}}\n",
            .{
                i,
                18 + (i % 55),
                cities[i % cities.len],
                if (i % 3 == 0) "true" else "false",
                45_000 + (i % 90_000),
            },
        );
    }

    return buf;
}

fn benchZson(data: []const u8, allocator: std.mem.Allocator, threads: usize) !BenchResult {
    const q = "{\"age\":{\"$gte\":40},\"active\":true}";

    // Warm up once so timing is less dominated by first-use effects.
    var warmup = try zson.queryData(data, q, .{ .num_threads = threads }, allocator);
    warmup.deinit();

    const start = std.time.nanoTimestamp();
    var result = try zson.queryData(data, q, .{ .num_threads = threads }, allocator);
    defer result.deinit();
    const elapsed = std.time.nanoTimestamp() - start;

    return .{
        .name = if (threads == 1) "zson parsed (1 thread)" else "zson parsed (4 threads)",
        .matches = result.len(),
        .ms = nanosToMs(elapsed),
    };
}

fn benchStdJsonValue(data: []const u8, allocator: std.mem.Allocator) !BenchResult {
    _ = try countStdJsonValue(data, allocator);

    const start = std.time.nanoTimestamp();
    const matches = try countStdJsonValue(data, allocator);
    const elapsed = std.time.nanoTimestamp() - start;

    return .{
        .name = "std.json Value",
        .matches = matches,
        .ms = nanosToMs(elapsed),
    };
}

fn countStdJsonValue(data: []const u8, allocator: std.mem.Allocator) !usize {
    var matches: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        const age = valueAsUsize(obj.get("age") orelse continue) orelse continue;
        const active = (obj.get("active") orelse continue).bool;

        if (age >= 40 and active) matches += 1;
    }

    return matches;
}

fn benchStdJsonTyped(data: []const u8, allocator: std.mem.Allocator) !BenchResult {
    _ = try countStdJsonTyped(data, allocator);

    const start = std.time.nanoTimestamp();
    const matches = try countStdJsonTyped(data, allocator);
    const elapsed = std.time.nanoTimestamp() - start;

    return .{
        .name = "std.json typed",
        .matches = matches,
        .ms = nanosToMs(elapsed),
    };
}

fn countStdJsonTyped(data: []const u8, allocator: std.mem.Allocator) !usize {
    var matches: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const parsed = try std.json.parseFromSlice(Record, allocator, line, .{});
        defer parsed.deinit();

        if (parsed.value.age >= 40 and parsed.value.active) matches += 1;
    }

    return matches;
}

fn benchJq(path: []const u8, allocator: std.mem.Allocator) !?BenchResult {
    const args = [_][]const u8{
        "jq",
        "-n",
        "reduce inputs as $x (0; if ($x.age >= 40 and $x.active == true) then . + 1 else . end)",
        path,
    };
    return benchExternal("jq", &args, allocator);
}

fn benchDuckDb(path: []const u8, allocator: std.mem.Allocator) !?BenchResult {
    const sql = try std.fmt.allocPrint(
        allocator,
        "SELECT count(*) FROM read_ndjson_auto('{s}') WHERE age >= 40 AND active = true;",
        .{path},
    );
    defer allocator.free(sql);

    const args = [_][]const u8{
        "duckdb",
        "-csv",
        "-noheader",
        "-c",
        sql,
    };
    return benchExternal("duckdb", &args, allocator);
}

fn benchExternal(name: []const u8, args: []const []const u8, allocator: std.mem.Allocator) !?BenchResult {
    _ = runExternalCount(args, allocator) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    const start = std.time.nanoTimestamp();
    const matches = runExternalCount(args, allocator) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const elapsed = std.time.nanoTimestamp() - start;

    return .{
        .name = name,
        .matches = matches,
        .ms = nanosToMs(elapsed),
    };
}

fn runExternalCount(args: []const []const u8, allocator: std.mem.Allocator) !usize {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.ExternalCommandFailed,
        else => return error.ExternalCommandFailed,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    return std.fmt.parseInt(usize, trimmed, 10);
}

fn valueAsUsize(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .float => |f| if (f >= 0) @intFromFloat(f) else null,
        .number_string => |s| std.fmt.parseInt(usize, s, 10) catch null,
        else => null,
    };
}

fn nanosToMs(nanos: i128) f64 {
    return @as(f64, @floatFromInt(nanos)) / 1_000_000.0;
}
