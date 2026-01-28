const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");
const cpu_gnu = @import("cpu_gnu");
const pcre = @import("pcre");

const SearchOptions = gpu.SearchOptions;

/// Backend selection mode
const BackendMode = enum {
    auto, // Automatically select based on workload
    gpu, // Auto-select best GPU (Metal on macOS, else Vulkan)
    cpu, // Optimized SIMD CPU backend (default for CPU)
    cpu_gnu, // GNU grep backend (reference implementation)
    metal,
    vulkan,
};

/// Configurable thresholds for auto-selection
const AutoSelectConfig = struct {
    min_gpu_file_size: usize = 128 * 1024, // 128KB default (adjusted by hardware)
    max_gpu_file_size: usize = gpu.MAX_GPU_BUFFER_SIZE, // 16MB default (adjusted by hardware)
    short_pattern_len: usize = 4, // Patterns <= this favor GPU
    long_pattern_len: usize = 8, // Patterns >= this favor CPU
    gpu_bias: i32 = 0, // Adjustment to GPU score (+ve favors GPU, -ve favors CPU)
    hardware_detected: bool = false, // Whether hardware-based adjustments have been applied

    /// Apply hardware-based adjustments from detected GPU capabilities
    pub fn applyHardwareCapabilities(self: *AutoSelectConfig, caps: gpu.GpuCapabilities) void {
        if (self.hardware_detected) return; // Only apply once

        // Adjust GPU bias based on hardware performance score
        self.gpu_bias += caps.gpuBiasAdjustment();

        // Adjust min file size based on GPU tier (better GPUs can handle smaller files)
        self.min_gpu_file_size = caps.minGpuWorkloadSize();

        // Adjust max file size based on actual buffer limits
        self.max_gpu_file_size = caps.maxGpuWorkloadSize(self.max_gpu_file_size);

        self.hardware_detected = true;
    }
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return 0;
    }

    var options = SearchOptions{};
    var backend_mode: BackendMode = .auto;
    var patterns: std.ArrayListUnmanaged([]const u8) = .{};
    defer patterns.deinit(allocator);
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    defer files.deinit(allocator);
    var verbose = false;
    var count_only = false;
    var line_numbers = false;
    var files_with_matches = false;
    var files_without_match = false;
    var quiet_mode = false;
    var only_matching = false;
    var before_context: u32 = 0;
    var after_context: u32 = 0;
    var recursive = false;
    var color_mode: ColorMode = .never;
    var config = AutoSelectConfig{};

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
            options.case_insensitive = true;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--word-regexp")) {
            options.word_boundary = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--invert-match")) {
            options.invert_match = true;
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings")) {
            options.fixed_string = true;
            options.extended = false;
        } else if (std.mem.eql(u8, arg, "-G") or std.mem.eql(u8, arg, "--basic-regexp")) {
            options.fixed_string = false;
            options.extended = false;
        } else if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--extended-regexp")) {
            options.fixed_string = false;
            options.extended = true;
            options.perl = false;
        } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--perl-regexp")) {
            options.fixed_string = false;
            options.extended = false;
            options.perl = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            count_only = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--line-number")) {
            line_numbers = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--files-with-matches")) {
            files_with_matches = true;
        } else if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--files-without-match")) {
            files_without_match = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--silent")) {
            quiet_mode = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--only-matching")) {
            only_matching = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "-R") or std.mem.eql(u8, arg, "--recursive")) {
            recursive = true;
        } else if (std.mem.eql(u8, arg, "--color") or std.mem.eql(u8, arg, "--colour")) {
            color_mode = .always;
        } else if (std.mem.eql(u8, arg, "--color=always") or std.mem.eql(u8, arg, "--colour=always")) {
            color_mode = .always;
        } else if (std.mem.eql(u8, arg, "--color=never") or std.mem.eql(u8, arg, "--colour=never")) {
            color_mode = .never;
        } else if (std.mem.eql(u8, arg, "--color=auto") or std.mem.eql(u8, arg, "--colour=auto")) {
            color_mode = .auto;
        } else if (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--after-context")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Option -A requires an argument\n", .{});
                return 2;
            }
            after_context = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Invalid -A value: {s}\n", .{args[i]});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "-A")) {
            after_context = std.fmt.parseInt(u32, arg[2..], 10) catch {
                std.debug.print("Invalid -A value: {s}\n", .{arg[2..]});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--after-context=")) {
            after_context = std.fmt.parseInt(u32, arg["--after-context=".len..], 10) catch {
                std.debug.print("Invalid --after-context value: {s}\n", .{arg["--after-context=".len..]});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--before-context")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Option -B requires an argument\n", .{});
                return 2;
            }
            before_context = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Invalid -B value: {s}\n", .{args[i]});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "-B")) {
            before_context = std.fmt.parseInt(u32, arg[2..], 10) catch {
                std.debug.print("Invalid -B value: {s}\n", .{arg[2..]});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--before-context=")) {
            before_context = std.fmt.parseInt(u32, arg["--before-context=".len..], 10) catch {
                std.debug.print("Invalid --before-context value: {s}\n", .{arg["--before-context=".len..]});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--context")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Option -C requires an argument\n", .{});
                return 2;
            }
            const ctx_val = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Invalid -C value: {s}\n", .{args[i]});
                return 2;
            };
            before_context = ctx_val;
            after_context = ctx_val;
        } else if (std.mem.startsWith(u8, arg, "-C")) {
            const ctx_val = std.fmt.parseInt(u32, arg[2..], 10) catch {
                std.debug.print("Invalid -C value: {s}\n", .{arg[2..]});
                return 2;
            };
            before_context = ctx_val;
            after_context = ctx_val;
        } else if (std.mem.startsWith(u8, arg, "--context=")) {
            const ctx_val = std.fmt.parseInt(u32, arg["--context=".len..], 10) catch {
                std.debug.print("Invalid --context value: {s}\n", .{arg["--context=".len..]});
                return 2;
            };
            before_context = ctx_val;
            after_context = ctx_val;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--regexp")) {
            // -e PATTERN: add pattern
            i += 1;
            if (i >= args.len) {
                std.debug.print("Option -e requires an argument\n", .{});
                return 2;
            }
            try patterns.append(allocator, args[i]);
        } else if (std.mem.startsWith(u8, arg, "-e")) {
            // -ePATTERN (no space)
            try patterns.append(allocator, arg[2..]);
        } else if (std.mem.startsWith(u8, arg, "--regexp=")) {
            try patterns.append(allocator, arg["--regexp=".len..]);
        } else if (std.mem.eql(u8, arg, "--cpu") or std.mem.eql(u8, arg, "--cpu-optimized")) {
            backend_mode = .cpu;
        } else if (std.mem.eql(u8, arg, "--gnu")) {
            backend_mode = .cpu_gnu;
        } else if (std.mem.eql(u8, arg, "--gpu")) {
            backend_mode = .gpu;
        } else if (std.mem.eql(u8, arg, "--metal")) {
            backend_mode = .metal;
        } else if (std.mem.eql(u8, arg, "--vulkan")) {
            backend_mode = .vulkan;
        } else if (std.mem.eql(u8, arg, "--auto")) {
            backend_mode = .auto;
        } else if (std.mem.eql(u8, arg, "--prefer-gpu")) {
            config.gpu_bias = 3; // Strong GPU preference
        } else if (std.mem.eql(u8, arg, "--prefer-cpu")) {
            config.gpu_bias = -3; // Strong CPU preference
        } else if (std.mem.startsWith(u8, arg, "--min-gpu-size=")) {
            const val = arg["--min-gpu-size=".len..];
            config.min_gpu_file_size = parseSize(val) catch {
                std.debug.print("Invalid --min-gpu-size value: {s}\n", .{val});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--max-gpu-size=")) {
            const val = arg["--max-gpu-size=".len..];
            config.max_gpu_file_size = parseSize(val) catch {
                std.debug.print("Invalid --max-gpu-size value: {s}\n", .{val});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--short-pattern=")) {
            const val = arg["--short-pattern=".len..];
            config.short_pattern_len = std.fmt.parseInt(usize, val, 10) catch {
                std.debug.print("Invalid --short-pattern value: {s}\n", .{val});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--long-pattern=")) {
            const val = arg["--long-pattern=".len..];
            config.long_pattern_len = std.fmt.parseInt(usize, val, 10) catch {
                std.debug.print("Invalid --long-pattern value: {s}\n", .{val});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--gpu-bias=")) {
            const val = arg["--gpu-bias=".len..];
            config.gpu_bias = std.fmt.parseInt(i32, val, 10) catch {
                std.debug.print("Invalid --gpu-bias value: {s}\n", .{val});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-V")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return 0;
        } else if (std.mem.eql(u8, arg, "--version")) {
            _ = std.posix.write(std.posix.STDOUT_FILENO, "grep (e-jerk GPU-accelerated) 1.0\n") catch {};
            return 0;
        } else if (arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
            // Non-option argument or "-" for stdin
            if (patterns.items.len == 0) {
                // First non-option is pattern (if no -e was used)
                try patterns.append(allocator, arg);
            } else {
                try files.append(allocator, arg);
            }
        } else if (arg[0] == '-' and arg.len > 1 and arg[1] != '-') {
            // Combined short options like -rn, -ri, -rin
            var valid = true;
            for (arg[1..]) |c| {
                switch (c) {
                    'i' => options.case_insensitive = true,
                    'w' => options.word_boundary = true,
                    'v' => options.invert_match = true,
                    'F' => {
                        options.fixed_string = true;
                        options.extended = false;
                    },
                    'G' => {
                        options.fixed_string = false;
                        options.extended = false;
                    },
                    'E' => {
                        options.fixed_string = false;
                        options.extended = true;
                        options.perl = false;
                    },
                    'P' => {
                        options.fixed_string = false;
                        options.extended = false;
                        options.perl = true;
                    },
                    'c' => count_only = true,
                    'n' => line_numbers = true,
                    'l' => files_with_matches = true,
                    'L' => files_without_match = true,
                    'q' => quiet_mode = true,
                    'o' => only_matching = true,
                    'r', 'R' => recursive = true,
                    else => {
                        valid = false;
                        break;
                    },
                }
            }
            if (!valid) {
                std.debug.print("Unknown option: {s}\n", .{arg});
                printUsage();
                return 2;
            }
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printUsage();
            return 2;
        }
    }

    // If no patterns specified, error
    if (patterns.items.len == 0) {
        std.debug.print("Error: No pattern specified\n", .{});
        printUsage();
        return 2;
    }

    // If no files specified, read from stdin
    const read_stdin = files.items.len == 0;

    if (verbose) {
        std.debug.print("grep - GPU-accelerated grep\n", .{});
        std.debug.print("Patterns: {d} pattern(s)\n", .{patterns.items.len});
        for (patterns.items) |p| {
            std.debug.print("  - \"{s}\" (len={d})\n", .{ p, p.len });
        }
        std.debug.print("Mode: {s}\n", .{@tagName(backend_mode)});
        std.debug.print("Options: case_insensitive={}, word_boundary={}, invert={}\n", .{
            options.case_insensitive,
            options.word_boundary,
            options.invert_match,
        });
        if (backend_mode == .auto) {
            std.debug.print("Auto-config: min_gpu={d}KB, max_gpu={d}MB, short_pat={d}, long_pat={d}, bias={d}\n\n", .{
                config.min_gpu_file_size / 1024,
                config.max_gpu_file_size / (1024 * 1024),
                config.short_pattern_len,
                config.long_pattern_len,
                config.gpu_bias,
            });
        } else {
            std.debug.print("\n", .{});
        }
    }

    // Track whether we found any matches (for exit code)
    var found_match = false;
    var had_error = false;
    const show_filename = files.items.len > 1;

    // Resolve color mode: 'auto' checks if stdout is a tty
    const effective_color_mode: ColorMode = switch (color_mode) {
        .auto => if (std.posix.isatty(std.posix.STDOUT_FILENO)) .always else .never,
        else => color_mode,
    };

    const output_opts = OutputOptions{
        .count_only = count_only,
        .line_numbers = line_numbers,
        .files_with_matches = files_with_matches,
        .files_without_match = files_without_match,
        .quiet_mode = quiet_mode,
        .only_matching = only_matching,
        .show_filename = show_filename,
        .before_context = before_context,
        .after_context = after_context,
        .color_mode = effective_color_mode,
    };

    // Process each file or stdin
    if (read_stdin) {
        const result = processStdin(allocator, patterns.items, options, backend_mode, config, verbose, output_opts, null);
        if (result.found) found_match = true;
        if (result.had_error) had_error = true;
        // For quiet mode, exit early on first match
        if (quiet_mode and found_match) return 0;
    } else {
        for (files.items) |filepath| {
            // Handle "-" as stdin
            if (std.mem.eql(u8, filepath, "-")) {
                const result = processStdin(allocator, patterns.items, options, backend_mode, config, verbose, output_opts, if (show_filename) "(standard input)" else null);
                if (result.found) found_match = true;
                if (result.had_error) had_error = true;
            } else if (recursive) {
                // Check if path is a directory
                const stat = std.fs.cwd().statFile(filepath) catch |err| {
                    std.debug.print("grep: {s}: {}\n", .{ filepath, err });
                    had_error = true;
                    continue;
                };
                if (stat.kind == .directory) {
                    // In recursive mode, always show filenames
                    var recursive_opts = output_opts;
                    recursive_opts.show_filename = true;
                    processDirectory(allocator, filepath, patterns.items, options, backend_mode, config, verbose, recursive_opts, &found_match, &had_error, quiet_mode);
                } else {
                    const result = processFile(allocator, filepath, patterns.items, options, backend_mode, config, verbose, output_opts);
                    if (result.found) found_match = true;
                    if (result.had_error) had_error = true;
                }
            } else {
                const result = processFile(allocator, filepath, patterns.items, options, backend_mode, config, verbose, output_opts);
                if (result.found) found_match = true;
                if (result.had_error) had_error = true;
            }
            // For quiet mode, exit early on first match
            if (quiet_mode and found_match) return 0;
        }
    }

    // Exit codes: 0 = match found, 1 = no match, 2 = error
    if (had_error) return 2;
    if (found_match) return 0;
    return 1;
}

const ProcessResult = struct {
    found: bool,
    had_error: bool,
};

/// Output format options
const ColorMode = enum {
    never,
    always,
    auto,
};

const OutputOptions = struct {
    count_only: bool = false,
    line_numbers: bool = false,
    files_with_matches: bool = false,
    files_without_match: bool = false,
    quiet_mode: bool = false,
    only_matching: bool = false,
    show_filename: bool = false,
    before_context: u32 = 0, // -B N: show N lines before match
    after_context: u32 = 0, // -A N: show N lines after match
    color_mode: ColorMode = .never,
};

// ANSI color escape codes
const COLOR_MATCH_START = "\x1b[01;31m"; // Bold red for match
const COLOR_RESET = "\x1b[m";
const COLOR_FILENAME = "\x1b[35m"; // Magenta for filename
const COLOR_LINE_NUM = "\x1b[32m"; // Green for line number
const COLOR_SEP = "\x1b[36m"; // Cyan for separator

/// Choose appropriate search function based on options and backend
fn doSearch(text: []const u8, pattern: []const u8, options: SearchOptions, allocator: std.mem.Allocator, backend_mode: BackendMode) !gpu.SearchResult {
    const use_gnu = backend_mode == .cpu_gnu;

    if (options.fixed_string) {
        return if (use_gnu)
            cpu_gnu.search(text, pattern, options, allocator)
        else
            cpu.search(text, pattern, options, allocator);
    } else if (options.perl) {
        // Use PCRE2 for Perl-compatible regex (-P flag)
        return pcre.searchPcre(text, pattern, options, allocator);
    } else {
        return if (use_gnu)
            cpu_gnu.searchRegex(text, pattern, options, allocator)
        else
            cpu.searchRegex(text, pattern, options, allocator);
    }
}

/// Search for multiple patterns in text, combining results (OR semantics)
fn searchMultiPattern(allocator: std.mem.Allocator, text: []const u8, all_patterns: []const []const u8, options: SearchOptions, backend_mode: BackendMode) !gpu.SearchResult {
    if (all_patterns.len == 0) {
        return gpu.SearchResult{ .matches = &.{}, .total_matches = 0, .allocator = allocator };
    }

    // For single pattern, use regular search
    if (all_patterns.len == 1) {
        return doSearch(text, all_patterns[0], options, allocator, backend_mode);
    }

    // Multiple patterns: search each and combine results
    var all_line_starts = std.AutoHashMap(u32, void).init(allocator);
    defer all_line_starts.deinit();

    var combined_matches: std.ArrayListUnmanaged(gpu.MatchResult) = .{};
    defer combined_matches.deinit(allocator);

    var total_matches: u64 = 0;

    for (all_patterns) |pattern| {
        var result = doSearch(text, pattern, options, allocator, backend_mode) catch continue;
        defer result.deinit();

        for (result.matches) |match| {
            // Only add if this line hasn't been matched before
            if (!all_line_starts.contains(match.line_start)) {
                try all_line_starts.put(match.line_start, {});
                try combined_matches.append(allocator, match);
            }
        }
        total_matches += result.total_matches;
    }

    // Sort combined matches by line_start to maintain order
    std.mem.sort(gpu.MatchResult, combined_matches.items, {}, struct {
        fn cmp(_: void, a: gpu.MatchResult, b: gpu.MatchResult) bool {
            return a.line_start < b.line_start;
        }
    }.cmp);

    const matches_slice = try combined_matches.toOwnedSlice(allocator);
    return gpu.SearchResult{
        .matches = matches_slice,
        .total_matches = total_matches,
        .allocator = allocator,
    };
}

/// Line information for context output
const LineInfo = struct {
    start: usize,
    end: usize,
};

/// Build an array of line boundaries from text
fn buildLineIndex(allocator: std.mem.Allocator, text: []const u8) ![]LineInfo {
    var lines: std.ArrayListUnmanaged(LineInfo) = .{};
    errdefer lines.deinit(allocator);

    var line_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            try lines.append(allocator, .{ .start = line_start, .end = i });
            line_start = i + 1;
        }
    }
    // Last line (if no trailing newline)
    if (line_start < text.len) {
        try lines.append(allocator, .{ .start = line_start, .end = text.len });
    }

    return lines.toOwnedSlice(allocator);
}

/// Find line number for a given position (binary search)
fn findLineNumber(lines: []const LineInfo, pos: usize) usize {
    var left: usize = 0;
    var right: usize = lines.len;
    while (left < right) {
        const mid = left + (right - left) / 2;
        if (pos < lines[mid].start) {
            right = mid;
        } else if (pos > lines[mid].end) {
            left = mid + 1;
        } else {
            return mid;
        }
    }
    return left;
}

/// Output a line with colored match highlighting
fn outputLineWithColor(
    text: []const u8,
    line_start: usize,
    line_end: usize,
    matches: []const gpu.MatchResult,
    color: bool,
) void {
    const line = text[line_start..line_end];

    if (!color) {
        _ = std.posix.write(std.posix.STDOUT_FILENO, line) catch {};
        return;
    }

    // Find matches within this line and highlight them
    // Collect match spans within this line
    var match_spans: [64]struct { start: usize, end: usize } = undefined;
    var span_count: usize = 0;

    for (matches) |match| {
        // Check if this match is within our line
        if (match.position >= line_start and match.position < line_end) {
            if (span_count < 64) {
                const rel_start = match.position - line_start;
                const rel_end = @min(rel_start + match.match_len, line.len);
                match_spans[span_count] = .{ .start = rel_start, .end = rel_end };
                span_count += 1;
            }
        }
    }

    if (span_count == 0) {
        // No matches in this line, output as-is
        _ = std.posix.write(std.posix.STDOUT_FILENO, line) catch {};
        return;
    }

    // Sort spans by start position
    std.mem.sort(@TypeOf(match_spans[0]), match_spans[0..span_count], {}, struct {
        fn cmp(_: void, a: @TypeOf(match_spans[0]), b: @TypeOf(match_spans[0])) bool {
            return a.start < b.start;
        }
    }.cmp);

    // Output with color highlighting
    var pos: usize = 0;
    for (match_spans[0..span_count]) |span| {
        // Output text before match
        if (pos < span.start) {
            _ = std.posix.write(std.posix.STDOUT_FILENO, line[pos..span.start]) catch {};
        }
        // Output match with color
        _ = std.posix.write(std.posix.STDOUT_FILENO, COLOR_MATCH_START) catch {};
        _ = std.posix.write(std.posix.STDOUT_FILENO, line[span.start..span.end]) catch {};
        _ = std.posix.write(std.posix.STDOUT_FILENO, COLOR_RESET) catch {};
        pos = span.end;
    }
    // Output remaining text after last match
    if (pos < line.len) {
        _ = std.posix.write(std.posix.STDOUT_FILENO, line[pos..]) catch {};
    }
}

/// Output matches with context lines
fn outputWithContext(
    text: []const u8,
    matches: []const gpu.MatchResult,
    output_opts: OutputOptions,
    filename_prefix: ?[]const u8,
    allocator: std.mem.Allocator,
) void {
    if (matches.len == 0) return;

    // Build line index
    const lines = buildLineIndex(allocator, text) catch return;
    defer allocator.free(lines);

    if (lines.len == 0) return;

    // Get unique matching lines
    var match_lines = std.AutoHashMap(usize, void).init(allocator);
    defer match_lines.deinit();

    for (matches) |match| {
        const line_num = findLineNumber(lines, match.line_start);
        match_lines.put(line_num, {}) catch continue;
    }

    // Build output ranges (line_num ranges including context)
    const Range = struct { start: usize, end: usize };
    var ranges: std.ArrayListUnmanaged(Range) = .{};
    defer ranges.deinit(allocator);

    // Collect and sort matching line numbers
    var sorted_matches: std.ArrayListUnmanaged(usize) = .{};
    defer sorted_matches.deinit(allocator);
    var iter = match_lines.keyIterator();
    while (iter.next()) |line_num| {
        sorted_matches.append(allocator, line_num.*) catch continue;
    }
    std.mem.sort(usize, sorted_matches.items, {}, std.sort.asc(usize));

    // Build ranges with context
    for (sorted_matches.items) |line_num| {
        const before = output_opts.before_context;
        const after = output_opts.after_context;
        const range_start = if (line_num >= before) line_num - before else 0;
        const range_end = @min(line_num + after, lines.len - 1);

        // Try to merge with previous range
        if (ranges.items.len > 0) {
            var last = &ranges.items[ranges.items.len - 1];
            if (range_start <= last.end + 1) {
                // Ranges overlap or are adjacent - merge
                last.end = @max(last.end, range_end);
                continue;
            }
        }
        ranges.append(allocator, .{ .start = range_start, .end = range_end }) catch continue;
    }

    // Output ranges with separators
    var first_range = true;
    for (ranges.items) |range| {
        // Print separator between groups
        if (!first_range) {
            _ = std.posix.write(std.posix.STDOUT_FILENO, "--\n") catch {};
        }
        first_range = false;

        // Output lines in this range
        var line_idx = range.start;
        while (line_idx <= range.end) : (line_idx += 1) {
            const line = lines[line_idx];
            const is_match = match_lines.contains(line_idx);
            const separator: []const u8 = if (is_match) ":" else "-";

            if (filename_prefix) |prefix| {
                _ = std.posix.write(std.posix.STDOUT_FILENO, prefix) catch {};
                _ = std.posix.write(std.posix.STDOUT_FILENO, separator) catch {};
            }
            if (output_opts.line_numbers) {
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}{s}", .{ line_idx + 1, separator }) catch continue;
                _ = std.posix.write(std.posix.STDOUT_FILENO, num_str) catch {};
            }
            // Use color only for matching lines
            const use_color = output_opts.color_mode == .always and is_match;
            outputLineWithColor(text, line.start, line.end, matches, use_color);
            _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
        }
    }
}

fn processStdin(allocator: std.mem.Allocator, all_patterns: []const []const u8, options: SearchOptions, backend_mode: BackendMode, config: AutoSelectConfig, verbose: bool, output_opts: OutputOptions, filename_prefix: ?[]const u8) ProcessResult {
    // Read all stdin into a buffer
    var stdin_list: std.ArrayListUnmanaged(u8) = .{};
    defer stdin_list.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = std.posix.read(std.posix.STDIN_FILENO, &buf) catch |err| {
            if (err == error.WouldBlock) continue;
            std.debug.print("grep: error reading stdin: {}\n", .{err});
            return .{ .found = false, .had_error = true };
        };
        if (bytes_read == 0) break;
        stdin_list.appendSlice(allocator, buf[0..bytes_read]) catch {
            std.debug.print("grep: out of memory\n", .{});
            return .{ .found = false, .had_error = true };
        };
        if (stdin_list.items.len > gpu.MAX_GPU_BUFFER_SIZE) break;
    }
    const text = stdin_list.items;

    const file_size = text.len;

    // For auto mode, detect hardware capabilities
    var adjusted_config = config;
    if (backend_mode == .auto and !config.hardware_detected) {
        if (build_options.is_macos) {
            if (gpu.metal.MetalSearcher.init(allocator)) |searcher| {
                adjusted_config.applyHardwareCapabilities(searcher.capabilities);
                searcher.deinit();
            } else |_| {}
        } else {
            if (gpu.vulkan.VulkanSearcher.init(allocator)) |searcher| {
                adjusted_config.applyHardwareCapabilities(searcher.capabilities);
                searcher.deinit();
            } else |_| {}
        }
    }

    // Use first pattern for backend selection heuristics
    const first_pattern = if (all_patterns.len > 0) all_patterns[0] else "";

    const backend: gpu.Backend = switch (backend_mode) {
        .auto => selectOptimalBackend(first_pattern, options, file_size, adjusted_config),
        .gpu => if (build_options.is_macos) .metal else .vulkan,
        .cpu, .cpu_gnu => .cpu, // Both CPU backends use .cpu for dispatch
        .metal => .metal,
        .vulkan => .vulkan,
    };

    if (verbose) {
        std.debug.print("(standard input) ({d} bytes)\n", .{file_size});
        if (backend_mode == .cpu_gnu) {
            std.debug.print("Backend: cpu_gnu (GNU grep)\n", .{});
        } else {
            std.debug.print("Backend: {s}\n", .{@tagName(backend)});
        }
    }

    // For multiple patterns, always use CPU multi-pattern search
    var result = if (all_patterns.len > 1)
        searchMultiPattern(allocator, text, all_patterns, options, backend_mode) catch {
            return .{ .found = false, .had_error = true };
        }
    else switch (backend) {
        .metal => blk: {
            if (build_options.is_macos) {
                const searcher = gpu.metal.MetalSearcher.init(allocator) catch |err| {
                    if (verbose) std.debug.print("Metal init failed: {}, falling back to CPU\n", .{err});
                    break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                        return .{ .found = false, .had_error = true };
                    };
                };
                defer searcher.deinit();
                // Use GPU regex for regex patterns (including PCRE), literal search for fixed strings
                const use_regex = !options.fixed_string or options.perl;
                if (use_regex) {
                    break :blk searcher.searchRegex(text, first_pattern, options, allocator) catch |err| {
                        if (verbose) std.debug.print("Metal regex failed: {}, falling back to CPU\n", .{err});
                        break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                            return .{ .found = false, .had_error = true };
                        };
                    };
                } else {
                    break :blk searcher.search(text, first_pattern, options, allocator) catch |err| {
                        if (verbose) std.debug.print("Metal search failed: {}, falling back to CPU\n", .{err});
                        break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                            return .{ .found = false, .had_error = true };
                        };
                    };
                }
            } else {
                break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                    return .{ .found = false, .had_error = true };
                };
            }
        },
        .vulkan => blk: {
            const searcher = gpu.vulkan.VulkanSearcher.init(allocator) catch |err| {
                if (verbose) std.debug.print("Vulkan init failed: {}, falling back to CPU\n", .{err});
                break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                    return .{ .found = false, .had_error = true };
                };
            };
            defer searcher.deinit();
            // Use GPU regex for regex patterns (including PCRE), literal search for fixed strings
            const use_regex = !options.fixed_string or options.perl;
            if (use_regex) {
                break :blk searcher.searchRegex(text, first_pattern, options, allocator) catch |err| {
                    if (verbose) std.debug.print("Vulkan regex failed: {}, falling back to CPU\n", .{err});
                    break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                        return .{ .found = false, .had_error = true };
                    };
                };
            } else {
                break :blk searcher.search(text, first_pattern, options, allocator) catch |err| {
                    if (verbose) std.debug.print("Vulkan search failed: {}, falling back to CPU\n", .{err});
                    break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                        return .{ .found = false, .had_error = true };
                    };
                };
            }
        },
        .cpu => doSearch(text, first_pattern, options, allocator, backend_mode) catch {
            return .{ .found = false, .had_error = true };
        },
        .cuda, .opencl => doSearch(text, first_pattern, options, allocator, backend_mode) catch {
            return .{ .found = false, .had_error = true };
        },
    };
    defer result.deinit();

    const found = result.matches.len > 0;

    // For quiet mode, don't output anything
    if (output_opts.quiet_mode) {
        return .{ .found = found, .had_error = false };
    }

    // For files-without-match mode, only output filename if no matches
    if (output_opts.files_without_match) {
        if (!found) {
            if (filename_prefix) |prefix| {
                _ = std.posix.write(std.posix.STDOUT_FILENO, prefix) catch {};
                _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
            }
        }
        return .{ .found = found, .had_error = false };
    }

    // For files-with-matches mode, only output filename if matches found
    if (output_opts.files_with_matches) {
        if (found) {
            if (filename_prefix) |prefix| {
                _ = std.posix.write(std.posix.STDOUT_FILENO, prefix) catch {};
                _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
            }
        }
        return .{ .found = found, .had_error = false };
    }

    if (output_opts.count_only) {
        // Count unique lines with matches
        var line_count: u64 = 0;
        var last_line_start: u32 = std.math.maxInt(u32);
        for (result.matches) |match| {
            if (match.line_start != last_line_start) {
                last_line_start = match.line_start;
                line_count += 1;
            }
        }
        var count_buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}\n", .{line_count}) catch return .{ .found = found, .had_error = false };
        if (filename_prefix) |prefix| {
            _ = std.posix.write(std.posix.STDOUT_FILENO, prefix) catch {};
            _ = std.posix.write(std.posix.STDOUT_FILENO, ":") catch {};
        }
        _ = std.posix.write(std.posix.STDOUT_FILENO, count_str) catch {};
    } else if (output_opts.only_matching) {
        // Output only the matching text, not the whole line
        for (result.matches) |match| {
            if (filename_prefix) |prefix| {
                _ = std.posix.write(std.posix.STDOUT_FILENO, prefix) catch {};
                _ = std.posix.write(std.posix.STDOUT_FILENO, ":") catch {};
            }
            if (output_opts.line_numbers) {
                // Use GPU-computed line number if available, otherwise compute on CPU
                const line_num = if (match.line_num > 0) match.line_num else blk: {
                    var ln: u32 = 1;
                    var pos: usize = 0;
                    while (pos < match.line_start) : (pos += 1) {
                        if (text[pos] == '\n') ln += 1;
                    }
                    break :blk ln;
                };
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}:", .{line_num}) catch continue;
                _ = std.posix.write(std.posix.STDOUT_FILENO, num_str) catch {};
            }
            // Output the matched text (with color if enabled)
            const match_end = match.position + match.match_len;
            if (match_end <= text.len) {
                if (output_opts.color_mode == .always) {
                    _ = std.posix.write(std.posix.STDOUT_FILENO, COLOR_MATCH_START) catch {};
                }
                _ = std.posix.write(std.posix.STDOUT_FILENO, text[match.position..match_end]) catch {};
                if (output_opts.color_mode == .always) {
                    _ = std.posix.write(std.posix.STDOUT_FILENO, COLOR_RESET) catch {};
                }
            }
            _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
        }
    } else if (output_opts.before_context > 0 or output_opts.after_context > 0) {
        // Output with context lines
        outputWithContext(text, result.matches, output_opts, filename_prefix, allocator);
    } else {
        // Output matching lines
        var last_line_start: u32 = std.math.maxInt(u32);
        var current_line_num: u32 = 1;
        var last_line_counted: u32 = 0;

        for (result.matches) |match| {
            if (match.line_start != last_line_start) {
                last_line_start = match.line_start;

                var line_end = match.line_start;
                while (line_end < text.len and text[line_end] != '\n') line_end += 1;

                if (filename_prefix) |prefix| {
                    _ = std.posix.write(std.posix.STDOUT_FILENO, prefix) catch {};
                    _ = std.posix.write(std.posix.STDOUT_FILENO, ":") catch {};
                }
                if (output_opts.line_numbers) {
                    // Use GPU-computed line number if available, otherwise fall back to CPU computation
                    const line_num = if (match.line_num > 0) match.line_num else blk: {
                        // Fall back to counting newlines on CPU
                        var pos: usize = last_line_counted;
                        while (pos < match.line_start) : (pos += 1) {
                            if (text[pos] == '\n') current_line_num += 1;
                        }
                        last_line_counted = match.line_start;
                        break :blk current_line_num;
                    };
                    var num_buf: [16]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&num_buf, "{d}:", .{line_num}) catch continue;
                    _ = std.posix.write(std.posix.STDOUT_FILENO, num_str) catch {};
                }
                // Output line with color highlighting if enabled
                outputLineWithColor(text, match.line_start, line_end, result.matches, output_opts.color_mode == .always);
                _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
            }
        }
    }

    if (verbose) {
        std.debug.print("\nTotal matches: {d}\n", .{result.total_matches});
    }

    return .{ .found = found, .had_error = false };
}

/// Parse size string with optional K/M/G suffix
fn parseSize(str: []const u8) !usize {
    if (str.len == 0) return error.InvalidSize;

    var multiplier: usize = 1;
    var num_str = str;

    const last = str[str.len - 1];
    if (last == 'K' or last == 'k') {
        multiplier = 1024;
        num_str = str[0 .. str.len - 1];
    } else if (last == 'M' or last == 'm') {
        multiplier = 1024 * 1024;
        num_str = str[0 .. str.len - 1];
    } else if (last == 'G' or last == 'g') {
        multiplier = 1024 * 1024 * 1024;
        num_str = str[0 .. str.len - 1];
    }

    const value = try std.fmt.parseInt(usize, num_str, 10);
    return value * multiplier;
}

/// Selects the optimal backend based on workload characteristics.
///
/// Decision factors based on benchmarks (Apple M1 Max, clean GPU):
/// - GPU excels at: virtually all patterns when file size is appropriate
/// - CPU only wins: very small files (setup overhead), very large files (buffer limit)
///
/// Updated thresholds from smoke test results:
/// - Single char (len=1): GPU 10.2x faster
/// - Case-insensitive: GPU 8.4x faster
/// - Word boundary: GPU 6.9x faster
/// - Short patterns (len<=4): GPU 5.5x faster
/// - Medium patterns (len 5-7): GPU 3x faster
/// - Long patterns (len>=8): GPU 2.3-2.5x faster (still GPU wins!)
/// - Sparse matches (identifiers): GPU ~1.0x (tie)
fn selectOptimalBackend(pattern: []const u8, options: SearchOptions, file_size: usize, config: AutoSelectConfig) gpu.Backend {
    // Start with configurable bias
    var gpu_score: i32 = config.gpu_bias;

    // File size analysis - these are hard limits
    if (file_size < config.min_gpu_file_size) {
        // Too small - GPU setup overhead will dominate
        return .cpu;
    }
    if (file_size > config.max_gpu_file_size) {
        // Too large for GPU buffer
        return .cpu;
    }

    // Base GPU advantage: GPU is faster for most workloads
    gpu_score += 3;

    // Larger files benefit more from GPU parallelism
    if (file_size >= 1 * 1024 * 1024) gpu_score += 1; // >= 1MB
    if (file_size >= 4 * 1024 * 1024) gpu_score += 1; // >= 4MB

    // Pattern length analysis - GPU wins across all lengths now
    if (pattern.len == 1) {
        // Single char patterns: GPU 10.2x faster (high match density)
        gpu_score += 6;
    } else if (pattern.len <= config.short_pattern_len) {
        // Short patterns (2-4 chars): GPU 5.5x faster
        gpu_score += 4;
    } else if (pattern.len <= 7) {
        // Medium patterns (5-7 chars): GPU 3x faster
        gpu_score += 2;
    } else if (pattern.len >= config.long_pattern_len) {
        // Long patterns (8+ chars): GPU still 2.3x faster
        gpu_score += 1;
    }

    // Case-insensitive: GPU 8.4x faster (massive advantage)
    if (options.case_insensitive) {
        gpu_score += 6;
    }

    // Word boundary: GPU 6.9x faster
    if (options.word_boundary) {
        gpu_score += 5;
    }

    // Estimate match density from pattern characteristics
    // Patterns with common letters likely have more matches -> GPU wins more
    const common_letter_score = countCommonLetters(pattern);
    if (common_letter_score >= 3) {
        gpu_score += 2; // Likely high match density, GPU excels
    }

    // Sparse match patterns (identifiers with digits/underscores) - GPU ties CPU
    // Only penalize slightly since it's a tie, not a CPU win
    if (isLikelyRarePattern(pattern)) {
        gpu_score -= 3; // Reduce advantage but GPU can still be used
    }

    // Decision threshold - GPU is preferred by default now
    if (gpu_score >= 0) {
        // Prefer GPU - try Metal first on macOS, then Vulkan
        if (build_options.is_macos) {
            return .metal;
        }
        return .vulkan;
    }

    return .cpu;
}

/// Count common English letters in pattern (e, t, a, o, i, n, s, r, h, l)
fn countCommonLetters(pattern: []const u8) u32 {
    const common = "etaoinshrl";
    var count: u32 = 0;
    for (pattern) |c| {
        const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        for (common) |common_c| {
            if (lower == common_c) {
                count += 1;
                break;
            }
        }
    }
    return count;
}

/// Check if pattern is likely rare (all uppercase, contains digits, long unique string)
fn isLikelyRarePattern(pattern: []const u8) bool {
    if (pattern.len < 3) return false;

    var upper_count: usize = 0;
    var digit_count: usize = 0;
    var underscore_count: usize = 0;

    for (pattern) |c| {
        if (c >= 'A' and c <= 'Z') upper_count += 1;
        if (c >= '0' and c <= '9') digit_count += 1;
        if (c == '_') underscore_count += 1;
    }

    // All uppercase (like ERROR, WARNING) - moderate match frequency
    // But UNIQUE_MARKER_XYZ style patterns are rare
    if (upper_count == pattern.len and pattern.len >= 8) return true;

    // Contains digits or underscores - likely identifier/rare
    if (digit_count > 0 or underscore_count > 0) return true;

    return false;
}

/// Process a directory recursively
fn processDirectory(allocator: std.mem.Allocator, path: []const u8, all_patterns: []const []const u8, options: SearchOptions, backend_mode: BackendMode, config: AutoSelectConfig, verbose: bool, output_opts: OutputOptions, found_match: *bool, had_error: *bool, quiet_mode: bool) void {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        std.debug.print("grep: {s}: {}\n", .{ path, err });
        had_error.* = true;
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch |err| {
        std.debug.print("grep: {s}: {}\n", .{ path, err });
        had_error.* = true;
        return;
    }) |entry| {
        // Build full path
        const full_path = std.fs.path.join(allocator, &.{ path, entry.name }) catch {
            had_error.* = true;
            continue;
        };
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            // Skip hidden directories (starting with .)
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            // Recurse into subdirectory
            processDirectory(allocator, full_path, all_patterns, options, backend_mode, config, verbose, output_opts, found_match, had_error, quiet_mode);
        } else if (entry.kind == .file) {
            // Process file
            const result = processFile(allocator, full_path, all_patterns, options, backend_mode, config, verbose, output_opts);
            if (result.found) found_match.* = true;
            if (result.had_error) had_error.* = true;
        }
        // Skip symlinks and other special files

        // For quiet mode, exit early on first match
        if (quiet_mode and found_match.*) return;
    }
}

fn processFile(allocator: std.mem.Allocator, filepath: []const u8, all_patterns: []const []const u8, options: SearchOptions, backend_mode: BackendMode, config: AutoSelectConfig, verbose: bool, output_opts: OutputOptions) ProcessResult {
    const file = std.fs.cwd().openFile(filepath, .{}) catch |err| {
        std.debug.print("grep: {s}: {}\n", .{ filepath, err });
        return .{ .found = false, .had_error = true };
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        std.debug.print("grep: {s}: {}\n", .{ filepath, err });
        return .{ .found = false, .had_error = true };
    };
    const file_size = stat.size;

    // For auto mode, detect hardware capabilities to adjust thresholds
    var adjusted_config = config;
    if (backend_mode == .auto and !config.hardware_detected) {
        // Try to detect GPU capabilities
        if (build_options.is_macos) {
            if (gpu.metal.MetalSearcher.init(allocator)) |searcher| {
                adjusted_config.applyHardwareCapabilities(searcher.capabilities);
                if (verbose) {
                    const score = searcher.capabilities.performanceScore();
                    std.debug.print("Hardware: Score={d}, MinSize={d}KB, MaxSize={d}MB, Bias={d}\n", .{
                        score,
                        adjusted_config.min_gpu_file_size / 1024,
                        adjusted_config.max_gpu_file_size / (1024 * 1024),
                        adjusted_config.gpu_bias,
                    });
                }
                searcher.deinit();
            } else |_| {}
        } else {
            if (gpu.vulkan.VulkanSearcher.init(allocator)) |searcher| {
                adjusted_config.applyHardwareCapabilities(searcher.capabilities);
                if (verbose) {
                    const score = searcher.capabilities.performanceScore();
                    std.debug.print("Hardware: Score={d}, MinSize={d}KB, MaxSize={d}MB, Bias={d}\n", .{
                        score,
                        adjusted_config.min_gpu_file_size / 1024,
                        adjusted_config.max_gpu_file_size / (1024 * 1024),
                        adjusted_config.gpu_bias,
                    });
                }
                searcher.deinit();
            } else |_| {}
        }
    }

    // Use first pattern for backend selection heuristics
    const first_pattern = if (all_patterns.len > 0) all_patterns[0] else "";

    // Select backend using hardware-adjusted config
    const backend: gpu.Backend = switch (backend_mode) {
        .auto => selectOptimalBackend(first_pattern, options, file_size, adjusted_config),
        .gpu => if (build_options.is_macos) .metal else .vulkan,
        .cpu, .cpu_gnu => .cpu, // Both CPU backends use .cpu for dispatch
        .metal => .metal,
        .vulkan => .vulkan,
    };

    if (verbose) {
        std.debug.print("File: {s} ({d} bytes)\n", .{ filepath, file_size });
        if (backend_mode == .auto) {
            std.debug.print("Auto-selected backend: {s}\n", .{@tagName(backend)});
        } else if (backend_mode == .cpu_gnu) {
            std.debug.print("Backend: cpu_gnu (GNU grep)\n", .{});
        } else {
            std.debug.print("Backend: {s}\n", .{@tagName(backend)});
        }
    }

    const text = file.readToEndAlloc(allocator, gpu.MAX_GPU_BUFFER_SIZE) catch |err| {
        std.debug.print("grep: {s}: {}\n", .{ filepath, err });
        return .{ .found = false, .had_error = true };
    };
    defer allocator.free(text);

    // For multiple patterns, always use CPU multi-pattern search
    var result = if (all_patterns.len > 1)
        searchMultiPattern(allocator, text, all_patterns, options, backend_mode) catch {
            return .{ .found = false, .had_error = true };
        }
    else switch (backend) {
        .metal => blk: {
            if (build_options.is_macos) {
                const searcher = gpu.metal.MetalSearcher.init(allocator) catch |err| {
                    if (verbose) std.debug.print("Metal init failed: {}, falling back to CPU\n", .{err});
                    break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                        return .{ .found = false, .had_error = true };
                    };
                };
                defer searcher.deinit();
                // Use GPU regex for regex patterns (including PCRE), literal search for fixed strings
                const use_regex = !options.fixed_string or options.perl;
                if (use_regex) {
                    break :blk searcher.searchRegex(text, first_pattern, options, allocator) catch |err| {
                        if (verbose) std.debug.print("Metal regex failed: {}, falling back to CPU\n", .{err});
                        break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                            return .{ .found = false, .had_error = true };
                        };
                    };
                } else {
                    break :blk searcher.search(text, first_pattern, options, allocator) catch |err| {
                        if (verbose) std.debug.print("Metal search failed: {}, falling back to CPU\n", .{err});
                        break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                            return .{ .found = false, .had_error = true };
                        };
                    };
                }
            } else {
                if (verbose) std.debug.print("Metal not available, falling back to CPU\n", .{});
                break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                    return .{ .found = false, .had_error = true };
                };
            }
        },
        .vulkan => blk: {
            const searcher = gpu.vulkan.VulkanSearcher.init(allocator) catch |err| {
                if (verbose) std.debug.print("Vulkan init failed: {}, falling back to CPU\n", .{err});
                break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                    return .{ .found = false, .had_error = true };
                };
            };
            defer searcher.deinit();
            // Use GPU regex for regex patterns (including PCRE), literal search for fixed strings
            const use_regex = !options.fixed_string or options.perl;
            if (use_regex) {
                break :blk searcher.searchRegex(text, first_pattern, options, allocator) catch |err| {
                    if (verbose) std.debug.print("Vulkan regex failed: {}, falling back to CPU\n", .{err});
                    break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                        return .{ .found = false, .had_error = true };
                    };
                };
            } else {
                break :blk searcher.search(text, first_pattern, options, allocator) catch |err| {
                    if (verbose) std.debug.print("Vulkan search failed: {}, falling back to CPU\n", .{err});
                    break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                        return .{ .found = false, .had_error = true };
                    };
                };
            }
        },
        .cpu => doSearch(text, first_pattern, options, allocator, backend_mode) catch {
            return .{ .found = false, .had_error = true };
        },
        // CUDA and OpenCL not yet supported - fall back to CPU
        .cuda, .opencl => blk: {
            if (verbose) std.debug.print("{s} not supported, falling back to CPU\n", .{@tagName(backend)});
            break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                return .{ .found = false, .had_error = true };
            };
        },
    };
    defer result.deinit();

    const found = result.matches.len > 0;

    // For quiet mode, don't output anything
    if (output_opts.quiet_mode) {
        return .{ .found = found, .had_error = false };
    }

    // For files-without-match mode, only output filename if no matches
    if (output_opts.files_without_match) {
        if (!found) {
            _ = std.posix.write(std.posix.STDOUT_FILENO, filepath) catch {};
            _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
        }
        return .{ .found = found, .had_error = false };
    }

    // For files-with-matches mode, only output filename if matches found
    if (output_opts.files_with_matches) {
        if (found) {
            _ = std.posix.write(std.posix.STDOUT_FILENO, filepath) catch {};
            _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
        }
        return .{ .found = found, .had_error = false };
    }

    if (output_opts.count_only) {
        // Count unique lines with matches
        var line_count: u64 = 0;
        var last_line_start: u32 = std.math.maxInt(u32);
        for (result.matches) |match| {
            if (match.line_start != last_line_start) {
                last_line_start = match.line_start;
                line_count += 1;
            }
        }
        var count_buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}\n", .{line_count}) catch return .{ .found = found, .had_error = false };
        if (output_opts.show_filename) {
            _ = std.posix.write(std.posix.STDOUT_FILENO, filepath) catch {};
            _ = std.posix.write(std.posix.STDOUT_FILENO, ":") catch {};
        }
        _ = std.posix.write(std.posix.STDOUT_FILENO, count_str) catch {};
    } else if (output_opts.only_matching) {
        // Output only the matching text, not the whole line
        for (result.matches) |match| {
            if (output_opts.show_filename) {
                _ = std.posix.write(std.posix.STDOUT_FILENO, filepath) catch {};
                _ = std.posix.write(std.posix.STDOUT_FILENO, ":") catch {};
            }
            if (output_opts.line_numbers) {
                // Use GPU-computed line number if available, otherwise compute on CPU
                const line_num = if (match.line_num > 0) match.line_num else blk: {
                    var ln: u32 = 1;
                    var pos: usize = 0;
                    while (pos < match.line_start) : (pos += 1) {
                        if (text[pos] == '\n') ln += 1;
                    }
                    break :blk ln;
                };
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}:", .{line_num}) catch continue;
                _ = std.posix.write(std.posix.STDOUT_FILENO, num_str) catch {};
            }
            // Output the matched text (with color if enabled)
            const match_end = match.position + match.match_len;
            if (match_end <= text.len) {
                if (output_opts.color_mode == .always) {
                    _ = std.posix.write(std.posix.STDOUT_FILENO, COLOR_MATCH_START) catch {};
                }
                _ = std.posix.write(std.posix.STDOUT_FILENO, text[match.position..match_end]) catch {};
                if (output_opts.color_mode == .always) {
                    _ = std.posix.write(std.posix.STDOUT_FILENO, COLOR_RESET) catch {};
                }
            }
            _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
        }
    } else if (output_opts.before_context > 0 or output_opts.after_context > 0) {
        // Output with context lines
        const filename_prefix: ?[]const u8 = if (output_opts.show_filename) filepath else null;
        outputWithContext(text, result.matches, output_opts, filename_prefix, allocator);
    } else {
        // Output matching lines
        var last_line_start: u32 = std.math.maxInt(u32);
        var current_line_num: u32 = 1;
        var last_line_counted: u32 = 0;

        for (result.matches) |match| {
            if (match.line_start != last_line_start) {
                last_line_start = match.line_start;

                // Find line end
                var line_end = match.line_start;
                while (line_end < text.len and text[line_end] != '\n') line_end += 1;

                if (output_opts.show_filename) {
                    _ = std.posix.write(std.posix.STDOUT_FILENO, filepath) catch {};
                    _ = std.posix.write(std.posix.STDOUT_FILENO, ":") catch {};
                }
                if (output_opts.line_numbers) {
                    // Use GPU-computed line number if available, otherwise fall back to CPU computation
                    const line_num = if (match.line_num > 0) match.line_num else blk: {
                        // Fall back to counting newlines on CPU
                        var pos: usize = last_line_counted;
                        while (pos < match.line_start) : (pos += 1) {
                            if (text[pos] == '\n') current_line_num += 1;
                        }
                        last_line_counted = match.line_start;
                        break :blk current_line_num;
                    };
                    var num_buf: [16]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&num_buf, "{d}:", .{line_num}) catch continue;
                    _ = std.posix.write(std.posix.STDOUT_FILENO, num_str) catch {};
                }
                // Output line with color highlighting if enabled
                outputLineWithColor(text, match.line_start, line_end, result.matches, output_opts.color_mode == .always);
                _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
            }
        }
    }

    if (verbose) {
        std.debug.print("\nTotal matches: {d}\n\n", .{result.total_matches});
    }

    return .{ .found = found, .had_error = false };
}

fn printUsage() void {
    const help_text =
        \\Usage: grep [OPTION]... PATTERN [FILE]...
        \\Search for PATTERN in each FILE.
        \\If no FILE is given, read standard input.
        \\Example: grep -i 'hello world' menu.h main.c
        \\
        \\Pattern selection and interpretation:
        \\  -e, --regexp=PATTERN      use PATTERN for matching
        \\  -E, --extended-regexp     PATTERN is an extended regular expression (ERE)
        \\  -G, --basic-regexp        PATTERN is a basic regular expression (BRE)
        \\  -P, --perl-regexp         PATTERN is a Perl-compatible regular expression (PCRE)
        \\  -F, --fixed-strings       PATTERN is a literal string (default)
        \\  -i, --ignore-case         ignore case distinctions in patterns and data
        \\  -w, --word-regexp         match only whole words
        \\  -v, --invert-match        select non-matching lines
        \\
        \\Output control:
        \\  -A NUM, --after-context=NUM   print NUM lines of trailing context
        \\  -B NUM, --before-context=NUM  print NUM lines of leading context
        \\  -C NUM, --context=NUM         print NUM lines of output context
        \\  -c, --count               print only a count of matching lines per FILE
        \\      --color[=WHEN]        use markers to highlight matching strings
        \\                            WHEN is 'always', 'never', or 'auto'
        \\  -l, --files-with-matches  print only names of FILEs with matches
        \\  -L, --files-without-match print only names of FILEs without matches
        \\  -n, --line-number         print line number with output lines
        \\  -o, --only-matching       print only the matched (non-empty) parts
        \\  -q, --quiet, --silent     suppress all normal output
        \\  -r, -R, --recursive       search directories recursively
        \\  -V, --verbose             print backend and timing information
        \\
        \\Backend selection:
        \\  --auto                    auto-select optimal backend (default)
        \\  --cpu, --cpu-optimized    force optimized CPU backend (SIMD)
        \\  --gnu                     force GNU grep backend (reference)
        \\  --gpu                     force GPU (Metal on macOS, Vulkan on Linux)
        \\  --metal                   force Metal backend (macOS only)
        \\  --vulkan                  force Vulkan backend
        \\
        \\GPU tuning:
        \\  --prefer-gpu              bias auto-selection toward GPU
        \\  --prefer-cpu              bias auto-selection toward CPU
        \\  --gpu-bias=NUM            fine-tune GPU preference (-10 to +10)
        \\  --min-gpu-size=SIZE       minimum input size for GPU (e.g., 128K)
        \\  --max-gpu-size=SIZE       maximum input size for GPU (e.g., 16M)
        \\
        \\Miscellaneous:
        \\  -h, --help                display this help text and exit
        \\      --version             display version information and exit
        \\
        \\When FILE is '-', read standard input. With no FILE, read standard input.
        \\Exit status is 0 if any line is selected, 1 otherwise;
        \\if any error occurs, the exit status is 2.
        \\
        \\GPU Performance (typical speedups vs CPU):
        \\  Single char patterns:     ~10x
        \\  Case-insensitive (-i):    ~8x
        \\  Word boundary (-w):       ~7x
        \\  Short patterns (2-4):     ~5x
        \\  Long patterns (8+):       ~2x
        \\
        \\Examples:
        \\  grep 'error' /var/log/syslog      Search for 'error' in syslog
        \\  grep -i 'warning' *.log           Case-insensitive search
        \\  grep -E 'error|warning' *.log     Extended regex (ERE)
        \\  grep -G 'ab\+c' file.txt          Basic regex (BRE)
        \\  grep -P '(?<=@)\w+' file.txt      Perl regex with lookbehind
        \\  cat file.txt | grep 'pattern'     Read from stdin
        \\  grep --gpu 'needle' haystack.txt  Force GPU acceleration
        \\
    ;
    _ = std.posix.write(std.posix.STDOUT_FILENO, help_text) catch {};
}

test "cpu search basic" {
    const allocator = std.testing.allocator;
    const text = "hello world\nhello there\nworld hello\n";
    const pattern = "hello";
    var result = try cpu.search(text, pattern, .{}, allocator);
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "backend selection - short pattern" {
    // Short patterns should prefer GPU
    const backend = selectOptimalBackend("the", .{}, 1024 * 1024, .{});
    try std.testing.expect(backend != .cpu);
}

test "backend selection - long pattern" {
    // Long patterns still prefer GPU (benchmarks show GPU is 2.3x faster even for long patterns)
    // Only extreme CPU bias or file size limits will force CPU
    const backend = selectOptimalBackend("implementation", .{}, 1024 * 1024, .{});
    try std.testing.expect(backend != .cpu); // GPU is preferred
}

test "backend selection - case insensitive" {
    // Case insensitive should prefer GPU even with medium pattern
    const backend = selectOptimalBackend("error", .{ .case_insensitive = true }, 1024 * 1024, .{});
    try std.testing.expect(backend != .cpu);
}

test "backend selection - small file" {
    // Small files should always use CPU
    const backend = selectOptimalBackend("the", .{}, 64 * 1024, .{});
    try std.testing.expectEqual(gpu.Backend.cpu, backend);
}

test "backend selection - gpu bias" {
    // With strong GPU bias, even long patterns should use GPU
    const backend = selectOptimalBackend("implementation", .{}, 1024 * 1024, .{ .gpu_bias = 10 });
    try std.testing.expect(backend != .cpu);
}

test "backend selection - cpu bias" {
    // With very strong CPU bias, even short patterns should use CPU
    // Need -15 to overcome: base(3) + pattern(4) + file_size(1) + common_letters(2) = +10
    const backend = selectOptimalBackend("the", .{}, 1024 * 1024, .{ .gpu_bias = -15 });
    try std.testing.expectEqual(gpu.Backend.cpu, backend);
}

test "parse size" {
    try std.testing.expectEqual(@as(usize, 1024), try parseSize("1K"));
    try std.testing.expectEqual(@as(usize, 1024), try parseSize("1k"));
    try std.testing.expectEqual(@as(usize, 1048576), try parseSize("1M"));
    try std.testing.expectEqual(@as(usize, 1073741824), try parseSize("1G"));
    try std.testing.expectEqual(@as(usize, 500), try parseSize("500"));
    try std.testing.expectEqual(@as(usize, 128 * 1024), try parseSize("128K"));
}
