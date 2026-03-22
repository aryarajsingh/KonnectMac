import Foundation

class KLog {
    enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    // Stable build — logging disabled for distribution.
    // All KLog.log() calls become no-ops. No file I/O, no disk usage.
    // Enable logging in alpha/beta branches for debugging.
    static let logPath: String = ""

    static func log(_ message: String, level: LogLevel = .info) {
        // No-op in stable builds
    }
}
