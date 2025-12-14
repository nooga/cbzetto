<div align="center">
  <img src="resources/icon.png" alt="CBZetto" width="128" height="128">

# CBZetto

**Like Alacritty, but for CBZ files.**

A stupid-fast, minimal CBZ reader for macOS — written in Zig and powered by Raylib.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.13.0-orange.svg)](https://ziglang.org/)
[![macOS](https://img.shields.io/badge/macOS-10.12+-black.svg)](https://www.apple.com/macos/)

</div>

---

Built out of pure spite for slow manga viewers and an unhealthy obsession with scroll performance.

CBZetto does one thing — scroll _HUGE_ comics quickly.

## Features

- **GPU-accelerated** — Smooth 60fps scrolling, always
- **Background threaded** — Images load while you scroll, no stutters
- **Smart memory** — Lazy loading keeps RAM under ~200MB
- **Instant wake** — Zero input lag, even from idle
- **Native trackpad** — Pinch-to-zoom via macOS gesture recognizer
- **State persistence** — Remembers your position per-file
- **Minimal UI** — No chrome, no distractions

## Keyboard Shortcuts

| Key                   | Action                  |
| --------------------- | ----------------------- |
| `↑` `↓`               | Scroll                  |
| `Page Up` `Page Down` | Jump pages              |
| `Home` `End`          | First/last page         |
| `+` `-` `0`           | Zoom in/out/reset       |
| `Cmd+O`               | Open file/folder        |
| `B`                   | Toggle background color |
| `H`                   | Show help               |
| `Esc` `Q`             | Quit                    |

## Installation

### From Releases

Download the `.dmg` from [Releases](../../releases) and drag to Applications.

### From Source

```bash
# Requires Zig 0.13.0 and Xcode Command Line Tools
zig build run -- /path/to/comics/

# Or build a release .app bundle
./build_release.sh
```

## Usage

CBZetto opens:

1. **A folder with CBZ files** — Shows them in sequence (recommended for series)
2. **A single CBZ file** — Opens that comic

Simply open the app and select a folder or file in the file dialog that appears.

You can also open the app with a folder or file as an argument:

```bash
# Open a folder
open CBZetto.app --args ~/Comics/OnePiece/

# Open a single file
open CBZetto.app --args ~/Comics/chapter-001.cbz
```

Or just double-click any .cbz file after installing.

## Building

The `build_release.sh` script creates a proper macOS app bundle with:

- ReleaseFast optimization
- Stripped debug symbols
- Multi-resolution app icon
- File associations for `.cbz` and `.cbr`
- Notarization-ready `.dmg`

**Key design decisions:**

- **Raylib** for cross-platform OpenGL without the pain
- **Zig's GeneralPurposeAllocator** for predictable memory
- **Native Obj-C runtime calls** for macOS integration (no bridging headers)
- **Dynamic FPS** — 60fps active, 10fps idle, instant wake on input

## Dependencies

- [raylib](https://www.raylib.com/) 5.5 — Graphics and windowing
- macOS Frameworks — CoreFoundation, AppKit, OpenGL

## Why?

Every CBZ reader I tried was either:

- Electron bloat with 500MB RAM for one comic
- Ancient Qt apps that stutter on retina displays
- "Feature-rich" viewers that take ages to open

CBZetto is none of those things.

## License

MIT License — See [LICENSE](LICENSE) for details.
