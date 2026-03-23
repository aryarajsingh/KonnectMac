import SwiftUI
import UserNotifications

struct MenuBarView: View {
    @ObservedObject var manager = DeviceManager.shared
    @State private var notificationsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let paired = manager.devices.values
                .filter { $0.connectionState == .paired }
                .sorted { $0.name < $1.name }
            let discovered = manager.devices.values
                .filter { $0.connectionState == .discovered }
                .sorted { $0.name < $1.name }

            // Connected devices
            if !paired.isEmpty {
                ForEach(Array(paired), id: \.id) { device in
                    DeviceCard(device: device)
                }
            }

            // Discovered (unpaired) devices
            if !discovered.isEmpty {
                if !paired.isEmpty {
                    Divider().padding(.vertical, 6).padding(.horizontal, 12)
                }
                SectionLabel("Available")
                ForEach(Array(discovered), id: \.id) { device in
                    DiscoveredDeviceRow(device: device)
                }
            }

            // Empty state
            if paired.isEmpty && discovered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text("No Devices Found")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Open KDE Connect on your phone\nwhile on the same Wi-Fi")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            // Notification warning
            if !notificationsEnabled {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                    Text("Notifications off —")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Enable") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings")!)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
                    .accessibilityLabel("Enable notifications")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }

            Divider().padding(.vertical, 6).padding(.horizontal, 12)

            // App controls
            MenuItem("Preferences…", icon: "gearshape") {
                AppDelegate.instance?.openPreferences()
            }
            MenuItem("Quit KonnectMac", icon: "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 8)
        .frame(width: 280)
        .onAppear { checkNotifications() }
    }

    private func checkNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { notificationsEnabled = s.authorizationStatus == .authorized }
        }
    }
}

// MARK: - Device Card (paired/connected device)

private struct DeviceCard: View {
    @ObservedObject var device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + name + status + battery
            HStack(spacing: 10) {
                // Device icon with status dot
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: iconForDeviceType(device.type))
                        .font(.system(size: 18))
                        .foregroundStyle(.primary)
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                        .offset(x: 2, y: 2)
                }
                .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("Connected")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }

                Spacer()

                if device.batteryLevel >= 0 {
                    BatteryBadge(level: device.batteryLevel, charging: device.batteryCharging)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)

            // Quick actions — evenly distributed
            HStack(spacing: 6) {
                ActionChip("Ping", icon: "bell") {
                    (device.plugins["ping"] as? PingPlugin)?.sendPing()
                }
                .frame(maxWidth: .infinity)
                ActionChip("Find", icon: "location") {
                    (device.plugins["findmyphone"] as? FindMyPhonePlugin)?.ringPhone()
                }
                .frame(maxWidth: .infinity)
                ActionChip("Send File", icon: "paperplane") {
                    AppDelegate.instance?.sendFileFor(device: device)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Action Chip

private struct ActionChip: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    init(_ title: String, icon: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(hovered ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - Discovered Device Row

private struct DiscoveredDeviceRow: View {
    @ObservedObject var device: Device
    @ObservedObject var manager = DeviceManager.shared
    @State private var hovered = false

    private var isPairing: Bool {
        manager.pendingPairRequests.contains(device.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: iconForDeviceType(device.type))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(device.name)
                    .font(.system(size: 13))
                Spacer()
                if isPairing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Text("Pair")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovered ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture {
                if !isPairing {
                    DeviceManager.shared.requestPairing(deviceId: device.id)
                }
                // During pairing, tap does nothing — prevents accidental cancellation.
                // User can cancel via the explicit Cancel button shown below the verification key.
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Pair with \(device.name)")
            .accessibilityAddTraits(.isButton)

            if isPairing {
                VStack(alignment: .leading, spacing: 3) {
                    if let key = manager.verificationKey(for: device.id),
                       !key.isEmpty, key != "Unknown", key.count >= 4 {
                        HStack(spacing: 4) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 9))
                            Text("Verify: \(key)")
                                .font(.system(size: 11, weight: .medium).monospaced())
                        }
                        .foregroundColor(.orange)
                    }
                    HStack(spacing: 4) {
                        Text("Accept on phone")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("Cancel")
                            .font(.system(size: 10))
                            .foregroundColor(.red.opacity(0.7))
                            .onTapGesture {
                                DeviceManager.shared.cancelPairing(deviceId: device.id)
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                .padding(.leading, 22)
            }
        }
    }
}

// MARK: - Battery Badge

private struct BatteryBadge: View {
    let level: Int
    let charging: Bool

    private var icon: String {
        if charging { return "battery.100.bolt" }
        if level <= 25 { return "battery.25" }
        if level <= 50 { return "battery.50" }
        if level <= 75 { return "battery.75" }
        return "battery.100"
    }

    private var color: Color {
        if charging { return .green }
        if level <= 20 { return .red }
        return .secondary
    }

    var body: some View {
        if level >= 0 {
            HStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text("\(min(max(level, 0), 100))%")
                    .font(.system(size: 11).monospacedDigit())
            }
            .foregroundColor(color)
            .accessibilityLabel("Battery at \(level)%\(charging ? ", charging" : "")")
        }
    }
}

// MARK: - Menu Item (app-level actions)

private struct MenuItem: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    init(_ title: String, icon: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(hovered ? Color.accentColor.opacity(0.12) : .clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .padding(.horizontal, 4)
    }
}

// MARK: - Helpers

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }
}

func iconForDeviceType(_ type: String) -> String {
    switch type.lowercased() {
    case "phone", "smartphone": return "iphone"
    case "tablet": return "ipad"
    case "desktop": return "desktopcomputer"
    case "laptop": return "laptopcomputer"
    default: return "iphone"
    }
}
