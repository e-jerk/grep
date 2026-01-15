const std = @import("std");
const gpu = @import("gpu");
const regex = @import("regex");

const SearchOptions = gpu.SearchOptions;
const SearchResult = gpu.SearchResult;
const MatchResult = gpu.MatchResult;

// SIMD vector types for optimal performance
const Vec16 = @Vector(16, u8);
const Vec32 = @Vector(32, u8);
const BoolVec16 = @Vector(16, bool);
const BoolVec32 = @Vector(32, bool);

// Constants for vectorized operations
const NEWLINE_VEC16: Vec16 = @splat('\n');
const NEWLINE_VEC32: Vec32 = @splat('\n');
const UPPER_A_VEC16: Vec16 = @splat('A');
const UPPER_Z_VEC16: Vec16 = @splat('Z');
const CASE_DIFF_VEC16: Vec16 = @splat(32);

/// CPU-based search using SIMD-optimized Boyer-Moore-Horspool algorithm
pub fn search(text: []const u8, pattern: []const u8, options: SearchOptions, allocator: std.mem.Allocator) !SearchResult {
    // Handle invert_match separately - find non-matching lines
    if (options.invert_match) {
        return searchInverted(text, pattern, options, allocator);
    }

    // Empty pattern matches all lines (GNU grep behavior)
    if (pattern.len == 0) {
        return searchAllLines(text, allocator);
    }

    if (text.len < pattern.len) {
        return SearchResult{ .matches = &.{}, .total_matches = 0, .allocator = allocator };
    }

    const skip_table = gpu.buildSkipTable(pattern, options.case_insensitive);

    var matches: std.ArrayListUnmanaged(MatchResult) = .{};
    defer matches.deinit(allocator);

    var pos: usize = 0;
    var total_matches: u64 = 0;

    // Pre-compute lowercase pattern if case insensitive
    var lower_pattern_buf: [1024]u8 = undefined;
    const lower_pattern = if (options.case_insensitive and pattern.len <= 1024) blk: {
        toLowerSlice(pattern, lower_pattern_buf[0..pattern.len]);
        break :blk lower_pattern_buf[0..pattern.len];
    } else pattern;

    while (pos + pattern.len <= text.len) {
        const matched = if (options.case_insensitive)
            matchAtPositionSIMD(text, pos, lower_pattern, true)
        else
            matchAtPositionSIMD(text, pos, pattern, false);

        if (matched) {
            var valid = true;

            if (options.word_boundary) {
                valid = checkWordBoundary(text, pos, pos + pattern.len);
            }

            if (valid) {
                try matches.append(allocator, MatchResult{
                    .position = @intCast(pos),
                    .pattern_idx = 0,
                    .match_len = @intCast(pattern.len),
                    .line_start = @intCast(findLineStartSIMD(text, pos)),
                });
                total_matches += 1;
            }
        }

        const skip_char = if (options.case_insensitive)
            toLowerChar(text[pos + pattern.len - 1])
        else
            text[pos + pattern.len - 1];
        const skip = skip_table[skip_char];
        pos += @max(skip, 1);
    }

    const result = try matches.toOwnedSlice(allocator);
    return SearchResult{ .matches = result, .total_matches = total_matches, .allocator = allocator };
}

/// SIMD-optimized pattern matching at a specific position
inline fn matchAtPositionSIMD(text: []const u8, pos: usize, pattern: []const u8, case_insensitive: bool) bool {
    if (pos + pattern.len > text.len) return false;

    const text_slice = text[pos..][0..pattern.len];
    var offset: usize = 0;

    // Process 16 bytes at a time
    while (offset + 16 <= pattern.len) {
        const text_vec: Vec16 = text_slice[offset..][0..16].*;
        const pattern_vec: Vec16 = pattern[offset..][0..16].*;

        const cmp_result = if (case_insensitive)
            @as(Vec16, toLowerVec16(text_vec)) == pattern_vec
        else
            text_vec == pattern_vec;

        if (!@reduce(.And, cmp_result)) return false;
        offset += 16;
    }

    // Process remaining bytes (up to 15)
    while (offset < pattern.len) {
        var tc = text_slice[offset];
        const pc = pattern[offset];

        if (case_insensitive) {
            tc = toLowerChar(tc);
        }

        if (tc != pc) return false;
        offset += 1;
    }

    return true;
}

/// Vectorized lowercase conversion for Vec16
inline fn toLowerVec16(v: Vec16) Vec16 {
    const is_upper = (v >= UPPER_A_VEC16) & (v <= UPPER_Z_VEC16);
    return @select(u8, is_upper, v + CASE_DIFF_VEC16, v);
}

/// Scalar lowercase conversion
inline fn toLowerChar(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Convert slice to lowercase
inline fn toLowerSlice(src: []const u8, dst: []u8) void {
    var i: usize = 0;
    // Process 16 bytes at a time
    while (i + 16 <= src.len) {
        const vec: Vec16 = src[i..][0..16].*;
        const lower = toLowerVec16(vec);
        dst[i..][0..16].* = lower;
        i += 16;
    }
    // Handle remaining bytes
    while (i < src.len) {
        dst[i] = toLowerChar(src[i]);
        i += 1;
    }
}

/// SIMD-optimized line start finder
fn findLineStartSIMD(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;

    var i = pos - 1;

    // Search backwards 16 bytes at a time when we have enough room
    while (i >= 16) {
        const start = i - 15;
        const chunk: Vec16 = text[start..][0..16].*;
        const newlines = chunk == NEWLINE_VEC16;

        // Find the last newline in this chunk
        if (@reduce(.Or, newlines)) {
            // Find the rightmost newline
            var j: usize = 15;
            while (j < 16) : (j -%= 1) {
                if (text[start + j] == '\n') {
                    return start + j + 1;
                }
                if (j == 0) break;
            }
        }
        i -= 16;
    }

    // Handle remaining bytes
    while (i > 0) {
        if (text[i] == '\n') return i + 1;
        i -= 1;
    }

    if (text[0] == '\n') return 1;
    return 0;
}

/// SIMD-optimized search for all lines (empty pattern)
fn searchAllLines(text: []const u8, allocator: std.mem.Allocator) !SearchResult {
    var matches: std.ArrayListUnmanaged(MatchResult) = .{};
    defer matches.deinit(allocator);

    var total_matches: u64 = 0;
    var line_start: usize = 0;

    // Count newlines using SIMD
    var i: usize = 0;
    while (i + 32 <= text.len) {
        const chunk: Vec32 = text[i..][0..32].*;
        const newlines = chunk == NEWLINE_VEC32;

        // Check if any newlines in this chunk
        if (@reduce(.Or, newlines)) {
            // Process byte by byte to find exact positions
            for (0..32) |j| {
                if (text[i + j] == '\n') {
                    try matches.append(allocator, MatchResult{
                        .position = @intCast(line_start),
                        .pattern_idx = 0,
                        .match_len = 0,
                        .line_start = @intCast(line_start),
                    });
                    total_matches += 1;
                    line_start = i + j + 1;
                }
            }
        }
        i += 32;
    }

    // Handle remaining bytes
    while (i < text.len) {
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
        i += 1;
    }

    // Don't forget the last line if it doesn't end with newline
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

    // Pre-compute lowercase pattern if case insensitive
    var lower_pattern_buf: [1024]u8 = undefined;
    const lower_pattern = if (options.case_insensitive and pattern.len <= 1024) blk: {
        toLowerSlice(pattern, lower_pattern_buf[0..pattern.len]);
        break :blk lower_pattern_buf[0..pattern.len];
    } else pattern;

    // Process line by line
    var line_start: usize = 0;
    while (line_start < text.len) {
        // Find line end using SIMD
        const line_end = findNextNewlineSIMD(text, line_start);
        const line = text[line_start..line_end];

        // Check if line contains pattern
        const has_match = if (pattern.len == 0 or line.len < pattern.len)
            false
        else
            lineContainsPatternSIMD(line, lower_pattern, options);

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

        // Move to next line
        line_start = line_end + 1;
    }

    const result = try matches.toOwnedSlice(allocator);
    return SearchResult{ .matches = result, .total_matches = total_matches, .allocator = allocator };
}

/// SIMD-optimized newline finder
fn findNextNewlineSIMD(text: []const u8, start: usize) usize {
    var i = start;

    // Search 32 bytes at a time
    while (i + 32 <= text.len) {
        const chunk: Vec32 = text[i..][0..32].*;
        const newlines = chunk == NEWLINE_VEC32;

        if (@reduce(.Or, newlines)) {
            // Find the first newline
            for (0..32) |j| {
                if (text[i + j] == '\n') return i + j;
            }
        }
        i += 32;
    }

    // Handle remaining bytes
    while (i < text.len) {
        if (text[i] == '\n') return i;
        i += 1;
    }

    return text.len;
}

/// SIMD-optimized check if a line contains the pattern
fn lineContainsPatternSIMD(line: []const u8, pattern: []const u8, options: SearchOptions) bool {
    if (line.len < pattern.len) return false;

    const skip_table = gpu.buildSkipTable(pattern, options.case_insensitive);
    var pos: usize = 0;

    while (pos + pattern.len <= line.len) {
        if (matchAtPositionSIMD(line, pos, pattern, options.case_insensitive)) {
            var valid = true;
            if (options.word_boundary) {
                valid = checkWordBoundary(line, pos, pos + pattern.len);
            }
            if (valid) return true;
        }

        const skip_char = if (options.case_insensitive)
            toLowerChar(line[pos + pattern.len - 1])
        else
            line[pos + pattern.len - 1];
        const skip = skip_table[skip_char];
        pos += @max(skip, 1);
    }

    return false;
}

fn checkWordBoundary(text: []const u8, start: usize, end: usize) bool {
    if (start > 0 and isWordChar(text[start - 1])) return false;
    if (end < text.len and isWordChar(text[end])) return false;
    return true;
}

inline fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// CPU-based regex search using Thompson NFA
/// Supports BRE (Basic Regular Expressions) and ERE (Extended Regular Expressions)
pub fn searchRegex(text: []const u8, pattern: []const u8, options: SearchOptions, allocator: std.mem.Allocator) !SearchResult {
    // Handle invert_match separately
    if (options.invert_match) {
        return searchRegexInverted(text, pattern, options, allocator);
    }

    // Empty pattern matches all lines (GNU grep behavior)
    if (pattern.len == 0) {
        return searchAllLines(text, allocator);
    }

    // Convert BRE pattern to ERE if needed
    const ere_pattern = if (!options.extended)
        try convertBREtoERE(pattern, allocator)
    else
        null;
    defer if (ere_pattern) |p| allocator.free(p);

    const actual_pattern = ere_pattern orelse pattern;

    // Compile the regex pattern
    var compiled = regex.Regex.compile(allocator, actual_pattern, .{
        .case_insensitive = options.case_insensitive,
        .extended = true, // Always use ERE internally after conversion
        .multiline = true, // Enable multiline mode for ^ and $ to match at line boundaries
    }) catch |err| {
        // If regex compilation fails, fall back to literal search
        if (err == error.InvalidPattern or err == error.UnmatchedParen or err == error.UnmatchedBracket) {
            return search(text, pattern, .{
                .case_insensitive = options.case_insensitive,
                .word_boundary = options.word_boundary,
                .invert_match = options.invert_match,
                .fixed_string = true,
            }, allocator);
        }
        return err;
    };
    defer compiled.deinit();

    var matches: std.ArrayListUnmanaged(MatchResult) = .{};
    defer matches.deinit(allocator);

    var total_matches: u64 = 0;

    // Find all matches
    const all_matches = try compiled.findAll(text, allocator);
    defer {
        for (all_matches) |*m| m.deinit();
        allocator.free(all_matches);
    }

    for (all_matches) |m| {
        // Word boundary check if requested
        if (options.word_boundary) {
            if (!checkWordBoundary(text, m.start, m.end)) continue;
        }

        const line_start = findLineStartSIMD(text, m.start);

        try matches.append(allocator, MatchResult{
            .position = @intCast(m.start),
            .pattern_idx = 0,
            .match_len = @intCast(m.end - m.start),
            .line_start = @intCast(line_start),
        });
        total_matches += 1;
    }

    const result = try matches.toOwnedSlice(allocator);
    return SearchResult{ .matches = result, .total_matches = total_matches, .allocator = allocator };
}

/// Search for lines that don't match the regex pattern (for -v/--invert-match)
fn searchRegexInverted(text: []const u8, pattern: []const u8, options: SearchOptions, allocator: std.mem.Allocator) !SearchResult {
    var matches: std.ArrayListUnmanaged(MatchResult) = .{};
    defer matches.deinit(allocator);

    var total_matches: u64 = 0;

    // Convert BRE pattern to ERE if needed
    const ere_pattern = if (!options.extended)
        try convertBREtoERE(pattern, allocator)
    else
        null;
    defer if (ere_pattern) |p| allocator.free(p);

    const actual_pattern = ere_pattern orelse pattern;

    // Compile the regex pattern
    var compiled = regex.Regex.compile(allocator, actual_pattern, .{
        .case_insensitive = options.case_insensitive,
        .extended = true,
        .multiline = true, // Enable multiline mode for ^ and $ to match at line boundaries
    }) catch |err| {
        // If regex compilation fails, fall back to literal search
        if (err == error.InvalidPattern or err == error.UnmatchedParen or err == error.UnmatchedBracket) {
            return searchInverted(text, pattern, .{
                .case_insensitive = options.case_insensitive,
                .word_boundary = options.word_boundary,
                .invert_match = true,
                .fixed_string = true,
            }, allocator);
        }
        return err;
    };
    defer compiled.deinit();

    // Process line by line
    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = findNextNewlineSIMD(text, line_start);
        const line = text[line_start..line_end];

        // Check if line matches pattern
        const has_match = compiled.isMatch(line);

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

/// Convert BRE (Basic Regular Expression) pattern to ERE (Extended Regular Expression)
/// In BRE: \+ \? \| \( \) \{ \} are special, unescaped versions are literal
/// In ERE: + ? | ( ) { } are special, escaped versions are literal
fn convertBREtoERE(bre_pattern: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < bre_pattern.len) {
        if (bre_pattern[i] == '\\' and i + 1 < bre_pattern.len) {
            const next = bre_pattern[i + 1];
            switch (next) {
                // In BRE, \+ \? \| \( \) are special (quantifiers/grouping)
                // In ERE, just + ? | ( ) without backslash
                '+', '?', '|', '(', ')' => {
                    try result.append(allocator, next);
                    i += 2;
                },
                // In BRE, \{ \} are interval brackets
                // In ERE, just { } without backslash
                '{', '}' => {
                    try result.append(allocator, next);
                    i += 2;
                },
                // Other escapes pass through
                else => {
                    try result.append(allocator, '\\');
                    try result.append(allocator, next);
                    i += 2;
                },
            }
        } else if (bre_pattern[i] == '+' or bre_pattern[i] == '?' or bre_pattern[i] == '|' or
            bre_pattern[i] == '(' or bre_pattern[i] == ')' or
            bre_pattern[i] == '{' or bre_pattern[i] == '}')
        {
            // In BRE, unescaped + ? | ( ) { } are literal
            // In ERE, they need to be escaped
            try result.append(allocator, '\\');
            try result.append(allocator, bre_pattern[i]);
            i += 1;
        } else {
            try result.append(allocator, bre_pattern[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}
