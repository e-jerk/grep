const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is_macos = target.result.os.tag == .macos;
    const is_linux = target.result.os.tag == .linux;
    const is_native = target.result.os.tag == @import("builtin").os.tag;

    // Build options to pass compile-time config to source
    const build_options = b.addOptions();
    build_options.addOption(bool, "is_macos", is_macos);
    const build_options_module = build_options.createModule();

    // GNU grep dependency
    const gnu_grep = b.dependency("gnu_grep", .{});

    // GNU grep source files
    const gnu_src_files = &[_][]const u8{
        "src/dfasearch.c",
        "src/kwsearch.c",
        "src/kwset.c",
        "src/searchutils.c",
    };

    // Core gnulib files needed for grep search functionality
    // Note: regex.c includes regex_internal.c, regcomp.c, regexec.c
    // Excluded: reallocarray.c, rawmemchr.c, memrchr.c, mbslen.c, setlocale_null.c
    //           (we provide inline implementations in gnulib_compat.h)
    const gnu_lib_files = &[_][]const u8{
        "lib/argmatch.c",
        "lib/c-ctype.c",
        "lib/c-strcasecmp.c",
        "lib/c-strncasecmp.c",
        "lib/dfa.c",
        "lib/error.c",
        "lib/exitfail.c",
        "lib/getprogname.c",
        "lib/hard-locale.c",
        "lib/hash.c",
        "lib/ialloc.c",
        "lib/localcharset.c",
        "lib/localeinfo.c",
        "lib/malloca.c",
        "lib/mbchar.c",
        "lib/mbiter.c",
        "lib/mbscasecmp.c",
        // "lib/mbslen.c",  // Using inline implementation
        "lib/mbsstr.c",
        "lib/mbuiter.c",
        "lib/memchr.c",
        "lib/memchr2.c",
        "lib/mempcpy.c",
        // "lib/memrchr.c",  // Using inline implementation
        "lib/obstack.c",
        "lib/quotearg.c",
        // "lib/rawmemchr.c",  // Using inline implementation
        // "lib/reallocarray.c",  // Using inline implementation
        "lib/regex.c",
        "lib/safe-read.c",
        // "lib/setlocale_null.c",  // Using inline implementation
        "lib/setlocale-lock.c",
        "lib/striconv.c",
        "lib/strnlen1.c",
        // "lib/xalloc-die.c",  // Using our own implementation in gnulib_stubs.c
        // "lib/xmalloc.c",     // Using our own implementation in gnulib_stubs.c
    };

    // C compiler flags
    const c_flags = &[_][]const u8{
        "-std=gnu11",
        "-DHAVE_CONFIG_H",
        "-D_GNU_SOURCE",
        "-Wno-unused-parameter",
        "-Wno-sign-compare",
        "-Wno-implicit-fallthrough",
        "-Wno-nullability-completeness",
        "-Wno-nullability-extension",
        "-Wno-expansion-to-defined",
        "-Wno-gnu-statement-expression",
        "-Wno-format",
        "-fno-strict-aliasing",
        // Disable UB sanitizer - gnulib obstack uses intentional null pointer arithmetic
        "-fno-sanitize=undefined",
    };

    // Helper function to add GNU grep C sources to an artifact
    const addGnuGrepSources = struct {
        fn add(compile: *std.Build.Step.Compile, builder: *std.Build, gnu: *std.Build.Dependency, target_is_macos: bool) void {
            // Add GNU grep source files
            for (gnu_src_files) |src| {
                compile.addCSourceFile(.{
                    .file = gnu.path(src),
                    .flags = c_flags,
                });
            }
            // Add gnulib source files
            for (gnu_lib_files) |src| {
                compile.addCSourceFile(.{
                    .file = gnu.path(src),
                    .flags = c_flags,
                });
            }
            // Add our wrapper and stub files
            compile.addCSourceFile(.{
                .file = builder.path("src/gnu/gnu_grep_wrapper.c"),
                .flags = c_flags,
            });
            compile.addCSourceFile(.{
                .file = builder.path("src/gnu/gnulib_stubs.c"),
                .flags = c_flags,
            });
            // Include paths - our config.h first, then gnulib lib, then src
            compile.addIncludePath(builder.path("src/gnu")); // Our config.h and stubs
            compile.addIncludePath(gnu.path("lib"));
            compile.addIncludePath(gnu.path("src"));
            // Link libc (iconv is included in libc on macOS)
            compile.linkLibC();
            // On Linux, link iconv separately
            if (!target_is_macos) {
                compile.linkSystemLibrary("iconv");
            }
        }
    }.add;

    _ = is_linux;

    // e_jerk_gpu library for GPU detection and auto-selection (also provides zigtrait)
    const e_jerk_gpu_dep = b.dependency("e_jerk_gpu", .{});
    const e_jerk_gpu_module = e_jerk_gpu_dep.module("e_jerk_gpu");
    const zigtrait_module = e_jerk_gpu_dep.module("zigtrait");

    // zig-metal dependency
    const zig_metal_dep = b.dependency("zig_metal", .{});
    const zig_metal_module = b.addModule("zig-metal", .{
        .root_source_file = zig_metal_dep.path("src/main.zig"),
        .imports = &.{
            .{ .name = "zigtrait", .module = zigtrait_module },
        },
    });

    // Vulkan dependencies
    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vulkan_dep = b.dependency("vulkan_zig", .{
        .registry = vulkan_headers.path("registry/vk.xml"),
    });
    const vulkan_module = vulkan_dep.module("vulkan-zig");

    // Regex engine
    const regex_dep = b.dependency("regex", .{});
    const regex_module = regex_dep.module("regex");

    // Shared shader library
    const shaders_common = b.dependency("shaders_common", .{});

    // Compile SPIR-V shader from GLSL for Vulkan
    const spirv_compile = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-O",
    });
    // Add include path for shared GLSL headers
    spirv_compile.addArg("-I");
    spirv_compile.addDirectoryArg(shaders_common.path("glsl"));
    spirv_compile.addArg("-o");
    const spirv_output = spirv_compile.addOutputFileArg("search.spv");
    spirv_compile.addFileArg(b.path("src/shaders/search.comp"));

    // Create embedded SPIR-V module
    const spirv_module = b.addModule("spirv", .{
        .root_source_file = b.addWriteFiles().add("spirv.zig",
            \\pub const EMBEDDED_SPIRV = @embedFile("search.spv");
        ),
    });
    spirv_module.addAnonymousImport("search.spv", .{ .root_source_file = spirv_output });

    // Preprocess Metal shader to inline the string_ops.h include
    // Concatenates: header + shader (with include line removed)
    const metal_preprocess = b.addSystemCommand(&.{
        "/bin/sh", "-c",
        \\cat "$1" && grep -v '#include "string_ops.h"' "$2"
        , "--",
    });
    metal_preprocess.addFileArg(shaders_common.path("metal/string_ops.h"));
    metal_preprocess.addFileArg(b.path("src/shaders/search.metal"));
    const preprocessed_metal = metal_preprocess.captureStdOut();

    // Create embedded Metal shader module
    const metal_module = b.addModule("metal_shader", .{
        .root_source_file = b.addWriteFiles().add("metal_shader.zig",
            \\pub const EMBEDDED_METAL_SHADER = @embedFile("search.metal");
        ),
    });
    metal_module.addAnonymousImport("search.metal", .{ .root_source_file = preprocessed_metal });

    // Create gpu module for reuse
    const gpu_module = b.addModule("gpu", .{
        .root_source_file = b.path("src/gpu/mod.zig"),
        .imports = &.{
            .{ .name = "zig-metal", .module = zig_metal_module },
            .{ .name = "build_options", .module = build_options_module },
            .{ .name = "vulkan", .module = vulkan_module },
            .{ .name = "spirv", .module = spirv_module },
            .{ .name = "metal_shader", .module = metal_module },
            .{ .name = "e_jerk_gpu", .module = e_jerk_gpu_module },
        },
    });

    // Create cpu module for reuse (optimized SIMD implementation)
    const cpu_module = b.addModule("cpu", .{
        .root_source_file = b.path("src/cpu_optimized.zig"),
        .imports = &.{
            .{ .name = "gpu", .module = gpu_module },
            .{ .name = "regex", .module = regex_module },
        },
    });

    // Create cpu_gnu module (GNU grep reference implementation)
    // Note: cpu_gnu uses cpu_optimized for regex (GNU regex has memory issues with quantifiers)
    const cpu_gnu_module = b.addModule("cpu_gnu", .{
        .root_source_file = b.path("src/cpu_gnu.zig"),
        .imports = &.{
            .{ .name = "gpu", .module = gpu_module },
            .{ .name = "cpu_optimized", .module = cpu_module },
        },
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "grep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "cpu_gnu", .module = cpu_gnu_module },
            },
        }),
    });

    // Add GNU grep C sources to main executable (includes wrapper and stubs)
    addGnuGrepSources(exe, b, gnu_grep, is_macos);

    // Platform-specific linking
    if (is_macos) {
        if (is_native) {
            exe.linkFramework("Foundation");
            exe.linkFramework("Metal");
            exe.linkFramework("QuartzCore");
            exe.linkFramework("CoreFoundation");

            // MoltenVK from Homebrew for Vulkan on macOS
            exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
            exe.linkSystemLibrary("MoltenVK");
        }
    } else {
        if (is_native) {
            exe.linkSystemLibrary("vulkan");
        }
    }

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run grep");
    run_step.dependOn(&run_cmd.step);

    // Benchmark executable
    // Note: Uses ReleaseSafe instead of ReleaseFast because the GNU grep C code
    // has undefined behavior that manifests as crashes under aggressive optimizations
    const bench_exe = b.addExecutable(.{
        .name = "grep-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
                .{ .name = "cpu_gnu", .module = cpu_gnu_module },
            },
        }),
    });

    // Add GNU grep C sources to benchmark
    addGnuGrepSources(bench_exe, b, gnu_grep, is_macos);

    if (is_macos) {
        if (is_native) {
            bench_exe.linkFramework("Foundation");
            bench_exe.linkFramework("Metal");
            bench_exe.linkFramework("QuartzCore");
            bench_exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
            bench_exe.linkSystemLibrary("MoltenVK");
        }
    } else {
        if (is_native) {
            bench_exe.linkSystemLibrary("vulkan");
        }
    }

    b.installArtifact(bench_exe);

    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // Smoke tests executable
    const smoke_exe = b.addExecutable(.{
        .name = "grep-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/smoke_tests.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
            },
        }),
    });

    if (is_macos) {
        if (is_native) {
            smoke_exe.linkFramework("Foundation");
            smoke_exe.linkFramework("Metal");
            smoke_exe.linkFramework("QuartzCore");
            smoke_exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
            smoke_exe.linkSystemLibrary("MoltenVK");
        }
    } else {
        if (is_native) {
            smoke_exe.linkSystemLibrary("vulkan");
        }
    }

    b.installArtifact(smoke_exe);

    const smoke_cmd = b.addRunArtifact(smoke_exe);
    smoke_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        smoke_cmd.addArgs(args);
    }

    const smoke_step = b.step("smoke", "Run smoke tests");
    smoke_step.dependOn(&smoke_cmd.step);

    // Tests from src/main.zig
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
            },
        }),
    });

    if (is_macos and is_native) {
        main_tests.linkFramework("Foundation");
        main_tests.linkFramework("Metal");
        main_tests.linkFramework("QuartzCore");
        main_tests.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        main_tests.linkSystemLibrary("MoltenVK");
    }

    // Unit tests from tests/unit_tests.zig
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
            },
        }),
    });

    if (is_macos and is_native) {
        unit_tests.linkFramework("Foundation");
        unit_tests.linkFramework("Metal");
        unit_tests.linkFramework("QuartzCore");
        unit_tests.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        unit_tests.linkSystemLibrary("MoltenVK");
    }

    // Metal shader compilation check (macOS only)
    // This validates the shader compiles without warnings at build time
    if (is_macos) {
        const write_shader = b.addWriteFiles();
        _ = write_shader.addCopyFile(preprocessed_metal, "search_check.metal");

        const metal_compile_check = b.addSystemCommand(&.{
            "xcrun", "-sdk", "macosx", "metal",
            "-Werror",
            "-c",
        });
        metal_compile_check.addFileArg(write_shader.getDirectory().path(b, "search_check.metal"));
        metal_compile_check.addArg("-o");
        _ = metal_compile_check.addOutputFileArg("search.air");

        unit_tests.step.dependOn(&metal_compile_check.step);
    }

    // Regex tests from tests/regex_tests.zig
    const regex_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/regex_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-metal", .module = zig_metal_module },
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "cpu", .module = cpu_module },
            },
        }),
    });

    if (is_macos and is_native) {
        regex_tests.linkFramework("Foundation");
        regex_tests.linkFramework("Metal");
        regex_tests.linkFramework("QuartzCore");
        regex_tests.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/molten-vk/lib" });
        regex_tests.linkSystemLibrary("MoltenVK");
    }

    const run_main_tests = b.addRunArtifact(main_tests);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_regex_tests = b.addRunArtifact(regex_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_regex_tests.step);
}
