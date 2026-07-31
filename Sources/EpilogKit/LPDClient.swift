/*
 * LPDClient.swift - Hand a finished job to the laser
 *
 * The Epilog speaks LPD (RFC 1179) on port 515 and nothing else over the
 * network. It is a small protocol: announce the queue, send a control file
 * describing the job, send the data file, and wait for a zero byte after each
 * step. Every one of those acknowledgements matters - a machine that is busy,
 * lidless or out of memory says so by refusing one of them, and without
 * checking you would simply never find out.
 *
 * One quirk worth knowing: the Epilog decides a job is complete when it sees
 * the trailing NUL padding the PJL footer emits. That is why the footer ends
 * with 4096 zero bytes and why nothing here trims them.
 */

import Foundation
import Darwin

public enum LPDError: LocalizedError {
    case noHost
    case cannotResolve(String)
    case cannotConnect(String, Int, String)
    case timedOut(String)
    case rejected(String, UInt8)
    case closed(String)
    case writeFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noHost:
            return "No laser address is set. Enter the machine's IP address in Machine settings."
        case .cannotResolve(let host):
            return "Cannot find \(host) on the network."
        case .cannotConnect(let host, let port, let reason):
            return "Cannot reach \(host) on port \(port): \(reason). "
                 + "Check the laser is switched on and on the same network."
        case .timedOut(let step):
            return "The laser stopped responding while \(step). "
                 + "It may be busy with another job."
        case .rejected(let step, let code):
            return "The laser refused the job while \(step) (code \(code)). "
                 + "This usually means it is busy, or its job memory is full."
        case .closed(let step):
            return "The laser closed the connection while \(step)."
        case .writeFailed(let step):
            return "Lost the connection to the laser while \(step)."
        case .cancelled:
            return "Sending was cancelled."
        }
    }
}

public struct LPDClient {

    public struct Destination {
        public var host: String
        public var port: Int
        /// Print queue name. Epilog ignores it, and an empty string is what
        /// their own driver sends.
        public var queue: String
        public var user: String

        public init(host: String, port: Int = 515, queue: String = "",
                    user: String = NSUserName()) {
            self.host = host
            self.port = port
            self.queue = queue
            self.user = user
        }
    }

    /// Seconds to wait for each acknowledgement.
    public var timeout: TimeInterval = 30

    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    /// Send a job. Blocking - call it off the main thread.
    ///
    /// - Parameter progress: fraction of the data file sent, 0 to 1.
    public func send(job: Data, title: String, to destination: Destination,
                     progress: ((Double) -> Void)? = nil,
                     shouldCancel: () -> Bool = { false }) throws {

        guard !destination.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LPDError.noHost
        }

        let localHost = sanitize(ProcessInfo.processInfo.hostName
            .split(separator: ".").first.map(String.init) ?? "mac")
        let user = sanitize(destination.user)
        let jobNumber = "1"

        let socket = try connect(to: destination)
        defer { close(socket) }

        // 0x02: receive a printer job on this queue.
        try write(socket, Data([0x02]) + Data(destination.queue.utf8) + Data([0x0A]),
                  step: "starting the job")
        try acknowledge(socket, step: "starting the job")

        // The control file names the job. Epilog shows it on the panel.
        let control = """
            H\(localHost)
            P\(user)
            J\(sanitize(title))
            ldfA\(jobNumber)\(localHost)
            UdfA\(jobNumber)\(localHost)
            N\(sanitize(title))

            """.replacingOccurrences(of: "\r\n", with: "\n")
        let controlData = Data(control.utf8)

        try write(socket,
                  Data("\u{02}\(controlData.count) cfA\(jobNumber)\(localHost)\n".utf8),
                  step: "announcing the job description")
        try acknowledge(socket, step: "announcing the job description")
        try write(socket, controlData + Data([0x00]), step: "sending the job description")
        try acknowledge(socket, step: "sending the job description")

        try write(socket,
                  Data("\u{03}\(job.count) dfA\(jobNumber)\(localHost)\n".utf8),
                  step: "announcing the job data")
        try acknowledge(socket, step: "announcing the job data")

        // Send in chunks so progress means something on a large engraving,
        // which can run to tens of megabytes.
        let chunkSize = 32 * 1024
        var offset = 0
        while offset < job.count {
            if shouldCancel() { throw LPDError.cancelled }
            let end = min(offset + chunkSize, job.count)
            try write(socket, job.subdata(in: offset..<end), step: "sending the job data")
            offset = end
            progress?(Double(offset) / Double(job.count))
        }
        try write(socket, Data([0x00]), step: "finishing the job data")
        try acknowledge(socket, step: "finishing the job data")

        EpilogLog.info("Sent \(job.count) bytes to \(destination.host)")
    }

    /// Open and immediately close a connection, to check the machine answers.
    public func testConnection(to destination: Destination) throws {
        let socket = try connect(to: destination)
        close(socket)
    }

    // MARK: - Socket plumbing

    private func connect(to destination: Destination) throws -> Int32 {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(destination.host, String(destination.port), &hints, &info)
        guard status == 0, let first = info else {
            throw LPDError.cannotResolve(destination.host)
        }
        defer { freeaddrinfo(info) }

        var lastError = "no route"
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let addr = candidate {
            let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype,
                            addr.pointee.ai_protocol)
            if fd >= 0 {
                // Fail fast rather than hanging for the kernel's default two
                // minutes when the machine is off.
                var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var on: Int32 = 1
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))

                if Darwin.connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0 {
                    return fd
                }
                lastError = String(cString: strerror(errno))
                close(fd)
            }
            candidate = addr.pointee.ai_next
        }

        throw LPDError.cannotConnect(destination.host, destination.port, lastError)
    }

    private func write(_ fd: Int32, _ data: Data, step: String) throws {
        var sent = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw LPDError.writeFailed(step)
                }
            }
        }
    }

    /// Read the single byte the protocol sends after each step. Zero is yes.
    private func acknowledge(_ fd: Int32, step: String) throws {
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, 0)
        if n == 0 { throw LPDError.closed(step) }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { throw LPDError.timedOut(step) }
            throw LPDError.closed(step)
        }
        if byte != 0 { throw LPDError.rejected(step, byte) }
    }

    /// LPD control files are line-oriented ASCII; anything else confuses them.
    private func sanitize(_ s: String) -> String {
        let cleaned = s.unicodeScalars.map { scalar -> Character in
            (scalar.isASCII && scalar.value >= 32 && scalar.value != 127)
                ? Character(scalar) : "_"
        }
        let result = String(cleaned).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "job" : String(result.prefix(72))
    }
}
