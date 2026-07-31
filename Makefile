# Makefile for Epilog Zing macOS Printer Driver
#
# Builds universal binaries and creates installer package

PRODUCT_NAME = EpilogDriver
VERSION = 1.0.0
BUILD_DIR = .build/apple/Products/Release
STAGING_DIR = .build/staging
PKG_DIR = .build/pkg

# Installation paths
FILTER_DIR = /Library/Printers/Epilog/Filters
PPD_DIR = /Library/Printers/PPDs/Contents/Resources

# Executables
FILTER = rastertoepiloz

.PHONY: all build release install uninstall clean package staging

all: build

# Build for debugging
build:
	swift build

# Build universal release binaries (arm64 + x86_64)
release:
	swift build -c release --arch arm64 --arch x86_64

# Create staging directory with all files
staging: release
	@echo "Creating staging directory..."
	rm -rf $(STAGING_DIR)
	mkdir -p $(STAGING_DIR)$(FILTER_DIR)
	mkdir -p $(STAGING_DIR)$(PPD_DIR)

	# Copy filter executable
	cp $(BUILD_DIR)/$(FILTER) $(STAGING_DIR)$(FILTER_DIR)/

	# Copy PPD files
	cp PPD/*.ppd $(STAGING_DIR)$(PPD_DIR)/

	# Set permissions
	chmod 755 $(STAGING_DIR)$(FILTER_DIR)/$(FILTER)
	chmod 644 $(STAGING_DIR)$(PPD_DIR)/*.ppd

	@echo "Staging complete."

# Build installer package
#
# Delegates to the installer script rather than repeating it here. The two had
# already drifted: this target used to stage only the filter and the PPDs,
# leaving out the application, the USB backend and the uninstaller.
package:
	./Installer/build-pkg.sh

# Build signed installer (requires Developer ID)
package-signed: staging
	@echo "Building signed installer package..."
	rm -rf $(PKG_DIR)
	mkdir -p $(PKG_DIR)

	pkgbuild \
		--root $(STAGING_DIR) \
		--identifier com.epilog.driver \
		--version $(VERSION) \
		--scripts Installer \
		--sign "Developer ID Installer" \
		$(PKG_DIR)/$(PRODUCT_NAME)-$(VERSION).pkg

	@echo "Signed package created: $(PKG_DIR)/$(PRODUCT_NAME)-$(VERSION).pkg"

# Install directly (for development)
install: release
	@echo "Installing Epilog driver..."
	sudo mkdir -p $(FILTER_DIR)
	sudo mkdir -p $(PPD_DIR)

	sudo cp $(BUILD_DIR)/$(FILTER) $(FILTER_DIR)/
	sudo cp PPD/*.ppd $(PPD_DIR)/

	sudo chmod 755 $(FILTER_DIR)/$(FILTER)
	sudo chmod 644 $(PPD_DIR)/EpilogZing*.ppd

	sudo chown root:wheel $(FILTER_DIR)/$(FILTER)
	sudo chown root:wheel $(PPD_DIR)/EpilogZing*.ppd

	@echo "Installation complete."
	@echo ""
	@echo "To add the printer:"
	@echo "  1. System Preferences > Printers & Scanners > + > IP tab"
	@echo "  2. Address: 192.168.3.4 (or your laser's IP)"
	@echo "  3. Protocol: Line Printer Daemon - LPD"
	@echo "  4. Use: Select 'Epilog Zing 16' or 'Epilog Zing 24'"
	@echo ""
	@echo "Or via command line:"
	@echo "  lpadmin -p EpilogZing -E -v lpd://192.168.3.4 -P $(PPD_DIR)/EpilogZing16.ppd"

# Uninstall
uninstall:
	@echo "Uninstalling Epilog driver..."
	sudo rm -f $(FILTER_DIR)/$(FILTER)
	sudo rm -f $(PPD_DIR)/EpilogZing16.ppd
	sudo rm -f $(PPD_DIR)/EpilogZing24.ppd
	-sudo rmdir $(FILTER_DIR) 2>/dev/null || true
	-sudo rmdir /Library/Printers/Epilog 2>/dev/null || true
	@echo "Uninstallation complete."

# Clean build artifacts
clean:
	swift package clean
	rm -rf $(STAGING_DIR)
	rm -rf $(PKG_DIR)

# Run tests
test:
	swift test

# Show help
help:
	@echo "Epilog Zing macOS Printer Driver"
	@echo ""
	@echo "Targets:"
	@echo "  build     - Build for debugging"
	@echo "  release   - Build universal release binaries"
	@echo "  install   - Install driver to system (requires sudo)"
	@echo "  uninstall - Remove driver from system (requires sudo)"
	@echo "  package   - Create installer .pkg"
	@echo "  clean     - Remove build artifacts"
	@echo "  test      - Run unit tests"
	@echo "  help      - Show this help"
