#!/bin/bash
#
# Epilog Zing Driver Uninstaller
#
# This script removes the Epilog Zing printer driver from your system.
#

set -e

echo "=== Epilog Zing Driver Uninstaller ==="
echo ""

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "This script requires administrator privileges."
    echo "Please run: sudo $0"
    exit 1
fi

# Remove any Epilog printers from CUPS
echo "Removing Epilog printers from CUPS..."
for printer in $(lpstat -p 2>/dev/null | grep -i epilog | awk '{print $2}'); do
    echo "  Removing printer: $printer"
    lpadmin -x "$printer" 2>/dev/null || true
done

# Remove filter
echo "Removing CUPS filter..."
rm -f /Library/Printers/Epilog/Filters/rastertoepiloz
rm -f /usr/libexec/cups/filter/rastertoepiloz

# Remove PPD files
echo "Removing PPD files..."
rm -f /Library/Printers/PPDs/Contents/Resources/EpilogZing16.ppd
rm -f /Library/Printers/PPDs/Contents/Resources/EpilogZing24.ppd

# Remove the application
echo "Removing Epilog Studio..."
rm -rf "/Applications/Epilog Studio.app"

# Settings live in the user's own preferences, not here. Left alone
# deliberately: reinstalling should not lose the machine address, and anyone
# who truly wants them gone can delete them.
echo "  (Preferences and saved jobs are left where they are.)"

# Remove directories if empty
rmdir /Library/Printers/Epilog/Filters 2>/dev/null || true
rmdir /Library/Printers/Epilog 2>/dev/null || true

# Forget package receipt
echo "Removing package receipt..."
pkgutil --forget com.epilog.driver 2>/dev/null || true

echo ""
echo "=== Uninstallation Complete ==="
echo ""
echo "The Epilog Zing driver has been removed from your system."
