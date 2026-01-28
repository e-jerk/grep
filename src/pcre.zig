// PCRE2 Zig wrapper for Perl-compatible regular expressions (-P flag)

const std = @import("std");
const gpu = @import("gpu");

const SearchOptions = gpu.SearchOptions;
const SearchResult = gpu.SearchResult;
const MatchResult = gpu.MatchResult;

/// Opaque PCRE2 context handle
const PcreContext = opaque {};

/// Match result from PCRE2
const PcreMatch = extern struct {
    start: usize,
    end: usize,
    valid: c_int,
};

// External C functions from pcre2_wrapper.c
extern fn pcre2_compile_pattern(
    pattern: [*]const u8,
    pattern_len: usize,
    case_insensitive: c_int,
    multiline: c_int,
) ?*PcreContext;

extern fn pcre2_is_valid(ctx: ?*PcreContext) c_int;

extern fn pcre2_get_error_message(
    ctx: ?*PcreContext,
    buffer: [*]u8,
    buffer_len: usize,
) void;

extern fn pcre2_get_error_offset(ctx: ?*PcreContext) usize;

extern fn pcre2_find_first(
    ctx: ?*PcreContext,
    text: [*]const u8,
    text_len: usize,
    start_offset: usize,
    result: *PcreMatch,
) c_int;

extern fn pcre2_find_all(
    ctx: ?*PcreContext,
    text: [*]const u8,
    text_len: usize,
    results: [*]PcreMatch,
    max_results: usize,
) c_int;

extern fn pcre2_free_context(ctx: ?*PcreContext) void;

/// PCRE2 regex wrapper
pub const PcreRegex = struct {
    ctx: *PcreContext,

    const Self = @This();

    /// Compile a Perl regex pattern
    pub fn compile(pattern: []const u8, options: SearchOptions) !Self {
        const ctx = pcre2_compile_pattern(
            pattern.ptr,
            pattern.len,
            if (options.case_insensitive) 1 else 0,
            1, // Always multiline for grep
        ) orelse return error.OutOfMemory;

        if (pcre2_is_valid(ctx) == 0) {
            defer pcre2_free_context(ctx);
            return error.InvalidRegex;
        }

        return Self{ .ctx = ctx };
    }

    /// Free the compiled regex
    pub fn deinit(self: *Self) void {
        pcre2_free_context(self.ctx);
    }

    /// Find all matches in text
    pub fn findAll(self: *Self, text: []const u8, allocator: std.mem.Allocator) ![]PcreMatch {
        // Allocate buffer for results (max 1M matches like other backends)
        const max_results: usize = 1000000;
        const results_buf = try allocator.alloc(PcreMatch, max_results);
        errdefer allocator.free(results_buf);

        const count = pcre2_find_all(
            self.ctx,
            text.ptr,
            text.len,
            results_buf.ptr,
            max_results,
        );

        if (count < 0) {
            allocator.free(results_buf);
            return error.MatchError;
        }

        // Shrink to actual size
        return allocator.realloc(results_buf, @intCast(count)) catch results_buf[0..@intCast(count)];
    }
};

/// Find line start position (scan backwards for newline)
fn findLineStart(text: []const u8, pos: usize) u32 {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and text[i] != '\n') : (i -= 1) {}
    if (text[i] == '\n' and i < pos) return @intCast(i + 1);
    return @intCast(i);
}

/// Count newlines before position
fn countNewlines(text: []const u8, end: usize) u32 {
    var count: u32 = 0;
    for (text[0..end]) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

/// Search text using Perl regex (PCRE2)
pub fn searchPcre(text: []const u8, pattern: []const u8, options: SearchOptions, allocator: std.mem.Allocator) !SearchResult {
    // Handle invert match separately
    if (options.invert_match) {
        return searchPcreInverted(text, pattern, options, allocator);
    }

    var pcre = PcreRegex.compile(pattern, options) catch {
        // Return empty result on regex error (match GNU grep behavior)
        return SearchResult{
            .matches = &[_]MatchResult{},
            .total_matches = 0,
            .allocator = allocator,
        };
    };
    defer pcre.deinit();

    const pcre_matches = try pcre.findAll(text, allocator);
    defer allocator.free(pcre_matches);

    // Convert PCRE matches to MatchResult
    var matches: std.ArrayListUnmanaged(MatchResult) = .{};
    defer matches.deinit(allocator);

    for (pcre_matches) |m| {
        if (m.valid != 0) {
            const line_start = findLineStart(text, m.start);
            const line_num = 1 + countNewlines(text, line_start);

            try matches.append(allocator, MatchResult{
                .position = @intCast(m.start),
                .pattern_idx = 0,
                .match_len = @intCast(m.end - m.start),
                .line_start = line_start,
                .line_num = line_num,
            });
        }
    }

    const result = try matches.toOwnedSlice(allocator);
    return SearchResult{
        .matches = result,
        .total_matches = result.len,
        .allocator = allocator,
    };
}

/// Search for non-matching lines using PCRE
fn searchPcreInverted(text: []const u8, pattern: []const u8, options: SearchOptions, allocator: std.mem.Allocator) !SearchResult {
    var pcre = PcreRegex.compile(pattern, options) catch {
        // On regex error, all lines are "non-matching"
        return searchAllLines(text, allocator);
    };
    defer pcre.deinit();

    const pcre_matches = try pcre.findAll(text, allocator);
    defer allocator.free(pcre_matches);

    // Build set of matching line starts
    var matching_lines = std.AutoHashMap(u32, void).init(allocator);
    defer matching_lines.deinit();

    for (pcre_matches) |m| {
        if (m.valid != 0) {
            const line_start = findLineStart(text, m.start);
            try matching_lines.put(line_start, {});
        }
    }

    // Find non-matching lines
    var matches: std.ArrayListUnmanaged(MatchResult) = .{};
    defer matches.deinit(allocator);

    var line_start: usize = 0;
    var line_num: u32 = 1;

    while (line_start < text.len) {
        // Find end of line
        var line_end = line_start;
        while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}

        // Check if this line is NOT in matching set
        if (!matching_lines.contains(@intCast(line_start))) {
            try matches.append(allocator, MatchResult{
                .position = @intCast(line_start),
                .pattern_idx = 0,
                .match_len = @intCast(line_end - line_start),
                .line_start = @intCast(line_start),
                .line_num = line_num,
            });
        }

        // Move to next line
        line_start = line_end + 1;
        line_num += 1;
    }

    const result = try matches.toOwnedSlice(allocator);
    return SearchResult{
        .matches = result,
        .total_matches = result.len,
        .allocator = allocator,
    };
}

/// Return all lines (for empty pattern or regex error in inverted mode)
fn searchAllLines(text: []const u8, allocator: std.mem.Allocator) !SearchResult {
    var matches: std.ArrayListUnmanaged(MatchResult) = .{};
    defer matches.deinit(allocator);

    var line_start: usize = 0;
    var line_num: u32 = 1;

    while (line_start < text.len) {
        var line_end = line_start;
        while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}

        try matches.append(allocator, MatchResult{
            .position = @intCast(line_start),
            .pattern_idx = 0,
            .match_len = @intCast(line_end - line_start),
            .line_start = @intCast(line_start),
            .line_num = line_num,
        });

        line_start = line_end + 1;
        line_num += 1;
    }

    const result = try matches.toOwnedSlice(allocator);
    return SearchResult{
        .matches = result,
        .total_matches = result.len,
        .allocator = allocator,
    };
}
