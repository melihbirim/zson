const std = @import("std");
const json_parser = @import("json_parser.zig");
const parallel = @import("parallel_ndjson.zig");
const query_mod = @import("query.zig");

pub const Options = struct {
    num_threads: usize = 4,
};

pub const QueryResult = struct {
    inner: parallel.ChunkResult,

    pub fn deinit(self: *QueryResult) void {
        self.inner.deinit();
    }

    pub fn items(self: *const QueryResult) []const json_parser.JsonObject {
        return self.inner.matches.items;
    }

    pub fn len(self: *const QueryResult) usize {
        return self.inner.matches.items.len;
    }
};

/// Query NDJSON or a JSON array from an in-memory buffer.
///
/// Matched objects are parsed `JsonObject` values. Simple field values are
/// zero-copy slices into `data`, so `data` must outlive the returned result
/// when querying NDJSON input. JSON array input is converted internally and
/// owned by the result.
pub fn queryData(
    data: []const u8,
    query: []const u8,
    options: Options,
    allocator: std.mem.Allocator,
) !QueryResult {
    var parsed_query = try query_mod.parseQuery(query, allocator);
    defer parsed_query.deinit(allocator);

    return .{ .inner = try parallel.processData(
        data,
        &parsed_query.filter,
        .{ .num_threads = options.num_threads },
        allocator,
    ) };
}

/// Query an NDJSON buffer from memory.
pub fn queryNdjson(
    data: []const u8,
    query: []const u8,
    allocator: std.mem.Allocator,
) !QueryResult {
    return queryData(data, query, .{}, allocator);
}

/// Query a file containing NDJSON or a JSON array.
///
/// The result owns the mapped or allocated backing data needed by returned
/// objects and must be deinitialized by the caller.
pub fn queryFile(
    path: []const u8,
    query: []const u8,
    options: Options,
    allocator: std.mem.Allocator,
) !QueryResult {
    var parsed_query = try query_mod.parseQuery(query, allocator);
    defer parsed_query.deinit(allocator);

    return .{ .inner = try parallel.processFile(
        path,
        &parsed_query.filter,
        .{ .num_threads = options.num_threads },
        allocator,
    ) };
}

test "api: query ndjson returns parsed native objects" {
    const data =
        \\{"id":1,"name":"Alice","age":30}
        \\{"id":2,"name":"Bob","age":35}
        \\
    ;

    var result = try queryNdjson(data, "{\"age\":{\"$gt\":30}}", std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.len());
    try std.testing.expectEqualStrings("Bob", result.items()[0].get("name").?.string);
}

test "api: query JSON array returns parsed native objects" {
    const data = "[{\"id\":1,\"age\":20},{\"id\":2,\"age\":40}]";

    var result = try queryData(data, "{\"age\":{\"$gte\":30}}", .{ .num_threads = 1 }, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.len());
    try std.testing.expectEqualStrings("2", result.items()[0].get("id").?.number);
}
