#!/bin/bash

# Script to embed JetBrains Mono font for distribution
# This eliminates the need to distribute font files separately

set -e

FONT_FILE="fonts/ttf/JetBrainsMono-Regular.ttf"
OUTPUT_ZIG="src/embedded_font_data.zig"

echo "Embedding JetBrains Mono font for distribution..."

# Check if font file exists
if [ ! -f "$FONT_FILE" ]; then
    echo "Error: Font file $FONT_FILE not found!"
    echo "Please run this script from the project root directory."
    exit 1
fi

# Generate Zig file with embedded font data using Python
echo "Converting $FONT_FILE to Zig data..."
python3 -c "
import sys
with open('$FONT_FILE', 'rb') as f:
    data = f.read()
    
with open('$OUTPUT_ZIG', 'w') as f:
    f.write('// Auto-generated embedded font data\n')
    f.write('// JetBrains Mono Regular TTF font\n\n')
    f.write('pub const font_data = [_]u8{\n')
    
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        hex_values = ', '.join(f'0x{b:02x}' for b in chunk)
        f.write(f'    {hex_values},\n')
    
    f.write('};\n\n')
    f.write(f'pub const font_size: usize = {len(data)};\n')
    
print(f'Generated embedded font data: {len(data)} bytes')
"

# Get file size for verification
FONT_SIZE=$(stat -f%z "$FONT_FILE" 2>/dev/null || stat -c%s "$FONT_FILE" 2>/dev/null)
echo "Font embedded successfully!"
echo "Font size: $FONT_SIZE bytes"
echo "Zig file: $OUTPUT_ZIG"

echo ""
echo "The font is now embedded in your binary. You can distribute your"
echo "CBZ viewer without needing to include the fonts/ directory."
echo ""
echo "To build: zig build"
echo "To run: ./zig-out/bin/cbz_viewer <path_to_cbz_folder>" 