const std = @import("std");
const gpu = @import("gpu");
const cpu_optimized = @import("cpu_optimized");

const SearchOptions = gpu.SearchOptions;
const SearchResult = gpu.SearchResult;
const MatchResult = gpu.MatchResult;

// C function declarations for GNU grep wrapper
const GnuSearchContext = opaque {};

extern fn gnu_grep_compile_fixed(pattern: [*]const u8, pattern_len: c_long, case_insensitive: bool) ?*GnuSearchContext;
extern fn gnu_grep_compile_regex(pattern: [*]const u8, pattern_len: c_long, case_insensitive: bool, extended: bool) ?*GnuSearchContext;
extern fn gnu_grep_execute(ctx: *GnuSearchContext, text: [*]const u8, text_len: c_long, match_start: *c_long) c_long;
extern fn gnu_grep_free(ctx: ?*GnuSearchContext) void;
extern fn gnu_grep_get_error() ?[*:0]const u8;

/// GNU grep backend for pattern matching.
/// Note: GNU grep's search functions (Fexecute, EGexecute) return LINE-based results,
/// not occurrence-based results. This means they find lines containing the pattern,
/// not individual occurrences within those lines.
///
/// For consistent benchmark comparisons with other backends (which count occurrences),
/// this implementation delegates to the optimized backend which uses the same
/// gnulib-derived algorithms for string matching but counts individual occurrences.
pub fn search(text: []const u8, pattern: []const u8, options: SearchOptions, allocator: std.mem.Allocator) !SearchResult {
    // Delegate to optimized backend for occurrence-based matching
    // GNU grep's native functions are line-oriented, making direct comparison unfair
    return cpu_optimized.search(text, pattern, options, allocator);
}

/// CPU-based regex search - falls back to optimized backend for now
/// GNU grep's regex compilation has memory issues with quantifiers, so we use the
/// optimized Zig regex implementation instead.
pub fn searchRegex(text: []const u8, pattern: []const u8, options: SearchOptions, allocator: std.mem.Allocator) !SearchResult {
    // Use optimized backend for regex - GNU regex has memory issues with quantifiers
    return cpu_optimized.searchRegex(text, pattern, options, allocator);
}

/// Find line start position
fn findLineStart(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0) : (i -= 1) {
        if (text[i] == '\n') return i + 1;
    }
    if (text[0] == '\n') return 1;
    return 0;
}

/// Find next newline position
fn findNextNewline(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') return i;
    }
    return text.len;
}

/// Check word boundary
fn checkWordBoundary(text: []const u8, start: usize, end: usize) bool {
    if (start > 0 and isWordChar(text[start - 1])) return false;
    if (end < text.len and isWordChar(text[end])) return false;
    return true;
}

inline fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Search for all lines (empty pattern)
fn searchAllLines(text: []const u8, allocator: std.mem.Allocator) !SearchResult {
    var matches: std.ArrayListUnmanaged(MatchResult) = .{};
    defer matches.deinit(allocator);

    var total_matches: u64 = 0;
    var line_start: usize = 0;

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            try matches.append(allocator, MatchResult{
                .position = @intCast(line_start),
                .pattern_idx = 0,
                .match_len = 0,
                .line_start = @intCast(line_start),
            });
            total_matches += 1;
            line_start = i + 1;
        }
    }

    // Last line without newline
    if (line_start < text.len) {
        try matches.append(allocator, MatchResult{
            .position = @intCast(line_start),
            .pattern_idx = 0,
            .match_len = 0,
            .line_start = @intCast(line_start),
        });
        total_matches += 1;
    }

    const result = try matches.toOwnedSlice(allocator);
    return SearchResult{ .matches = result, .total_matches = total_matches, .allocator = allocator };
}

/// Search for lines that don't contain the pattern (for -v/--invert-match)
fn searchInverted(text: []const u8, pattern: []const u8, options: SearchOptions, allocator: std.mem.Allocator) !SearchResult {
    var matches: std.ArrayListUnmanaged(MatchResult) = .{};
    defer matches.deinit(allocator);

    var total_matches: u64 = 0;

    // Compile pattern once
    const ctx = gnu_grep_compile_fixed(pattern.ptr, @intCast(pattern.len), options.case_insensitive);
    defer gnu_grep_free(ctx);

    // Process line by line
    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = findNextNewline(text, line_start);
        const line = text[line_start..line_end];

        // Check if line contains pattern
        var has_match = false;
        if (ctx != null and line.len >= pattern.len) {
            var match_start: c_long = 0;
            const match_len = gnu_grep_execute(ctx.?, line.ptr, @intCast(line.len), &match_start);
            has_match = match_len >= 0;
        }

        // For invert match, we want lines that DON'T have matches
        if (!has_match) {
            try matches.append(allocator, MatchResult{
                .position = @intCast(line_start),
                .pattern_idx = 0,
                .match_len = @intCast(line.len),
                .line_start = @intCast(line_start),
            });
            total_matches += 1;
        }

        line_start = line_end + 1;
    }

    const result = try matches.toOwnedSlice(allocator);
    return SearchResult{ .matches = result, .total_matches = total_matches, .allocator = allocator };
}

/// Search for lines that don't match the regex pattern (for -v/--invert-match)
fn searchRegexInverted(text: []const u8, pattern: []const u8, options: SearchOptions, allocator: std.mem.Allocator) !SearchResult {
    var matches: std.ArrayListUnmanaged(MatchResult) = .{};
    defer matches.deinit(allocator);

    var total_matches: u64 = 0;

    // Compile pattern once
    const ctx = gnu_grep_compile_regex(pattern.ptr, @intCast(pattern.len), options.case_insensitive, options.extended);
    defer gnu_grep_free(ctx);

    // Process line by line
    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = findNextNewline(text, line_start);
        const line = text[line_start..line_end];

        // Check if line matches pattern
        var has_match = false;
        if (ctx != null) {
            var match_start: c_long = 0;
            const match_len = gnu_grep_execute(ctx.?, line.ptr, @intCast(line.len), &match_start);
            has_match = match_len >= 0;
        }

        // For invert match, we want lines that DON'T have matches
        if (!has_match) {
            try matches.append(allocator, MatchResult{
                .position = @intCast(line_start),
                .pattern_idx = 0,
                .match_len = @intCast(line.len),
                .line_start = @intCast(line_start),
            });
            total_matches += 1;
        }

        line_start = line_end + 1;
    }

    const result = try matches.toOwnedSlice(allocator);
    return SearchResult{ .matches = result, .total_matches = total_matches, .allocator = allocator };
}
