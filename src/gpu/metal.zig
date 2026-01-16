const std = @import("std");
const mtl = @import("zig-metal");
const mod = @import("mod.zig");
const regex_compiler = @import("regex_compiler.zig");
const regex_lib = @import("regex");

const SearchConfig = mod.SearchConfig;
const MatchResult = mod.MatchResult;
const SearchOptions = mod.SearchOptions;
const SearchResult = mod.SearchResult;
const RegexSearchConfig = mod.RegexSearchConfig;
const RegexState = mod.RegexState;
const RegexMatchResult = mod.RegexMatchResult;
const EMBEDDED_METAL_SHADER = mod.EMBEDDED_METAL_SHADER;
const MAX_RESULTS = mod.MAX_RESULTS;
const MAX_GPU_BUFFER_SIZE = mod.MAX_GPU_BUFFER_SIZE;

// Access low-level Metal device methods for memory queries
const DeviceMixin = mtl.gen.MTLDeviceProtocolMixin(mtl.gen.MTLDevice, "MTLDevice");

pub const MetalSearcher = struct {
    device: mtl.MTLDevice,
    command_queue: mtl.MTLCommandQueue,
    bmh_pipeline: mtl.MTLComputePipelineState,
    regex_pipeline: mtl.MTLComputePipelineState,
    allocator: std.mem.Allocator,
    threads_per_group: usize,
    capabilities: mod.GpuCapabilities,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const device = mtl.createSystemDefaultDevice() orelse return error.NoMetalDevice;
        errdefer device.release();

        const command_queue = device.newCommandQueue() orelse return error.NoCommandQueue;
        errdefer command_queue.release();

        const source_ns = mtl.NSString.stringWithUTF8String(EMBEDDED_METAL_SHADER.ptr);
        var library = device.newLibraryWithSourceOptionsError(source_ns, null, null) orelse {
            return error.ShaderCompileFailed;
        };
        defer library.release();

        const func_name = mtl.NSString.stringWithUTF8String("bmh_search");
        var func = library.newFunctionWithName(func_name) orelse {
            return error.FunctionNotFound;
        };
        defer func.release();

        var bmh_pipeline = device.newComputePipelineStateWithFunctionError(func, null) orelse {
            return error.PipelineCreationFailed;
        };

        // Create regex search pipeline
        const regex_func_name = mtl.NSString.stringWithUTF8String("regex_search_lines");
        var regex_func = library.newFunctionWithName(regex_func_name) orelse {
            return error.FunctionNotFound;
        };
        defer regex_func.release();

        const regex_pipeline = device.newComputePipelineStateWithFunctionError(regex_func, null) orelse {
            return error.PipelineCreationFailed;
        };

        // Query actual hardware attributes from Metal API
        const max_threads = bmh_pipeline.maxTotalThreadsPerThreadgroup();
        const threads_to_use: usize = @min(256, max_threads);

        // Query actual memory from Metal API (deterministic, not inferred)
        const recommended_memory = DeviceMixin.recommendedMaxWorkingSetSize(device.ptr);
        const max_buffer_len = DeviceMixin.maxBufferLength(device.ptr);
        const has_unified = DeviceMixin.hasUnifiedMemory(device.ptr) != 0;

        // Apple Silicon with unified memory is high-performance
        const is_high_perf = has_unified and max_threads >= 1024;

        // Build capabilities from actual hardware attributes
        const capabilities = mod.GpuCapabilities{
            .max_threads_per_group = @intCast(max_threads),
            .max_buffer_size = @min(max_buffer_len, MAX_GPU_BUFFER_SIZE),
            .recommended_memory = recommended_memory,
            .is_discrete = is_high_perf,
            .device_type = if (is_high_perf) .discrete else .integrated,
        };

        const self = try allocator.create(Self);
        self.* = Self{
            .device = device,
            .command_queue = command_queue,
            .bmh_pipeline = bmh_pipeline,
            .regex_pipeline = regex_pipeline,
            .allocator = allocator,
            .threads_per_group = threads_to_use,
            .capabilities = capabilities,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.regex_pipeline.release();
        self.bmh_pipeline.release();
        self.command_queue.release();
        self.device.release();
        self.allocator.destroy(self);
    }

    pub fn search(self: *Self, text: []const u8, pattern: []const u8, options: SearchOptions, allocator: std.mem.Allocator) !SearchResult {
        if (pattern.len == 0 or pattern.len > mod.MAX_PATTERN_LEN) {
            return error.InvalidPatternLength;
        }
        if (text.len > MAX_GPU_BUFFER_SIZE) {
            return error.TextTooLarge;
        }

        // Create text buffer and copy data
        var text_buffer = self.device.newBufferWithLengthOptions(text.len, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer text_buffer.release();
        if (text_buffer.contents()) |ptr| {
            const text_ptr: [*]u8 = @ptrCast(ptr);
            @memcpy(text_ptr[0..text.len], text);
        }

        // Create pattern buffer and copy data
        var pattern_buffer = self.device.newBufferWithLengthOptions(pattern.len, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer pattern_buffer.release();
        if (pattern_buffer.contents()) |ptr| {
            const pattern_ptr: [*]u8 = @ptrCast(ptr);
            @memcpy(pattern_ptr[0..pattern.len], pattern);
        }

        // Create skip table buffer and copy data
        const skip_table = mod.buildSkipTable(pattern, options.case_insensitive);
        var skip_buffer = self.device.newBufferWithLengthOptions(256, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer skip_buffer.release();
        if (skip_buffer.contents()) |ptr| {
            const skip_ptr: [*]u8 = @ptrCast(ptr);
            @memcpy(skip_ptr[0..256], &skip_table);
        }

        // Create config buffer and copy data
        const config = SearchConfig{
            .text_len = @intCast(text.len),
            .pattern_len = @intCast(pattern.len),
            .num_patterns = 1,
            .flags = options.toFlags(),
            .positions_per_thread = 1,
        };
        var config_buffer = self.device.newBufferWithLengthOptions(@sizeOf(SearchConfig), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer config_buffer.release();
        if (config_buffer.contents()) |ptr| {
            const config_ptr: *SearchConfig = @ptrCast(@alignCast(ptr));
            config_ptr.* = config;
        }

        // Create results buffer
        const results_size = @sizeOf(MatchResult) * MAX_RESULTS;
        var results_buffer = self.device.newBufferWithLengthOptions(results_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer results_buffer.release();

        // Create counters buffer and initialize
        var counters_buffer = self.device.newBufferWithLengthOptions(8, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer counters_buffer.release();

        const counters_ptr: *[2]u32 = @ptrCast(@alignCast(counters_buffer.contents()));
        counters_ptr[0] = 0;
        counters_ptr[1] = 0;

        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;

        encoder.setComputePipelineState(self.bmh_pipeline);
        encoder.setBufferOffsetAtIndex(text_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(pattern_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(skip_buffer, 0, 2);
        encoder.setBufferOffsetAtIndex(config_buffer, 0, 3);
        encoder.setBufferOffsetAtIndex(results_buffer, 0, 4);
        encoder.setBufferOffsetAtIndex(counters_buffer, 0, 5);
        encoder.setBufferOffsetAtIndex(counters_buffer, 4, 6);

        const num_threads = @max(1, text.len / 64);
        const grid_size = mtl.MTLSize{ .width = num_threads, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = self.threads_per_group, .height = 1, .depth = 1 };

        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        const result_count = counters_ptr[0];
        const total_matches = counters_ptr[1];

        const num_to_copy = @min(result_count, MAX_RESULTS);
        const matches = try allocator.alloc(MatchResult, num_to_copy);

        if (num_to_copy > 0) {
            const results_ptr: [*]MatchResult = @ptrCast(@alignCast(results_buffer.contents()));
            @memcpy(matches, results_ptr[0..num_to_copy]);
        }

        return SearchResult{ .matches = matches, .total_matches = total_matches, .allocator = allocator };
    }

    /// GPU-accelerated regex pattern search
    pub fn searchRegex(self: *Self, text: []const u8, pattern: []const u8, options: SearchOptions, allocator: std.mem.Allocator) !SearchResult {
        if (text.len > MAX_GPU_BUFFER_SIZE) return error.TextTooLarge;

        // Compile regex pattern for GPU
        var gpu_regex = try regex_compiler.compileForGpu(pattern, .{
            .case_insensitive = options.case_insensitive,
        }, allocator);
        defer gpu_regex.deinit();

        // Find line boundaries
        var line_offsets: std.ArrayListUnmanaged(u32) = .{};
        defer line_offsets.deinit(allocator);
        var line_lengths: std.ArrayListUnmanaged(u32) = .{};
        defer line_lengths.deinit(allocator);

        var line_start: usize = 0;
        for (text, 0..) |c, i| {
            if (c == '\n') {
                try line_offsets.append(allocator, @intCast(line_start));
                try line_lengths.append(allocator, @intCast(i - line_start));
                line_start = i + 1;
            }
        }
        if (line_start < text.len) {
            try line_offsets.append(allocator, @intCast(line_start));
            try line_lengths.append(allocator, @intCast(text.len - line_start));
        }

        const num_lines = line_offsets.items.len;
        if (num_lines == 0) {
            return SearchResult{
                .matches = &[_]MatchResult{},
                .total_matches = 0,
                .allocator = allocator,
            };
        }

        // Create text buffer
        var text_buffer = self.device.newBufferWithLengthOptions(text.len, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer text_buffer.release();
        if (text_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..text.len], text);
        }

        // Create states buffer
        const states_size = gpu_regex.states.len * @sizeOf(RegexState);
        var states_buffer = self.device.newBufferWithLengthOptions(@max(states_size, 1), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer states_buffer.release();
        if (states_size > 0) {
            if (states_buffer.contents()) |ptr| {
                const dst: [*]RegexState = @ptrCast(@alignCast(ptr));
                @memcpy(dst[0..gpu_regex.states.len], gpu_regex.states);
            }
        }

        // Create bitmaps buffer
        const bitmaps_size = gpu_regex.bitmaps.len * @sizeOf(u32);
        var bitmaps_buffer = self.device.newBufferWithLengthOptions(@max(bitmaps_size, 4), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer bitmaps_buffer.release();
        if (bitmaps_size > 0) {
            if (bitmaps_buffer.contents()) |ptr| {
                const dst: [*]u32 = @ptrCast(@alignCast(ptr));
                @memcpy(dst[0..gpu_regex.bitmaps.len], gpu_regex.bitmaps);
            }
        }

        // Create config buffer
        const config = RegexSearchConfig{
            .text_len = @intCast(text.len),
            .num_states = gpu_regex.header.num_states,
            .start_state = gpu_regex.header.start_state,
            .header_flags = gpu_regex.header.flags,
            .num_bitmaps = @intCast(gpu_regex.bitmaps.len / 8),
            .max_results = MAX_RESULTS,
            .flags = options.toFlags(),
        };
        var config_buffer = self.device.newBufferWithLengthOptions(@sizeOf(RegexSearchConfig), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer config_buffer.release();
        if (config_buffer.contents()) |ptr| {
            @as(*RegexSearchConfig, @ptrCast(@alignCast(ptr))).* = config;
        }

        // Create header buffer
        var header_buffer = self.device.newBufferWithLengthOptions(@sizeOf(mod.RegexHeader), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer header_buffer.release();
        if (header_buffer.contents()) |ptr| {
            @as(*mod.RegexHeader, @ptrCast(@alignCast(ptr))).* = gpu_regex.header;
        }

        // Create results buffer
        const results_size = @sizeOf(RegexMatchResult) * MAX_RESULTS;
        var results_buffer = self.device.newBufferWithLengthOptions(results_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer results_buffer.release();

        // Create counters buffer
        var counters_buffer = self.device.newBufferWithLengthOptions(8, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer counters_buffer.release();
        const counters_ptr: *[2]u32 = @ptrCast(@alignCast(counters_buffer.contents()));
        counters_ptr[0] = 0;
        counters_ptr[1] = 0;

        // Create line offsets/lengths buffers
        var line_offsets_buffer = self.device.newBufferWithLengthOptions(line_offsets.items.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer line_offsets_buffer.release();
        if (line_offsets_buffer.contents()) |ptr| {
            @memcpy(@as([*]u32, @ptrCast(@alignCast(ptr)))[0..line_offsets.items.len], line_offsets.items);
        }

        var line_lengths_buffer = self.device.newBufferWithLengthOptions(line_lengths.items.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer line_lengths_buffer.release();
        if (line_lengths_buffer.contents()) |ptr| {
            @memcpy(@as([*]u32, @ptrCast(@alignCast(ptr)))[0..line_lengths.items.len], line_lengths.items);
        }

        // Execute regex matching
        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;

        encoder.setComputePipelineState(self.regex_pipeline);
        encoder.setBufferOffsetAtIndex(text_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(states_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(bitmaps_buffer, 0, 2);
        encoder.setBufferOffsetAtIndex(config_buffer, 0, 3);
        encoder.setBufferOffsetAtIndex(header_buffer, 0, 4);
        encoder.setBufferOffsetAtIndex(results_buffer, 0, 5);
        encoder.setBufferOffsetAtIndex(counters_buffer, 0, 6);
        encoder.setBufferOffsetAtIndex(counters_buffer, 4, 7);
        encoder.setBufferOffsetAtIndex(line_offsets_buffer, 0, 8);
        encoder.setBufferOffsetAtIndex(line_lengths_buffer, 0, 9);

        const grid_size = mtl.MTLSize{ .width = num_lines, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = @min(self.threads_per_group, num_lines), .height = 1, .depth = 1 };

        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        const result_count = counters_ptr[0];
        const total_matches = counters_ptr[1];

        // Copy results and convert RegexMatchResult to MatchResult
        const num_to_copy = @min(result_count, MAX_RESULTS);
        const matches = try allocator.alloc(MatchResult, num_to_copy);

        if (num_to_copy > 0) {
            const regex_results_ptr: [*]RegexMatchResult = @ptrCast(@alignCast(results_buffer.contents()));
            for (0..num_to_copy) |i| {
                const r = regex_results_ptr[i];
                matches[i] = MatchResult{
                    .position = r.start,
                    .pattern_idx = 0,
                    .match_len = r.end - r.start,
                    .line_start = r.line_start,
                };
            }
        }

        return SearchResult{
            .matches = matches,
            .total_matches = total_matches,
            .allocator = allocator,
        };
    }
};
