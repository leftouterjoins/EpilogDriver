/*
 * rastertoepiloz - CUPS filter for Epilog Zing laser engravers
 *
 * This filter converts CUPS raster data to Epilog's PJL/PCL/HPGL format.
 * It reads raster data from stdin and writes the Epilog job to stdout.
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
fputs("DEBUG: Options: Power=\(options.rasterPower)%, Speed=\(options.rasterSpeed)%, Resolution=\(options.resolution)dpi\n", stderr)

// Open raster stream from stdin
guard let rasterStream = CUPSRasterStream() else {
    fputs("ERROR: Unable to open raster stream from stdin\n", stderr)
    exit(1)
}

// Create the Epilog job generator
let job = EpilogJob(
    title: title,
    user: user,
    options: options
)

// Process the raster stream and generate output
do {
    try job.process(raster: rasterStream)
    fputs("INFO: Job completed successfully\n", stderr)
} catch {
    fputs("ERROR: Failed to process job: \(error)\n", stderr)
    exit(1)
}
