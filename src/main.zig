const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");
const cpu_gnu = @import("cpu_gnu");

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
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            count_only = true;
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

    // Process each file or stdin
    if (read_stdin) {
        const result = processStdin(allocator, patterns.items, options, backend_mode, config, verbose, count_only, null);
        if (result.found) found_match = true;
        if (result.had_error) had_error = true;
    } else {
        for (files.items) |filepath| {
            // Handle "-" as stdin
            if (std.mem.eql(u8, filepath, "-")) {
                const result = processStdin(allocator, patterns.items, options, backend_mode, config, verbose, count_only, if (show_filename) "(standard input)" else null);
                if (result.found) found_match = true;
                if (result.had_error) had_error = true;
            } else {
                const result = processFile(allocator, filepath, patterns.items, options, backend_mode, config, verbose, count_only, show_filename);
                if (result.found) found_match = true;
                if (result.had_error) had_error = true;
            }
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

/// Choose appropriate search function based on options and backend
fn doSearch(text: []const u8, pattern: []const u8, options: SearchOptions, allocator: std.mem.Allocator, backend_mode: BackendMode) !gpu.SearchResult {
    const use_gnu = backend_mode == .cpu_gnu;

    if (options.fixed_string) {
        return if (use_gnu)
            cpu_gnu.search(text, pattern, options, allocator)
        else
            cpu.search(text, pattern, options, allocator);
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

fn processStdin(allocator: std.mem.Allocator, all_patterns: []const []const u8, options: SearchOptions, backend_mode: BackendMode, config: AutoSelectConfig, verbose: bool, count_only: bool, filename_prefix: ?[]const u8) ProcessResult {
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
                break :blk searcher.search(text, first_pattern, options, allocator) catch |err| {
                    if (verbose) std.debug.print("Metal search failed: {}, falling back to CPU\n", .{err});
                    break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                        return .{ .found = false, .had_error = true };
                    };
                };
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
            break :blk searcher.search(text, first_pattern, options, allocator) catch |err| {
                if (verbose) std.debug.print("Vulkan search failed: {}, falling back to CPU\n", .{err});
                break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                    return .{ .found = false, .had_error = true };
                };
            };
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

    if (count_only) {
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
    } else {
        // Output matching lines
        var last_line_start: u32 = std.math.maxInt(u32);

        for (result.matches) |match| {
            if (match.line_start != last_line_start) {
                last_line_start = match.line_start;

                var line_end = match.line_start;
                while (line_end < text.len and text[line_end] != '\n') line_end += 1;

                if (filename_prefix) |prefix| {
                    _ = std.posix.write(std.posix.STDOUT_FILENO, prefix) catch {};
                    _ = std.posix.write(std.posix.STDOUT_FILENO, ":") catch {};
                }
                _ = std.posix.write(std.posix.STDOUT_FILENO, text[match.line_start..line_end]) catch {};
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

fn processFile(allocator: std.mem.Allocator, filepath: []const u8, all_patterns: []const []const u8, options: SearchOptions, backend_mode: BackendMode, config: AutoSelectConfig, verbose: bool, count_only: bool, show_filename: bool) ProcessResult {
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
                break :blk searcher.search(text, first_pattern, options, allocator) catch |err| {
                    if (verbose) std.debug.print("Metal search failed: {}, falling back to CPU\n", .{err});
                    break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                        return .{ .found = false, .had_error = true };
                    };
                };
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
            break :blk searcher.search(text, first_pattern, options, allocator) catch |err| {
                if (verbose) std.debug.print("Vulkan search failed: {}, falling back to CPU\n", .{err});
                break :blk doSearch(text, first_pattern, options, allocator, backend_mode) catch {
                    return .{ .found = false, .had_error = true };
                };
            };
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

    if (count_only) {
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
        if (show_filename) {
            _ = std.posix.write(std.posix.STDOUT_FILENO, filepath) catch {};
            _ = std.posix.write(std.posix.STDOUT_FILENO, ":") catch {};
        }
        _ = std.posix.write(std.posix.STDOUT_FILENO, count_str) catch {};
    } else {
        // Output matching lines
        var last_line_start: u32 = std.math.maxInt(u32);

        for (result.matches) |match| {
            if (match.line_start != last_line_start) {
                last_line_start = match.line_start;

                // Find line end
                var line_end = match.line_start;
                while (line_end < text.len and text[line_end] != '\n') line_end += 1;

                if (show_filename) {
                    _ = std.posix.write(std.posix.STDOUT_FILENO, filepath) catch {};
                    _ = std.posix.write(std.posix.STDOUT_FILENO, ":") catch {};
                }
                _ = std.posix.write(std.posix.STDOUT_FILENO, text[match.line_start..line_end]) catch {};
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
        \\  -F, --fixed-strings       PATTERN is a literal string (default)
        \\  -i, --ignore-case         ignore case distinctions in patterns and data
        \\  -w, --word-regexp         match only whole words
        \\  -v, --invert-match        select non-matching lines
        \\
        \\Output control:
        \\  -c, --count               print only a count of matching lines per FILE
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
