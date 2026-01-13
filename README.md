# GPU-Accelerated Grep

A high-performance `grep` replacement that uses GPU acceleration via Metal (macOS) and Vulkan for blazing-fast text searches.

## Features

- **GPU-Accelerated Search**: Parallel pattern matching on Metal and Vulkan compute shaders
- **SIMD-Optimized CPU**: Vectorized Boyer-Moore-Horspool with 16/32-byte SIMD operations
- **Auto-Selection**: Intelligent backend selection based on file size, pattern complexity, and hardware tier
- **GNU Compatible**: Supports common grep flags (`-i`, `-w`, `-v`, `-F`)

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

# Force specific backend
grep --gpu "TODO" *.py
grep --metal "FIXME" src/
grep --vulkan "BUG" lib/
grep --cpu "pattern" file.txt

# Verbose output showing timing and backend info
grep -V "pattern" largefile.txt
```

## Options

| Flag | Description |
|------|-------------|
| `-i, --ignore-case` | Case-insensitive matching |
| `-w, --word-regexp` | Match whole words only |
| `-v, --invert-match` | Invert match (show non-matching lines) |
| `-F, --fixed-strings` | Treat pattern as fixed string |
| `-V, --verbose` | Show timing and backend information |

## Backend Selection

| Flag | Description |
|------|-------------|
| `--auto` | Automatically select optimal backend (default) |
| `--gpu` | Use GPU (Metal on macOS, Vulkan elsewhere) |
| `--cpu` | Force CPU backend |
| `--metal` | Force Metal backend (macOS only) |
| `--vulkan` | Force Vulkan backend |

## Architecture & Optimizations

### CPU Implementation (`src/cpu.zig`)

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

**Word Boundary Detection**:
- `checkWordBoundary()`: Validates alphanumeric/underscore boundaries
- `isWordChar()`: Inline character classification

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

| Workload | GPU Speedup |
|----------|-------------|
| Single character patterns | ~10-15x |
| Case-insensitive (`-i`) | ~8x |
| Word boundary (`-w`) | ~7x |
| Short patterns (2-4 chars) | ~5x |
| Long patterns (8+ chars) | ~2x |

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
zig build smoke     # Integration tests
zig build bench     # Benchmarks
```

## License

Source code: [Unlicense](LICENSE) (public domain)
Binaries: GPL-3.0-or-later
