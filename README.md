# Epilog Zing macOS Printer Driver

> **DISCLAIMER:** This is an unofficial, community-developed driver. This project is not affiliated with, endorsed by, or sponsored by Epilog Laser. Use at your own risk. The authors assume no liability for any damage to your equipment, materials, or property. Always follow proper laser safety procedures.

[![CI](https://github.com/leftouterjoins/EpilogDriver/actions/workflows/ci.yml/badge.svg)](https://github.com/leftouterjoins/EpilogDriver/actions/workflows/ci.yml)
[![Release](https://github.com/leftouterjoins/EpilogDriver/actions/workflows/release.yml/badge.svg)](https://github.com/leftouterjoins/EpilogDriver/releases)
[![License: LGPL v3](https://img.shields.io/badge/License-LGPL%20v3-blue.svg)](https://www.gnu.org/licenses/lgpl-3.0)

A native macOS CUPS printer driver for Epilog Zing laser engravers. Print directly to your laser cutter from any macOS application.

> **Note:** This project is a Swift port of the Epilog driver from [LibLaserCut](https://github.com/t-oster/LibLaserCut), originally written in Java by Thomas Oster and contributors.

## Features

- **Raster Engraving** - Standard bitmap engraving with adjustable power and speed
- **3D Greyscale Engraving** - Variable-depth engraving using 8-bit greyscale power modulation
- **Vector Cutting** - HPGL vector path support for cutting operations
- **Multiple Resolutions** - 100, 200, 250, 400, 500, and 1000 DPI
- **Universal Binary** - Native support for Apple Silicon (M1/M2/M3) and Intel Macs

## Supported Models

| Model | Engraving Area |
|-------|----------------|
| Epilog Zing 16 | 16" x 12" (406 x 305 mm) |
| Epilog Zing 24 | 24" x 12" (610 x 305 mm) |

## Installation

### From Release (Recommended)

1. Download the latest `.pkg` installer from [Releases](https://github.com/leftouterjoins/EpilogDriver/releases)
2. Double-click to run the installer
3. Follow the on-screen instructions

### From Source

```bash
# Clone the repository
git clone https://github.com/leftouterjoins/EpilogDriver.git
cd EpilogDriver

# Build and install
make release
sudo make install
```

## Adding the Printer

After installation, add your Epilog Zing:

### Via System Settings (GUI)

1. Open **System Settings** → **Printers & Scanners**
2. Click **+** to add a printer
3. Select the **IP** tab
4. Configure:
   - **Address:** Your laser's IP (default: `192.168.3.4`)
   - **Protocol:** Line Printer Daemon - LPD
   - **Queue:** (leave empty)
   - **Name:** Epilog Zing
   - **Use:** Select "Epilog Zing 16" or "Epilog Zing 24"

### Via Command Line

```bash
lpadmin -p "Epilog-Zing" -E \
  -v lpd://192.168.3.4 \
  -P /Library/Printers/PPDs/Contents/Resources/EpilogZing16.ppd \
  -D "Epilog Zing 16"
```

## Print Settings

When printing, you can adjust these settings in the print dialog:

| Setting | Range | Description |
|---------|-------|-------------|
| Resolution | 100-1000 DPI | Higher = finer detail, slower |
| Raster Power | 1-100% | Laser power for engraving |
| Raster Speed | 1-100% | Head movement speed |
| Raster Mode | Standard/3D | 1-bit bitmap or 8-bit greyscale |
| Vector Power | 0-100% | Laser power for cutting |
| Vector Speed | 1-100% | Cutting speed |
| Vector Frequency | 500-5000 Hz | Pulse frequency |

### 3D Greyscale Engraving

Select "3D Greyscale (8-bit)" raster mode for variable-depth engraving. Darker areas receive more power, creating depth variation in the material.

## Network Setup

- Default Epilog IP: `192.168.3.4`
- Protocol: LPD (Line Printer Daemon)
- Port: 515
- Ensure your Mac and laser are on the same network

## Building

### Requirements

- macOS 12.0 or later
- Xcode Command Line Tools
- Swift 5.9+

### Commands

```bash
# Debug build
make build

# Release build (universal binary)
make release

# Run tests
make test

# Build installer package
make package

# Install to system
sudo make install

# Uninstall
sudo make uninstall
```

## Project Structure

```
EpilogDriver/
├── Sources/
│   ├── RasterToEpilog/     # CUPS filter
│   │   ├── main.swift
│   │   ├── EpilogJob.swift
│   │   ├── RasterEncoder.swift
│   │   ├── VectorEncoder.swift
│   │   └── ...
│   └── CUPSBridge/         # C bridging for CUPS
├── PPD/                    # Printer description files
├── Installer/              # Package installer scripts
├── Tests/                  # Unit tests
└── Makefile
```

## Uninstalling

To remove the driver from your system:

1. Open Finder
2. Press **Cmd+Shift+G** to open "Go to Folder"
3. Enter: `/Library/Printers/Epilog`
4. Double-click **"Uninstall Epilog Driver.command"**
5. Follow the prompts (you'll be asked for your password)

Or via Terminal:

```bash
open "/Library/Printers/Epilog/Uninstall Epilog Driver.command"
```

## Troubleshooting

### Printer not responding
- Verify network connectivity: `ping 192.168.3.4`
- Check port 515 is accessible
- Ensure laser is powered on and connected

### View CUPS logs
```bash
tail -f /var/log/cups/error_log
```

### Test filter directly
```bash
# Test with a PDF file
cupsfilter -p /Library/Printers/PPDs/Contents/Resources/EpilogZing16.ppd \
  -m application/vnd.cups-raster test.pdf > output.prn
```

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

LGPL-3.0 - see [LICENSE](LICENSE) for details.

This project is a derivative work of [LibLaserCut](https://github.com/t-oster/LibLaserCut) and is licensed under the same terms.

## Acknowledgments

- Based on [VisiCut's LibLaserCut](https://github.com/t-oster/LibLaserCut) Epilog driver by Thomas Oster
- Uses Apple's CUPS printing system

## Related Projects

- [VisiCut](https://github.com/t-oster/VisiCut) - Laser cutter control software
- [LibLaserCut](https://github.com/t-oster/LibLaserCut) - Java library for laser cutters
