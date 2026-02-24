const std = @import("std");

pub const OutputFormat = enum {
    json,
    ndjson,
    csv,

    pub fn fromString(s: []const u8) ?OutputFormat {
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "ndjson")) return .ndjson;
        if (std.mem.eql(u8, s, "csv")) return .csv;
        return null;
    }
};

pub const CliOptions = struct {
    /// Input file path (null means stdin)
    input_file: ?[]const u8 = null,

    /// MongoDB query string
    query: []const u8,

    /// Output format
    output_format: OutputFormat = .ndjson,

    /// Fields to project (null means all fields)
    select_fields: ?[]const []const u8 = null,

    /// Just count matches, don't output records
    count_only: bool = false,

    /// Limit number of results
    limit: ?usize = null,

    /// Pretty-print JSON output
    pretty: bool = false,

    /// Number of threads to use
    threads: usize = 7,

    /// Show help message
    show_help: bool = false,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *CliOptions) void {
        if (self.select_fields) |fields| {
            self.allocator.free(fields);
        }
    }
};

pub fn parseArgs(allocator: std.mem.Allocator) !CliOptions {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.next();

    var options = CliOptions{
        .query = "",
        .allocator = allocator,
    };

    var positional_count: usize = 0;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) {
            // Long option
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                options.show_help = true;
            } else if (std.mem.eql(u8, arg, "--count")) {
                options.count_only = true;
            } else if (std.mem.eql(u8, arg, "--pretty")) {
                options.pretty = true;
            } else if (std.mem.eql(u8, arg, "--output")) {
                const value = args.next() orelse return error.MissingValue;
                options.output_format = OutputFormat.fromString(value) orelse {
                    std.debug.print("Invalid output format: {s}\n", .{value});
                    return error.InvalidOutputFormat;
                };
            } else if (std.mem.eql(u8, arg, "--select")) {
                const value = args.next() orelse return error.MissingValue;
                options.select_fields = try parseSelectFields(value, allocator);
            } else if (std.mem.eql(u8, arg, "--limit")) {
                const value = args.next() orelse return error.MissingValue;
                options.limit = try std.fmt.parseInt(usize, value, 10);
            } else if (std.mem.eql(u8, arg, "--threads")) {
                const value = args.next() orelse return error.MissingValue;
                options.threads = try std.fmt.parseInt(usize, value, 10);
            } else {
                std.debug.print("Unknown option: {s}\n", .{arg});
                return error.UnknownOption;
            }
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            // Short option
            if (std.mem.eql(u8, arg, "-h")) {
                options.show_help = true;
            } else if (std.mem.eql(u8, arg, "-c")) {
                options.count_only = true;
            } else if (std.mem.eql(u8, arg, "-p")) {
                options.pretty = true;
            } else {
                std.debug.print("Unknown option: {s}\n", .{arg});
                return error.UnknownOption;
            }
        } else {
            // Positional argument
            if (positional_count == 0) {
                // First positional: could be file or query
                // If it ends with .json or .ndjson, it's a file
                if (std.mem.endsWith(u8, arg, ".json") or
                    std.mem.endsWith(u8, arg, ".ndjson") or
                    std.mem.eql(u8, arg, "-"))
                {
                    options.input_file = arg;
                } else {
                    options.query = arg;
                }
                positional_count += 1;
            } else if (positional_count == 1) {
                // Second positional: if we got a file first, this is the query
                if (options.input_file != null) {
                    options.query = arg;
                } else {
                    // We got a query first, this is the file
                    options.input_file = arg;
                }
                positional_count += 1;
            } else {
                std.debug.print("Too many positional arguments\n", .{});
                return error.TooManyArgs;
            }
        }
    }

    // Validate required arguments
    if (!options.show_help and options.query.len == 0) {
        std.debug.print("Error: Query string is required\n\n", .{});
        options.show_help = true;
        return options;
    }

    return options;
}

fn parseSelectFields(value: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    var fields = std.ArrayList([]const u8){};
    defer fields.deinit(allocator);

    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |field| {
        const trimmed = std.mem.trim(u8, field, " \t");
        if (trimmed.len > 0) {
            try fields.append(allocator, trimmed);
        }
    }

    return try fields.toOwnedSlice(allocator);
}

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\zson - Fast MongoDB-syntax query engine for JSON/NDJSON files
        \\
        \\USAGE:
        \\    zson [OPTIONS] <QUERY> [FILE]
        \\    zson [OPTIONS] [FILE] <QUERY>
        \\    cat data.ndjson | zson [OPTIONS] <QUERY>
        \\
        \\ARGUMENTS:
        \\    <QUERY>    MongoDB query string (e.g., '{"age": {"$gt": 30}}')
        \\    [FILE]     Input file (NDJSON/JSON). Use '-' or omit for stdin
        \\
        \\OPTIONS:
        \\    -h, --help              Show this help message
        \\    -c, --count             Only count matches, don't output records
        \\    -p, --pretty            Pretty-print JSON output
        \\    --output <FORMAT>       Output format: json, ndjson, csv (default: ndjson)
        \\    --select <FIELDS>       Comma-separated fields to output (e.g., 'name,age,city')
        \\    --limit <N>             Limit number of results
        \\    --threads <N>           Number of threads to use (default: 7)
        \\
        \\EXAMPLES:
        \\    # Find all users over 30
        \\    zson '{"age": {"$gt": 30}}' users.ndjson
        \\
        \\    # Count active users in NYC
        \\    zson --count '{"city": "NYC", "active": true}' users.ndjson
        \\
        \\    # Select specific fields, output as JSON
        \\    zson --select 'name,email' --output json '{"age": {"$gte": 21}}' users.ndjson
        \\
        \\    # Pipe from stdin
        \\    cat data.ndjson | zson '{"status": "success"}' --limit 100
        \\
        \\    # Pretty-print results
        \\    zson -p --output json '{"category": "electronics"}' products.ndjson
        \\
        \\QUERY OPERATORS:
        \\    $eq, $ne               Equal, not equal
        \\    $gt, $gte, $lt, $lte   Comparison operators
        \\    $and, $or, $not        Logical operators
        \\    $exists                Field existence check
        \\
        \\
    );
}

// Tests
test "cli: parse basic query and file" {
    // Cannot easily test this without mocking args
    // Would need to restructure to pass args array directly
}

test "cli: output format parsing" {
    try std.testing.expectEqual(OutputFormat.json, OutputFormat.fromString("json"));
    try std.testing.expectEqual(OutputFormat.ndjson, OutputFormat.fromString("ndjson"));
    try std.testing.expectEqual(OutputFormat.csv, OutputFormat.fromString("csv"));
    try std.testing.expectEqual(@as(?OutputFormat, null), OutputFormat.fromString("invalid"));
}

test "cli: parse select fields" {
    const allocator = std.testing.allocator;

    const fields = try parseSelectFields("name,age,city", allocator);
    defer allocator.free(fields);

    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("name", fields[0]);
    try std.testing.expectEqualStrings("age", fields[1]);
    try std.testing.expectEqualStrings("city", fields[2]);
}

test "cli: parse select fields with spaces" {
    const allocator = std.testing.allocator;

    const fields = try parseSelectFields("name, age , city", allocator);
    defer allocator.free(fields);

    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("name", fields[0]);
    try std.testing.expectEqualStrings("age", fields[1]);
    try std.testing.expectEqualStrings("city", fields[2]);
}
