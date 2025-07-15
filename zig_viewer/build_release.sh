#!/bin/bash

# CBZT Release Build Script
# Builds an optimized, stripped app bundle for distribution

set -e  # Exit on any error

echo "🚀 Building CBZT for release..."

# Clean previous builds
echo "🧹 Cleaning previous builds..."
rm -rf zig-out/
rm -rf CBZT.app/

# Build with release optimization
echo "⚡ Building optimized binary..."
zig build -Doptimize=ReleaseFast

# Check if build was successful
if [ ! -f "zig-out/bin/cbzt" ]; then
    echo "❌ Build failed!"
    exit 1
fi

echo "📦 Creating app bundle structure..."

# Create app bundle directories
mkdir -p CBZT.app/Contents/MacOS
mkdir -p CBZT.app/Contents/Resources

# Copy the optimized binary
cp zig-out/bin/cbzt CBZT.app/Contents/MacOS/

# Strip debug symbols for smaller size
echo "✂️  Stripping debug symbols..."
strip CBZT.app/Contents/MacOS/cbzt

# Create icon if it doesn't exist
if [ ! -f "CBZT.app/Contents/Resources/icon.icns" ]; then
    echo "🎨 Creating app icon..."
    
    # Check if source icon exists
    if [ ! -f "resources/icon.png" ]; then
        echo "❌ Source icon not found: resources/icon.png"
        exit 1
    fi
    
    # Create iconset directory
    mkdir -p icon.iconset
    
    # Generate different icon sizes
    sips -z 16 16 resources/icon.png --out icon.iconset/icon_16x16.png
    sips -z 32 32 resources/icon.png --out icon.iconset/icon_16x16@2x.png
    sips -z 32 32 resources/icon.png --out icon.iconset/icon_32x32.png
    sips -z 64 64 resources/icon.png --out icon.iconset/icon_32x32@2x.png
    sips -z 128 128 resources/icon.png --out icon.iconset/icon_128x128.png
    sips -z 256 256 resources/icon.png --out icon.iconset/icon_128x128@2x.png
    sips -z 256 256 resources/icon.png --out icon.iconset/icon_256x256.png
    cp resources/icon.png icon.iconset/icon_256x256@2x.png
    cp resources/icon.png icon.iconset/icon_512x512.png
    
    # Convert to ICNS
    iconutil -c icns icon.iconset -o CBZT.app/Contents/Resources/icon.icns
    
    # Clean up
    rm -rf icon.iconset
fi

# Create PkgInfo
echo -n "APPL????" > CBZT.app/Contents/PkgInfo

# Create Info.plist if it doesn't exist
if [ ! -f "CBZT.app/Contents/Info.plist" ]; then
    echo "📝 Creating Info.plist..."
    cat > CBZT.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>cbzt</string>
    <key>CFBundleIdentifier</key>
    <string>com.nooga.cbzt</string>
    <key>CFBundleName</key>
    <string>CBZT</string>
    <key>CFBundleDisplayName</key>
    <string>CBZT</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleIconFile</key>
    <string>icon</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.12</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>cbz</string>
                <string>cbr</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>Comic Book Archive</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.archive</string>
            </array>
        </dict>
    </array>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF
fi

echo "📊 Build summary:"
echo "   Binary size: $(du -h zig-out/bin/cbzt | cut -f1)"
echo "   App bundle size: $(du -sh CBZT.app | cut -f1)"
echo "   Binary location: CBZT.app/Contents/MacOS/cbzt"

# Check if binary is stripped
if nm CBZT.app/Contents/MacOS/cbzt 2>/dev/null | grep -q "main\."; then
    echo "   Debug symbols: Present"
else
    echo "   Debug symbols: Stripped ✓"
fi

# Show dynamic library dependencies
echo ""
echo "📋 Dynamic library dependencies:"
otool -L CBZT.app/Contents/MacOS/cbzt

echo ""
echo "✅ Release build complete!"
echo "🎯 Ready for distribution: CBZT.app"
echo ""

# Ask if user wants to create a distribution package
echo "📦 Create distribution package? (y/n)"
read -r create_package
if [[ $create_package == "y" || $create_package == "Y" ]]; then
    echo "📦 Creating ZIP archive..."
    zip -r CBZT.zip CBZT.app
    echo "📦 Created: CBZT.zip ($(du -h CBZT.zip | cut -f1))"
fi

echo ""
echo "💡 Distribution options:"
echo "   1. Test the app bundle: open CBZT.app"
echo "   2. Archive: zip -r CBZT.zip CBZT.app"
echo "   3. Or create DMG: hdiutil create -volname CBZT -srcfolder CBZT.app -ov -format UDZO CBZT.dmg" 