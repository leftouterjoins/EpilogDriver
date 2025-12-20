#!/bin/bash
#
# Epilog Zing Driver Uninstaller
#
# Double-click this file to uninstall the Epilog Zing printer driver.
# You will be prompted for your administrator password.
#

# Change to a safe directory (user's home)
cd ~

# Clear the screen and show a nice header
clear
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Epilog Zing Driver Uninstaller                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "This will remove the Epilog Zing printer driver from your Mac."
echo ""

# Ask for confirmation
read -p "Do you want to continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Uninstall cancelled."
    echo ""
    read -p "Press Enter to close this window..."
    exit 0
fi

echo ""
echo "Administrator privileges are required to uninstall."
echo ""

# Run the uninstall commands with sudo (will prompt for password)
sudo bash << 'UNINSTALL_SCRIPT'
set -e

echo "Removing Epilog printers from CUPS..."
for printer in $(lpstat -p 2>/dev/null | grep -i epilog | awk '{print $2}'); do
    echo "  Removing printer: $printer"
    lpadmin -x "$printer" 2>/dev/null || true
done

echo "Removing CUPS filter..."
rm -f /Library/Printers/Epilog/Filters/rastertoepiloz
rm -f /usr/libexec/cups/filter/rastertoepiloz

echo "Removing USB backend..."
rm -f /usr/libexec/cups/backend/epilog-usb

echo "Removing PPD files..."
rm -f /Library/Printers/PPDs/Contents/Resources/EpilogZing16.ppd
rm -f /Library/Printers/PPDs/Contents/Resources/EpilogZing24.ppd

echo "Removing uninstaller..."
rm -f "/Library/Printers/Epilog/Uninstall Epilog Driver.command"

echo "Cleaning up directories..."
rmdir /Library/Printers/Epilog/Filters 2>/dev/null || true
rmdir /Library/Printers/Epilog 2>/dev/null || true

echo "Removing package receipt..."
pkgutil --forget com.epilog.driver 2>/dev/null || true
UNINSTALL_SCRIPT

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Uninstallation Complete!                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "The Epilog Zing driver has been removed from your system."
echo ""
read -p "Press Enter to close this window..."
