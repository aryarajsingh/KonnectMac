import Foundation
import Security
import ServiceManagement

@MainActor
class Config: ObservableObject {
    static let shared = Config()

    static let minPort: UInt16 = 1714
    static let maxPort: UInt16 = 1764
    static let defaultPort: UInt16 = 1716

    nonisolated(unsafe) let deviceId: String
    @Published var deviceName: String
    @Published var deviceType: String = "laptop"
    @Published var tcpPort: UInt16
    @Published var autoStart: Bool {
        didSet {
            guard autoStart != oldValue else { return }
            updateLoginItem()
        }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }
    @Published var tailscaleIP: String {
        didSet { UserDefaults.standard.set(tailscaleIP, forKey: "tailscaleIP") }
    }
    @Published var downloadDirectory: String {
        didSet { UserDefaults.standard.set(downloadDirectory, forKey: "downloadDirectory") }
    }

    let incomingCapabilities: [String] = [
        "kdeconnect.ping",
        "kdeconnect.battery",
        "kdeconnect.notification",
        "kdeconnect.notification.request",
        "kdeconnect.telephony",
        "kdeconnect.clipboard",
        "kdeconnect.clipboard.connect",
        "kdeconnect.findmyphone.request",
        "kdeconnect.share.request",
        "kdeconnect.pair"
    ]

    let outgoingCapabilities: [String] = [
        "kdeconnect.ping",
        "kdeconnect.battery.request",
        "kdeconnect.notification.reply",
        "kdeconnect.notification.action",
        "kdeconnect.telephony.request_mute",
        "kdeconnect.clipboard",
        "kdeconnect.clipboard.connect",
        "kdeconnect.findmyphone.request",
        "kdeconnect.share.request",
        "kdeconnect.pair"
    ]

    private init() {
        let defaults = UserDefaults.standard
        self.deviceId = defaults.string(forKey: "deviceId") ?? {
            let id = UUID().uuidString
            defaults.set(id, forKey: "deviceId")
            return id
        }()
        self.deviceName = defaults.string(forKey: "deviceName") ?? Host.current().localizedName ?? "Mac"
        let rawPort = defaults.integer(forKey: "tcpPort")
        let parsedPort = UInt16(exactly: rawPort) ?? Config.defaultPort
        self.tcpPort = (parsedPort >= Config.minPort && parsedPort <= Config.maxPort) ? parsedPort : Config.defaultPort
        self.autoStart = defaults.bool(forKey: "autoStart")
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        self.tailscaleIP = defaults.string(forKey: "tailscaleIP") ?? ""
        self.downloadDirectory = defaults.string(forKey: "downloadDirectory")
            ?? (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")).path
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(deviceName, forKey: "deviceName")
        defaults.set(Int(tcpPort), forKey: "tcpPort")
    }

    func isPaired(deviceId: String) -> Bool {
        let path = pairingPath(for: deviceId)
        return FileManager.default.fileExists(atPath: path)
    }

    func savePairedDevice(id: String, certData: Data) {
        let dir = pairingDirectory()
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            KLog.log("[Config] Failed to create pairing directory: \(error)", level: .error)
            return
        }
        let path = pairingPath(for: id)
        do {
            try certData.write(to: URL(fileURLWithPath: path))
        } catch {
            KLog.log("[Config] Failed to save paired device cert for \(id): \(error)", level: .error)
        }
    }

    func loadPairedDeviceCert(id: String) -> Data? {
        let path = pairingPath(for: id)
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            if FileManager.default.fileExists(atPath: path) {
                KLog.log("[Config] Cert file exists but read failed for \(id): \(error)", level: .error)
            }
            return nil
        }
        // Validate DER format
        guard SecCertificateCreateWithData(nil, data as CFData) != nil else {
            KLog.log("[Config] Invalid DER certificate data for \(id)", level: .error)
            return nil
        }
        return data
    }

    func removePairedDevice(id: String) {
        let path = pairingPath(for: id)
        try? FileManager.default.removeItem(atPath: path)
        var names = UserDefaults.standard.dictionary(forKey: "pairedDeviceNames") as? [String: String] ?? [:]
        names.removeValue(forKey: id)
        UserDefaults.standard.set(names, forKey: "pairedDeviceNames")
    }

    func savedDeviceName(for id: String) -> String? {
        let names = UserDefaults.standard.dictionary(forKey: "pairedDeviceNames") as? [String: String] ?? [:]
        return names[id]
    }

    func saveDeviceName(_ name: String, for id: String) {
        var names = UserDefaults.standard.dictionary(forKey: "pairedDeviceNames") as? [String: String] ?? [:]
        names[id] = name
        UserDefaults.standard.set(names, forKey: "pairedDeviceNames")
    }

    func saveDeviceType(_ type: String, for id: String) {
        var types = UserDefaults.standard.dictionary(forKey: "pairedDeviceTypes") as? [String: String] ?? [:]
        types[id] = type
        UserDefaults.standard.set(types, forKey: "pairedDeviceTypes")
    }

    func enabledPlugins(for deviceId: String) -> Set<String> {
        let key = "enabledPlugins_\(deviceId)"
        if let arr = UserDefaults.standard.array(forKey: key) as? [String] {
            return Set(arr)
        }
        return Set(["ping", "battery", "notification", "telephony", "clipboard", "findmyphone", "share"])
    }

    func setEnabledPlugins(_ plugins: Set<String>, for deviceId: String) {
        UserDefaults.standard.set(Array(plugins), forKey: "enabledPlugins_\(deviceId)")
    }

    private func pairingDirectory() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("KonnectMac/PairedDevices").path
    }

    private func pairingPath(for id: String) -> String {
        // Sanitize device ID to prevent path traversal, null byte truncation, and macOS resource fork issues
        var safeId = id.replacingOccurrences(of: "..", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        if safeId.isEmpty || safeId == "." || safeId == ".." {
            safeId = "_invalid_"
        }
        return pairingDirectory() + "/\(safeId).der"
    }

    private func updateLoginItem() {
        if autoStart {
            do {
                try SMAppService.mainApp.register()
                KLog.log("[Config] Login item registered. Status: \(SMAppService.mainApp.status.rawValue)")
            } catch {
                KLog.log("[Config] Failed to register login item: \(error)")
                self.autoStart = false
            }
        } else {
            do {
                try SMAppService.mainApp.unregister()
                KLog.log("[Config] Login item unregistered")
            } catch {
                KLog.log("[Config] Failed to unregister login item: \(error)")
            }
        }
        UserDefaults.standard.set(autoStart, forKey: "autoStart")
    }

    /// Check actual system status on launch and sync
    func syncLoginItemStatus() {
        let status = SMAppService.mainApp.status
        let registered = (status == .enabled)
        if autoStart != registered {
            KLog.log("[Config] Login item mismatch: saved=\(autoStart) actual=\(registered). Syncing.")
            autoStart = registered
            UserDefaults.standard.set(autoStart, forKey: "autoStart")
        }
    }
}
