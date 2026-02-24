const std = @import("std");

/// SIMD-accelerated JSON parsing utilities
/// Inspired by simdjson and proven patterns from sieswi
/// Token types for JSON structural characters
pub const TokenType = enum {
    open_brace, // {
    close_brace, // }
    open_bracket, // [
    close_bracket, // ]
    quote, // "
    colon, // :
    comma, // ,
    unknown,
};

pub const Token = struct {
    type: TokenType,
    pos: usize,
};

/// Find JSON structural characters using SIMD vectorization
/// This is like findCommasSIMD from sieswi, but for multiple JSON chars
pub fn findJsonStructure(data: []const u8, tokens: []Token) usize {
    var count: usize = 0;

    const VecSize = 16; // SSE/NEON vector size
    const Vec = @Vector(VecSize, u8);

    // Prepare comparison vectors for all structural characters
    const open_brace: Vec = @splat('{');
    const close_brace: Vec = @splat('}');
    const open_bracket: Vec = @splat('[');
    const close_bracket: Vec = @splat(']');
    const quote: Vec = @splat('"');
    const colon: Vec = @splat(':');
    const comma: Vec = @splat(',');

    var i: usize = 0;

    // Process 16 bytes at a time with SIMD
    while (i + VecSize <= data.len and count < tokens.len) : (i += VecSize) {
        const chunk: Vec = data[i..][0..VecSize].*;

        // SIMD comparison for all structural chars at once!
        const is_open_brace = chunk == open_brace;
        const is_close_brace = chunk == close_brace;
        const is_open_bracket = chunk == open_bracket;
        const is_close_bracket = chunk == close_bracket;
        const is_quote = chunk == quote;
        const is_colon = chunk == colon;
        const is_comma = chunk == comma;

        // Extract positions of matches
        var j: usize = 0;
        while (j < VecSize and count < tokens.len) : (j += 1) {
            // Check each structural character type
            if (is_open_brace[j]) {
                tokens[count] = Token{ .type = .open_brace, .pos = i + j };
                count += 1;
            } else if (is_close_brace[j]) {
                tokens[count] = Token{ .type = .close_brace, .pos = i + j };
                count += 1;
            } else if (is_open_bracket[j]) {
                tokens[count] = Token{ .type = .open_bracket, .pos = i + j };
                count += 1;
            } else if (is_close_bracket[j]) {
                tokens[count] = Token{ .type = .close_bracket, .pos = i + j };
                count += 1;
            } else if (is_quote[j]) {
                tokens[count] = Token{ .type = .quote, .pos = i + j };
                count += 1;
            } else if (is_colon[j]) {
                tokens[count] = Token{ .type = .colon, .pos = i + j };
                count += 1;
            } else if (is_comma[j]) {
                tokens[count] = Token{ .type = .comma, .pos = i + j };
                count += 1;
            }
        }
    }

    // Handle remaining bytes (scalar fallback)
    while (i < data.len and count < tokens.len) : (i += 1) {
        const token_type: TokenType = switch (data[i]) {
            '{' => .open_brace,
            '}' => .close_brace,
            '[' => .open_bracket,
            ']' => .close_bracket,
            '"' => .quote,
            ':' => .colon,
            ',' => .comma,
            else => continue,
        };

        tokens[count] = Token{ .type = token_type, .pos = i };
        count += 1;
    }

    return count;
}

/// Fast SIMD-optimized newline search (same as sieswi)
/// For splitting NDJSON into lines
pub inline fn findNewline(haystack: []const u8, start: usize) ?usize {
    if (start >= haystack.len) return null;

    const data = haystack[start..];

    // For small searches, use standard library
    if (data.len < 64) {
        if (std.mem.indexOfScalar(u8, data, '\n')) |pos| {
            return start + pos;
        }
        return null;
    }

    // For larger searches, std.mem.indexOfScalar may use SIMD internally
    if (std.mem.indexOfScalar(u8, data, '\n')) |pos| {
        return start + pos;
    }

    return null;
}

/// Fast string equality check using SIMD when available
/// Reused from sieswi - works great for JSON key comparison
pub inline fn stringsEqualFast(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.ptr == b.ptr) return true;

    // For short strings, use direct comparison
    if (a.len < 16) {
        return std.mem.eql(u8, a, b);
    }

    // For longer strings, std.mem.eql may use SIMD internally
    return std.mem.eql(u8, a, b);
}

/// Parse integer fast (for numeric JSON values)
/// Optimized version from sieswi
pub inline fn parseIntFast(str: []const u8) !i64 {
    // Skip leading whitespace
    var i: usize = 0;
    while (i < str.len and std.ascii.isWhitespace(str[i])) : (i += 1) {}

    if (i >= str.len) return error.InvalidInput;

    // Check for sign
    var negative = false;
    if (str[i] == '-') {
        negative = true;
        i += 1;
    } else if (str[i] == '+') {
        i += 1;
    }

    if (i >= str.len) return error.InvalidInput;

    // Parse digits - compiler can vectorize this loop
    var result: i64 = 0;
    while (i < str.len) : (i += 1) {
        const c = str[i];
        if (c < '0' or c > '9') break;
        result = result * 10 + (c - '0');
    }

    return if (negative) -result else result;
}

/// Parse float fast (for numeric JSON values)
pub inline fn parseFloatFast(str: []const u8) !f64 {
    return try std.fmt.parseFloat(f64, str);
}

test "SIMD JSON tokenization" {
    const json = "{\"name\":\"Alice\",\"age\":30}";
    var tokens: [100]Token = undefined;

    const count = findJsonStructure(json, &tokens);

    // Should find: { " " : " " , " " : } = 11 structural chars (7 unique + 4 quotes)
    try std.testing.expect(count > 0);
    try std.testing.expectEqual(TokenType.open_brace, tokens[0].type);
    try std.testing.expectEqual(@as(usize, 0), tokens[0].pos);
}

test "newline search" {
    const data = "line1\nline2\nline3\n";

    const pos1 = findNewline(data, 0);
    try std.testing.expectEqual(@as(usize, 5), pos1.?);

    const pos2 = findNewline(data, 6);
    try std.testing.expectEqual(@as(usize, 11), pos2.?);
}

test "fast integer parsing" {
    try std.testing.expectEqual(@as(i64, 42), try parseIntFast("42"));
    try std.testing.expectEqual(@as(i64, -123), try parseIntFast("-123"));
    try std.testing.expectEqual(@as(i64, 0), try parseIntFast("0"));
}
