import Foundation

class KLog {
    enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    static let logPath: String = {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("KonnectMac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("konnectmac.log").path
    }()
    private static let queue = DispatchQueue(label: "klog.serial")
    private static let maxLogSize: UInt64 = 5 * 1024 * 1024 // 5MB

    static func log(_ message: String, level: LogLevel = .info) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
        NSLog("%@", "[\(level.rawValue)] \(message)")  // NSLog is already thread-safe
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            // Rotate if log exceeds 5MB — keep up to 3 old logs
            if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
               let fileSize = attrs[.size] as? UInt64, fileSize > maxLogSize {
                // Shift old logs: .old.2 → .old.3, .old.1 → .old.2, .old → .old.1
                try? FileManager.default.removeItem(atPath: logPath + ".old.3")
                try? FileManager.default.moveItem(atPath: logPath + ".old.2", toPath: logPath + ".old.3")
                try? FileManager.default.moveItem(atPath: logPath + ".old.1", toPath: logPath + ".old.2")
                try? FileManager.default.moveItem(atPath: logPath + ".old", toPath: logPath + ".old.1")
                try? FileManager.default.moveItem(atPath: logPath, toPath: logPath + ".old")
            }

            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }
}
