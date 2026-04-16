import Foundation

class KLog {
    enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    static let logPath: String = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("KonnectMac/konnectmac.log").path
    }()

    private static let queue = DispatchQueue(label: "konnectmac.logger")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func log(_ message: String, level: LogLevel = .info) {
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue)] \(message)\n"

        queue.async {
            let fileURL = URL(fileURLWithPath: logPath)
            let directoryURL = fileURL.deletingLastPathComponent()

            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                fputs("KLog write failed: \(error)\n", stderr)
            }
        }
    }
}
