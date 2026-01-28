# GPU-Accelerated Grep

A high-performance `grep` replacement that uses GPU acceleration via Metal (macOS) and Vulkan for blazing-fast text searches.

## Features

- **GPU-Accelerated Search**: Parallel pattern matching on Metal and Vulkan compute shaders
- **SIMD-Optimized CPU**: Vectorized Boyer-Moore-Horspool with 16/32-byte SIMD operations
- **Auto-Selection**: Intelligent backend selection based on file size, pattern complexity, and hardware tier
- **GNU Compatible**: Full support for common grep flags including context lines, recursive search, and color output

## Installation

Available via Homebrew. See the homebrew-utils repository for installation instructions.

## Usage

```bash
# Basic usage (auto-selects best backend)
grep "pattern" file.txt

# Case-insensitive search
grep -i "error" log.txt

# Word boundary matching
grep -w "test" source.c

# Invert match (show non-matching lines)
grep -v "debug" output.log

# Context lines (before, after, both)
grep -B 3 "error" log.txt      # 3 lines before
grep -A 3 "error" log.txt      # 3 lines after
grep -C 2 "error" log.txt      # 2 lines before and after

# Recursive search
grep -r "TODO" src/
grep -rn "FIXME" .              # With line numbers

# Color output
grep --color=always "pattern" file.txt

# Force specific backend
grep --gpu "TODO" *.py
grep --metal "FIXME" src/
grep --vulkan "BUG" lib/
grep --cpu "pattern" file.txt

# Verbose output showing timing and backend info
grep -V "pattern" largefile.txt
```

## GNU Feature Compatibility

| Feature | CPU | Metal | Vulkan | GPU Speedup | Notes |
|---------|:---:|:-----:|:------:|:-----------:|-------|
| Basic pattern matching | ✓ | ✓ | ✓ | **17x** | Full GPU search |
| `-i` case insensitive | ✓ | ✓ | ✓ | **11x** | Full GPU search |
| `-w` word boundary | ✓ | ✓ | ✓ | **8x** | Full GPU search |
| `-v` invert match | ✓ | ✓ | ✓ | **8x** | Full GPU search |
| `-F` fixed strings | ✓ | ✓ | ✓ | **7x** | Full GPU search |
| `-E` extended regex | ✓ | ✓ | ✓ | **5-10x** | GPU regex engine |
| `-G` basic regex | ✓ | ✓ | ✓ | **5-10x** | GPU regex engine |
| `-e` multiple patterns | ✓ | ✓ | ✓ | **5-10x** | GPU per-pattern |
| `-n` line numbers | ✓ | ✓ | ✓ | **10x+** | GPU-computed line nums |
| `-c` count only | ✓ | ✓ | ✓ | **10x+** | GPU search + CPU count |
| `-l` files with matches | ✓ | ✓ | ✓ | **10x+** | GPU search + CPU filter |
| `-L` files without match | ✓ | ✓ | ✓ | **10x+** | GPU search + CPU filter |
| `-q` quiet mode | ✓ | ✓ | ✓ | **10x+** | GPU search + early exit |
| `-o` only matching | ✓ | ✓ | ✓ | **10x+** | GPU-computed positions |
| `-A/-B/-C` context lines | ✓ | ✓ | ✓ | **10x+** | GPU search + CPU format |
| `-r` recursive search | ✓ | ✓ | ✓ | **10x+** | GPU search per file |
| `--color` output | ✓ | ✓ | ✓ | **10x+** | GPU search + ANSI format |
| `-P` Perl regex | — | — | — | — | GNU fallback |

**GPU Architecture**: The GPU performs all pattern matching and line number computation. CPU handles file I/O and output formatting only.

**Test Coverage**: 42/42 GNU compatibility tests passing

## Options

| Flag | Description |
|------|-------------|
| `-i, --ignore-case` | Case-insensitive matching |
| `-w, --word-regexp` | Match whole words only |
| `-v, --invert-match` | Invert match (show non-matching lines) |
| `-F, --fixed-strings` | Treat pattern as fixed string |
| `-n, --line-number` | Print line numbers |
| `-c, --count` | Print only count of matching lines |
| `-l, --files-with-matches` | Print only filenames with matches |
| `-L, --files-without-match` | Print only filenames without matches |
| `-q, --quiet, --silent` | Quiet mode (exit status only) |
| `-o, --only-matching` | Print only matching parts |
| `-e PATTERN` | Use PATTERN for matching |
| `-A NUM` | Print NUM lines after match |
| `-B NUM` | Print NUM lines before match |
| `-C NUM` | Print NUM lines before and after match |
| `-r, --recursive` | Recursive directory search |
| `--color[=WHEN]` | Highlight matches (always/never/auto) |
| `-V, --verbose` | Show timing and backend information |

## Backend Selection

| Flag | Description |
|------|-------------|
| `--auto` | Automatically select optimal backend (default) |
| `--gpu` | Use GPU (Metal on macOS, Vulkan elsewhere) |
| `--cpu` | Force CPU backend |
| `--gnu` | Force GNU grep backend |
| `--metal` | Force Metal backend (macOS only) |
| `--vulkan` | Force Vulkan backend |

## Architecture & Optimizations

### CPU Implementation (`src/cpu_optimized.zig`)

The CPU backend uses a SIMD-optimized Boyer-Moore-Horspool algorithm:

**SIMD Vector Operations**:
- `Vec16` and `Vec32` types for 16/32-byte parallel processing
- `@Vector(16, u8)` and `@Vector(32, u8)` Zig vector types
- Processes pattern matching in 16-byte chunks with `matchAtPositionSIMD()`

**Boyer-Moore-Horspool Skip Table**:
- Pre-computed 256-entry skip table for O(n/m) average case
- Case-insensitive variant populates both upper/lower entries
- Skip calculation: `pattern_len - 1 - last_occurrence_index`

**Vectorized Operations**:
- `toLowerVec16()`: SIMD lowercase conversion using `@select`
- `findLineStartSIMD()`: Backwards 16-byte newline search
- `findNextNewlineSIMD()`: Forward 32-byte newline search
- `searchAllLines()`: 32-byte chunked newline counting for empty patterns

**Context Lines Implementation**:
- `outputWithContext()`: Builds line index, computes context ranges, merges overlapping groups
- Outputs `--` separator between non-adjacent context groups
- Supports combined `-n` with context for numbered output

**Recursive Search**:
- `processDirectory()`: Recursive directory walker with file type filtering
- Processes files in parallel where beneficial
- Supports combined flags (`-rn`, `-ri`, `-rc`, `-rl`)

**Color Output**:
- ANSI escape codes: `\033[01;31m` for match highlighting
- `--color=always|never|auto` modes
- Works with `-o` (only matching) mode

### GPU Implementation

**Metal Shader (`src/shaders/search.metal`)**:

- **Chunked Processing**: Each thread handles `chunk_size = text_len / num_threads` bytes
- **Boyer-Moore-Horspool**: GPU-side skip table with `build_skip_table` kernel
- **uchar4 SIMD**: 4-byte vectorized pattern matching via `match_at_position()`
- **Atomic Counters**: `atomic_uint` for thread-safe match counting
- **Line Start Tracking**: `find_line_start()` for result metadata

**Vulkan Shader (`src/shaders/search.comp`)**:

- **uvec4 SIMD**: 16-byte vectorized comparison via `match_uvec4()`
- **Packed Word Access**: `get_text_word_at()` handles unaligned 4-byte reads
- **Workgroup Size**: 256 threads per workgroup (`local_size_x = 256`)
- **Chunked Dispatch**: `(text_len / 64) / 256` workgroups for efficient parallelism

### Auto-Selection Algorithm

The `e_jerk_gpu` library scores workloads based on:

- **Data Size**: Minimum 32-256KB depending on GPU tier
- **Compute Intensity**: Pattern length and case-sensitivity increase GPU advantage
- **Hardware Tier**: Ultra/High/Mid/Entry classification affects thresholds
- **GPU Bias**: +4 for ultra-tier, -2 for entry-tier hardware

## Performance

| Workload | CPU | GPU | Speedup |
|----------|-----|-----|---------|
| Single character patterns | 128 MB/s | 2.2 GB/s | **17.4x** |
| Case-insensitive (`-i`) | 223 MB/s | 2.5 GB/s | **11.0x** |
| Word boundary (`-w`) | 482 MB/s | 3.8 GB/s | **8.0x** |
| Common words (`the`) | 335 MB/s | 2.4 GB/s | **7.2x** |
| Long patterns (8+ chars) | 1.3 GB/s | 3.7 GB/s | **2.7x** |
| Sparse matches | 3.9 GB/s | 6.3 GB/s | **1.6x** |

*Results measured on Apple M1 Max with 50MB test files.*

## Requirements

- **macOS**: Metal support (built-in), optional MoltenVK for Vulkan
- **Linux**: Vulkan runtime (`libvulkan1`)
- **Build**: Zig 0.15.2+, glslc (Vulkan shader compiler)

## Building from Source

```bash
zig build -Doptimize=ReleaseFast

# Run tests
zig build test      # Unit tests
zig build smoke     # Integration tests (GPU verification)
zig build bench     # Benchmarks
bash gnu-tests.sh   # GNU compatibility tests (42 tests)
```

## Recent Changes

- **GPU Regex Support**: Native Thompson NFA regex execution on Metal and Vulkan GPUs for `-E` extended regex patterns
- **Context Lines**: Native `-A`, `-B`, `-C` support with proper group separators
- **Recursive Search**: Native `-r` flag with combined options (`-rn`, `-ri`, `-rc`, `-rl`)
- **Color Output**: Native `--color` support with ANSI highlighting
- **Test Coverage**: 42 GNU compatibility tests passing

## License

Source code: [Unlicense](LICENSE) (public domain)
Binaries: GPL-3.0-or-later
