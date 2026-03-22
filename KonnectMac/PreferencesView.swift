import SwiftUI

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            DevicesTab()
                .tabItem { Label("Devices", systemImage: "iphone") }
            PluginsTab()
                .tabItem { Label("Plugins", systemImage: "puzzlepiece") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 380)
    }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var config = Config.shared
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Identity") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Device Name")
                            .frame(width: 100, alignment: .trailing)
                        TextField("", text: $config.deviceName)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFieldFocused)
                            .onSubmit { config.save(); nameFieldFocused = false }
                    }
                    HStack {
                        Text("Device ID")
                            .frame(width: 100, alignment: .trailing)
                        Text(config.deviceId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(6)
            }

            GroupBox("Startup") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch KonnectMac at login", isOn: $config.autoStart)
                        .toggleStyle(.checkbox)
                }
                .padding(6)
            }

            GroupBox("File Transfer") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Save files to")
                            .frame(width: 100, alignment: .trailing)
                        Text(config.downloadDirectory)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.directoryURL = URL(fileURLWithPath: config.downloadDirectory)
                            if panel.runModal() == .OK, let url = panel.url {
                                config.downloadDirectory = url.path
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(6)
            }

            Spacer()
        }
        .padding()
        .onAppear { DispatchQueue.main.async { nameFieldFocused = false } }
    }
}

// MARK: - Devices

private enum ConnectState: Equatable {
    case idle
    case connecting
    case connected(String) // device name
    case failed
}

struct DevicesTab: View {
    @ObservedObject var config = Config.shared
    @ObservedObject var manager = DeviceManager.shared
    @State private var connectIP = ""
    @State private var connectState: ConnectState = .idle
    @State private var rememberIP = false
    @State private var rememberStatus = ""
    @State private var connectingToIP = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Connect by IP") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Enter your phone's IP address to connect directly.\nUseful for Tailscale or when WiFi discovery doesn't work.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        TextField("IP address (e.g. 100.100.10.43)", text: $connectIP)
                            .textFieldStyle(.roundedBorder)
                            .disabled(connectState == .connecting)
                            .onSubmit { connectNow() }

                        switch connectState {
                        case .idle, .failed:
                            Button("Connect") { connectNow() }
                                .controlSize(.small)
                                .disabled(connectIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        case .connecting:
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                                Text("Connecting...")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: 100)
                        case .connected(let name):
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 12))
                                Text(name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.green)
                                    .lineLimit(1)
                            }
                        }
                    }

                    if connectState == .failed {
                        Text("Could not reach \(connectingToIP). Check the IP and ensure KDE Connect is running on the phone.")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle("Remember this IP and connect automatically", isOn: $rememberIP)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .disabled(connectIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(connectIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                        .onChange(of: rememberIP) { _, on in
                            let trimmed = connectIP.trimmingCharacters(in: .whitespacesAndNewlines)
                            if on && !trimmed.isEmpty {
                                config.tailscaleIP = trimmed
                                rememberStatus = "Saved"
                            } else {
                                rememberIP = false
                                config.tailscaleIP = ""
                                rememberStatus = on ? "" : "Auto-connect disabled"
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { rememberStatus = "" }
                        }
                        .onChange(of: connectIP) { _, newValue in
                            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && rememberIP {
                                rememberIP = false
                                config.tailscaleIP = ""
                            }
                            // Reset state when IP changes
                            if connectState == .failed || connectState != .connecting {
                                connectState = .idle
                            }
                        }

                    if !rememberStatus.isEmpty {
                        Text(rememberStatus)
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
                }
                .padding(6)
            }
            .onReceive(manager.objectWillChange) { _ in
                // Watch for a device that connected via the IP we're trying
                guard connectState == .connecting, !connectingToIP.isEmpty else { return }
                DispatchQueue.main.async {
                    for device in manager.devices.values {
                        guard device.connectionState == .discovered || device.connectionState == .paired else { continue }
                        if let conn = manager.connections[device.id], conn.host == connectingToIP, conn.running {
                            connectState = .connected(device.name)
                            return
                        }
                    }
                }
            }

            GroupBox("Paired Devices") {
                let pairedDevices = manager.devices.values.filter { Config.shared.isPaired(deviceId: $0.id) }.sorted { $0.name < $1.name }
                if pairedDevices.isEmpty {
                    HStack {
                        Spacer()
                        Text("No paired devices")
                            .foregroundColor(.secondary)
                            .padding(.vertical, 12)
                        Spacer()
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(pairedDevices), id: \.id) { device in
                            HStack {
                                Image(systemName: iconForDeviceType(device.type))
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(device.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(device.connectionState == .paired ? "Connected" : "Disconnected")
                                        .font(.caption)
                                        .foregroundColor(device.connectionState == .paired ? .green : .secondary)
                                }
                                Spacer()
                                Button("Unpair") {
                                    manager.unpair(deviceId: device.id)
                                }
                                .foregroundColor(.red)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding()
        .onAppear {
            if !config.tailscaleIP.isEmpty {
                connectIP = config.tailscaleIP
                rememberIP = true
            }
            // If already connected to the saved IP, show connected state
            if !connectIP.isEmpty {
                let trimmed = connectIP.trimmingCharacters(in: .whitespacesAndNewlines)
                for device in manager.devices.values {
                    if let conn = manager.connections[device.id], conn.host == trimmed, conn.running,
                       device.connectionState == .discovered || device.connectionState == .paired {
                        connectState = .connected(device.name)
                        break
                    }
                }
            }
        }
    }

    private func connectNow() {
        let trimmed = connectIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        connectIP = trimmed
        connectingToIP = trimmed
        connectState = .connecting
        manager.connectToDirectIP(trimmed)

        // Timeout after 10s — if still connecting, show failure
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if connectState == .connecting {
                connectState = .failed
            }
        }
    }
}

// MARK: - Plugins

struct PluginsTab: View {
    @ObservedObject var manager = DeviceManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let pairedDevices = manager.devices.values.filter { Config.shared.isPaired(deviceId: $0.id) }.sorted { $0.name < $1.name }

            if pairedDevices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text("Pair a device to configure plugins")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(Array(pairedDevices), id: \.id) { device in
                    PluginListView(device: device)
                }
            }

            Spacer()
        }
        .padding()
    }
}

struct PluginListView: View {
    let device: Device
    @State private var enabledPlugins: Set<String> = []

    private let allPlugins: [(key: String, name: String, description: String, icon: String)] = [
        ("ping", "Ping", "Send and receive pings", "bell.fill"),
        ("battery", "Battery", "Show phone battery level", "battery.100"),
        ("notification", "Notifications", "Mirror phone notifications", "app.badge.fill"),
        ("telephony", "Telephony", "Call alerts, media pause", "phone.fill"),
        ("clipboard", "Clipboard Sync", "Share clipboard content", "doc.on.clipboard.fill"),
        ("findmyphone", "Find My Phone", "Ring your phone remotely", "location.fill"),
        ("share", "File Transfer", "Send and receive files", "paperplane.fill"),
    ]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: iconForDeviceType(device.type))
                        .foregroundColor(.blue)
                    Text(device.name)
                        .font(.headline)
                }
                .padding(.bottom, 8)

                ForEach(allPlugins, id: \.key) { plugin in
                    HStack(spacing: 10) {
                        Image(systemName: plugin.icon)
                            .frame(width: 16)
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(plugin.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(plugin.description)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { enabledPlugins.contains(plugin.key) },
                            set: { on in
                                if on { enabledPlugins.insert(plugin.key) }
                                else { enabledPlugins.remove(plugin.key) }
                                Config.shared.setEnabledPlugins(enabledPlugins, for: device.id)
                                DeviceManager.shared.reloadPlugins(for: device.id)
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                    .padding(.vertical, 3)

                    if plugin.key != allPlugins.last?.key {
                        Divider().padding(.leading, 26)
                    }
                }
            }
            .padding(4)
        }
        .onAppear {
            enabledPlugins = Config.shared.enabledPlugins(for: device.id)
        }
    }
}

// MARK: - About

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            if let appIcon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 64, height: 64)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)
            }
            Text("KonnectMac")
                .font(.title.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .foregroundColor(.secondary)
            Text("A native macOS KDE Connect client")
                .foregroundColor(.secondary)

            Divider().frame(width: 200)

            VStack(spacing: 4) {
                Text("Protocol v7 • KDE Connect compatible")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("No third-party dependencies")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("© \(Calendar.current.component(.year, from: Date())) Aryaraj Singh")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }

            Divider().frame(width: 200)

            HStack(spacing: 16) {
                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://github.com/aryarajsingh/KonnectMac")!)
                }) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.link)

                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://github.com/sponsors/aryarajsingh")!)
                }) {
                    Label("Sponsor", systemImage: "heart.fill")
                }
                .buttonStyle(.link)
                .foregroundColor(.pink)
            }
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
