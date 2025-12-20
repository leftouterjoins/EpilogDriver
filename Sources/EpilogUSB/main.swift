/*
 * epilog-usb - CUPS USB backend for Epilog laser engravers
 *
 * This backend enables USB printing to Epilog laser cutters.
 * Epilog USB Vendor ID: 0x1453
 *
 * CUPS backend protocol:
 * - No arguments: List available devices (discovery mode)
 * - With arguments: job-id user title copies options [file]
 *
 * Device URI format: epilog-usb://serial?serial=XXXXX
 */

import Foundation
import IOKit
import IOKit.usb

// MARK: - IOKit UUID Constants (not available in Swift)

// kIOCFPlugInInterfaceID: C244E858-109C-11D4-91D4-0050E4C6426F
let kIOCFPlugInInterfaceIDBytes: [UInt8] = [
    0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
    0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F
]

// kIOUSBDeviceUserClientTypeID: 9DC7B780-9EC0-11D4-A54F-000A27052861
let kIOUSBDeviceUserClientTypeIDBytes: [UInt8] = [
    0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
    0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61
]

// kIOUSBDeviceInterfaceID300: 396104F7-943D-4893-90F1-69BD6CF5C2EB
let kIOUSBDeviceInterfaceID300Bytes: [UInt8] = [
    0x39, 0x61, 0x04, 0xF7, 0x94, 0x3D, 0x48, 0x93,
    0x90, 0xF1, 0x69, 0xBD, 0x6C, 0xF5, 0xC2, 0xEB
]

// kIOUSBInterfaceUserClientTypeID: 2D9786C6-9EF3-11D4-AD51-000A27052861
let kIOUSBInterfaceUserClientTypeIDBytes: [UInt8] = [
    0x2D, 0x97, 0x86, 0xC6, 0x9E, 0xF3, 0x11, 0xD4,
    0xAD, 0x51, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61
]

// kIOUSBInterfaceInterfaceID300: BCEAADDC-884D-4F27-8340-36D69FAB90F6
let kIOUSBInterfaceInterfaceID300Bytes: [UInt8] = [
    0xBC, 0xEA, 0xAD, 0xDC, 0x88, 0x4D, 0x4F, 0x27,
    0x83, 0x40, 0x36, 0xD6, 0x9F, 0xAB, 0x90, 0xF6
]

func makeUUID(from bytes: [UInt8]) -> CFUUID {
    return CFUUIDGetConstantUUIDWithBytes(
        nil,
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

// Epilog USB identifiers
let EPILOG_VENDOR_ID: UInt16 = 0x1453

// Known Epilog product IDs (add more as discovered)
let EPILOG_PRODUCT_IDS: [UInt16: String] = [
    0x4001: "Zing 16",
    0x4002: "Zing 24",
    0x4003: "Mini 18",
    0x4004: "Mini 24",
    0x4005: "Helix 24",
    0x4006: "Helix 60",
    0x4007: "Fusion M2 32",
    0x4008: "Fusion M2 40",
    0x4009: "Fusion Pro 32",
    0x400A: "Fusion Pro 48",
]

/// Represents a discovered Epilog USB device
struct EpilogUSBDevice {
    let vendorID: UInt16
    let productID: UInt16
    let serial: String
    let modelName: String
    let locationID: UInt32
}

/// Find all connected Epilog USB devices
func findEpilogDevices() -> [EpilogUSBDevice] {
    var devices: [EpilogUSBDevice] = []

    // Create matching dictionary for USB devices
    guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) else {
        return devices
    }

    var iterator: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)

    guard result == KERN_SUCCESS else {
        return devices
    }

    defer { IOObjectRelease(iterator) }

    var service: io_service_t = IOIteratorNext(iterator)
    while service != 0 {
        defer {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        // Get vendor ID
        var vendorID: UInt16 = 0
        if let vendorRef = IORegistryEntryCreateCFProperty(service, "idVendor" as CFString, kCFAllocatorDefault, 0) {
            vendorID = (vendorRef.takeRetainedValue() as? NSNumber)?.uint16Value ?? 0
        }

        // Skip non-Epilog devices
        guard vendorID == EPILOG_VENDOR_ID else { continue }

        // Get product ID
        var productID: UInt16 = 0
        if let productRef = IORegistryEntryCreateCFProperty(service, "idProduct" as CFString, kCFAllocatorDefault, 0) {
            productID = (productRef.takeRetainedValue() as? NSNumber)?.uint16Value ?? 0
        }

        // Get serial number
        var serial = "Unknown"
        if let serialRef = IORegistryEntryCreateCFProperty(service, "USB Serial Number" as CFString, kCFAllocatorDefault, 0) {
            serial = (serialRef.takeRetainedValue() as? String) ?? "Unknown"
        }

        // Get location ID
        var locationID: UInt32 = 0
        if let locationRef = IORegistryEntryCreateCFProperty(service, "locationID" as CFString, kCFAllocatorDefault, 0) {
            locationID = (locationRef.takeRetainedValue() as? NSNumber)?.uint32Value ?? 0
        }

        // Get model name
        let modelName = EPILOG_PRODUCT_IDS[productID] ?? "Epilog Laser"

        let device = EpilogUSBDevice(
            vendorID: vendorID,
            productID: productID,
            serial: serial,
            modelName: modelName,
            locationID: locationID
        )

        devices.append(device)
        fputs("DEBUG: Found Epilog device: \(modelName) (VID:0x\(String(format: "%04X", vendorID)) PID:0x\(String(format: "%04X", productID)) Serial:\(serial))\n", stderr)
    }

    return devices
}

/// Print discovered devices in CUPS backend format
func listDevices() {
    let devices = findEpilogDevices()

    if devices.isEmpty {
        fputs("DEBUG: No Epilog USB devices found\n", stderr)
    }

    for device in devices {
        // URL-encode the serial number
        let encodedSerial = device.serial.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? device.serial
        let encodedModel = device.modelName.replacingOccurrences(of: " ", with: "%20")

        // CUPS backend output format:
        // direct <uri> "<make>" "<model>" "<device-id>" "<location>"
        let uri = "epilog-usb://\(encodedModel)?serial=\(encodedSerial)"
        let deviceID = "MFG:Epilog;MDL:\(device.modelName);CMD:PJL,PCL,HPGL;"

        print("direct \(uri) \"Epilog\" \"\(device.modelName)\" \"\(deviceID)\" \"USB #\(String(format: "%08X", device.locationID))\"")
    }
}

/// Send data to Epilog via USB using IOKit
func sendToUSB(vendorID: UInt16, productID: UInt16, serial: String, data: Data) -> Bool {
    // Create matching dictionary for the specific device
    guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as? NSMutableDictionary else {
        fputs("ERROR: Cannot create matching dictionary\n", stderr)
        return false
    }

    matchingDict["idVendor"] = NSNumber(value: vendorID)
    matchingDict["idProduct"] = NSNumber(value: productID)

    var iterator: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)

    guard result == KERN_SUCCESS else {
        fputs("ERROR: No matching USB devices found\n", stderr)
        return false
    }

    defer { IOObjectRelease(iterator) }

    var service: io_service_t = IOIteratorNext(iterator)
    while service != 0 {
        defer {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        // Check serial number
        var deviceSerial = "Unknown"
        if let serialRef = IORegistryEntryCreateCFProperty(service, "USB Serial Number" as CFString, kCFAllocatorDefault, 0) {
            deviceSerial = (serialRef.takeRetainedValue() as? String) ?? "Unknown"
        }

        if deviceSerial != serial && serial != "Unknown" {
            continue
        }

        // Found the device - now we need to send data
        // For USB devices that aren't USB printer class, we typically need to:
        // 1. Open the device
        // 2. Find the correct interface
        // 3. Find the bulk OUT endpoint
        // 4. Send data

        fputs("INFO: Found matching Epilog device (serial: \(deviceSerial))\n", stderr)

        // Try to use libusb-style communication via IOKit
        // This is complex - for now, let's try a simpler approach using a file handle

        // Check if there's a character device for this USB device
        var pathRef: Unmanaged<CFString>?
        let pathResult = IORegistryEntryGetPath(service, kIOServicePlane, nil)

        // For Epilog devices, they may expose themselves as a serial device
        // Let's look for a USB serial interface child
        var childIterator: io_iterator_t = 0
        IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIterator)

        var child: io_service_t = IOIteratorNext(childIterator)
        while child != 0 {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(childIterator)
            }

            var className = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(child, &className)
            let classString = String(cString: className)

            fputs("DEBUG: Child class: \(classString)\n", stderr)

            // Look for IOUSBInterface or serial device
            if classString.contains("Serial") || classString.contains("UART") {
                if let pathRef = IORegistryEntryCreateCFProperty(child, "IOCalloutDevice" as CFString, kCFAllocatorDefault, 0) {
                    let path = pathRef.takeRetainedValue() as? String
                    fputs("DEBUG: Found serial device: \(path ?? "unknown")\n", stderr)

                    if let devicePath = path {
                        // Open and write to serial device
                        let fd = open(devicePath, O_WRONLY | O_NOCTTY)
                        if fd >= 0 {
                            defer { close(fd) }

                            let written = data.withUnsafeBytes { bytes in
                                write(fd, bytes.baseAddress!, data.count)
                            }

                            if written == data.count {
                                fputs("INFO: Successfully wrote \(written) bytes to \(devicePath)\n", stderr)
                                IOObjectRelease(childIterator)
                                return true
                            } else {
                                fputs("ERROR: Only wrote \(written) of \(data.count) bytes\n", stderr)
                            }
                        } else {
                            fputs("ERROR: Cannot open \(devicePath): \(String(cString: strerror(errno)))\n", stderr)
                        }
                    }
                }
            }
        }
        IOObjectRelease(childIterator)

        // If no serial device found, try to access raw USB
        fputs("INFO: No serial interface found, attempting raw USB access\n", stderr)
        fputs("ERROR: Raw USB access not yet implemented - device may need to be accessed as network printer\n", stderr)
        fputs("INFO: Try connecting via Ethernet instead, or check if device exposes a serial interface\n", stderr)
        return false
    }

    fputs("ERROR: Device with serial '\(serial)' not found\n", stderr)
    return false
}

/// Find device by serial number
func findDeviceBySerial(_ serial: String) -> EpilogUSBDevice? {
    let devices = findEpilogDevices()
    return devices.first { $0.serial == serial || serial == "Unknown" }
}

/// Parse device URI and extract serial number
func parseDeviceURI(_ uri: String) -> String? {
    // URI format: epilog-usb://Model?serial=XXXXX
    guard let url = URL(string: uri),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let serialItem = components.queryItems?.first(where: { $0.name == "serial" }) else {
        return nil
    }
    return serialItem.value
}

// MARK: - Main Entry Point

let args = CommandLine.arguments

// Discovery mode - no arguments
if args.count == 1 {
    listDevices()
    exit(0)
}

// Print mode - CUPS backend arguments
// argv[0] = backend name
// argv[1] = job-id
// argv[2] = user
// argv[3] = title
// argv[4] = copies
// argv[5] = options
// argv[6] = file (optional, use stdin if missing)

guard args.count >= 6 else {
    fputs("Usage: epilog-usb job-id user title copies options [file]\n", stderr)
    fputs("       epilog-usb          # Discovery mode\n", stderr)
    exit(1)
}

// Get device URI from environment (set by CUPS)
guard let deviceURI = ProcessInfo.processInfo.environment["DEVICE_URI"] else {
    fputs("ERROR: DEVICE_URI environment variable not set\n", stderr)
    exit(1)
}

fputs("INFO: Device URI: \(deviceURI)\n", stderr)

// Parse serial from URI
guard let serial = parseDeviceURI(deviceURI) else {
    fputs("ERROR: Cannot parse serial from URI: \(deviceURI)\n", stderr)
    exit(1)
}

// Find device
guard let device = findDeviceBySerial(serial) else {
    fputs("ERROR: Epilog device with serial '\(serial)' not found\n", stderr)
    fputs("INFO: Make sure the device is connected via USB\n", stderr)
    exit(1)
}

fputs("INFO: Found Epilog \(device.modelName) (serial: \(device.serial))\n", stderr)

// Read input data
var inputData = Data()

if args.count >= 7 && args[6] != "-" {
    // Read from file
    let filename = args[6]
    do {
        inputData = try Data(contentsOf: URL(fileURLWithPath: filename))
    } catch {
        fputs("ERROR: Cannot read file '\(filename)': \(error)\n", stderr)
        exit(1)
    }
} else {
    // Read from stdin
    let bufferSize = 65536
    var buffer = [UInt8](repeating: 0, count: bufferSize)

    while true {
        let bytesRead = fread(&buffer, 1, bufferSize, stdin)
        if bytesRead <= 0 { break }
        inputData.append(contentsOf: buffer[0..<bytesRead])
    }
}

guard !inputData.isEmpty else {
    fputs("ERROR: No input data\n", stderr)
    exit(1)
}

fputs("INFO: Sending \(inputData.count) bytes to Epilog via USB\n", stderr)

// Send to device
if sendToUSB(vendorID: device.vendorID, productID: device.productID, serial: device.serial, data: inputData) {
    fputs("INFO: Print job completed successfully\n", stderr)
    exit(0)
} else {
    fputs("ERROR: Failed to send data to Epilog\n", stderr)
    exit(1)
}
