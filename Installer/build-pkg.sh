#!/bin/bash
#
# build-pkg.sh - Build the Epilog Zing driver installer package
#
# This script creates a proper macOS installer package (.pkg) with
# a nice GUI installer experience.
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

echo "=== Building Epilog Zing Driver Installer ==="
echo ""

# Step 1: Build release binaries
echo "Step 1: Building universal release binaries..."
cd "$PROJECT_DIR"
swift build -c release --arch arm64 --arch x86_64
echo "  Done."
echo ""

# Step 2: Create staging directory
echo "Step 2: Creating staging directory..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR$FILTER_DIR"
mkdir -p "$STAGING_DIR$PPD_DIR"

cp "$RELEASE_DIR/rastertoepiloz" "$STAGING_DIR$FILTER_DIR/"
cp "$PROJECT_DIR/PPD/"*.ppd "$STAGING_DIR$PPD_DIR/"

chmod 755 "$STAGING_DIR$FILTER_DIR/rastertoepiloz"
chmod 644 "$STAGING_DIR$PPD_DIR/"*.ppd
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

pkgbuild \
    --root "$STAGING_DIR" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --scripts "$SCRIPT_DIR" \
    "$PKG_DIR/$PRODUCT_NAME.pkg"
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

productbuild \
    --distribution "$PKG_DIR/Distribution.xml" \
    --resources "$RESOURCES_DIR" \
    --package-path "$PKG_DIR" \
    "$PKG_DIR/$PRODUCT_NAME-$VERSION.pkg"

echo "  Done."
echo ""

# Cleanup intermediate files
rm -f "$PKG_DIR/Distribution.xml"
rm -f "$PKG_DIR/$PRODUCT_NAME.pkg"

echo "=== Build Complete ==="
echo ""
echo "Installer package created:"
echo "  $PKG_DIR/$PRODUCT_NAME-$VERSION.pkg"
echo ""
echo "To install, double-click the package or run:"
echo "  sudo installer -pkg '$PKG_DIR/$PRODUCT_NAME-$VERSION.pkg' -target /"
echo ""
