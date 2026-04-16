import SwiftUI
import UserNotifications
import Combine
import Security

@main
struct KonnectMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            PreferencesView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
    static var instance: AppDelegate?
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var onboardingWindow: NSWindow?
    private var preferencesWindow: NSWindow?
    private var notificationWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var lockFileFD: Int32 = -1
    private var preferencesCloseObserver: NSObjectProtocol?
    private var notificationCloseObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance enforcement via lock file
        if !acquireLockFile() {
            let alert = NSAlert()
            alert.messageText = "KonnectMac is already running"
            alert.informativeText = "Another instance of KonnectMac is already active. Only one instance can run at a time."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        AppDelegate.instance = self
        UNUserNotificationCenter.current().delegate = self
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        NSApp.disableRelaunchOnLogin()

        // Suppress ALL keychain dialogs for this process.
        // Our app keychain has an empty password and is always unlocked,
        // so operations succeed silently. This prevents macOS from ever
        // showing "KonnectMac wants to use keychain" prompts.
        SecKeychainSetUserInteractionAllowed(false)

        Config.shared.syncLoginItemStatus()

        // Show onboarding if: never completed, OR identity was wiped (fresh install over old prefs)
        let needsOnboarding = !Config.shared.hasCompletedOnboarding || !CertificateManager.shared.identityExists()
        if !needsOnboarding {
            setupMenuBar()
            startServices()
        } else {
            showOnboarding()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop broadcast timer
        DeviceManager.shared.stopServices()

        // Remove preferences close observer
        if let observer = preferencesCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            preferencesCloseObserver = nil
        }
        if let observer = notificationCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationCloseObserver = nil
        }

        // Release lock file
        releaseLockFile()

        KLog.log("[App] Terminated gracefully")
    }

    // MARK: - Single Instance Lock

    private func acquireLockFile() -> Bool {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            KLog.log("[App] Cannot find Application Support directory", level: .error)
            return true // Allow launch anyway — don't block on lock failure
        }
        let lockDir = appSupport.appendingPathComponent("KonnectMac")
        try? FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        let lockPath = lockDir.appendingPathComponent(".lock").path

        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            KLog.log("[App] Cannot open lock file: errno=\(errno)", level: .error)
            return true // Allow launch anyway
        }

        // Try to acquire an exclusive non-blocking lock
        // flock() auto-releases when process dies (even SIGKILL)
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // Lock held by another LIVE process
            Darwin.close(fd)
            return false
        }

        // Write our PID for debugging
        let pidStr = "\(ProcessInfo.processInfo.processIdentifier)\n"
        pidStr.data(using: .utf8).map { _ = Darwin.write(fd, ($0 as NSData).bytes, $0.count) }

        lockFileFD = fd
        return true
    }

    private func releaseLockFile() {
        guard lockFileFD >= 0 else { return }
        flock(lockFileFD, LOCK_UN)
        Darwin.close(lockFileFD)
        lockFileFD = -1
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        NSApp.setActivationPolicy(.regular)

        let onboardingView = OnboardingView { [weak self] in
            self?.completeOnboarding()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to KonnectMac"
        window.delegate = self // Prevent Cmd+W from closing onboarding
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.level = .floating // Ensure onboarding appears above all other windows
        NSApp.activate(ignoringOtherApps: true)
        // Reset window level after activation so it behaves normally
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            window.level = .normal
        }
        self.onboardingWindow = window
    }

    private func completeOnboarding() {
        setupMenuBar()
        startServices()
        onboardingWindow?.orderOut(nil)

        // Hide dock icon after a brief delay (menu bar icon is already visible)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing onboarding quits the app — setup is required
        if sender == onboardingWindow {
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    // MARK: - Menu Bar Setup

    func setupMenuBar() {
        guard statusItem == nil else {
            KLog.log("[MenuBar] setupMenuBar called but statusItem already exists — skipping")
            return
        }

        KLog.log("[MenuBar] Creating status item")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            let img = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right.slash", accessibilityDescription: "KonnectMac")
            img?.isTemplate = true
            button.image = img
            button.target = self
            button.action = #selector(togglePopover)
            KLog.log("[MenuBar] Button configured: image=\(img != nil), frame=\(button.frame), isHidden=\(button.isHidden)")

            let dropView = StatusBarDropView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            button.addSubview(dropView)
            KLog.log("[MenuBar] DropView added: frame=\(dropView.frame)")
        } else {
            KLog.log("[MenuBar] ERROR: statusItem.button is nil")
        }

        popover = NSPopover()
        popover?.contentSize = NSSize(width: 280, height: 300)
        popover?.behavior = .transient
        popover?.animates = true
        popover?.contentViewController = NSHostingController(rootView: MenuBarView())
        KLog.log("[MenuBar] Popover created")

        DeviceManager.shared.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                self?.updateStatusBarIcon(devices: devices)
            }
            .store(in: &cancellables)
    }

    private func updateStatusBarIcon(devices: [String: Device]) {
        guard let button = statusItem?.button else {
            KLog.log("[MenuBar] updateStatusBarIcon: button is nil")
            return
        }
        let hasConnected = devices.values.contains { $0.connectionState == .paired }
        let iconName = hasConnected
            ? "antenna.radiowaves.left.and.right"
            : "antenna.radiowaves.left.and.right.slash"
        let img = NSImage(systemSymbolName: iconName, accessibilityDescription: "KonnectMac")
        img?.isTemplate = true
        button.image = img
        KLog.log("[MenuBar] Icon updated: \(iconName), image=\(img != nil), buttonHidden=\(button.isHidden), frame=\(button.frame)")
    }

    // MARK: - Popover

    @objc func togglePopover() {
        if let popover = popover, popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private var popoverRetryCount = 0

    private func showPopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        // Ensure the button has a valid frame (not zero) before showing
        guard button.window != nil, button.bounds.width > 0 else {
            // Retry after a short delay if button isn't laid out yet (max 10 retries)
            popoverRetryCount += 1
            guard popoverRetryCount <= 10 else {
                KLog.log("[UI] Popover retry limit reached, giving up")
                popoverRetryCount = 0
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showPopover()
            }
            return
        }
        popoverRetryCount = 0
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func dismissPopover() {
        popover?.performClose(nil)
    }

    // MARK: - Actions (called from SwiftUI views)

    func sendFileFor(device: Device) {
        dismissPopover()
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                (device.plugins["share"] as? SharePlugin)?.sendFile(url: url)
            }
        }
    }

    @objc func openPreferences() {
        dismissPopover()

        if let existing = preferencesWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "KonnectMac Preferences"
        window.contentView = NSHostingView(rootView: PreferencesView())
        window.center()
        window.isReleasedWhenClosed = false
        preferencesWindow = window

        // Show dock icon while Preferences is open
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        // Watch for window close to hide dock icon
        // Remove previous observer if any (prevents leak on repeated opens)
        if let observer = preferencesCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        preferencesCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.preferencesWindow = nil
            if let observer = self?.preferencesCloseObserver {
                NotificationCenter.default.removeObserver(observer)
                self?.preferencesCloseObserver = nil
            }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func openNotificationPanel() {
        dismissPopover()

        if let existing = notificationWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Notifications"
        window.contentView = NSHostingView(rootView: NotificationPanelView())
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 300)
        notificationWindow = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        if let observer = notificationCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.notificationWindow = nil
            if let observer = self?.notificationCloseObserver {
                NotificationCenter.default.removeObserver(observer)
                self?.notificationCloseObserver = nil
            }
            if self?.preferencesWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    // When dock icon is clicked while Preferences is open, focus Preferences (don't open menu)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = preferencesWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return false
        }
        if let window = notificationWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return false
        }
        return false
    }

    // MARK: - Services

    @MainActor private func startServices() {
        // Clean stale login keychain items from older versions (prevents leftover prompts)
        CertificateManager.shared.cleanupOldKeychainItems()
        NotificationPlugin.registerNotificationCategories()
        DeviceManager.shared.start()

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
            KLog.log("[App] Notifications: status=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue) sound=\(settings.soundSetting.rawValue) banner=\(settings.alertStyle.rawValue)")
            // If not yet determined, request authorization
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    KLog.log("[App] Notification auth result: granted=\(granted) error=\(error?.localizedDescription ?? "none")")
                }
            } else if !granted {
                KLog.log("[App] WARNING: Notifications not authorized. Users should enable in System Settings > Notifications > KonnectMac")
            }
        }
    }

    // MARK: - Notification Delegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo

        switch response.actionIdentifier {
        case "REPLY_ACTION":
            if let textResponse = response as? UNTextInputNotificationResponse,
               let replyId = userInfo["replyId"] as? String,
               let deviceId = userInfo["deviceId"] as? String {
                let replyPacket = NetworkPacket(type: "kdeconnect.notification.reply", body: [
                    "requestReplyId": AnyCodable(replyId),
                    "message": AnyCodable(textResponse.userText)
                ])
                Task { @MainActor in
                    DeviceManager.shared.devices[deviceId]?.send(replyPacket)
                }
            }
        case "MUTE_RINGER":
            if let deviceId = userInfo["deviceId"] as? String {
                let mutePacket = NetworkPacket(type: "kdeconnect.telephony.request_mute")
                Task { @MainActor in
                    DeviceManager.shared.devices[deviceId]?.send(mutePacket)
                }
            }
        case "SHOW_IN_FINDER":
            if let path = userInfo["filePath"] as? String {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            }
        case "COPY_OTP":
            if let code = userInfo["otpCode"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                KLog.log("[OTP] Copied code to clipboard: \(code)")
            }
        default:
            break
        }

        completionHandler()
    }
}

// MARK: - Services (Right-Click > Services > Send to Phone)

extension AppDelegate {
    @objc func openFilesService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var fileURLs: [URL] = []
        if let files = pboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            fileURLs = files.filter { $0.isFileURL }
        }

        guard !fileURLs.isEmpty else {
            error.pointee = "No files selected." as NSString
            return
        }

        let pairedDevices = DeviceManager.shared.devices.values
            .filter { $0.connectionState == .paired }
            .sorted { ($0.kdeConn != nil ? 0 : 1) < ($1.kdeConn != nil ? 0 : 1) }

        guard !pairedDevices.isEmpty else {
            error.pointee = "No paired devices. Open KonnectMac to pair a device." as NSString
            return
        }

        if pairedDevices.count == 1 {
            let device = pairedDevices[0]
            for url in fileURLs {
                (device.plugins["share"] as? SharePlugin)?.sendFile(url: url)
            }
            KLog.log("[Service] Sent \(fileURLs.count) file(s) to \(device.name)")
        } else {
            // Multiple paired devices — show picker
            let alert = NSAlert()
            alert.messageText = "Send to Device"
            alert.informativeText = "Choose which device to send \(fileURLs.count) file(s) to:"
            alert.alertStyle = .informational

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            popup.addItems(withTitles: pairedDevices.map { $0.name })
            alert.accessoryView = popup
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")

            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                let idx = popup.indexOfSelectedItem
                guard idx >= 0, idx < pairedDevices.count else { return }
                let device = pairedDevices[idx]
                for url in fileURLs {
                    (device.plugins["share"] as? SharePlugin)?.sendFile(url: url)
                }
                KLog.log("[Service] Sent \(fileURLs.count) file(s) to \(device.name) via picker")
            }
        }
    }
}

// MARK: - Drag & Drop on Status Bar Icon

class StatusBarDropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Pass all mouse events through to the button underneath
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return false }

        Task { @MainActor in
            // Prefer the paired device with an active connection
            let pairedDevices = DeviceManager.shared.devices.values
                .filter { $0.connectionState == .paired }
                .sorted { ($0.kdeConn != nil ? 0 : 1) < ($1.kdeConn != nil ? 0 : 1) }
            guard let device = pairedDevices.first else { return }

            for url in urls {
                (device.plugins["share"] as? SharePlugin)?.sendFile(url: url)
            }
        }
        return true
    }
}
