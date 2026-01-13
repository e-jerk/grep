const std = @import("std");
const mtl = @import("zig-metal");
const mod = @import("mod.zig");

const SearchConfig = mod.SearchConfig;
const MatchResult = mod.MatchResult;
const SearchOptions = mod.SearchOptions;
const SearchResult = mod.SearchResult;
const EMBEDDED_METAL_SHADER = mod.EMBEDDED_METAL_SHADER;
const MAX_RESULTS = mod.MAX_RESULTS;
const MAX_GPU_BUFFER_SIZE = mod.MAX_GPU_BUFFER_SIZE;

// Access low-level Metal device methods for memory queries
const DeviceMixin = mtl.gen.MTLDeviceProtocolMixin(mtl.gen.MTLDevice, "MTLDevice");

pub const MetalSearcher = struct {
    device: mtl.MTLDevice,
    command_queue: mtl.MTLCommandQueue,
    bmh_pipeline: mtl.MTLComputePipelineState,
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
            .allocator = allocator,
            .threads_per_group = threads_to_use,
            .capabilities = capabilities,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
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
};
