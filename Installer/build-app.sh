#!/bin/bash
#
# build-app.sh - Assemble Epilog Studio.app
#
# SwiftPM builds a plain executable. macOS needs it inside a bundle with an
# Info.plist before it counts as an application: a dock icon, a menu bar, the
# ability to open a window, and file associations all come from that.
#
# usage: Installer/build-app.sh [--debug] [--open]

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

CONFIG=release
OPEN_AFTER=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug ;;
        --open)  OPEN_AFTER=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

APP_NAME="Epilog Studio"
BUNDLE_ID="sh.macinjo.epilogstudio"
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Building EpilogStudio ($CONFIG)"
if [ "$CONFIG" = release ]; then
    # Universal, so the same download runs on Intel and Apple silicon.
    swift build -c release --product EpilogStudio \
        --arch arm64 --arch x86_64
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/EpilogStudio"
else
    swift build --product EpilogStudio
    BIN="$(swift build --show-bin-path)/EpilogStudio"
fi

if [ ! -x "$BIN" ]; then
    echo "error: built executable not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EpilogStudio"

# ---- Icon ------------------------------------------------------------------
ICONSET="$BUILD_DIR/EpilogStudio.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
echo "==> Drawing the icon"
swift "$ROOT/tools/make_icon.swift" "$BUILD_DIR/icon-1024.png" 1024
for size in 16 32 64 128 256 512; do
    sips -z $size $size "$BUILD_DIR/icon-1024.png" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$BUILD_DIR/icon-1024.png" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/EpilogStudio.icns"
rm -rf "$ICONSET" "$BUILD_DIR/icon-1024.png"

# ---- Info.plist ------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>EpilogStudio</string>
    <key>CFBundleIconFile</key><string>EpilogStudio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key>
    <string>Unofficial. Not affiliated with or endorsed by Epilog Laser.</string>

    <!-- Sending a job means talking to the laser over the local network. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>Epilog Studio sends jobs to your laser engraver over the local network.</string>

    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Epilog Studio Job</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key>
            <array><string>$BUNDLE_ID.job</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Artwork</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
                <string>public.svg-image</string>
                <string>public.png</string>
                <string>public.jpeg</string>
                <string>public.tiff</string>
            </array>
        </dict>
    </array>

    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>$BUNDLE_ID.job</string>
            <key>UTTypeDescription</key><string>Epilog Studio Job</string>
            <key>UTTypeConformsTo</key><array><string>public.json</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>epilogjob</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

# ---- Signing ---------------------------------------------------------------
# Ad-hoc, which is enough for the app to run locally and for the hardened
# runtime not to complain about an unsigned binary. It is not notarised, so
# Gatekeeper still asks the first time - see the README.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null \
    || echo "    (codesign unavailable; the app will still run)"

# Strip the quarantine flag the build may have inherited.
xattr -cr "$APP" 2>/dev/null || true

echo
echo "Built $APP"
du -sh "$APP" | sed 's/^/    /'

if [ "$OPEN_AFTER" = 1 ]; then
    open "$APP"
fi
