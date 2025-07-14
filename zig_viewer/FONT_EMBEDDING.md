# Font Embedding for CBZ Viewer

This CBZ viewer uses an embedded JetBrains Mono font to ensure consistent typography without requiring external font files during distribution.

## How It Works

The font is embedded directly into the binary using raylib's `LoadFontFromMemory()` function. This approach:

- ✅ Eliminates the need to distribute font files separately
- ✅ Ensures consistent appearance across different systems
- ✅ Reduces deployment complexity
- ✅ Works even when system fonts are unavailable

## Files Involved

- `src/embedded_font_data.zig` - Generated Zig file containing the font data as a byte array
- `src/embedded_font.zig` - Wrapper module that loads the embedded font using raylib
- `embed_font.sh` - Script to regenerate the embedded font data

## Regenerating the Embedded Font

If you want to update the font or use a different font file:

1. Replace `fonts/ttf/JetBrainsMono-Regular.ttf` with your desired font
2. Run the embedding script:
   ```bash
   ./embed_font.sh
   ```
3. Rebuild the project:
   ```bash
   zig build
   ```

## Technical Details

- **Font**: JetBrains Mono Regular (273,900 bytes)
- **Format**: TTF embedded as Zig byte array
- **Loading**: Uses `rl.LoadFontFromMemory()` with `.ttf` type
- **Fallback**: Falls back to external file, then default font if embedding fails

## License Compliance

JetBrains Mono is licensed under the Apache 2.0 License, which allows:

- ✅ Commercial use
- ✅ Distribution
- ✅ Modification
- ✅ Private use

The embedded font maintains full license compliance.

## Distribution

When distributing your CBZ viewer:

- ✅ No need to include the `fonts/` directory
- ✅ Single binary distribution
- ✅ No external font dependencies
- ✅ Consistent appearance across all systems
