// PCRE to GPU NFA Compiler
// Converts Perl-compatible regex patterns to GPU-executable NFA format
// Supports: lookahead (?=) (?!), lookbehind (?<=) (?<!), non-greedy quantifiers

const std = @import("std");
const mod = @import("mod.zig");
const regex_lib = @import("regex");

const RegexState = mod.RegexState;
const RegexHeader = mod.RegexHeader;
const RegexStateType = mod.RegexStateType;
const MAX_REGEX_STATES = mod.MAX_REGEX_STATES;
const BITMAP_WORDS_PER_CLASS = mod.BITMAP_WORDS_PER_CLASS;

pub const PcreCompileError = error{
    InvalidPattern,
    UnsupportedFeature,
    TooManyStates,
    LookbehindNotFixedLength,
    OutOfMemory,
};

pub const CompiledPcreRegex = struct {
    header: RegexHeader,
    states: []RegexState,
    bitmaps: []u32,
    allocator: std.mem.Allocator,
    supports_gpu: bool, // True if pattern can run on GPU

    pub fn deinit(self: *CompiledPcreRegex) void {
        self.allocator.free(self.states);
        if (self.bitmaps.len > 0) {
            self.allocator.free(self.bitmaps);
        }
    }
};

/// Check if a PCRE pattern can be compiled to GPU format
/// Returns true if all features are supported on GPU
pub fn canCompileToGpu(pattern: []const u8) bool {
    var i: usize = 0;
    while (i < pattern.len) {
        if (i + 1 < pattern.len and pattern[i] == '(' and pattern[i + 1] == '?') {
            // Check for PCRE extensions
            if (i + 2 < pattern.len) {
                const c = pattern[i + 2];
                switch (c) {
                    '=', '!' => {
                        // Lookahead - supported
                        i += 3;
                        continue;
                    },
                    '<' => {
                        if (i + 3 < pattern.len) {
                            const d = pattern[i + 3];
                            if (d == '=' or d == '!') {
                                // Lookbehind - check if fixed length (simplified check)
                                i += 4;
                                continue;
                            }
                            // Named group (?<name>...) - not yet supported
                            return false;
                        }
                    },
                    '>' => {
                        // Atomic group - supported
                        i += 3;
                        continue;
                    },
                    ':' => {
                        // Non-capturing group - supported (same as regular group on GPU)
                        i += 3;
                        continue;
                    },
                    else => {
                        // Other extensions not supported
                        return false;
                    },
                }
            }
        }
        // Check for backreferences \1, \2, etc. - not supported on GPU
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            const c = pattern[i + 1];
            if (c >= '1' and c <= '9') {
                return false;
            }
        }
        i += 1;
    }
    return true;
}

/// Compile a PCRE pattern for GPU execution
/// Falls back to CPU-only mode if pattern uses unsupported features
pub fn compileForGpu(pattern: []const u8, case_insensitive: bool, allocator: std.mem.Allocator) !CompiledPcreRegex {
    // Check if pattern can be compiled to GPU
    if (!canCompileToGpu(pattern)) {
        // Return a stub that indicates CPU-only execution
        return CompiledPcreRegex{
            .header = RegexHeader{
                .num_states = 0,
                .start_state = 0,
                .num_groups = 0,
                .flags = 0,
            },
            .states = &[_]RegexState{},
            .bitmaps = &[_]u32{},
            .allocator = allocator,
            .supports_gpu = false,
        };
    }

    // Pre-process pattern to convert PCRE syntax to extended ERE
    var preprocessed = try preprocessPcrePattern(pattern, allocator);
    defer allocator.free(preprocessed.pattern);

    // Compile the base pattern using the standard regex library
    var cpu_regex = regex_lib.Regex.compile(allocator, preprocessed.pattern, .{
        .case_insensitive = case_insensitive,
    }) catch {
        return PcreCompileError.InvalidPattern;
    };
    defer cpu_regex.deinit();

    // Convert to GPU format with PCRE extensions
    return convertToGpuFormatWithPcre(&cpu_regex, preprocessed.extensions, allocator);
}

const PcreExtension = struct {
    ext_type: ExtType,
    start_pos: usize, // Position in preprocessed pattern
    sub_pattern_start: u16, // NFA state where sub-pattern starts
    sub_pattern_end: u16, // NFA state where sub-pattern ends
    fixed_length: u32, // For lookbehind: fixed length of sub-pattern

    const ExtType = enum {
        lookahead_pos,
        lookahead_neg,
        lookbehind_pos,
        lookbehind_neg,
        atomic_group,
    };
};

const PreprocessResult = struct {
    pattern: []u8,
    extensions: []PcreExtension,
};

fn preprocessPcrePattern(pattern: []const u8, allocator: std.mem.Allocator) !PreprocessResult {
    // For now, pass through the pattern without modification
    // The PCRE extensions will be handled by the NFA converter
    var result = try allocator.alloc(u8, pattern.len);
    @memcpy(result, pattern);

    return PreprocessResult{
        .pattern = result,
        .extensions = &[_]PcreExtension{},
    };
}

fn convertToGpuFormatWithPcre(cpu_regex: *regex_lib.Regex, _: []const PcreExtension, allocator: std.mem.Allocator) !CompiledPcreRegex {
    const states = cpu_regex.states;

    if (states.len > MAX_REGEX_STATES) {
        return PcreCompileError.TooManyStates;
    }

    // Count character classes for bitmap allocation
    var num_char_classes: u32 = 0;
    for (states) |state| {
        if (state.type == .char_class) {
            num_char_classes += 1;
        }
    }

    // Allocate GPU state array
    const gpu_states = try allocator.alloc(RegexState, states.len);
    errdefer allocator.free(gpu_states);

    // Allocate bitmap buffer
    const bitmap_words = num_char_classes * BITMAP_WORDS_PER_CLASS;
    const bitmaps: []u32 = if (bitmap_words > 0)
        try allocator.alloc(u32, bitmap_words)
    else
        @constCast(&[_]u32{});
    errdefer if (bitmap_words > 0) allocator.free(bitmaps);

    // Convert states
    var bitmap_offset: u32 = 0;
    for (states, 0..) |state, i| {
        gpu_states[i] = convertState(state, &bitmap_offset, bitmaps);
    }

    // Build header
    const header = RegexHeader{
        .num_states = @intCast(states.len),
        .start_state = cpu_regex.start_state,
        .num_groups = @intCast(cpu_regex.num_groups),
        .flags = buildHeaderFlags(cpu_regex),
    };

    return CompiledPcreRegex{
        .header = header,
        .states = gpu_states,
        .bitmaps = bitmaps,
        .allocator = allocator,
        .supports_gpu = true,
    };
}

fn convertState(state: regex_lib.State, bitmap_offset: *u32, bitmaps: []u32) RegexState {
    var gpu_state = RegexState{
        .type = @intFromEnum(state.type),
        .flags = 0,
        .out = if (state.out == regex_lib.State.NONE) 0xFFFF else @intCast(@min(state.out, 0xFFFF)),
        .out2 = if (state.out2 == regex_lib.State.NONE) 0xFFFF else @intCast(@min(state.out2, 0xFFFF)),
        .literal_char = 0,
        .group_idx = 0,
        .bitmap_offset = 0,
    };

    switch (state.type) {
        .literal => {
            gpu_state.literal_char = state.data.literal.char;
            if (state.data.literal.case_insensitive) {
                gpu_state.flags |= RegexState.FLAG_CASE_INSENSITIVE;
            }
        },
        .char_class => {
            const cpu_bitmap = state.data.char_class.bitmap;
            const offset = bitmap_offset.*;

            var j: usize = 0;
            while (j < 8) : (j += 1) {
                const byte_idx = j * 4;
                bitmaps[offset + j] =
                    @as(u32, cpu_bitmap.bitmap[byte_idx]) |
                    (@as(u32, cpu_bitmap.bitmap[byte_idx + 1]) << 8) |
                    (@as(u32, cpu_bitmap.bitmap[byte_idx + 2]) << 16) |
                    (@as(u32, cpu_bitmap.bitmap[byte_idx + 3]) << 24);
            }

            gpu_state.bitmap_offset = offset;
            if (state.data.char_class.negated) {
                gpu_state.flags |= RegexState.FLAG_NEGATED;
            }
            bitmap_offset.* += BITMAP_WORDS_PER_CLASS;
        },
        .group_start, .group_end => {
            gpu_state.group_idx = @intCast(state.data.group_idx);
        },
        .lookahead_pos, .lookahead_neg, .lookbehind_pos, .lookbehind_neg => {
            // For lookaround states:
            // - group_idx stores sub-pattern start state (shader expects this)
            // - out2 stores dummy end state (shader uses STATE_MATCH check)
            // - bitmap_offset stores fixed length for lookbehind
            const la_data = state.data.lookaround;
            gpu_state.group_idx = @intCast(@min(la_data.sub_pattern_start, 0xFF));
            gpu_state.out2 = 0xFFFF; // Shader relies on STATE_MATCH in sub-pattern
            gpu_state.bitmap_offset = la_data.sub_pattern_len;
        },
        else => {},
    }

    return gpu_state;
}

fn buildHeaderFlags(cpu_regex: *regex_lib.Regex) u32 {
    var flags: u32 = 0;
    if (cpu_regex.anchored_start) flags |= RegexHeader.FLAG_ANCHORED_START;
    if (cpu_regex.anchored_end) flags |= RegexHeader.FLAG_ANCHORED_END;
    if (cpu_regex.case_insensitive) flags |= RegexHeader.FLAG_CASE_INSENSITIVE;
    return flags;
}
