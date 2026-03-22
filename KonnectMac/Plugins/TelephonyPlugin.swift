import Foundation
import UserNotifications
import AppKit

@MainActor
class TelephonyPlugin: PluginProtocol {
    let device: Device
    private var wasPlayingMedia = false
    private var mediaPausedByUs = false
    private var currentCallId: String?
    private var callStartTime: Date?
    private var callTimeoutTask: Task<Void, Never>?
    private var callEndedTime: Date?
    private var cachedMediaPlaying = false

    // MediaRemote
    private var mrSendCommand: (@convention(c) (UInt32, AnyObject?) -> Bool)?
    private var mrGetNowPlayingInfo: (@convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void)?

    init(device: Device) {
        self.device = device
        loadMediaRemote()
        updateMediaPlayerState()
    }

    var hasActiveCall: Bool { currentCallId != nil }

    /// Reset all call state on disconnect — prevents stale flags from bleeding into next connection
    func resetOnDisconnect() {
        callTimeoutTask?.cancel()
        callTimeoutTask = nil
        mediaPausedByUs = false
        wasPlayingMedia = false
        currentCallId = nil
        callStartTime = nil
        callEndedTime = nil
        KLog.log("[Telephony] State reset on disconnect")
    }

    func canHandle(type: String) -> Bool { type == "kdeconnect.telephony" }

    func handle(packet: NetworkPacket) {
        let event = packet.body["event"]?.value as? String ?? ""
        let name = packet.body["contactName"]?.value as? String
            ?? packet.body["phoneNumber"]?.value as? String ?? "Unknown"
        let isCancel = packet.body["isCancel"]?.value as? Bool ?? false

        KLog.log("[Telephony] Event: \(event), isCancel: \(isCancel)")

        if isCancel {
            let hadActiveCall = currentCallId != nil
            callTimeoutTask?.cancel()
            callTimeoutTask = nil
            resumeMediaIfNeeded()
            currentCallId = nil
            callStartTime = nil
            if hadActiveCall {
                callEndedTime = Date()
                KLog.log("[Telephony] Call cancelled via telephony packet, cooldown active for 5s")
            } else {
                KLog.log("[Telephony] isCancel with no active call — ignoring (no cooldown)")
            }
            dismissCallNotification()
            return
        }

        switch event {
        case "ringing":
            guard currentCallId == nil else { return }
            currentCallId = UUID().uuidString
            pauseMediaPlayback()
            showCallNotification(title: "Incoming Call", body: name, isMissed: false)
            startCallTimeout()
        case "missedCall":
            callTimeoutTask?.cancel()
            callTimeoutTask = nil
            resumeMediaIfNeeded()
            currentCallId = nil
            callStartTime = nil
            callEndedTime = Date()
            dismissCallNotification()
            showCallNotification(title: "Missed Call", body: name, isMissed: true)
        case "talking":
            if currentCallId == nil {
                // Ignore "talking" within 5s of a call ending — stale event from phone
                if let ended = callEndedTime, Date().timeIntervalSince(ended) < 5 {
                    KLog.log("[Telephony] Ignoring 'talking' within \(Int(Date().timeIntervalSince(ended)))s of call end")
                    return
                }
                // Outgoing call (no prior ringing)
                currentCallId = UUID().uuidString
                pauseMediaPlayback()
                showCallNotification(title: "On Call", body: name, isMissed: false)
                startCallTimeout()
            } else {
                // Duplicate "talking" while already on call — ignore
                KLog.log("[Telephony] Duplicate 'talking' ignored (already in call)")
            }
        default:
            break
        }
    }

    // Called from NotificationPlugin when incallui notification appears/disappears
    func onCallStarted(caller: String) {
        guard currentCallId == nil else { return }
        // Ignore call-start signals within 5s of a call ending — the dialer sends
        // post-call notifications (call log, duration) that aren't actual new calls
        if let ended = callEndedTime, Date().timeIntervalSince(ended) < 5 {
            KLog.log("[Telephony] Ignoring onCallStarted within \(Int(Date().timeIntervalSince(ended)))s of call end (post-call notification)")
            return
        }
        currentCallId = UUID().uuidString
        pauseMediaPlayback()
        showCallNotification(title: "On Call", body: caller, isMissed: false)
        startCallTimeout()
    }

    func onCallEnded() {
        let hadActiveCall = currentCallId != nil
        callTimeoutTask?.cancel()
        callTimeoutTask = nil
        resumeMediaIfNeeded()
        currentCallId = nil
        callStartTime = nil
        // Only set cooldown if there was an actual active call — spurious dialer
        // cancel events (before any ringing/talking) should NOT block future calls
        if hadActiveCall {
            callEndedTime = Date()
            KLog.log("[Telephony] Call ended, cooldown active for 5s")
        } else {
            KLog.log("[Telephony] onCallEnded with no active call — ignoring (no cooldown)")
        }
        dismissCallNotification()
    }

    private func startCallTimeout() {
        callTimeoutTask?.cancel()
        callStartTime = Date()
        callTimeoutTask = Task { @MainActor in
            // If no call-end signal after 2 hours, assume call ended
            try? await Task.sleep(nanoseconds: 2 * 60 * 60 * 1_000_000_000)
            guard !Task.isCancelled, currentCallId != nil else { return }
            KLog.log("[Telephony] Call timeout — forcing end after 2 hours")
            onCallEnded()
        }
    }

    private func showCallNotification(title: String, body: String, isMissed: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // Try to get phone app icon from NotificationPlugin cache
        if let notifPlugin = device.plugins["notification"] as? NotificationPlugin,
           let iconPath = notifPlugin.getCachedIconPath(packageName: "com.samsung.android.dialer")
               ?? notifPlugin.getCachedIconPath(packageName: "com.android.dialer")
               ?? notifPlugin.getCachedIconPath(packageName: "com.google.android.dialer") {
            // Hardlink so UNNotificationAttachment move doesn't destroy the cache
            let linkPath = NSTemporaryDirectory() + "konnect-call-\(UUID().uuidString).png"
            if let _ = try? FileManager.default.linkItem(atPath: iconPath, toPath: linkPath) {
                if let attachment = try? UNNotificationAttachment(identifier: "icon", url: URL(fileURLWithPath: linkPath), options: [
                    UNNotificationAttachmentOptionsTypeHintKey: "public.png",
                    UNNotificationAttachmentOptionsThumbnailClippingRectKey: CGRect(x: 0, y: 0, width: 1, height: 1).dictionaryRepresentation
                ]) {
                    content.attachments = [attachment]
                } else {
                    try? FileManager.default.removeItem(atPath: linkPath)
                }
            }
        } else {
            // SF Symbol fallback
            let symbolName = isMissed ? "phone.arrow.down.left" : "phone.fill"
            let color = isMissed ? NSColor.systemRed : NSColor.systemGreen
            if let iconPath = createSFSymbolIcon(named: symbolName, color: color) {
                if let attachment = try? UNNotificationAttachment(identifier: "icon", url: URL(fileURLWithPath: iconPath), options: [
                    UNNotificationAttachmentOptionsTypeHintKey: "public.png"
                ]) {
                    content.attachments = [attachment]
                }
            }
        }

        if !isMissed {
            content.categoryIdentifier = "CALL_ACTIONS"
            content.userInfo = ["deviceId": device.id]
        }

        let id = isMissed ? "telephony-missed-\(device.id)" : "telephony-call-\(device.id)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized {
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        KLog.log("[Telephony] Notification error: \(error)")
                    }
                }
            } else {
                DispatchQueue.main.async {
                    NSSound.beep()
                }
                KLog.log("[Telephony] Notifications denied, played beep")
            }
        }
    }

    private func dismissCallNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["telephony-call-\(device.id)"])
    }

    // MARK: - Media Control via MediaRemote

    private func loadMediaRemote() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY) else { return }
        mrSendCommand = unsafeBitCast(dlsym(handle, "MRMediaRemoteSendCommand"), to: (@convention(c) (UInt32, AnyObject?) -> Bool).self)
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            mrGetNowPlayingInfo = unsafeBitCast(sym, to: (@convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void).self)
        }
    }

    /// Update cached media player state asynchronously via MediaRemote.
    /// Call this periodically or on app activation so `isMediaPlayerPlaying()` has a fresh value.
    func updateMediaPlayerState() {
        guard let getInfo = mrGetNowPlayingInfo else { return }

        getInfo(DispatchQueue.global()) { [weak self] info in
            let playing: Bool
            if let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double {
                playing = rate > 0
            } else {
                playing = false
            }
            DispatchQueue.main.async {
                self?.cachedMediaPlaying = playing
            }
        }
    }

    /// Check if a media player is actively playing via MediaRemote (not CoreAudio).
    /// CoreAudio's isRunningSomewhere catches ALL audio (system sounds, browser, notification chimes).
    /// MediaRemote's NowPlayingInfo targets the actual media player and its playbackRate.
    /// Returns the cached value updated by `updateMediaPlayerState()` — non-blocking.
    private func isMediaPlayerPlaying() -> Bool {
        return cachedMediaPlaying
    }

    private func pauseMediaPlayback() {
        guard !mediaPausedByUs else {
            KLog.log("[Telephony] Already paused by us, skipping")
            return
        }

        // Check the actual media player state (not CoreAudio which catches all audio)
        let mediaPlaying = isMediaPlayerPlaying()
        KLog.log("[Telephony] Media player active: \(mediaPlaying)")

        guard mediaPlaying else {
            KLog.log("[Telephony] No media player active, nothing to pause")
            return
        }

        // Media is truly playing — pause it and record that we did
        mediaPausedByUs = true
        wasPlayingMedia = true

        if let send = mrSendCommand {
            let _ = send(1, nil) // MRMediaRemoteCommandPause = 1
            KLog.log("[Telephony] Paused media player")
        }
    }

    private func resumeMediaIfNeeded() {
        KLog.log("[Telephony] Resume check: pausedByUs=\(mediaPausedByUs) wasPlaying=\(wasPlayingMedia)")
        guard mediaPausedByUs, wasPlayingMedia else {
            KLog.log("[Telephony] We didn't pause media, not resuming")
            mediaPausedByUs = false
            wasPlayingMedia = false
            currentCallId = nil
            return
        }

        // Double-check: if media is already playing, someone else resumed — don't interfere
        if isMediaPlayerPlaying() {
            KLog.log("[Telephony] Media already playing (user or another app resumed), skipping resume")
        } else {
            if let send = mrSendCommand {
                let _ = send(0, nil) // MRMediaRemoteCommandPlay = 0
                KLog.log("[Telephony] Resumed media player")
            }
        }
        mediaPausedByUs = false
        wasPlayingMedia = false
        currentCallId = nil
    }

    // Cache SF symbol icons in memory — generated once, reused for all calls.
    // UNNotificationAttachment moves the file, so we write a fresh copy each time
    // from cached PNG data (no temp file accumulation).
    private static var sfSymbolCache: [String: Data] = [:]

    private func createSFSymbolIcon(named: String, color: NSColor) -> String? {
        let cacheKey = "\(named)-\(color.description)"

        let pngData: Data
        if let cached = Self.sfSymbolCache[cacheKey] {
            pngData = cached
        } else {
            guard let image = NSImage(systemSymbolName: named, accessibilityDescription: nil) else { return nil }
            let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .medium)
            guard let configured = image.withSymbolConfiguration(config) else { return nil }

            let size = NSSize(width: 64, height: 64)
            let finalImage = NSImage(size: size, flipped: false) { rect in
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
                NSColor.white.setFill()
                let symbolRect = NSRect(x: 12, y: 12, width: 40, height: 40)
                configured.draw(in: symbolRect, from: .zero, operation: .sourceAtop, fraction: 1.0)
                return true
            }

            guard let tiffData = finalImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
            Self.sfSymbolCache[cacheKey] = data
            pngData = data
        }

        // Write a disposable copy for UNNotificationAttachment (it moves/deletes the file)
        let tempPath = NSTemporaryDirectory() + "konnect-sf-\(UUID().uuidString).png"
        try? pngData.write(to: URL(fileURLWithPath: tempPath))
        return tempPath
    }
}
