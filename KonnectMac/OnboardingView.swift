import SwiftUI
import UserNotifications

struct OnboardingView: View {
    @State private var notificationGranted: Bool? = nil
    @State private var identityReady: Bool? = nil
    @State private var launchAtLogin = false
    @State private var tailscaleDetected = false
    @State private var tailscaleIP = ""
    @State private var identityError = false
    @State private var isCreatingIdentity = false
    @State private var showAndroid15Detail = false
    @State private var isAtBottom = false
    var onComplete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Left — branding panel
            VStack(spacing: 12) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(.white.opacity(0.1))
                        .frame(width: 88, height: 88)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.white)
                }

                Text("KonnectMac")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize()

                Text("Connect your Android\nphone to your Mac")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)

                Spacer()

                // Feature pills
                VStack(spacing: 6) {
                    FeaturePill("Notifications")
                    FeaturePill("Calls & Media")
                    FeaturePill("Clipboard Sync")
                    FeaturePill("File Transfer")
                }

                Spacer().frame(height: 16)
            }
            .padding(.horizontal, 24)
            .frame(width: 200)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.16, blue: 0.42),
                        Color(red: 0.14, green: 0.28, blue: 0.58),
                        Color(red: 0.10, green: 0.22, blue: 0.50)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )

            // Right — setup steps
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Welcome")
                        .font(.system(size: 20, weight: .bold))
                    Text("Let\u{2019}s get everything set up.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 20)

                    // Step 1 — Android prerequisite
                    StepRow(number: 1, icon: "iphone.and.arrow.forward", color: .purple) {
                        Text("Install KDE Connect on Android")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Available on Play Store and F-Droid.\nBoth devices must be on the same WiFi network.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    StepDivider()

                    // Step 2 — macOS Notifications
                    StepRow(number: 2,
                            icon: notificationGranted == true ? "checkmark.circle.fill" : "bell.badge.fill",
                            color: notificationGranted == true ? .green : .blue) {
                        HStack {
                            Text("Notifications").font(.system(size: 13, weight: .semibold))
                            if notificationGranted == true {
                                Text("Enabled")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.green.opacity(0.12)))
                            }
                        }
                        if notificationGranted != true {
                            Text("Required to show phone notifications on your Mac.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Button("Allow Notifications") { requestNotifications() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .padding(.top, 2)
                        }
                    }

                    StepDivider()

                    // Step 3 — Android 15 Sensitive Notifications
                    StepRow(number: 3, icon: "eye.trianglebadge.exclamationmark.fill", color: .orange) {
                        HStack {
                            Text("OTP & SMS Visibility").font(.system(size: 13, weight: .semibold))
                            Text("Android 15+")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.orange.opacity(0.12)))
                        }
                        Text("Android 15 hides OTP/2FA codes from notification listeners.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button(showAndroid15Detail ? "Hide Details" : "Show How to Fix") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showAndroid15Detail.toggle()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 2)

                        if showAndroid15Detail {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Label("ADB Command", systemImage: "1.circle.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("Recommended")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(.green))
                                }
                                Text("Keeps smart replies & suggested actions intact.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.green.opacity(0.8))
                                HStack(spacing: 6) {
                                    Text("adb shell appops set org.kde.kdeconnect_tp RECEIVE_SENSITIVE_NOTIFICATIONS allow")
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString("adb shell appops set org.kde.kdeconnect_tp RECEIVE_SENSITIVE_NOTIFICATIONS allow", forType: .string)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Copy to clipboard")
                                }
                                Text("Requires USB debugging. Reboot phone after.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)

                                Divider().padding(.vertical, 2)

                                Label("Alternative: Disable Enhanced Notifications", systemImage: "2.circle.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Disables smart replies & suggested actions globally.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange.opacity(0.8))
                                Text("Pixel: Settings \u{2192} Notifications \u{2192} Enhanced notifications \u{2192} OFF\nSamsung: Settings \u{2192} Notifications \u{2192} Advanced \u{2192} Suggest actions and replies \u{2192} OFF")
                                    .font(.system(size: 10, design: .monospaced))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                            .padding(.top, 4)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    StepDivider()

                    // Step 4 — Secure Identity
                    StepRow(number: 4,
                            icon: identityReady == true ? "checkmark.circle.fill" : "lock.shield.fill",
                            color: identityReady == true ? .green : .blue) {
                        HStack {
                            Text("Secure Identity").font(.system(size: 13, weight: .semibold))
                            if identityReady == true {
                                Text("Ready")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.green.opacity(0.12)))
                            }
                        }
                        Text("Generates a local certificate for encrypted pairing.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    StepDivider()

                    // Step 5 — Launch at Login
                    StepRow(number: 5, icon: "sunrise.fill", color: .orange) {
                        Toggle("Launch at Login", isOn: $launchAtLogin)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 13, weight: .semibold))
                            .onChange(of: launchAtLogin) { _, newValue in
                                Config.shared.autoStart = newValue
                            }
                    }

                    // Step 6 — Tailscale (optional, conditional)
                    if tailscaleDetected {
                        StepDivider()
                        StepRow(number: 6, icon: "network", color: .cyan) {
                            HStack(spacing: 6) {
                                Text("Tailscale").font(.system(size: 13, weight: .semibold))
                                Text("Optional")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.secondary.opacity(0.12)))
                            }
                            Text("Enter your phone\u{2019}s Tailscale IP for cross-network discovery.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            TextField("100.x.x.x", text: $tailscaleIP)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                        }
                    }

                    Spacer(minLength: 20)

                    // Footer — menu bar hint
                    HStack(spacing: 6) {
                        Image(systemName: "menubar.arrow.up.rectangle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        (Text("Look for ")
                            + Text(Image(systemName: "antenna.radiowaves.left.and.right"))
                            + Text(" in your menu bar after setup."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                    .padding(.bottom, 14)

                    if identityError {
                        Label("Failed to create secure identity. Please try again.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.bottom, 6)
                    }

                    Button(action: finish) {
                        if isCreatingIdentity {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Get Started")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isCreatingIdentity)
                    // Invisible bottom marker to detect scroll position
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: BottomVisibleKey.self,
                            value: geo.frame(in: .named("scroll")).maxY
                        )
                    }
                    .frame(height: 0)
                }
                .padding(24)
            }
            .coordinateSpace(name: "scroll")
            .onPreferenceChange(BottomVisibleKey.self) { maxY in
                // When the bottom of content is within the scroll view's visible area
                withAnimation(.easeOut(duration: 0.2)) {
                    isAtBottom = maxY < 660
                }
            }
            .frame(minWidth: 380)
            .scrollIndicators(.visible)
            .overlay(alignment: .bottom) {
                if !isAtBottom {
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.95)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 40)
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.compact.down")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("Scroll for more")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        }
        .frame(width: 620, height: 640)
        .onAppear {
            checkNotifications()
            checkIdentity()
            checkTailscale()
            launchAtLogin = Config.shared.autoStart
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkNotifications()
        }
    }

    private func checkNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                notificationGranted = settings.authorizationStatus == .authorized
            }
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                notificationGranted = granted
                if !granted {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings")!)
                }
            }
        }
    }

    private func checkIdentity() {
        identityReady = CertificateManager.shared.identityExists()
    }

    private func createIdentity(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let identity = CertificateManager.shared.getOrCreateIdentity()
            DispatchQueue.main.async {
                identityReady = identity != nil
                completion?()
            }
        }
    }

    private func checkTailscale() {
        tailscaleDetected = FileManager.default.fileExists(atPath: "/Applications/Tailscale.app")
        let saved = Config.shared.tailscaleIP
        if !saved.isEmpty { tailscaleIP = saved }
    }

    private func finish() {
        if !tailscaleIP.isEmpty {
            Config.shared.tailscaleIP = tailscaleIP
        }
        if identityReady != true {
            isCreatingIdentity = true
            identityError = false
            createIdentity {
                isCreatingIdentity = false
                guard identityReady == true else {
                    identityError = true
                    KLog.log("[Onboarding] Identity creation failed — cannot complete onboarding")
                    return
                }
                Config.shared.hasCompletedOnboarding = true
                onComplete()
            }
        } else {
            Config.shared.hasCompletedOnboarding = true
            onComplete()
        }
    }
}

// MARK: - Step Components

private struct StepRow<Content: View>: View {
    let number: Int
    let icon: String
    let color: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.system(size: 13))
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
        }
    }
}

private struct StepDivider: View {
    var body: some View {
        Divider().padding(.vertical, 10)
    }
}

private struct BottomVisibleKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct FeaturePill: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.12)))
    }
}
