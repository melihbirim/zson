const std = @import("std");
const json_parser = @import("json_parser.zig");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("regex.h");
});

/// Query parsing errors
pub const QueryError = error{
    InvalidOperator,
    InvalidQuery,
    ExpectedObject,
    ExpectedArray,
    UnsupportedOperator,
    UnsupportedValueType,
    UnsupportedQueryStructure,
} || Allocator.Error || json_parser.ParseError;

/// MongoDB query AST
pub const Query = struct {
    filter: Filter,
    projection: ?[][]const u8 = null, // Future: field selection

    pub fn deinit(self: *Query, allocator: Allocator) void {
        self.filter.deinit(allocator);
        if (self.projection) |proj| {
            allocator.free(proj);
        }
    }
};

/// Filter represents a MongoDB query condition
pub const Filter = union(enum) {
    comparison: Comparison,
    logical: Logical,
    array_op: ArrayOp,
    exists: Exists,
    regex_match: RegexMatch,
    size_match: SizeMatch,
    type_match: TypeMatch,
    always_true: void, // For empty query {}

    pub fn deinit(self: *Filter, allocator: Allocator) void {
        switch (self.*) {
            .comparison => |*cmp| cmp.deinit(allocator),
            .logical => |*l| l.deinit(allocator),
            .array_op => |*a| a.deinit(allocator),
            .exists => |*e| e.deinit(allocator),
            .regex_match => |*r| r.deinit(allocator),
            .size_match => |*s| s.deinit(allocator),
            .type_match => |*t| t.deinit(allocator),
            .always_true => {},
        }
    }
};

/// Comparison operators: { field: { $gt: value } }
pub const Comparison = struct {
    field: []const u8,
    op: CompOp,
    value: Value,

    pub const CompOp = enum {
        eq, // $eq or implicit
        ne, // $ne
        gt, // $gt
        gte, // $gte
        lt, // $lt
        lte, // $lte
    };

    pub fn deinit(self: *Comparison, allocator: Allocator) void {
        allocator.free(self.field);
        self.value.deinit(allocator);
    }
};

/// Logical operators: { $and: [...], $or: [...], $not: {...} }
pub const Logical = struct {
    op: LogicalOp,
    operands: []Filter,

    pub const LogicalOp = enum {
        @"and",
        @"or",
        not,
        nor, // $nor: none of the conditions match
    };

    pub fn deinit(self: *Logical, allocator: Allocator) void {
        for (self.operands) |*operand| {
            operand.deinit(allocator);
        }
        allocator.free(self.operands);
    }
};

/// Array operators: { field: { $in: [values] } }
pub const ArrayOp = struct {
    field: []const u8,
    op: enum { in, nin },
    values: []Value,

    pub fn deinit(self: *ArrayOp, allocator: Allocator) void {
        allocator.free(self.field);
        for (self.values) |*val| {
            val.deinit(allocator);
        }
        allocator.free(self.values);
    }
};

/// Exists operator: { field: { $exists: true } }
pub const Exists = struct {
    field: []const u8,
    should_exist: bool,

    pub fn deinit(self: *Exists, allocator: Allocator) void {
        allocator.free(self.field);
    }
};

/// Regex match: { field: { $regex: "pattern", $options: "i" } }
pub const RegexMatch = struct {
    field: []const u8,
    pattern: []const u8,
    options: []const u8, // e.g. "i" for case-insensitive
    compiled: *c.regex_t,

    pub fn deinit(self: *RegexMatch, allocator: Allocator) void {
        c.regfree(self.compiled);
        allocator.destroy(self.compiled);
        allocator.free(self.field);
        allocator.free(self.pattern);
        allocator.free(self.options);
    }
};

/// Size match: { field: { $size: N } }
pub const SizeMatch = struct {
    field: []const u8,
    size: usize,

    pub fn deinit(self: *SizeMatch, allocator: Allocator) void {
        allocator.free(self.field);
    }
};

/// Type match: { field: { $type: "string" } }
pub const TypeMatch = struct {
    field: []const u8,
    type_name: []const u8, // "string", "number", "bool", "null", "array", "object"

    pub fn deinit(self: *TypeMatch, allocator: Allocator) void {
        allocator.free(self.field);
        allocator.free(self.type_name);
    }
};

/// Value types in queries
pub const Value = union(enum) {
    null_value,
    bool_value: bool,
    number: f64,
    string: []const u8,

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }
};

/// Parse MongoDB query from JSON string
/// Example: '{ "age": { "$gt": 30 }, "city": "NYC" }'
pub fn parseQuery(query_str: []const u8, allocator: Allocator) QueryError!Query {
    // Parse as JSON object first
    var obj = try json_parser.parseObject(query_str, allocator);
    defer obj.deinit();

    // Convert to filter
    const filter = try objectToFilter(&obj, allocator);

    return Query{
        .filter = filter,
        .projection = null,
    };
}

/// Convert JSON object to Filter
fn objectToFilter(obj: *json_parser.JsonObject, allocator: Allocator) QueryError!Filter {
    // Empty object = always true
    if (obj.fields.len == 0) {
        return Filter{ .always_true = {} };
    }

    // Single field - check if it's a logical operator
    if (obj.fields.len == 1) {
        const field = obj.fields[0];

        // Check for logical operators
        if (std.mem.startsWith(u8, field.key, "$")) {
            if (std.mem.eql(u8, field.key, "$and")) {
                return try parseLogical(field.value, .@"and", allocator);
            } else if (std.mem.eql(u8, field.key, "$or")) {
                return try parseLogical(field.value, .@"or", allocator);
            } else if (std.mem.eql(u8, field.key, "$not")) {
                return try parseLogical(field.value, .not, allocator);
            } else if (std.mem.eql(u8, field.key, "$nor")) {
                return try parseLogical(field.value, .nor, allocator);
            }
        }

        // Single field comparison
        return try parseFieldFilter(field.key, field.value, allocator);
    }

    // Multiple fields = implicit $and
    var filters = std.ArrayList(Filter){};
    errdefer {
        for (filters.items) |*f| f.deinit(allocator);
        filters.deinit(allocator);
    }

    for (obj.fields) |field| {
        const filter = try parseFieldFilter(field.key, field.value, allocator);
        try filters.append(allocator, filter);
    }

    return Filter{
        .logical = Logical{
            .op = .@"and",
            .operands = try filters.toOwnedSlice(allocator),
        },
    };
}

/// Parse a single field filter. Supports multiple operators: {"age":{"$gt":18,"$lt":65}}
/// Also handles $regex + $options as a unit: {"name":{"$regex":"alice","$options":"i"}}
fn parseFieldFilter(key: []const u8, value: json_parser.JsonValue, allocator: Allocator) QueryError!Filter {
    switch (value) {
        .object => |obj| {
            if (obj.fields.len == 0) return error.UnsupportedQueryStructure;

            // Pre-scan for $regex and $options — they must be handled together
            var regex_pattern: ?[]const u8 = null;
            var regex_options: []const u8 = "";
            for (obj.fields) |f| {
                if (std.mem.eql(u8, f.key, "$regex")) regex_pattern = try json_parser.getString(f.value);
                if (std.mem.eql(u8, f.key, "$options")) regex_options = try json_parser.getString(f.value);
            }

            // Build filter list, skipping $options (merged into $regex)
            var filters = std.ArrayList(Filter){};
            errdefer {
                for (filters.items) |*f| f.deinit(allocator);
                filters.deinit(allocator);
            }
            var regex_consumed = false;
            for (obj.fields) |op_field| {
                if (std.mem.eql(u8, op_field.key, "$options")) continue; // consumed with $regex
                if (std.mem.eql(u8, op_field.key, "$regex")) {
                    if (!regex_consumed) {
                        regex_consumed = true;
                        try filters.append(allocator, try buildRegexFilter(key, regex_pattern.?, regex_options, allocator));
                    }
                    continue;
                }
                try filters.append(allocator, try parseFieldOp(key, op_field, allocator));
            }

            if (filters.items.len == 1) {
                const f = filters.items[0];
                filters.deinit(allocator); // free the list backing array only, not the filter
                return f;
            }
            return Filter{ .logical = Logical{
                .op = .@"and",
                .operands = try filters.toOwnedSlice(allocator),
            } };
        },
        else => return try makeComparison(key, .eq, value, allocator),
    }
}

/// Build a RegexMatch filter with optional flags (e.g. "i" for case-insensitive)
fn buildRegexFilter(key: []const u8, pattern: []const u8, options: []const u8, allocator: Allocator) !Filter {
    const pat_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pat_z);
    const compiled = try allocator.create(c.regex_t);
    errdefer allocator.destroy(compiled);
    var flags: c_int = c.REG_EXTENDED;
    if (std.mem.indexOfScalar(u8, options, 'i') != null) flags |= c.REG_ICASE;
    if (c.regcomp(compiled, pat_z.ptr, flags) != 0) return error.InvalidOperator;
    return Filter{ .regex_match = RegexMatch{
        .field = try allocator.dupe(u8, key),
        .pattern = try allocator.dupe(u8, pattern),
        .options = try allocator.dupe(u8, options),
        .compiled = compiled,
    } };
}

/// Parse one {$op: value} pair for the given field key
fn parseFieldOp(key: []const u8, op_field: json_parser.JsonObject.Field, allocator: Allocator) QueryError!Filter {
    if (!std.mem.startsWith(u8, op_field.key, "$")) return error.UnsupportedQueryStructure;

    if (std.mem.eql(u8, op_field.key, "$eq")) {
        return try makeComparison(key, .eq, op_field.value, allocator);
    } else if (std.mem.eql(u8, op_field.key, "$ne")) {
        return try makeComparison(key, .ne, op_field.value, allocator);
    } else if (std.mem.eql(u8, op_field.key, "$gt")) {
        return try makeComparison(key, .gt, op_field.value, allocator);
    } else if (std.mem.eql(u8, op_field.key, "$gte")) {
        return try makeComparison(key, .gte, op_field.value, allocator);
    } else if (std.mem.eql(u8, op_field.key, "$lt")) {
        return try makeComparison(key, .lt, op_field.value, allocator);
    } else if (std.mem.eql(u8, op_field.key, "$lte")) {
        return try makeComparison(key, .lte, op_field.value, allocator);
    } else if (std.mem.eql(u8, op_field.key, "$in")) {
        if (op_field.value != .array) return error.ExpectedArray;
        return Filter{ .array_op = ArrayOp{
            .field = try allocator.dupe(u8, key),
            .op = .in,
            .values = try parseArrayValues(op_field.value.array, allocator),
        } };
    } else if (std.mem.eql(u8, op_field.key, "$nin")) {
        if (op_field.value != .array) return error.ExpectedArray;
        return Filter{ .array_op = ArrayOp{
            .field = try allocator.dupe(u8, key),
            .op = .nin,
            .values = try parseArrayValues(op_field.value.array, allocator),
        } };
    } else if (std.mem.eql(u8, op_field.key, "$exists")) {
        return Filter{ .exists = Exists{
            .field = try allocator.dupe(u8, key),
            .should_exist = try json_parser.getBool(op_field.value),
        } };
    } else if (std.mem.eql(u8, op_field.key, "$regex")) {
        // Fallback: $regex without $options sibling (handled in parseFieldFilter when paired)
        const pattern = try json_parser.getString(op_field.value);
        return try buildRegexFilter(key, pattern, "", allocator);
    } else if (std.mem.eql(u8, op_field.key, "$size")) {
        const n = try json_parser.getFloat(op_field.value);
        if (n < 0) return error.InvalidOperator;
        return Filter{ .size_match = SizeMatch{
            .field = try allocator.dupe(u8, key),
            .size = @intFromFloat(n),
        } };
    } else if (std.mem.eql(u8, op_field.key, "$type")) {
        const type_name = try json_parser.getString(op_field.value);
        return Filter{ .type_match = TypeMatch{
            .field = try allocator.dupe(u8, key),
            .type_name = try allocator.dupe(u8, type_name),
        } };
    } else if (std.mem.eql(u8, op_field.key, "$not")) {
        // {"field":{"$not":{"$op":v}}} → negate the inner filter for the same field
        const inner = try parseFieldFilter(key, op_field.value, allocator);
        const operands = try allocator.alloc(Filter, 1);
        operands[0] = inner;
        return Filter{ .logical = Logical{ .op = .not, .operands = operands } };
    }

    return error.UnsupportedOperator;
}

/// Convert a slice of JsonValues (from a parsed JSON array) to owned query Values
fn parseArrayValues(arr: []const json_parser.JsonValue, allocator: Allocator) ![]Value {
    var values = std.ArrayList(Value){};
    errdefer {
        for (values.items) |*v| v.deinit(allocator);
        values.deinit(allocator);
    }
    for (arr) |jv| try values.append(allocator, try jsonValueToQueryValue(jv, allocator));
    return values.toOwnedSlice(allocator);
}

/// Create a comparison filter
fn makeComparison(field: []const u8, op: Comparison.CompOp, json_value: json_parser.JsonValue, allocator: Allocator) !Filter {
    const value = try jsonValueToQueryValue(json_value, allocator);

    return Filter{
        .comparison = Comparison{
            .field = try allocator.dupe(u8, field),
            .op = op,
            .value = value,
        },
    };
}

/// Convert JsonValue to Query Value
fn jsonValueToQueryValue(json_val: json_parser.JsonValue, allocator: Allocator) !Value {
    return switch (json_val) {
        .null_value => Value{ .null_value = {} },
        .bool_value => |b| Value{ .bool_value = b },
        .number => Value{ .number = try json_parser.getFloat(json_val) },
        .string => |s| Value{ .string = try allocator.dupe(u8, s) },
        else => error.UnsupportedValueType,
    };
}

/// Parse logical operator
fn parseLogical(value: json_parser.JsonValue, op: Logical.LogicalOp, allocator: Allocator) QueryError!Filter {
    // For $and and $or, expect an array of filters
    if (value != .array) {
        return error.ExpectedArray;
    }

    var filters = std.ArrayList(Filter){};
    errdefer {
        for (filters.items) |*f| f.deinit(allocator);
        filters.deinit(allocator);
    }

    // Parse each element in the array as a filter
    for (value.array) |*element| {
        if (element.* != .object) {
            return error.ExpectedObject;
        }

        const filter = try objectToFilter(&element.object, allocator);
        try filters.append(allocator, filter);
    }

    return Filter{
        .logical = Logical{
            .op = op,
            .operands = try filters.toOwnedSlice(allocator),
        },
    };
}

// ============================================================================
// QUERY EVALUATION
// ============================================================================

/// Check if a JSON object matches the query filter
pub fn matches(obj: *json_parser.JsonObject, filter: *const Filter) bool {
    return switch (filter.*) {
        .comparison => |*cmp| matchesComparison(obj, cmp),
        .logical => |*log| matchesLogical(obj, log),
        .array_op => |*arr| matchesArrayOp(obj, arr),
        .exists => |*ex| matchesExists(obj, ex),
        .regex_match => |*rm| matchesRegex(obj, rm),
        .size_match => |*sm| matchesSizeMatch(obj, sm),
        .type_match => |*tm| matchesTypeMatch(obj, tm),
        .always_true => true,
    };
}

fn matchesComparison(obj: *json_parser.JsonObject, cmp: *const Comparison) bool {
    const field_value = getNestedValue(obj.*, cmp.field) orelse return false;

    return switch (cmp.op) {
        .eq => valuesEqual(field_value, &cmp.value),
        .ne => !valuesEqual(field_value, &cmp.value),
        .gt => compareValues(field_value, &cmp.value) == .gt,
        .gte => blk: {
            const ord = compareValues(field_value, &cmp.value);
            break :blk ord == .gt or ord == .eq;
        },
        .lt => compareValues(field_value, &cmp.value) == .lt,
        .lte => blk: {
            const ord = compareValues(field_value, &cmp.value);
            break :blk ord == .lt or ord == .eq;
        },
    };
}

fn matchesLogical(obj: *json_parser.JsonObject, log: *const Logical) bool {
    return switch (log.op) {
        .@"and" => {
            for (log.operands) |*operand| {
                if (!matches(obj, operand)) return false;
            }
            return true;
        },
        .@"or" => {
            for (log.operands) |*operand| {
                if (matches(obj, operand)) return true;
            }
            return false;
        },
        .not => !matches(obj, &log.operands[0]),
        .nor => blk: {
            for (log.operands) |*operand| {
                if (matches(obj, operand)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn matchesArrayOp(obj: *json_parser.JsonObject, arr: *const ArrayOp) bool {
    const field_value = getNestedValue(obj.*, arr.field) orelse return arr.op == .nin;

    // Scalar field: check if field value is one of the listed values
    const scalar_match = for (arr.values) |*v| {
        if (valuesEqual(field_value, v)) break true;
    } else false;

    // Array field: check if any element matches (e.g. tags: {$in: ["go"]})
    const is_in = if (scalar_match) true else if (field_value == .array) blk: {
        for (field_value.array) |elem| {
            for (arr.values) |*v| {
                if (valuesEqual(elem, v)) break :blk true;
            }
        }
        break :blk false;
    } else false;

    return switch (arr.op) {
        .in => is_in,
        .nin => !is_in,
    };
}

fn matchesExists(obj: *json_parser.JsonObject, ex: *const Exists) bool {
    const has_field = getNestedValue(obj.*, ex.field) != null;
    return has_field == ex.should_exist;
}

fn matchesSizeMatch(obj: *json_parser.JsonObject, sm: *const SizeMatch) bool {
    const fv = getNestedValue(obj.*, sm.field) orelse return false;
    if (fv != .array) return false;
    return fv.array.len == sm.size;
}

fn matchesTypeMatch(obj: *json_parser.JsonObject, tm: *const TypeMatch) bool {
    const fv = getNestedValue(obj.*, tm.field) orelse {
        return std.mem.eql(u8, tm.type_name, "null");
    };
    const actual: []const u8 = switch (fv) {
        .string => "string",
        .number => "number",
        .bool_value => "bool",
        .null_value => "null",
        .array => "array",
        .object => "object",
    };
    return std.mem.eql(u8, actual, tm.type_name);
}

/// Traverse dot-separated field path through nested objects: "address.city"
fn getNestedValue(obj: json_parser.JsonObject, field_path: []const u8) ?json_parser.JsonValue {
    const dot = std.mem.indexOfScalar(u8, field_path, '.') orelse return obj.get(field_path);
    const head = field_path[0..dot];
    const tail = field_path[dot + 1 ..];
    const val = obj.get(head) orelse return null;
    return switch (val) {
        .object => |nested| getNestedValue(nested, tail),
        else => null,
    };
}

/// Match POSIX extended regex against a string field
fn matchesRegex(obj: *json_parser.JsonObject, rm: *const RegexMatch) bool {
    const field_value = getNestedValue(obj.*, rm.field) orelse return false;
    if (field_value != .string) return false;
    const str = field_value.string;
    // Stack buffer for null-terminated copy (regex requires C string)
    var buf: [4096]u8 = undefined;
    if (str.len >= buf.len) return false;
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    var match: c.regmatch_t = undefined;
    return c.regexec(rm.compiled, &buf, 1, &match, 0) == 0;
}

/// Check if two values are equal
fn valuesEqual(json_val: json_parser.JsonValue, query_val: *const Value) bool {
    return switch (query_val.*) {
        .null_value => json_val == .null_value,
        .bool_value => |b| {
            if (json_val == .bool_value) {
                return json_val.bool_value == b;
            }
            return false;
        },
        .number => |n| {
            if (json_val == .number) {
                const val = json_parser.getFloat(json_val) catch return false;
                return val == n;
            }
            return false;
        },
        .string => |s| {
            if (json_val == .string) {
                return std.mem.eql(u8, json_val.string, s);
            }
            return false;
        },
    };
}

/// Compare values (for >, <, >=, <=)
fn compareValues(json_val: json_parser.JsonValue, query_val: *const Value) std.math.Order {
    // Only compare numbers for now
    if (query_val.* == .number and json_val == .number) {
        const a = json_parser.getFloat(json_val) catch return .eq;
        const b = query_val.number;

        if (a < b) return .lt;
        if (a > b) return .gt;
        return .eq;
    }

    // String comparison
    if (query_val.* == .string and json_val == .string) {
        return std.mem.order(u8, json_val.string, query_val.string);
    }

    return .eq;
}

// ============================================================================
// TESTS
// ============================================================================

test "parse simple equality query" {
    const query_str = "{\"age\":30}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);

    try std.testing.expect(query.filter == .comparison);
    try std.testing.expectEqualStrings("age", query.filter.comparison.field);
    try std.testing.expectEqual(Comparison.CompOp.eq, query.filter.comparison.op);
    try std.testing.expectEqual(@as(f64, 30), query.filter.comparison.value.number);
}

test "parse greater than query" {
    const query_str = "{\"age\":{\"$gt\":30}}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);

    try std.testing.expect(query.filter == .comparison);
    try std.testing.expectEqual(Comparison.CompOp.gt, query.filter.comparison.op);
    try std.testing.expectEqual(@as(f64, 30), query.filter.comparison.value.number);
}

test "parse multiple field query (implicit AND)" {
    const query_str = "{\"age\":30,\"city\":\"NYC\"}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);

    try std.testing.expect(query.filter == .logical);
    try std.testing.expectEqual(Logical.LogicalOp.@"and", query.filter.logical.op);
    try std.testing.expectEqual(@as(usize, 2), query.filter.logical.operands.len);
}

test "match simple equality" {
    const data = "{\"age\":30,\"name\":\"Alice\"}";
    var obj = try json_parser.parseObject(data, std.testing.allocator);
    defer obj.deinit();

    const query_str = "{\"age\":30}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);

    try std.testing.expect(matches(&obj, &query.filter));
}

test "match greater than" {
    const data = "{\"age\":35}";
    var obj = try json_parser.parseObject(data, std.testing.allocator);
    defer obj.deinit();

    const query_str = "{\"age\":{\"$gt\":30}}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);

    try std.testing.expect(matches(&obj, &query.filter));

    // Should not match if age is less
    const data2 = "{\"age\":25}";
    var obj2 = try json_parser.parseObject(data2, std.testing.allocator);
    defer obj2.deinit();

    try std.testing.expect(!matches(&obj2, &query.filter));
}

test "match multiple conditions (AND)" {
    const data = "{\"age\":35,\"city\":\"NYC\"}";
    var obj = try json_parser.parseObject(data, std.testing.allocator);
    defer obj.deinit();

    const query_str = "{\"age\":35,\"city\":\"NYC\"}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);

    try std.testing.expect(matches(&obj, &query.filter));

    // Should not match if one condition fails
    const query_str2 = "{\"age\":35,\"city\":\"LA\"}";
    var query2 = try parseQuery(query_str2, std.testing.allocator);
    defer query2.deinit(std.testing.allocator);

    try std.testing.expect(!matches(&obj, &query2.filter));
}

test "match $exists operator" {
    const data = "{\"age\":30,\"name\":\"Alice\"}";
    var obj = try json_parser.parseObject(data, std.testing.allocator);
    defer obj.deinit();

    const query_str = "{\"email\":{\"$exists\":false}}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);

    try std.testing.expect(matches(&obj, &query.filter));

    // Should match when field exists
    const query_str2 = "{\"name\":{\"$exists\":true}}";
    var query2 = try parseQuery(query_str2, std.testing.allocator);
    defer query2.deinit(std.testing.allocator);

    try std.testing.expect(matches(&obj, &query2.filter));
}

test "match $ne (not equal) operator" {
    const data = "{\"city\":\"NYC\",\"age\":30}";
    var obj = try json_parser.parseObject(data, std.testing.allocator);
    defer obj.deinit();

    const query_str = "{\"city\":{\"$ne\":\"LA\"}}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);

    try std.testing.expect(matches(&obj, &query.filter));

    // Should not match when equal
    const data2 = "{\"city\":\"LA\"}";
    var obj2 = try json_parser.parseObject(data2, std.testing.allocator);
    defer obj2.deinit();

    try std.testing.expect(!matches(&obj2, &query.filter));
}

test "match $lt and $lte operators" {
    const data = "{\"age\":28}";
    var obj = try json_parser.parseObject(data, std.testing.allocator);
    defer obj.deinit();

    // Test $lt
    const query_str_lt = "{\"age\":{\"$lt\":30}}";
    var query_lt = try parseQuery(query_str_lt, std.testing.allocator);
    defer query_lt.deinit(std.testing.allocator);
    try std.testing.expect(matches(&obj, &query_lt.filter));

    // Test $lte with exact match
    const query_str_lte = "{\"age\":{\"$lte\":28}}";
    var query_lte = try parseQuery(query_str_lte, std.testing.allocator);
    defer query_lte.deinit(std.testing.allocator);
    try std.testing.expect(matches(&obj, &query_lte.filter));

    // Should not match when greater
    const query_str_fail = "{\"age\":{\"$lt\":25}}";
    var query_fail = try parseQuery(query_str_fail, std.testing.allocator);
    defer query_fail.deinit(std.testing.allocator);
    try std.testing.expect(!matches(&obj, &query_fail.filter));
}

test "match $gte operator" {
    const data = "{\"age\":30}";
    var obj = try json_parser.parseObject(data, std.testing.allocator);
    defer obj.deinit();

    // Test $gte with exact match
    const query_str = "{\"age\":{\"$gte\":30}}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);
    try std.testing.expect(matches(&obj, &query.filter));

    // Test $gte with greater value
    const query_str2 = "{\"age\":{\"$gte\":25}}";
    var query2 = try parseQuery(query_str2, std.testing.allocator);
    defer query2.deinit(std.testing.allocator);
    try std.testing.expect(matches(&obj, &query2.filter));
}

test "match explicit $and operator" {
    const data = "{\"age\":35,\"city\":\"LA\"}";
    var obj = try json_parser.parseObject(data, std.testing.allocator);
    defer obj.deinit();

    const query_str = "{\"$and\":[{\"age\":{\"$gte\":30}},{\"city\":\"LA\"}]}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);

    try std.testing.expect(matches(&obj, &query.filter));

    // Should not match if one condition fails
    const query_str2 = "{\"$and\":[{\"age\":{\"$gte\":40}},{\"city\":\"LA\"}]}";
    var query2 = try parseQuery(query_str2, std.testing.allocator);
    defer query2.deinit(std.testing.allocator);
    try std.testing.expect(!matches(&obj, &query2.filter));
}

test "match $or operator" {
    const data = "{\"city\":\"NYC\",\"age\":30}";
    var obj = try json_parser.parseObject(data, std.testing.allocator);
    defer obj.deinit();

    const query_str = "{\"$or\":[{\"city\":\"NYC\"},{\"city\":\"LA\"}]}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);

    try std.testing.expect(matches(&obj, &query.filter));

    // Should also match second condition
    const data2 = "{\"city\":\"LA\"}";
    var obj2 = try json_parser.parseObject(data2, std.testing.allocator);
    defer obj2.deinit();
    try std.testing.expect(matches(&obj2, &query.filter));

    // Should not match when neither condition matches
    const data3 = "{\"city\":\"Chicago\"}";
    var obj3 = try json_parser.parseObject(data3, std.testing.allocator);
    defer obj3.deinit();
    try std.testing.expect(!matches(&obj3, &query.filter));
}

test "match $regex with $options case-insensitive" {
    const data = "{\"name\":\"Alice\"}";
    var obj = try json_parser.parseObject(data, std.testing.allocator);
    defer obj.deinit();

    // Case-insensitive match via $options:"i"
    const query_str = "{\"name\":{\"$regex\":\"alice\",\"$options\":\"i\"}}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);
    try std.testing.expect(matches(&obj, &query.filter));

    // Case-sensitive should NOT match
    const query_str2 = "{\"name\":{\"$regex\":\"alice\"}}";
    var query2 = try parseQuery(query_str2, std.testing.allocator);
    defer query2.deinit(std.testing.allocator);
    try std.testing.expect(!matches(&obj, &query2.filter));
}

test "match $size operator" {
    const data = "{\"tags\":[\"go\",\"zig\",\"rust\"]}";
    var obj = try json_parser.parseObject(data, std.testing.allocator);
    defer obj.deinit();

    const query_str = "{\"tags\":{\"$size\":3}}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);
    try std.testing.expect(matches(&obj, &query.filter));

    // Wrong size should not match
    const query_str2 = "{\"tags\":{\"$size\":2}}";
    var query2 = try parseQuery(query_str2, std.testing.allocator);
    defer query2.deinit(std.testing.allocator);
    try std.testing.expect(!matches(&obj, &query2.filter));
}

test "match $type operator" {
    const data = "{\"name\":\"Alice\",\"age\":30,\"active\":true,\"score\":null}";
    var obj = try json_parser.parseObject(data, std.testing.allocator);
    defer obj.deinit();

    const cases = .{
        .{ "{\"name\":{\"$type\":\"string\"}}", true },
        .{ "{\"age\":{\"$type\":\"number\"}}", true },
        .{ "{\"active\":{\"$type\":\"bool\"}}", true },
        .{ "{\"score\":{\"$type\":\"null\"}}", true },
        .{ "{\"name\":{\"$type\":\"number\"}}", false },
        .{ "{\"age\":{\"$type\":\"string\"}}", false },
    };
    inline for (cases) |tc| {
        var q = try parseQuery(tc[0], std.testing.allocator);
        defer q.deinit(std.testing.allocator);
        try std.testing.expectEqual(tc[1], matches(&obj, &q.filter));
    }
}

test "match $nor operator" {
    const data = "{\"city\":\"Chicago\",\"age\":25}";
    var obj = try json_parser.parseObject(data, std.testing.allocator);
    defer obj.deinit();

    // Neither NYC nor LA → $nor should match
    const query_str = "{\"$nor\":[{\"city\":\"NYC\"},{\"city\":\"LA\"}]}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);
    try std.testing.expect(matches(&obj, &query.filter));

    // City is NYC → $nor should NOT match
    const data2 = "{\"city\":\"NYC\"}";
    var obj2 = try json_parser.parseObject(data2, std.testing.allocator);
    defer obj2.deinit();
    try std.testing.expect(!matches(&obj2, &query.filter));
}

test "match nested $and with $or" {
    const data = "{\"age\":35,\"city\":\"LA\"}";
    var obj = try json_parser.parseObject(data, std.testing.allocator);
    defer obj.deinit();

    const query_str = "{\"$and\":[{\"$or\":[{\"city\":\"NYC\"},{\"city\":\"LA\"}]},{\"age\":{\"$gte\":30}}]}";
    var query = try parseQuery(query_str, std.testing.allocator);
    defer query.deinit(std.testing.allocator);

    try std.testing.expect(matches(&obj, &query.filter));

    // Should not match if age condition fails
    const data2 = "{\"age\":25,\"city\":\"LA\"}";
    var obj2 = try json_parser.parseObject(data2, std.testing.allocator);
    defer obj2.deinit();
    try std.testing.expect(!matches(&obj2, &query.filter));

    // Should not match if city condition fails
    const data3 = "{\"age\":35,\"city\":\"Chicago\"}";
    var obj3 = try json_parser.parseObject(data3, std.testing.allocator);
    defer obj3.deinit();
    try std.testing.expect(!matches(&obj3, &query.filter));
}
