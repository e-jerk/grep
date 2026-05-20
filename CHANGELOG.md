# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Stdin EOF handling: `error.EndOfStream` from `readStreaming()` is now treated as normal EOF instead of fatal error, fixing all piped-input modes (`-q`, `-o`, `--color=always`, stdin input)
- Removed empty `for` loops in `defer` blocks that were incorrectly produced by transpiler, where `deinit()` had become the loop body
- Docker CI test commands now use `--entrypoint ""` to override `ENTRYPOINT ["grep"]` during verification

## [0.6.0] - 2026-05-20

### Changed
- Migrated to Zig 0.16.0 API throughout (`std.process.Init`, `std.Io`, `std.Io.File`, `std.Io.Clock`)
- Docker base images upgraded from Alpine 3.19 to 3.21 for statx(2) compatibility
- Shared CI workflow (`e-jerk/.github`) updated to Zig 0.16.0
- zust added as proper `build.zig.zon` dependency
- e_jerk_regex dependency updated to `main` branch with Zig 0.16 fixes
- vulkan-zig dependency updated to `master` for Zig 0.16 compat

### Fixed
- Transpiler-induced compilation errors: `ArrayListUnmanaged = .empty`, `ArrayList = .{}`, `DebugAllocator`, `trimStart`
- `statx: symbol not found` on Alpine Linux by upgrading base images
- gnu-tests-linux container upgraded from Alpine 3.19 to 3.21

### Added
- Zust memory-safety transpilation with memory-safety analyzer integration
- GNU compatibility tests: 42 tests covering pattern matching, context lines, recursive search, color output, and quiet mode

[0.6.0]: https://github.com/e-jerk/grep/releases/tag/v0.6.0
