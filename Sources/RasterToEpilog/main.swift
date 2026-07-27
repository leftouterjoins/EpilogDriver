/*
 * rastertoepiloz - CUPS filter for Epilog Zing laser engravers
 *
 * This filter converts print data to Epilog's PJL/PCL/HPGL format.
 * It can accept either PDF input (for vector cutting support) or
 * CUPS raster input (for backward compatibility).
 *
 * Based on VisiCut's LibLaserCut EpilogCutter.java implementation.
 *
 * CUPS filter arguments:
 * filter job-id user title copies options [file]
 * argv[0] = filter name
 * argv[1] = job ID
 * argv[2] = user name
 * argv[3] = job title
 * argv[4] = number of copies
 * argv[5] = options string
 * argv[6] = filename (optional, or "-" for stdin)
 */

import Foundation
import EpilogKit
import CUPSBridge

// Ignore SIGPIPE to handle broken pipes gracefully
signal(SIGPIPE, SIG_IGN)

let args = CommandLine.arguments

guard args.count >= 6 else {
    fputs("ERROR: Usage: rastertoepiloz job-id user title copies options [file]\n", stderr)
    exit(1)
}

let jobId = args[1]
let user = args[2]
let title = args[3]
let copies = Int(args[4]) ?? 1
let optionsString = args[5]

// Parse job options
let options = JobOptions.parse(from: optionsString)

fputs("INFO: Starting Epilog filter for job \(jobId)\n", stderr)
fputs("DEBUG: User: \(user), Title: \(title), Copies: \(copies)\n", stderr)
fputs("DEBUG: Options: RasterPower=\(options.rasterPower)%, RasterSpeed=\(options.rasterSpeed)%, Resolution=\(options.resolution)dpi\n", stderr)
fputs("DEBUG: Options: VectorPower=\(options.vectorPower)%, VectorSpeed=\(options.vectorSpeed)%, VectorFreq=\(options.vectorFrequency)Hz\n", stderr)
fputs("DEBUG: Options: JobType=\(options.jobType)\n", stderr)

// Read input data - either from file (argv[6]) or stdin
var inputData = Data()

// Check if input file is provided as argument
let inputFile: String? = args.count >= 7 ? args[6] : nil

if let filename = inputFile, filename != "-" {
    // Read from file
    fputs("DEBUG: Reading input from file: \(filename)\n", stderr)
    do {
        inputData = try Data(contentsOf: URL(fileURLWithPath: filename))
    } catch {
        fputs("ERROR: Cannot read input file '\(filename)': \(error)\n", stderr)
        exit(1)
    }
} else {
    // Read from stdin
    fputs("DEBUG: Reading input from stdin\n", stderr)
    let bufferSize = 65536
    var buffer = [UInt8](repeating: 0, count: bufferSize)

    while true {
        let bytesRead = fread(&buffer, 1, bufferSize, stdin)
        if bytesRead <= 0 { break }
        inputData.append(contentsOf: buffer[0..<bytesRead])
    }
}

guard !inputData.isEmpty else {
    fputs("ERROR: No input data received\n", stderr)
    exit(1)
}

fputs("DEBUG: Read \(inputData.count) bytes\n", stderr)

// Detect input format by magic bytes
let isPDF = inputData.count >= 4 && inputData.prefix(4) == Data("%PDF".utf8)
// CUPS raster starts with "RaS2" or "RaS3" (big-endian) or "2SaR"/"3SaR" (little-endian)
let cupsRasterSignatures: [Data] = [
    Data("RaS2".utf8),
    Data("RaS3".utf8),
    Data("2SaR".utf8),
    Data("3SaR".utf8)
]
let isCUPSRaster = inputData.count >= 4 && cupsRasterSignatures.contains(where: { inputData.prefix(4) == $0 })

fputs("DEBUG: Input format detected: \(isPDF ? "PDF" : (isCUPSRaster ? "CUPS Raster" : "Unknown"))\n", stderr)

// Create the Epilog job generator
let job = EpilogJob(
    title: title,
    user: user,
    options: options,
    copies: copies
)

do {
    if isPDF {
        // PDF input - extract vectors and rasterize for engraving
        fputs("INFO: Processing PDF input with vector extraction\n", stderr)
        try job.processPDF(data: inputData)
    } else if isCUPSRaster {
        // CUPS raster input - use legacy raster-only path
        fputs("INFO: Processing CUPS raster input (vector paths not available)\n", stderr)

        // Create CUPSRasterStream from the data we already read
        guard let rasterStream = CUPSRasterStream(data: inputData) else {
            fputs("ERROR: Unable to parse CUPS raster data\n", stderr)
            exit(1)
        }
        try job.process(raster: rasterStream)
    } else {
        // Unknown format - try to process as raster anyway
        fputs("WARNING: Unknown input format, attempting to process as CUPS raster\n", stderr)
        guard let rasterStream = CUPSRasterStream(data: inputData) else {
            fputs("ERROR: Unable to parse input as CUPS raster\n", stderr)
            exit(1)
        }
        try job.process(raster: rasterStream)
    }

    fputs("INFO: Job completed successfully\n", stderr)
} catch {
    fputs("ERROR: Failed to process job: \(error)\n", stderr)
    exit(1)
}
