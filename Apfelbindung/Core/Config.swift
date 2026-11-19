import Foundation
import Security
import ServiceManagement

@MainActor
class Config: ObservableObject {
    static let shared = Config()

    static let minPort: UInt16 = 1716
    static let maxPort: UInt16 = 1764
    static let defaultPort: UInt16 = 1716

    /// Fixed UDP discovery port mandated by the KDE Connect protocol.
    /// TCP lives in `minPort...maxPort`, but UDP discovery is always 1716.
    static let udpPort: UInt16 = 1716

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
        "kdeconnect.telephony",
        "kdeconnect.clipboard",
        "kdeconnect.clipboard.connect",
        "kdeconnect.findmyphone.request",
        "kdeconnect.share.request",
        "kdeconnect.sms.messages",
        "kdeconnect.pair"
    ]

    let outgoingCapabilities: [String] = [
        "kdeconnect.ping",
        "kdeconnect.battery.request",
        "kdeconnect.notification.request",
        "kdeconnect.notification.reply",
        "kdeconnect.notification.action",
        "kdeconnect.telephony.request_mute",
        "kdeconnect.clipboard",
        "kdeconnect.clipboard.connect",
        "kdeconnect.findmyphone.request",
        "kdeconnect.share.request",
        "kdeconnect.sms.request",
        "kdeconnect.sms.request_conversations",
        "kdeconnect.sms.request_conversation",
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
        UserDefaults.standard.removeObject(forKey: "notificationApps_\(id)")
        UserDefaults.standard.removeObject(forKey: "notificationAppRules_\(id)")
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

    func savedDeviceType(for id: String) -> String? {
        let types = UserDefaults.standard.dictionary(forKey: "pairedDeviceTypes") as? [String: String] ?? [:]
        return types[id]
    }

    func saveDeviceIP(_ ip: String, for id: String) {
        var ips = UserDefaults.standard.dictionary(forKey: "pairedDeviceIPs") as? [String: String] ?? [:]
        ips[id] = ip
        UserDefaults.standard.set(ips, forKey: "pairedDeviceIPs")
    }

    func savedDeviceIP(for id: String) -> String? {
        let ips = UserDefaults.standard.dictionary(forKey: "pairedDeviceIPs") as? [String: String] ?? [:]
        return ips[id]
    }

    func allSavedDeviceIPs() -> [String: String] {
        return UserDefaults.standard.dictionary(forKey: "pairedDeviceIPs") as? [String: String] ?? [:]
    }

    func enabledPlugins(for deviceId: String) -> Set<String> {
        let key = "enabledPlugins_\(deviceId)"
        if let arr = UserDefaults.standard.array(forKey: key) as? [String] {
            return Set(arr)
        }
        return Set(["ping", "battery", "notification", "telephony", "clipboard", "findmyphone", "share"])
    }

    func setEnabledPlugins(_ plugins: Set<String>, for deviceId: String) {
        objectWillChange.send()
        UserDefaults.standard.set(Array(plugins), forKey: "enabledPlugins_\(deviceId)")
    }

    func notificationApps(for deviceId: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: "notificationApps_\(deviceId)") as? [String: String] ?? [:]
    }

    func recordNotificationApp(_ package: String, name: String, for deviceId: String) {
        guard !package.isEmpty, package.utf8.count <= 256, name.utf8.count <= 256 else { return }
        var apps = notificationApps(for: deviceId)
        guard apps[package] != name, apps[package] != nil || apps.count < 500 else { return }
        objectWillChange.send()
        apps[package] = name
        UserDefaults.standard.set(apps, forKey: "notificationApps_\(deviceId)")
    }

    func receivesNotifications(from package: String, for deviceId: String) -> Bool {
        let overrides = UserDefaults.standard.dictionary(forKey: "notificationAppRules_\(deviceId)") as? [String: Bool]
        if let enabled = overrides?[package] { return enabled }
        return !["android", "com.android.systemui", "com.android.settings", "com.android.vending",
                  "org.kde.kdeconnect_tp", "org.kde.kdeconnect_tp.debug"].contains(package)
            && !package.hasPrefix("com.android.providers.")
    }

    func setReceivesNotifications(_ enabled: Bool, from package: String, for deviceId: String) {
        let key = "notificationAppRules_\(deviceId)"
        var overrides = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        objectWillChange.send()
        overrides[package] = enabled
        UserDefaults.standard.set(overrides, forKey: key)
    }

    enum ClipboardDirection: String {
        case send, receive
    }

    func clipboardEnabled(_ direction: ClipboardDirection, for deviceId: String) -> Bool {
        UserDefaults.standard.object(forKey: "clipboard_\(direction.rawValue)_\(deviceId)") as? Bool ?? true
    }

    func setClipboardEnabled(_ enabled: Bool, _ direction: ClipboardDirection, for deviceId: String) {
        objectWillChange.send()
        UserDefaults.standard.set(enabled, forKey: "clipboard_\(direction.rawValue)_\(deviceId)")
    }

    private func pairingDirectory() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Apfelbindung/PairedDevices").path
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

    private static let launchAgentPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/LaunchAgents/com.apfelbindung.app.plist"
    }()

    private func updateLoginItem() {
        if autoStart {
            installLaunchAgent()
        } else {
            removeLaunchAgent()
        }
        UserDefaults.standard.set(autoStart, forKey: "autoStart")
    }

    private func installLaunchAgent() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.apfelbindung.app</string>
            <key>ProgramArguments</key>
            <array>
                <string>/Applications/Apfelbindung.app/Contents/MacOS/Apfelbindung</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
        </dict>
        </plist>
        """

        let dir = (FileManager.default.homeDirectoryForCurrentUser.path) + "/Library/LaunchAgents"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        do {
            try plist.write(toFile: Config.launchAgentPath, atomically: true, encoding: .utf8)
            KLog.log("[Config] LaunchAgent installed at \(Config.launchAgentPath)")
            // Do NOT call launchctl load here — RunAtLoad=true would immediately launch
            // a second instance while the app is already running, triggering the duplicate
            // instance guard. The plist in LaunchAgents/ is picked up automatically on
            // next login, which is the correct behavior.
        } catch {
            KLog.log("[Config] Failed to install LaunchAgent: \(error)")
            self.autoStart = false
        }
    }

    private func removeLaunchAgent() {
        let path = Config.launchAgentPath
        // Unload from launchd so it won't run at the next login, then delete the plist.
        // We DO need launchctl unload here to deregister it from the current session.
        DispatchQueue.global(qos: .background).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            try? FileManager.default.removeItem(atPath: path)
            KLog.log("[Config] LaunchAgent unloaded and removed")
        }
    }

    /// Sync login item state on launch. Always overwrites the plist when autoStart is on
    /// so that existing users pick up KeepAlive / other plist changes on next app launch.
    func syncLoginItemStatus() {
        if autoStart {
            installLaunchAgent()
        } else if FileManager.default.fileExists(atPath: Config.launchAgentPath) {
            KLog.log("[Config] LaunchAgent exists but autoStart=false. Removing.")
            removeLaunchAgent()
        }
    }
}
