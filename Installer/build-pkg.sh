#!/bin/bash
#
# build-pkg.sh - Build the Epilog Zing driver installer package
#
# This script creates a proper macOS installer package (.pkg) with
# a nice GUI installer experience.
#
# Usage:
#   ./build-pkg.sh           # Build unsigned package
#   ./build-pkg.sh --sign    # Build signed package (requires Apple Developer certs)
#
# Environment variables for signing:
#   APPLE_TEAM_ID          - Your Apple Developer Team ID
#   SIGNING_IDENTITY_APP   - Developer ID Application identity (optional, auto-detected)
#   SIGNING_IDENTITY_PKG   - Developer ID Installer identity (optional, auto-detected)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
# Universal binaries are placed in apple/Products/Release
RELEASE_DIR="$BUILD_DIR/apple/Products/Release"
PKG_DIR="$BUILD_DIR/pkg"
STAGING_DIR="$BUILD_DIR/staging"
RESOURCES_DIR="$BUILD_DIR/resources"

VERSION="1.0.0"
PRODUCT_NAME="EpilogDriver"
IDENTIFIER="com.epilog.driver"

# Installation paths
FILTER_DIR="/Library/Printers/Epilog/Filters"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
BACKEND_DIR="/usr/libexec/cups/backend"

# Parse command line arguments
SIGN_PACKAGE=false
for arg in "$@"; do
    case $arg in
        --sign)
            SIGN_PACKAGE=true
            shift
            ;;
    esac
done

# Set up signing identities
if [ "$SIGN_PACKAGE" = true ]; then
    # Use provided identity or find one automatically
    if [ -z "$SIGNING_IDENTITY_APP" ]; then
        SIGNING_IDENTITY_APP="Developer ID Application"
    fi
    if [ -z "$SIGNING_IDENTITY_PKG" ]; then
        SIGNING_IDENTITY_PKG="Developer ID Installer"
    fi
fi

echo "=== Building Epilog Zing Driver Installer ==="
if [ "$SIGN_PACKAGE" = true ]; then
    echo "Mode: SIGNED (Apple Developer ID)"
else
    echo "Mode: Unsigned"
fi
echo ""

# Step 1: Build release binaries
echo "Step 1: Building release binaries..."
cd "$PROJECT_DIR"

# Check if binaries already exist (for CI)
if [ -f "$RELEASE_DIR/rastertoepiloz" ] && [ -f "$RELEASE_DIR/epilog-usb" ]; then
    echo "  Binaries already exist at $RELEASE_DIR/"
elif [ -f "$BUILD_DIR/release/rastertoepiloz" ] && [ -f "$BUILD_DIR/release/epilog-usb" ]; then
    echo "  Binaries found at $BUILD_DIR/release/"
    mkdir -p "$RELEASE_DIR"
    cp "$BUILD_DIR/release/rastertoepiloz" "$RELEASE_DIR/"
    cp "$BUILD_DIR/release/epilog-usb" "$RELEASE_DIR/"
else
    # Build universal binary if possible, fallback to single arch
    if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
        echo "  Built universal binaries."
    else
        echo "  Universal build failed, building native..."
        swift build -c release
        mkdir -p "$RELEASE_DIR"
        cp "$BUILD_DIR/release/rastertoepiloz" "$RELEASE_DIR/"
        cp "$BUILD_DIR/release/epilog-usb" "$RELEASE_DIR/"
    fi
fi
echo "  Done."
echo ""

# Step 2: Create staging directory
echo "Step 2: Creating staging directory..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR$FILTER_DIR"
mkdir -p "$STAGING_DIR$PPD_DIR"
mkdir -p "$STAGING_DIR$BACKEND_DIR"
mkdir -p "$STAGING_DIR/Library/Printers/Epilog"

cp "$RELEASE_DIR/rastertoepiloz" "$STAGING_DIR$FILTER_DIR/"
cp "$RELEASE_DIR/epilog-usb" "$STAGING_DIR$BACKEND_DIR/"
cp "$PROJECT_DIR/PPD/"*.ppd "$STAGING_DIR$PPD_DIR/"
cp "$SCRIPT_DIR/Uninstall Epilog Driver.command" "$STAGING_DIR/Library/Printers/Epilog/"

chmod 755 "$STAGING_DIR$FILTER_DIR/rastertoepiloz"
chmod 755 "$STAGING_DIR$BACKEND_DIR/epilog-usb"
chmod 644 "$STAGING_DIR$PPD_DIR/"*.ppd
chmod 755 "$STAGING_DIR/Library/Printers/Epilog/Uninstall Epilog Driver.command"

# Sign the binary if signing is enabled
if [ "$SIGN_PACKAGE" = true ]; then
    echo "  Signing binary with Developer ID..."
    codesign --force --options runtime \
        --sign "$SIGNING_IDENTITY_APP" \
        --timestamp \
        "$STAGING_DIR$FILTER_DIR/rastertoepiloz"
    echo "  Binary signed."
fi
echo "  Done."
echo ""

# Step 3: Create resources directory for installer UI
echo "Step 3: Preparing installer resources..."
rm -rf "$RESOURCES_DIR"
mkdir -p "$RESOURCES_DIR"
cp "$SCRIPT_DIR/welcome.html" "$RESOURCES_DIR/"
cp "$SCRIPT_DIR/readme.html" "$RESOURCES_DIR/"
cp "$SCRIPT_DIR/conclusion.html" "$RESOURCES_DIR/"
echo "  Done."
echo ""

# Step 4: Create component package
echo "Step 4: Creating component package..."
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

if [ "$SIGN_PACKAGE" = true ]; then
    pkgbuild \
        --root "$STAGING_DIR" \
        --identifier "$IDENTIFIER" \
        --version "$VERSION" \
        --scripts "$SCRIPT_DIR" \
        --sign "$SIGNING_IDENTITY_PKG" \
        --timestamp \
        "$PKG_DIR/$PRODUCT_NAME.pkg"
    echo "  Component package signed."
else
    pkgbuild \
        --root "$STAGING_DIR" \
        --identifier "$IDENTIFIER" \
        --version "$VERSION" \
        --scripts "$SCRIPT_DIR" \
        "$PKG_DIR/$PRODUCT_NAME.pkg"
fi
echo "  Done."
echo ""

# Step 5: Create product archive with Distribution.xml
echo "Step 5: Creating product archive..."

# Update Distribution.xml with correct package reference
cat > "$PKG_DIR/Distribution.xml" << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Epilog Zing Laser Printer Driver</title>
    <organization>com.epilog</organization>
    <domains enable_localSystem="true"/>
    <options customize="never" require-scripts="true" rootVolumeOnly="true"/>

    <volume-check>
        <allowed-os-versions>
            <os-version min="10.15"/>
        </allowed-os-versions>
    </volume-check>

    <welcome file="welcome.html" mime-type="text/html"/>
    <readme file="readme.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>

    <choices-outline>
        <line choice="default">
            <line choice="com.epilog.driver"/>
        </line>
    </choices-outline>

    <choice id="default"/>
    <choice id="com.epilog.driver" visible="false" title="Epilog Zing Driver">
        <pkg-ref id="com.epilog.driver"/>
    </choice>

    <pkg-ref id="com.epilog.driver" version="1.0.0" onConclusion="none">EpilogDriver.pkg</pkg-ref>
</installer-gui-script>
EOF

if [ "$SIGN_PACKAGE" = true ]; then
    # Create unsigned product first, then sign it
    productbuild \
        --distribution "$PKG_DIR/Distribution.xml" \
        --resources "$RESOURCES_DIR" \
        --package-path "$PKG_DIR" \
        "$PKG_DIR/$PRODUCT_NAME-$VERSION-unsigned.pkg"

    # Sign the final product
    productsign \
        --sign "$SIGNING_IDENTITY_PKG" \
        --timestamp \
        "$PKG_DIR/$PRODUCT_NAME-$VERSION-unsigned.pkg" \
        "$PKG_DIR/$PRODUCT_NAME-$VERSION.pkg"

    rm -f "$PKG_DIR/$PRODUCT_NAME-$VERSION-unsigned.pkg"
    echo "  Product archive signed."
else
    productbuild \
        --distribution "$PKG_DIR/Distribution.xml" \
        --resources "$RESOURCES_DIR" \
        --package-path "$PKG_DIR" \
        "$PKG_DIR/$PRODUCT_NAME-$VERSION.pkg"
fi

echo "  Done."
echo ""

# Cleanup intermediate files
rm -f "$PKG_DIR/Distribution.xml"
rm -f "$PKG_DIR/$PRODUCT_NAME.pkg"

echo "=== Build Complete ==="
echo ""
echo "Installer package created:"
echo "  $PKG_DIR/$PRODUCT_NAME-$VERSION.pkg"
if [ "$SIGN_PACKAGE" = true ]; then
    echo ""
    echo "Package is SIGNED with Apple Developer ID."
    echo "Next step: Notarize with 'xcrun notarytool submit'"
fi
echo ""
echo "To install, double-click the package or run:"
echo "  sudo installer -pkg '$PKG_DIR/$PRODUCT_NAME-$VERSION.pkg' -target /"
echo ""
