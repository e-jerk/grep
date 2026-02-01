const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const spirv = @import("spirv");
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
const MAX_RESULTS = mod.MAX_RESULTS;
const MAX_GPU_BUFFER_SIZE = mod.MAX_GPU_BUFFER_SIZE;

const VulkanLoader = struct {
    lib: std.DynLib,
    getProcAddr: vk.PfnGetInstanceProcAddr,

    fn load() !VulkanLoader {
        const lib_names = switch (builtin.os.tag) {
            .macos => &[_][]const u8{
                "libMoltenVK.dylib",
                "libvulkan.1.dylib",
                "libvulkan.dylib",
                // Homebrew paths (Apple Silicon and Intel)
                "/opt/homebrew/lib/libMoltenVK.dylib",
                "/opt/homebrew/lib/libvulkan.1.dylib",
                "/usr/local/lib/libMoltenVK.dylib",
                "/usr/local/lib/libvulkan.1.dylib",
            },
            .linux => &[_][]const u8{ "libvulkan.so.1", "libvulkan.so" },
            .windows => &[_][]const u8{"vulkan-1.dll"},
            else => return error.UnsupportedPlatform,
        };

        for (lib_names) |name| {
            var lib = std.DynLib.open(name) catch continue;
            if (lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr")) |proc| {
                return .{ .lib = lib, .getProcAddr = proc };
            }
            lib.close();
        }
        return error.VulkanNotFound;
    }
};

var vulkan_loader: ?VulkanLoader = null;

fn getVkGetInstanceProcAddr() !vk.PfnGetInstanceProcAddr {
    if (vulkan_loader) |loader| return loader.getProcAddr;
    vulkan_loader = try VulkanLoader.load();
    return vulkan_loader.?.getProcAddr;
}

pub const VulkanSearcher = struct {
    instance: vk.Instance,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    compute_queue: vk.Queue,
    compute_queue_family: u32,
    descriptor_set_layout: vk.DescriptorSetLayout,
    pipeline_layout: vk.PipelineLayout,
    compute_pipeline: vk.Pipeline,
    // Regex pipeline components
    regex_descriptor_set_layout: vk.DescriptorSetLayout,
    regex_pipeline_layout: vk.PipelineLayout,
    regex_compute_pipeline: vk.Pipeline,
    regex_shader_module: vk.ShaderModule,
    descriptor_pool: vk.DescriptorPool,
    shader_module: vk.ShaderModule,
    command_pool: vk.CommandPool,
    fence: vk.Fence,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    allocator: std.mem.Allocator,
    vkb: vk.BaseWrapper,
    vki: vk.InstanceWrapper,
    vkd: vk.DeviceWrapper,
    capabilities: mod.GpuCapabilities,

    const Self = @This();
    const BufferAllocation = struct { buffer: vk.Buffer, memory: vk.DeviceMemory, size: vk.DeviceSize, mapped: ?*anyopaque };

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const vkb = vk.BaseWrapper.load(try getVkGetInstanceProcAddr());

        const app_info = vk.ApplicationInfo{
            .p_application_name = "grep",
            .application_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
            .p_engine_name = "grep",
            .engine_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_2),
        };

        const instance = vkb.createInstance(&.{ .p_application_info = &app_info, .enabled_layer_count = 0, .pp_enabled_layer_names = null, .enabled_extension_count = 0, .pp_enabled_extension_names = null }, null) catch return error.InstanceCreationFailed;
        const vki = vk.InstanceWrapper.load(instance, vkb.dispatch.vkGetInstanceProcAddr.?);
        errdefer vki.destroyInstance(instance, null);

        var device_count: u32 = 0;
        _ = try vki.enumeratePhysicalDevices(instance, &device_count, null);
        if (device_count == 0) return error.NoVulkanDevice;

        var physical_devices: [16]vk.PhysicalDevice = undefined;
        device_count = @min(device_count, 16);
        _ = try vki.enumeratePhysicalDevices(instance, &device_count, &physical_devices);

        var selected_device: ?vk.PhysicalDevice = null;
        var selected_queue_family: u32 = 0;
        var selected_props: vk.PhysicalDeviceProperties = undefined;

        // Prefer discrete GPUs over integrated
        for (physical_devices[0..device_count]) |pdev| {
            const props = vki.getPhysicalDeviceProperties(pdev);

            var queue_count: u32 = 0;
            vki.getPhysicalDeviceQueueFamilyProperties(pdev, &queue_count, null);
            var queue_props: [32]vk.QueueFamilyProperties = undefined;
            queue_count = @min(queue_count, 32);
            vki.getPhysicalDeviceQueueFamilyProperties(pdev, &queue_count, &queue_props);

            for (queue_props[0..queue_count], 0..) |qp, i| {
                if (qp.queue_flags.compute_bit) {
                    // Prefer discrete GPU if we haven't selected one yet, or if current is not discrete
                    if (selected_device == null or
                        (props.device_type == .discrete_gpu and selected_props.device_type != .discrete_gpu))
                    {
                        selected_device = pdev;
                        selected_queue_family = @intCast(i);
                        selected_props = props;
                    }
                    break;
                }
            }
        }

        const physical_device = selected_device orelse return error.NoComputeQueue;

        const queue_priority: f32 = 1.0;
        const device = vki.createDevice(physical_device, &.{
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&vk.DeviceQueueCreateInfo{ .queue_family_index = selected_queue_family, .queue_count = 1, .p_queue_priorities = @ptrCast(&queue_priority) }),
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
            .enabled_extension_count = 0,
            .pp_enabled_extension_names = null,
            .p_enabled_features = null,
        }, null) catch return error.DeviceCreationFailed;

        const vkd = vk.DeviceWrapper.load(device, vki.dispatch.vkGetDeviceProcAddr.?);
        errdefer vkd.destroyDevice(device, null);

        const compute_queue = vkd.getDeviceQueue(device, selected_queue_family, 0);

        const shader_module = vkd.createShaderModule(device, &.{ .code_size = spirv.EMBEDDED_SPIRV.len, .p_code = @ptrCast(@alignCast(spirv.EMBEDDED_SPIRV.ptr)) }, null) catch return error.ShaderModuleCreationFailed;
        errdefer vkd.destroyShaderModule(device, shader_module, null);

        const bindings = [_]vk.DescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 3, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 4, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 5, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
        };

        const descriptor_set_layout = vkd.createDescriptorSetLayout(device, &.{ .binding_count = bindings.len, .p_bindings = &bindings }, null) catch return error.DescriptorSetLayoutCreationFailed;
        errdefer vkd.destroyDescriptorSetLayout(device, descriptor_set_layout, null);

        const pipeline_layout = vkd.createPipelineLayout(device, &.{ .set_layout_count = 1, .p_set_layouts = @ptrCast(&descriptor_set_layout), .push_constant_range_count = 0, .p_push_constant_ranges = null }, null) catch return error.PipelineLayoutCreationFailed;
        errdefer vkd.destroyPipelineLayout(device, pipeline_layout, null);

        var compute_pipeline: vk.Pipeline = undefined;
        _ = vkd.createComputePipelines(device, .null_handle, 1, @ptrCast(&vk.ComputePipelineCreateInfo{
            .stage = .{ .stage = .{ .compute_bit = true }, .module = shader_module, .p_name = "main", .p_specialization_info = null },
            .layout = pipeline_layout,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        }), null, @ptrCast(&compute_pipeline)) catch return error.ComputePipelineCreationFailed;
        errdefer vkd.destroyPipeline(device, compute_pipeline, null);

        const descriptor_pool = vkd.createDescriptorPool(device, &.{ .max_sets = 1, .pool_size_count = 1, .p_pool_sizes = @ptrCast(&vk.DescriptorPoolSize{ .type = .storage_buffer, .descriptor_count = 6 }) }, null) catch return error.DescriptorPoolCreationFailed;
        errdefer vkd.destroyDescriptorPool(device, descriptor_pool, null);

        const command_pool = vkd.createCommandPool(device, &.{ .queue_family_index = selected_queue_family, .flags = .{ .reset_command_buffer_bit = true } }, null) catch return error.CommandPoolCreationFailed;
        errdefer vkd.destroyCommandPool(device, command_pool, null);

        const fence = vkd.createFence(device, &.{ .flags = .{} }, null) catch return error.FenceCreationFailed;
        errdefer vkd.destroyFence(device, fence, null);

        const mem_props = vki.getPhysicalDeviceMemoryProperties(physical_device);

        // Build capabilities from actual Vulkan hardware attributes
        const is_discrete = selected_props.device_type == .discrete_gpu;
        const device_type: mod.GpuCapabilities.DeviceType = switch (selected_props.device_type) {
            .discrete_gpu => .discrete,
            .integrated_gpu => .integrated,
            .virtual_gpu => .virtual,
            .cpu => .cpu,
            else => .other,
        };

        // Get max threads per workgroup from device limits
        const max_threads = selected_props.limits.max_compute_work_group_invocations;

        // Get max buffer size from device limits
        const max_buffer = selected_props.limits.max_storage_buffer_range;

        // Calculate total device local memory from memory heaps
        var device_local_memory: u64 = 0;
        for (0..mem_props.memory_heap_count) |i| {
            const heap = mem_props.memory_heaps[i];
            if (heap.flags.device_local_bit) {
                device_local_memory += heap.size;
            }
        }

        const capabilities = mod.GpuCapabilities{
            .max_threads_per_group = max_threads,
            .max_buffer_size = max_buffer,
            .recommended_memory = device_local_memory,
            .is_discrete = is_discrete,
            .device_type = device_type,
        };

        // Create regex shader module from SPIR-V
        const regex_shader_module = vkd.createShaderModule(device, &.{
            .code_size = spirv.EMBEDDED_SPIRV_REGEX.len,
            .p_code = @ptrCast(@alignCast(spirv.EMBEDDED_SPIRV_REGEX.ptr)),
        }, null) catch return error.ShaderModuleCreationFailed;
        errdefer vkd.destroyShaderModule(device, regex_shader_module, null);

        // Regex pipeline needs 9 bindings to match search_regex.comp
        const regex_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null }, // TextBuffer
            .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null }, // StatesBuffer
            .{ .binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null }, // BitmapsBuffer
            .{ .binding = 3, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null }, // ConfigBuffer
            .{ .binding = 4, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null }, // HeaderBuffer
            .{ .binding = 5, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null }, // ResultBuffer
            .{ .binding = 6, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null }, // CounterBuffer
            .{ .binding = 7, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null }, // LineOffsetsBuffer
            .{ .binding = 8, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null }, // LineLengthsBuffer
        };

        const regex_descriptor_set_layout = vkd.createDescriptorSetLayout(device, &.{
            .binding_count = regex_bindings.len,
            .p_bindings = &regex_bindings,
        }, null) catch return error.DescriptorSetLayoutCreationFailed;
        errdefer vkd.destroyDescriptorSetLayout(device, regex_descriptor_set_layout, null);

        const regex_pipeline_layout = vkd.createPipelineLayout(device, &.{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&regex_descriptor_set_layout),
            .push_constant_range_count = 0,
            .p_push_constant_ranges = null,
        }, null) catch return error.PipelineLayoutCreationFailed;
        errdefer vkd.destroyPipelineLayout(device, regex_pipeline_layout, null);

        var regex_compute_pipeline: vk.Pipeline = undefined;
        _ = vkd.createComputePipelines(device, .null_handle, 1, @ptrCast(&vk.ComputePipelineCreateInfo{
            .stage = .{
                .stage = .{ .compute_bit = true },
                .module = regex_shader_module,
                .p_name = "main",
                .p_specialization_info = null,
            },
            .layout = regex_pipeline_layout,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        }), null, @ptrCast(&regex_compute_pipeline)) catch return error.ComputePipelineCreationFailed;
        errdefer vkd.destroyPipeline(device, regex_compute_pipeline, null);

        const self = try allocator.create(Self);
        self.* = Self{
            .instance = instance,
            .physical_device = physical_device,
            .device = device,
            .compute_queue = compute_queue,
            .compute_queue_family = selected_queue_family,
            .descriptor_set_layout = descriptor_set_layout,
            .pipeline_layout = pipeline_layout,
            .compute_pipeline = compute_pipeline,
            .regex_descriptor_set_layout = regex_descriptor_set_layout,
            .regex_pipeline_layout = regex_pipeline_layout,
            .regex_compute_pipeline = regex_compute_pipeline,
            .regex_shader_module = regex_shader_module,
            .descriptor_pool = descriptor_pool,
            .shader_module = shader_module,
            .command_pool = command_pool,
            .fence = fence,
            .mem_props = mem_props,
            .allocator = allocator,
            .vkb = vkb,
            .vki = vki,
            .vkd = vkd,
            .capabilities = capabilities,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.vkd.destroyFence(self.device, self.fence, null);
        self.vkd.destroyCommandPool(self.device, self.command_pool, null);
        self.vkd.destroyDescriptorPool(self.device, self.descriptor_pool, null);
        // Clean up regex pipeline
        self.vkd.destroyPipeline(self.device, self.regex_compute_pipeline, null);
        self.vkd.destroyPipelineLayout(self.device, self.regex_pipeline_layout, null);
        self.vkd.destroyDescriptorSetLayout(self.device, self.regex_descriptor_set_layout, null);
        self.vkd.destroyShaderModule(self.device, self.regex_shader_module, null);
        // Clean up literal pipeline
        self.vkd.destroyPipeline(self.device, self.compute_pipeline, null);
        self.vkd.destroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.vkd.destroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
        self.vkd.destroyShaderModule(self.device, self.shader_module, null);
        self.vkd.destroyDevice(self.device, null);
        self.vki.destroyInstance(self.instance, null);
        self.allocator.destroy(self);
    }

    fn createBuffer(self: *Self, size: vk.DeviceSize) !BufferAllocation {
        const buffer = self.vkd.createBuffer(self.device, &.{ .size = size, .usage = .{ .storage_buffer_bit = true }, .sharing_mode = .exclusive, .queue_family_index_count = 0, .p_queue_family_indices = null }, null) catch return error.BufferCreationFailed;
        const mem_reqs = self.vkd.getBufferMemoryRequirements(self.device, buffer);
        const mem_type_index = findMemoryType(&self.mem_props, mem_reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true }) orelse return error.NoSuitableMemoryType;
        const memory = self.vkd.allocateMemory(self.device, &.{ .allocation_size = mem_reqs.size, .memory_type_index = mem_type_index }, null) catch return error.MemoryAllocationFailed;
        self.vkd.bindBufferMemory(self.device, buffer, memory, 0) catch return error.MemoryBindFailed;
        const mapped = self.vkd.mapMemory(self.device, memory, 0, size, .{}) catch return error.MemoryMapFailed;
        return BufferAllocation{ .buffer = buffer, .memory = memory, .size = size, .mapped = mapped };
    }

    fn destroyBuffer(self: *Self, buf: BufferAllocation) void {
        self.vkd.unmapMemory(self.device, buf.memory);
        self.vkd.freeMemory(self.device, buf.memory, null);
        self.vkd.destroyBuffer(self.device, buf.buffer, null);
    }

    pub fn search(self: *Self, text: []const u8, pattern: []const u8, options: SearchOptions, result_allocator: std.mem.Allocator) !SearchResult {
        if (pattern.len == 0 or pattern.len > mod.MAX_PATTERN_LEN) return error.InvalidPatternLength;
        if (text.len > MAX_GPU_BUFFER_SIZE) return error.TextTooLarge;

        const text_size: vk.DeviceSize = @intCast(((text.len + 3) / 4) * 4);
        const text_buffer = try self.createBuffer(text_size);
        defer self.destroyBuffer(text_buffer);

        const pattern_size: vk.DeviceSize = @intCast(((pattern.len + 3) / 4) * 4);
        const pattern_buffer = try self.createBuffer(pattern_size);
        defer self.destroyBuffer(pattern_buffer);

        const skip_buffer = try self.createBuffer(256);
        defer self.destroyBuffer(skip_buffer);

        const config_buffer = try self.createBuffer(@sizeOf(SearchConfig));
        defer self.destroyBuffer(config_buffer);

        const results_size: vk.DeviceSize = @intCast(@sizeOf(MatchResult) * MAX_RESULTS);
        const results_buffer = try self.createBuffer(results_size);
        defer self.destroyBuffer(results_buffer);

        const counters_buffer = try self.createBuffer(8);
        defer self.destroyBuffer(counters_buffer);

        @memcpy(@as([*]u8, @ptrCast(text_buffer.mapped))[0..text.len], text);
        @memcpy(@as([*]u8, @ptrCast(pattern_buffer.mapped))[0..pattern.len], pattern);

        const skip_table = mod.buildSkipTable(pattern, options.case_insensitive);
        @as(*[256]u8, @ptrCast(@alignCast(skip_buffer.mapped))).* = skip_table;

        @as(*SearchConfig, @ptrCast(@alignCast(config_buffer.mapped))).* = SearchConfig{
            .text_len = @intCast(text.len),
            .pattern_len = @intCast(pattern.len),
            .num_patterns = 1,
            .flags = options.toFlags(),
            .positions_per_thread = 1,
        };

        const counters_ptr: *[2]u32 = @ptrCast(@alignCast(counters_buffer.mapped));
        counters_ptr[0] = 0;
        counters_ptr[1] = 0;

        var descriptor_set: vk.DescriptorSet = undefined;
        self.vkd.allocateDescriptorSets(self.device, &.{ .descriptor_pool = self.descriptor_pool, .descriptor_set_count = 1, .p_set_layouts = @ptrCast(&self.descriptor_set_layout) }, @ptrCast(&descriptor_set)) catch return error.DescriptorSetAllocationFailed;

        const buffer_infos = [_]vk.DescriptorBufferInfo{
            .{ .buffer = text_buffer.buffer, .offset = 0, .range = text_size },
            .{ .buffer = pattern_buffer.buffer, .offset = 0, .range = pattern_size },
            .{ .buffer = skip_buffer.buffer, .offset = 0, .range = 256 },
            .{ .buffer = config_buffer.buffer, .offset = 0, .range = @sizeOf(SearchConfig) },
            .{ .buffer = results_buffer.buffer, .offset = 0, .range = results_size },
            .{ .buffer = counters_buffer.buffer, .offset = 0, .range = 8 },
        };

        var writes: [6]vk.WriteDescriptorSet = undefined;
        for (0..6) |i| {
            writes[i] = .{
                .dst_set = descriptor_set,
                .dst_binding = @intCast(i),
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast(&buffer_infos[i]),
                .p_texel_buffer_view = undefined,
            };
        }
        self.vkd.updateDescriptorSets(self.device, 6, &writes, 0, undefined);

        var command_buffer: vk.CommandBuffer = undefined;
        self.vkd.allocateCommandBuffers(self.device, &.{ .command_pool = self.command_pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&command_buffer)) catch return error.CommandBufferAllocationFailed;
        defer self.vkd.freeCommandBuffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));

        self.vkd.beginCommandBuffer(command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } }) catch return error.CommandBufferBeginFailed;
        self.vkd.cmdBindPipeline(command_buffer, .compute, self.compute_pipeline);
        self.vkd.cmdBindDescriptorSets(command_buffer, .compute, self.pipeline_layout, 0, 1, @ptrCast(&descriptor_set), 0, undefined);

        const workgroups = @max(1, (text.len + 64 * 64 - 1) / (64 * 64));
        self.vkd.cmdDispatch(command_buffer, @intCast(workgroups), 1, 1);
        self.vkd.endCommandBuffer(command_buffer) catch return error.CommandBufferEndFailed;

        self.vkd.queueSubmit(self.compute_queue, 1, @ptrCast(&vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        }), self.fence) catch return error.QueueSubmitFailed;
        _ = self.vkd.waitForFences(self.device, 1, @ptrCast(&self.fence), .true, std.math.maxInt(u64)) catch return error.FenceWaitFailed;
        self.vkd.resetFences(self.device, 1, @ptrCast(&self.fence)) catch return error.FenceResetFailed;

        const result_count = counters_ptr[0];
        const total_matches = counters_ptr[1];

        const num_to_copy = @min(result_count, MAX_RESULTS);
        const matches = try result_allocator.alloc(MatchResult, num_to_copy);
        if (num_to_copy > 0) @memcpy(matches, @as([*]MatchResult, @ptrCast(@alignCast(results_buffer.mapped)))[0..num_to_copy]);

        self.vkd.resetDescriptorPool(self.device, self.descriptor_pool, .{}) catch {};
        return SearchResult{ .matches = matches, .total_matches = total_matches, .allocator = result_allocator };
    }

    /// GPU-accelerated regex pattern search (Vulkan Thompson NFA)
    pub fn searchRegex(self: *Self, text: []const u8, pattern: []const u8, options: SearchOptions, result_allocator: std.mem.Allocator) !SearchResult {
        if (text.len == 0) return SearchResult{ .matches = &.{}, .total_matches = 0, .allocator = result_allocator };
        if (text.len > MAX_GPU_BUFFER_SIZE) return error.TextTooLarge;

        // Compile regex to GPU format
        var gpu_regex = try regex_compiler.compileForGpu(pattern, .{
            .case_insensitive = options.case_insensitive,
        }, self.allocator);
        defer gpu_regex.deinit();

        // Count lines first
        var num_lines: usize = 0;
        for (text) |c| {
            if (c == '\n') num_lines += 1;
        }
        // Add one for last line if no trailing newline
        if (text.len > 0 and text[text.len - 1] != '\n') num_lines += 1;
        if (num_lines == 0) num_lines = 1; // At least one line

        // Allocate line offsets and lengths
        const line_offsets_slice = try self.allocator.alloc(u32, num_lines);
        defer self.allocator.free(line_offsets_slice);
        const line_lengths_slice = try self.allocator.alloc(u32, num_lines);
        defer self.allocator.free(line_lengths_slice);

        // Fill in line data
        var line_idx: usize = 0;
        var line_start: u32 = 0;
        for (text, 0..) |c, i| {
            if (c == '\n') {
                line_offsets_slice[line_idx] = line_start;
                line_lengths_slice[line_idx] = @intCast(i - line_start);
                line_idx += 1;
                line_start = @intCast(i + 1);
            }
        }
        // Handle last line (if no trailing newline)
        if (line_start < text.len and line_idx < num_lines) {
            line_offsets_slice[line_idx] = line_start;
            line_lengths_slice[line_idx] = @intCast(text.len - line_start);
        }
        if (num_lines == 0) return SearchResult{ .matches = &.{}, .total_matches = 0, .allocator = result_allocator };

        // Create buffers
        const text_size: vk.DeviceSize = @intCast(((text.len + 3) / 4) * 4);
        const text_buffer = try self.createBuffer(text_size);
        defer self.destroyBuffer(text_buffer);

        // States buffer: 3 u32s per state (packed for GPU)
        const states_size: vk.DeviceSize = @intCast(gpu_regex.states.len * 3 * @sizeOf(u32));
        const states_buffer = try self.createBuffer(@max(states_size, 16));
        defer self.destroyBuffer(states_buffer);

        // Bitmaps buffer
        const bitmaps_size: vk.DeviceSize = @intCast(@max(gpu_regex.bitmaps.len * @sizeOf(u32), 32));
        const bitmaps_buffer = try self.createBuffer(bitmaps_size);
        defer self.destroyBuffer(bitmaps_buffer);

        const config_buffer = try self.createBuffer(@sizeOf(RegexSearchConfig));
        defer self.destroyBuffer(config_buffer);

        const header_buffer = try self.createBuffer(16); // 4 u32s
        defer self.destroyBuffer(header_buffer);

        const results_size: vk.DeviceSize = @intCast(@sizeOf(RegexMatchResult) * MAX_RESULTS);
        const results_buffer = try self.createBuffer(results_size);
        defer self.destroyBuffer(results_buffer);

        const counters_buffer = try self.createBuffer(8); // result_count, total_matches
        defer self.destroyBuffer(counters_buffer);

        const line_offsets_size: vk.DeviceSize = @intCast(num_lines * @sizeOf(u32));
        const line_offsets_buffer = try self.createBuffer(line_offsets_size);
        defer self.destroyBuffer(line_offsets_buffer);

        const line_lengths_buffer = try self.createBuffer(line_offsets_size);
        defer self.destroyBuffer(line_lengths_buffer);

        // Upload data
        @memcpy(@as([*]u8, @ptrCast(text_buffer.mapped))[0..text.len], text);

        // Pack states into GPU format (3 u32s per state)
        const states_ptr: [*]u32 = @ptrCast(@alignCast(states_buffer.mapped));
        for (gpu_regex.states, 0..) |state, i| {
            const base = i * 3;
            // Word 0: type(4) | flags(4) | out(12) | unused(12)
            states_ptr[base] = @as(u32, state.type) |
                (@as(u32, state.flags) << 8) |
                (@as(u32, state.out) << 16);
            // Word 1: out2(16) | literal_char(8) | group_idx(8)
            states_ptr[base + 1] = @as(u32, state.out2) |
                (@as(u32, state.literal_char) << 16) |
                (@as(u32, state.group_idx) << 24);
            // Word 2: bitmap_offset(32)
            states_ptr[base + 2] = state.bitmap_offset;
        }

        // Upload bitmaps
        if (gpu_regex.bitmaps.len > 0) {
            const bitmaps_ptr: [*]u32 = @ptrCast(@alignCast(bitmaps_buffer.mapped));
            @memcpy(bitmaps_ptr[0..gpu_regex.bitmaps.len], gpu_regex.bitmaps);
        }

        // Upload config
        var search_flags: u32 = 0;
        if (options.invert_match) search_flags |= 16; // FLAG_INVERT_MATCH
        @as(*RegexSearchConfig, @ptrCast(@alignCast(config_buffer.mapped))).* = .{
            .text_len = @intCast(text.len),
            .num_states = @intCast(gpu_regex.states.len),
            .start_state = gpu_regex.header.start_state,
            .header_flags = gpu_regex.header.flags,
            .num_bitmaps = @intCast(gpu_regex.bitmaps.len),
            .max_results = MAX_RESULTS,
            .flags = search_flags,
        };

        // Upload header
        const header_ptr: [*]u32 = @ptrCast(@alignCast(header_buffer.mapped));
        header_ptr[0] = @intCast(gpu_regex.states.len);
        header_ptr[1] = gpu_regex.header.start_state;
        header_ptr[2] = gpu_regex.header.num_groups;
        header_ptr[3] = gpu_regex.header.flags;

        // Upload line data
        @memcpy(@as([*]u32, @ptrCast(@alignCast(line_offsets_buffer.mapped)))[0..num_lines], line_offsets_slice);
        @memcpy(@as([*]u32, @ptrCast(@alignCast(line_lengths_buffer.mapped)))[0..num_lines], line_lengths_slice);

        // Zero counters
        const counters_ptr: *[2]u32 = @ptrCast(@alignCast(counters_buffer.mapped));
        counters_ptr[0] = 0;
        counters_ptr[1] = 0;

        // Allocate descriptor set for regex pipeline (need a separate pool for 9 descriptors)
        const regex_pool = self.vkd.createDescriptorPool(self.device, &.{
            .max_sets = 1,
            .pool_size_count = 1,
            .p_pool_sizes = @ptrCast(&vk.DescriptorPoolSize{
                .type = .storage_buffer,
                .descriptor_count = 9,
            }),
        }, null) catch return error.DescriptorPoolCreationFailed;
        defer self.vkd.destroyDescriptorPool(self.device, regex_pool, null);

        var descriptor_set: vk.DescriptorSet = undefined;
        self.vkd.allocateDescriptorSets(self.device, &.{
            .descriptor_pool = regex_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&self.regex_descriptor_set_layout),
        }, @ptrCast(&descriptor_set)) catch return error.DescriptorSetAllocationFailed;

        // Update descriptor set with all 9 buffers
        const buffer_infos = [_]vk.DescriptorBufferInfo{
            .{ .buffer = text_buffer.buffer, .offset = 0, .range = text_size },
            .{ .buffer = states_buffer.buffer, .offset = 0, .range = @max(states_size, 16) },
            .{ .buffer = bitmaps_buffer.buffer, .offset = 0, .range = bitmaps_size },
            .{ .buffer = config_buffer.buffer, .offset = 0, .range = @sizeOf(RegexSearchConfig) },
            .{ .buffer = header_buffer.buffer, .offset = 0, .range = 16 },
            .{ .buffer = results_buffer.buffer, .offset = 0, .range = results_size },
            .{ .buffer = counters_buffer.buffer, .offset = 0, .range = 8 },
            .{ .buffer = line_offsets_buffer.buffer, .offset = 0, .range = line_offsets_size },
            .{ .buffer = line_lengths_buffer.buffer, .offset = 0, .range = line_offsets_size },
        };

        var writes: [9]vk.WriteDescriptorSet = undefined;
        for (0..9) |i| {
            writes[i] = .{
                .dst_set = descriptor_set,
                .dst_binding = @intCast(i),
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast(&buffer_infos[i]),
                .p_texel_buffer_view = undefined,
            };
        }
        self.vkd.updateDescriptorSets(self.device, 9, &writes, 0, undefined);

        // Allocate and record command buffer
        var command_buffer: vk.CommandBuffer = undefined;
        self.vkd.allocateCommandBuffers(self.device, &.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&command_buffer)) catch return error.CommandBufferAllocationFailed;
        defer self.vkd.freeCommandBuffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));

        self.vkd.beginCommandBuffer(command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } }) catch return error.CommandBufferBeginFailed;
        self.vkd.cmdBindPipeline(command_buffer, .compute, self.regex_compute_pipeline);
        self.vkd.cmdBindDescriptorSets(command_buffer, .compute, self.regex_pipeline_layout, 0, 1, @ptrCast(&descriptor_set), 0, undefined);

        // Dispatch one thread per line (local_size_x = 64 in shader)
        const workgroups = @max(1, (num_lines + 63) / 64);
        self.vkd.cmdDispatch(command_buffer, @intCast(workgroups), 1, 1);
        self.vkd.endCommandBuffer(command_buffer) catch return error.CommandBufferEndFailed;

        // Submit and wait
        self.vkd.queueSubmit(self.compute_queue, 1, @ptrCast(&vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        }), self.fence) catch return error.QueueSubmitFailed;
        _ = self.vkd.waitForFences(self.device, 1, @ptrCast(&self.fence), .true, std.math.maxInt(u64)) catch return error.FenceWaitFailed;
        self.vkd.resetFences(self.device, 1, @ptrCast(&self.fence)) catch return error.FenceResetFailed;

        // Read results
        const result_count = counters_ptr[0];
        const total_matches = counters_ptr[1];

        const num_to_copy = @min(result_count, MAX_RESULTS);
        const regex_results = @as([*]RegexMatchResult, @ptrCast(@alignCast(results_buffer.mapped)));

        // Convert RegexMatchResult to MatchResult
        const matches = try result_allocator.alloc(MatchResult, num_to_copy);
        for (0..num_to_copy) |i| {
            matches[i] = .{
                .position = regex_results[i].start,
                .pattern_idx = 0,
                .match_len = regex_results[i].end - regex_results[i].start,
                .line_start = regex_results[i].line_start,
            };
        }

        return SearchResult{ .matches = matches, .total_matches = total_matches, .allocator = result_allocator };
    }
};

fn findMemoryType(mem_props: *const vk.PhysicalDeviceMemoryProperties, type_filter: u32, properties: vk.MemoryPropertyFlags) ?u32 {
    for (0..mem_props.memory_type_count) |i| {
        const idx: u5 = @intCast(i);
        if ((type_filter & (@as(u32, 1) << idx)) != 0) {
            const mem_type = mem_props.memory_types[i];
            if (mem_type.property_flags.host_visible_bit == properties.host_visible_bit and mem_type.property_flags.host_coherent_bit == properties.host_coherent_bit) return @intCast(i);
        }
    }
    return null;
}
