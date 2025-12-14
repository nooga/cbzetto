<div align="center">
  <img src="resources/icon.png" alt="CBZetto" width="128" height="128">

# CBZetto

**Like Alacritty, but for CBZ files.**

A stupid-fast, minimal CBZ reader for macOS — written in Zig and powered by Raylib.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.13.0-orange.svg)](https://ziglang.org/)
[![macOS](https://img.shields.io/badge/macOS-14+_Apple_Silicon-black.svg)](https://www.apple.com/macos/)

</div>

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
| `H`, `F1`, `?`        | Show help               |
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

Or, `zig build run` to run the app directly from source.

## How it works (high level)

The whole app is basically “one tall scroll surface” made of page textures, with aggressive lazy loading.

- **Scan + index CBZ(s)** (`src/main.zig`: `loadPath`, `loadFolder`, `loadCBZ`)
  - Opens the `.cbz` as a ZIP, collects image entry names (`.jpg/.jpeg/.png`), sorts them, and stores _only_ the filenames initially.
  - Keeps the ZIP file handle open so pages can be extracted on demand.
- **Layout is based on known (or guessed) page sizes** (`src/main.zig`: `updateCumulative`)
  - Each page has a “display height” computed from the window width and the page’s aspect ratio.
  - Until an image is decoded, pages start with default dimensions and get corrected once the real size is known.
- **Rendering is just a loop that draws each loaded texture** (`src/main.zig`: `renderPages`)
  - Pages are drawn top-to-bottom at their accumulated Y offsets using `DrawTexturePro`.
  - Scrolling/zooming is just `Camera2D` target/zoom changes (`updateCamera`).
- **Lazy loading is driven by the current scroll position** (`src/main.zig`: `updateLazyLoading`)
  - Computes the visible page range (plus a small buffer), requests loads for nearby pages, and unloads textures far outside the buffer to cap GPU memory.
  - There’s also a small synchronous “visible pages” fallback if background work lags.
- **Background decoding happens off-thread** (`src/image_loader.zig`)
  - A worker thread pulls prioritized requests, extracts image bytes from the ZIP, decodes them via raylib, and returns raw pixel buffers.
  - The main thread converts those pixels into GPU textures (`src/main.zig`: `processBackgroundResults`) because GPU uploads must happen on the render thread.
  - Note: the loader contains logic for downsampling and “extra-tall image slicing”; the current renderer stores **one** texture per page, so slicing is currently more “future work” than a complete feature.
- **State persistence** (`src/main.zig`: `saveState`, `loadState`)
  - Writes `.cbzviewer_state.json` into the opened folder (page number + in-page progress + zoom + window geometry + background color).
  - Saved on idle (dynamic FPS drop), on exit, and on SIGINT/SIGTERM.
- **macOS glue** (`src/macos_wrapper.zig`)
  - Uses the Obj‑C runtime to show an `NSOpenPanel`, add a basic menu bar (“Open…”), and install a native pinch recognizer.
  - Pinch deltas are accumulated in the wrapper and consumed once per frame (`consumeMagnifyDelta`) in `handleInput`.

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
