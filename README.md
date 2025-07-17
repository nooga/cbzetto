<div align="center">
  <img src="resources/icon.png" alt="CBZetto" width="128" height="128">
</div>

# CBZetto

**Like Alacritty, but for CBZ files.**

A stupid-fast, minimal CBZ reader for macOS — written in Zig and powered by Raylib.
Built out of pure spite for slow manga viewers and an unhealthy obsession with scroll performance.

CBZetto does one thing — scroll _HUGE_ comics quickly.

## Features

🚀 **GPU-accelerated** - Smooth like buttered shame  
🧵 **Background threaded** - No stutters, ever  
🧠 **Smart memory** - ~200MB RAM usage max  
🧼 **Minimal UI** - No clutter, no nonsense  
🍎 **Native macOS** - Proper app bundle with file associations

## Requirements

- **Zig** 0.13.0
- **macOS** 10.12 or later
- **Xcode Command Line Tools**
- **raylib** 4.5.0+

## Usage

CBZetto opens:

1. **A folder with CBZ files** → Shows them in order (recommended)
2. **A single CBZ file** → Opens that comic

```bash
# Development
zig build run -- /path/to/folder/with/cbz/files

# Release build
./build_release.sh
open CBZetto.app --args /path/to/comics/
```

Hit `h` for help once it's running.

## Building

If you're one of the 7 people on Earth writing Zig apps for fun, you already know:

```bash
zig build run -- /path/to/comics/
```

Everyone else: just use the `.dmg` from releases.

The `build_release.sh` script creates a proper macOS app bundle with:

- ReleaseFast optimization
- Stripped debug symbols
- Multi-resolution app icon
- File associations for CBZ/CBR
- Distribution packages

## Dependencies

- **raylib** - For not sucking at graphics
- **macOS Frameworks** - CoreFoundation, AppKit, OpenGL

Managed by Zig's package system via `build.zig.zon`.

## Disclaimer

Despite what the icon might suggest, CBZetto:

- Works with any CBZ file
- Does not come with manga preloaded
- Will absolutely remember what you were reading if someone walks in
