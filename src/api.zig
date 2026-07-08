const std = @import("std");
const json_parser = @import("json_parser.zig");
const parallel = @import("parallel_ndjson.zig");
const query_mod = @import("query.zig");

pub const Filter = query_mod.Filter;
pub const Value = query_mod.Value;

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

/// Native Zig query builders.
///
/// Filters returned by `q` borrow field names and string values. They are meant
/// to be passed directly to `queryDataWhere`, `queryNdjsonWhere`, or
/// `queryFileWhere`, and must not be deinitialized.
pub const q = struct {
    pub fn nil() Value {
        return .{ .null_value = {} };
    }

    pub fn boolean(value: bool) Value {
        return .{ .bool_value = value };
    }

    pub fn number(value: f64) Value {
        return .{ .number = value };
    }

    pub fn string(value: []const u8) Value {
        return .{ .string = value };
    }

    pub fn eq(field: []const u8, value: Value) Filter {
        return comparison(field, .eq, value);
    }

    pub fn ne(field: []const u8, value: Value) Filter {
        return comparison(field, .ne, value);
    }

    pub fn gt(field: []const u8, value: Value) Filter {
        return comparison(field, .gt, value);
    }

    pub fn gte(field: []const u8, value: Value) Filter {
        return comparison(field, .gte, value);
    }

    pub fn lt(field: []const u8, value: Value) Filter {
        return comparison(field, .lt, value);
    }

    pub fn lte(field: []const u8, value: Value) Filter {
        return comparison(field, .lte, value);
    }

    pub fn all(filters: []Filter) Filter {
        return logical(.@"and", filters);
    }

    pub fn any(filters: []Filter) Filter {
        return logical(.@"or", filters);
    }

    pub fn none(filters: []Filter) Filter {
        return logical(.nor, filters);
    }

    pub fn not(filter: *Filter) Filter {
        return logical(.not, filter[0..1]);
    }

    pub fn exists(field: []const u8) Filter {
        return .{ .exists = .{
            .field = field,
            .should_exist = true,
        } };
    }

    pub fn missing(field: []const u8) Filter {
        return .{ .exists = .{
            .field = field,
            .should_exist = false,
        } };
    }

    pub fn in(field: []const u8, values: []Value) Filter {
        return .{ .array_op = .{
            .field = field,
            .op = .in,
            .values = values,
        } };
    }

    pub fn nin(field: []const u8, values: []Value) Filter {
        return .{ .array_op = .{
            .field = field,
            .op = .nin,
            .values = values,
        } };
    }

    pub fn regex(field: []const u8, pattern: []const u8) Filter {
        return regexWithOptions(field, pattern, "");
    }

    pub fn regexWithOptions(field: []const u8, pattern: []const u8, options: []const u8) Filter {
        return .{ .regex_match = .{
            .field = field,
            .pattern = pattern,
            .options = options,
        } };
    }

    pub fn size(field: []const u8, expected: usize) Filter {
        return .{ .size_match = .{
            .field = field,
            .size = expected,
        } };
    }

    pub fn typeIs(field: []const u8, type_name: []const u8) Filter {
        return .{ .type_match = .{
            .field = field,
            .type_name = type_name,
        } };
    }

    fn comparison(field: []const u8, op: query_mod.Comparison.CompOp, value: Value) Filter {
        return .{ .comparison = .{
            .field = field,
            .op = op,
            .value = value,
        } };
    }

    fn logical(op: query_mod.Logical.LogicalOp, filters: []Filter) Filter {
        return .{ .logical = .{
            .op = op,
            .operands = filters,
        } };
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

/// Query NDJSON or a JSON array from an in-memory buffer with a native filter.
pub fn queryDataWhere(
    data: []const u8,
    filter: Filter,
    options: Options,
    allocator: std.mem.Allocator,
) !QueryResult {
    return .{ .inner = try parallel.processData(
        data,
        &filter,
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

/// Query an NDJSON buffer from memory with a native filter.
pub fn queryNdjsonWhere(
    data: []const u8,
    filter: Filter,
    allocator: std.mem.Allocator,
) !QueryResult {
    return queryDataWhere(data, filter, .{}, allocator);
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

/// Query a file containing NDJSON or a JSON array with a native filter.
pub fn queryFileWhere(
    path: []const u8,
    filter: Filter,
    options: Options,
    allocator: std.mem.Allocator,
) !QueryResult {
    return .{ .inner = try parallel.processFile(
        path,
        &filter,
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

test "api: query ndjson with native filter" {
    const data =
        \\{"id":1,"name":"Alice","age":30,"city":"NYC","active":true}
        \\{"id":2,"name":"Bob","age":35,"city":"LA","active":true}
        \\{"id":3,"name":"Iris","age":45,"city":"NYC","active":true}
        \\
    ;

    var filters = [_]Filter{
        q.eq("city", q.string("NYC")),
        q.eq("active", q.boolean(true)),
        q.gte("age", q.number(30)),
    };

    var result = try queryNdjsonWhere(data, q.all(&filters), std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.len());
    try std.testing.expectEqualStrings("Alice", result.items()[0].get("name").?.string);
    try std.testing.expectEqualStrings("Iris", result.items()[1].get("name").?.string);
}

test "api: query JSON array returns parsed native objects" {
    const data = "[{\"id\":1,\"age\":20},{\"id\":2,\"age\":40}]";

    var result = try queryData(data, "{\"age\":{\"$gte\":30}}", .{ .num_threads = 1 }, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.len());
    try std.testing.expectEqualStrings("2", result.items()[0].get("id").?.number);
}
