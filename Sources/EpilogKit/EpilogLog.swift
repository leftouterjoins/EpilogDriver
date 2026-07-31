/*
 * EpilogLog.swift - Where the core reports what it is doing
 *
 * The core started life inside a CUPS filter, where the only channel back to
 * the user was stderr and CUPS' own INFO:/WARNING: prefixes. An application
 * wants the same messages in a log panel instead, so they go through here and
 * the host decides what to do with them.
 */

import Foundation

/// Severity of a message from the core.
public enum EpilogLogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (a: EpilogLogLevel, b: EpilogLogLevel) -> Bool {
        a.rawValue < b.rawValue
    }

    /// CUPS reads these prefixes off a filter's stderr and surfaces anything
    /// above DEBUG in the print queue window.
    public var cupsPrefix: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARNING"
        case .error:   return "ERROR"
        }
    }
}

/// Message sink for the core.
public enum EpilogLog {
    /// Where messages go. Defaults to CUPS-style stderr, which is what the
    /// filter needs and what a command-line run should do anyway.
    public static var handler: @Sendable (EpilogLogLevel, String) -> Void = { level, message in
        fputs("\(level.cupsPrefix): \(message)\n", stderr)
    }

    /// Messages below this level are dropped before the handler sees them.
    public static var minimumLevel: EpilogLogLevel = .debug

    public static func debug(_ message: @autoclosure () -> String) {
        log(.debug, message())
    }

    public static func info(_ message: @autoclosure () -> String) {
        log(.info, message())
    }

    public static func warning(_ message: @autoclosure () -> String) {
        log(.warning, message())
    }

    public static func error(_ message: @autoclosure () -> String) {
        log(.error, message())
    }

    public static func log(_ level: EpilogLogLevel, _ message: @autoclosure () -> String) {
        guard level >= minimumLevel else { return }
        handler(level, message())
    }

    /// Accept a line already written in CUPS' "LEVEL: text\n" convention and
    /// route it by its prefix.
    ///
    /// The core was written as a CUPS filter, where every message was an
    /// `fputs` of exactly this shape. Rather than rewrite hundreds of call
    /// sites and risk changing what the queue window shows, the prefix is
    /// parsed back off here; with the default handler the bytes on stderr come
    /// out identical to before.
    public static func raw(_ line: String) {
        var text = line
        if text.hasSuffix("\n") { text.removeLast() }

        for level: EpilogLogLevel in [.debug, .info, .warning, .error] {
            let prefix = level.cupsPrefix + ": "
            if text.hasPrefix(prefix) {
                log(level, String(text.dropFirst(prefix.count)))
                return
            }
        }
        log(.info, text)
    }
}
