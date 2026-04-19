import SwiftUI

enum MainWindowTab {
    case notifications, messages, settings

    var icon: String {
        switch self {
        case .notifications: return "bell.fill"
        case .messages: return "message.fill"
        case .settings: return "gearshape"
        }
    }

    var label: String {
        switch self {
        case .notifications: return "Notifications"
        case .messages: return "Messages"
        case .settings: return "Settings"
        }
    }
}

@MainActor
class MainWindowState: ObservableObject {
    static let shared = MainWindowState()
    @Published var selectedTab: MainWindowTab = .notifications
}

struct MainView: View {
    @ObservedObject var manager = DeviceManager.shared
    @ObservedObject var store = NotificationStore.shared
    @ObservedObject var config = Config.shared
    @ObservedObject var windowState = MainWindowState.shared
    @State private var hoveredTab: MainWindowTab?

    private var pairedDevices: [Device] {
        manager.devices.values
            .filter { $0.connectionState == .paired }
            .sorted { $0.name < $1.name }
    }

    private var allDevices: [Device] {
        manager.devices.values.sorted { $0.name < $1.name }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            contentArea
        }
        .frame(minWidth: 700, idealWidth: 820, minHeight: 480, idealHeight: 560)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            deviceHeader
            Divider().padding(.vertical, 6)
            quickActions
            Divider().padding(.vertical, 6)
            navItems
            Spacer()
            bottomNav
        }
        .frame(width: 200)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var deviceHeader: some View {
        Group {
            if let device = pairedDevices.first {
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: iconForDeviceType(device.type))
                            .font(.system(size: 22))
                            .foregroundStyle(.primary)
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if device.batteryLevel >= 0 {
                            HStack(spacing: 3) {
                                Image(systemName: batteryIcon(device.batteryLevel, charging: device.batteryCharging))
                                    .font(.system(size: 10))
                                Text(device.batteryLevel >= 0 ? "\(device.batteryLevel)%" : "")
                                    .font(.system(size: 10).monospacedDigit())
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    Text("No device connected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing: 6) {
            QuickActionButton(icon: "bell", label: "Ping") {
                if let device = pairedDevices.first {
                    (device.plugins["ping"] as? PingPlugin)?.sendPing()
                }
            }
            QuickActionButton(icon: "location.fill", label: "Find") {
                if let device = pairedDevices.first {
                    (device.plugins["findmyphone"] as? FindMyPhonePlugin)?.ringPhone()
                }
            }
            QuickActionButton(icon: "paperplane.fill", label: "Send") {
                if let device = pairedDevices.first {
                    AppDelegate.instance?.sendFileFor(device: device)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var navItems: some View {
        VStack(spacing: 2) {
            SidebarNavItem(
                tab: .notifications,
                selectedTab: windowState.selectedTab,
                hoveredTab: hoveredTab,
                badge: store.count
            ) { hoveredTab = $0 } onSelect: { windowState.selectedTab = .notifications }
            SidebarNavItem(
                tab: .messages,
                selectedTab: windowState.selectedTab,
                hoveredTab: hoveredTab,
                badge: nil
            ) { hoveredTab = $0 } onSelect: { windowState.selectedTab = .messages }
        }
        .padding(.horizontal, 8)
    }

    private var bottomNav: some View {
        VStack(spacing: 2) {
            SidebarNavItem(
                tab: .settings,
                selectedTab: windowState.selectedTab,
                hoveredTab: hoveredTab,
                badge: nil
            ) { hoveredTab = $0 } onSelect: { windowState.selectedTab = .settings }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        switch windowState.selectedTab {
        case .notifications: notificationsContent
        case .messages: messagesContent
        case .settings: settingsContent
        }
    }

    // MARK: Notifications

    private var notificationsContent: some View {
        VStack(spacing: 0) {
            contentHeader(
                title: "Notifications",
                badge: store.count,
                trailing: store.notifications.isEmpty ? nil : AnyView(
                    Button("Clear All") { store.dismissAll() }
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.7))
                        .buttonStyle(.plain)
                )
            )

            Divider()

            if store.notifications.isEmpty {
                emptyState(icon: "bell.slash", title: "No Notifications", subtitle: "Phone notifications will appear here")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.notifications) { item in
                            MainNotificationRow(item: item)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    // MARK: Messages

    private var messagesContent: some View {
        HStack(spacing: 0) {
            // Conversation list
            VStack(spacing: 0) {
                contentHeader(title: "Messages", badge: nil, trailing: nil)
                Divider()

                if store_conversations.isEmpty {
                    if isLoadingConversations {
                        VStack(spacing: 8) {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Text("Loading conversations\u{2026}")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        emptyState(icon: "message", title: "No Conversations", subtitle: "Tap to load conversations from your phone")
                            .onTapGesture { requestConversations() }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store_conversations) { convo in
                                ConversationRow(conversation: convo, isSelected: selectedThreadId == convo.id)
                                    .onTapGesture {
                                        selectedThreadId = convo.id
                                        if messagesForThread(convo.id).isEmpty {
                                            requestConversation(convo.id)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .frame(width: 240)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Message thread
            messageThreadView
        }
    }

    @State private var selectedThreadId: Int64?
    @State private var messageText = ""
    @ObservedObject var smsStore = SMSStore.shared

    private var store_conversations: [SMSConversation] { smsStore.conversations }
    private var isLoadingConversations: Bool { smsStore.isLoadingConversations }

    private func messagesForThread(_ threadId: Int64) -> [SMSMessage] {
        smsStore.messages[threadId] ?? []
    }

    private func requestConversations() {
        if let device = pairedDevices.first,
           let plugin = device.plugins["sms"] as? SMSPlugin {
            plugin.requestConversations()
        }
    }

    private func requestConversation(_ threadId: Int64) {
        if let device = pairedDevices.first,
           let plugin = device.plugins["sms"] as? SMSPlugin {
            plugin.requestConversation(threadId: threadId)
        }
    }

    private func sendSMS() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let threadId = selectedThreadId,
              let convo = store_conversations.first(where: { $0.id == threadId }),
              let device = pairedDevices.first,
              let plugin = device.plugins["sms"] as? SMSPlugin else { return }
        plugin.sendSMS(threadId: threadId, phoneNumber: convo.phoneNumber, body: messageText)
        messageText = ""
    }

    @ViewBuilder
    private var messageThreadView: some View {
        if let threadId = selectedThreadId,
           let convo = store_conversations.first(where: { $0.id == threadId }) {
            VStack(spacing: 0) {
                // Thread header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(convo.name)
                            .font(.system(size: 15, weight: .semibold))
                        Text(convo.phoneNumber)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()

                // Messages
                let msgs = messagesForThread(threadId)
                if smsStore.isLoadingMessages == threadId {
                    VStack(spacing: 8) {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Text("Loading messages\u{2026}")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if msgs.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Text("No messages yet")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(msgs) { msg in
                                    MessageBubble(message: msg)
                                        .id(msg.id)
                                }
                            }
                            .padding(12)
                        }
                        .onChange(of: msgs.count) { _, _ in
                            if let last = msgs.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        .onAppear {
                            if let last = msgs.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                // Compose bar
                HStack(spacing: 8) {
                    TextField("Type a message\u{2026}", text: $messageText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { sendSMS() }
                    Button(action: sendSMS) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        } else {
            emptyState(icon: "message.fill", title: "SMS Messages", subtitle: "Select a conversation to start messaging")
        }
    }

    // MARK: Settings

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                contentHeader(title: "Settings", badge: nil, trailing: nil)

                // Identity
                SettingsGroupBox("Identity") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Device Name")
                                .frame(width: 100, alignment: .trailing)
                            TextField("", text: $config.deviceName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { config.save() }
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
                }

                // Startup
                SettingsGroupBox("Startup") {
                    Toggle("Launch KonnectMac at login", isOn: $config.autoStart)
                        .toggleStyle(.checkbox)
                }

                // File Transfer
                SettingsGroupBox("File Transfer") {
                    HStack {
                        Text("Save files to")
                            .frame(width: 100, alignment: .trailing)
                        Text(config.downloadDirectory)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose\u{2026}") {
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

                // Direct Connect
                SettingsGroupBox("Direct Connect") {
                    DirectConnectSection()
                }

                // Paired Devices
                SettingsGroupBox("Paired Devices") {
                    PairedDevicesList()
                }

                // Plugins
                if let device = pairedDevices.first {
                    SettingsGroupBox("Plugins \u{2014} \(device.name)") {
                        PluginToggles(device: device)
                    }
                }

                // About
                SettingsGroupBox("About") {
                    HStack(spacing: 12) {
                        if let appIcon = NSImage(named: NSImage.applicationIconName) {
                            Image(nsImage: appIcon)
                                .resizable()
                                .frame(width: 40, height: 40)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("KonnectMac")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text("Protocol v7 \u{2022} KDE Connect compatible")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private func contentHeader(title: String, badge: Int?, trailing: AnyView?) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 20, weight: .bold))
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
            }
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.quaternary)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func batteryIcon(_ level: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        if level <= 25 { return "battery.25" }
        if level <= 50 { return "battery.50" }
        if level <= 75 { return "battery.75" }
        return "battery.100"
    }
}

// MARK: - Sidebar Nav Item

private struct SidebarNavItem: View {
    let tab: MainWindowTab
    let selectedTab: MainWindowTab
    let hoveredTab: MainWindowTab?
    let badge: Int?
    let onHover: (MainWindowTab?) -> Void
    let onSelect: () -> Void

    private var isSelected: Bool { selectedTab == tab }
    private var isHovered: Bool { hoveredTab == tab }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .frame(width: 20)
                    if let badge, badge > 0 {
                        Text("\(min(badge, 99))")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 8, y: -6)
                    }
                }
                Text(tab.label)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
            .onHover { onHover($0 ? tab : nil) }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quick Action Button

private struct QuickActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 9))
            }
            .foregroundStyle(hovered ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Notification Row (main window variant)

private struct MainNotificationRow: View {
    let item: NotificationItem
    @State private var hovered = false

    private var displayText: String {
        item.text.isEmpty ? item.ticker : item.text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            appIcon
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.appName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(item.timestamp, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                if !item.title.isEmpty && item.title != item.appName {
                    Text(item.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }

                if !displayText.isEmpty {
                    Text(displayText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Button {
                NotificationStore.shared.dismiss(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovered ? Color.primary.opacity(0.04) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let iconPath = item.iconPath,
           let img = NSImage(contentsOfFile: iconPath) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
                Image(systemName: "app")
                    .font(.system(size: 14))
                    .foregroundStyle(.quaternary)
            }
        }
    }
}

// MARK: - Settings Components

private struct SettingsGroupBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            GroupBox { content().padding(8) }
        }
    }
}

private struct DirectConnectSection: View {
    @ObservedObject var config = Config.shared
    @ObservedObject var manager = DeviceManager.shared
    @State private var connectIP = ""
    @State private var connectState: ConnectState = .idle
    @State private var rememberIP = false
    @State private var connectingToIP = ""

    private enum ConnectState: Equatable {
        case idle, connecting, connected(String), failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter your phone\u{2019}s IP for Tailscale/VPN connections.")
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
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("Connecting...")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .frame(width: 100)
                case .connected(let name):
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 12))
                        Text(name).font(.system(size: 11, weight: .medium)).foregroundColor(.green).lineLimit(1)
                    }
                }
            }

            if connectState == .failed {
                Text("Could not reach \(connectingToIP). Check the IP and ensure KDE Connect is running.")
                    .font(.system(size: 10)).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Remember and auto-connect", isOn: $rememberIP)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .onChange(of: rememberIP) { _, on in
                    let trimmed = connectIP.trimmingCharacters(in: .whitespacesAndNewlines)
                    if on && !trimmed.isEmpty { config.tailscaleIP = trimmed }
                    else { config.tailscaleIP = ""; rememberIP = false }
                }
        }
        .onAppear {
            if !config.tailscaleIP.isEmpty { connectIP = config.tailscaleIP; rememberIP = true }
        }
    }

    private func connectNow() {
        let trimmed = connectIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        connectIP = trimmed; connectingToIP = trimmed; connectState = .connecting
        manager.connectToDirectIP(trimmed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if connectState == .connecting { connectState = .failed }
        }
    }
}

private struct PairedDevicesList: View {
    @ObservedObject var manager = DeviceManager.shared

    private var pairedDevices: [Device] {
        manager.devices.values.filter { Config.shared.isPaired(deviceId: $0.id) }.sorted { $0.name < $1.name }
    }

    var body: some View {
        if pairedDevices.isEmpty {
            HStack {
                Spacer()
                Text("No paired devices").foregroundColor(.secondary).padding(.vertical, 12)
                Spacer()
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(pairedDevices), id: \.id) { device in
                    HStack {
                        Image(systemName: iconForDeviceType(device.type)).foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).font(.system(size: 13, weight: .medium))
                            Text(device.connectionState == .paired ? "Connected" : "Disconnected")
                                .font(.caption)
                                .foregroundColor(device.connectionState == .paired ? .green : .secondary)
                        }
                        Spacer()
                        Button("Unpair") { manager.unpair(deviceId: device.id) }
                            .foregroundColor(.red).controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct PluginToggles: View {
    let device: Device
    @State private var enabledPlugins: Set<String> = []

    private let allPlugins: [(key: String, name: String, icon: String)] = [
        ("ping", "Ping", "bell.fill"),
        ("battery", "Battery", "battery.100"),
        ("notification", "Notifications", "app.badge.fill"),
        ("telephony", "Telephony", "phone.fill"),
        ("sms", "SMS Messages", "message.fill"),
        ("clipboard", "Clipboard Sync", "doc.on.clipboard.fill"),
        ("findmyphone", "Find My Phone", "location.fill"),
        ("share", "File Transfer", "paperplane.fill"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(allPlugins, id: \.key) { plugin in
                HStack(spacing: 10) {
                    Image(systemName: plugin.icon).frame(width: 16).foregroundColor(.secondary)
                    Text(plugin.name).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { enabledPlugins.contains(plugin.key) },
                        set: { on in
                            if on { enabledPlugins.insert(plugin.key) } else { enabledPlugins.remove(plugin.key) }
                            Config.shared.setEnabledPlugins(enabledPlugins, for: device.id)
                            DeviceManager.shared.reloadPlugins(for: device.id)
                        }
                    ))
                    .toggleStyle(.switch).controlSize(.mini)
                }
                .padding(.vertical, 3)
                if plugin.key != allPlugins.last?.key { Divider().padding(.leading, 26) }
            }
        }
        .onAppear { enabledPlugins = Config.shared.enabledPlugins(for: device.id) }
    }
}

// MARK: - Conversation Row

private struct ConversationRow: View {
    let conversation: SMSConversation
    let isSelected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
                    .frame(width: 36, height: 36)
                Text(String(conversation.name.prefix(2)).uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(conversation.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(conversation.lastMessageDate, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                HStack {
                    Text(conversation.lastMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : (hovered ? Color.primary.opacity(0.04) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: SMSMessage

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 60) }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                Text(message.body)
                    .font(.system(size: 13))
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(message.isFromMe ? Color.accentColor : Color.primary.opacity(0.08))
                    )
                    .frame(maxWidth: 400, alignment: message.isFromMe ? .trailing : .leading)

                Text(message.date, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            if !message.isFromMe { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 4)
    }
}
