import Foundation
import UserNotifications
import AppKit
import CoreAudio

@MainActor
class TelephonyPlugin: PluginProtocol {
    let device: Device
    private var wasPlayingMedia = false
    private var mediaPausedByUs = false
    private var currentCallId: String?      // For async pause race guard
    private var activeCallCount = 0          // Track concurrent calls (call waiting)
    private var callStartTime: Date?
    private var callTimeoutTask: Task<Void, Never>?
    private var callEndedTime: Date?

    // MediaRemote — pause/play commands + now playing info
    private var mrSendCommand: (@convention(c) (UInt32, AnyObject?) -> Bool)?
    private var mrGetNowPlayingInfo: (@convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void)?

    init(device: Device) {
        self.device = device
        loadMediaRemote()
    }

    var hasActiveCall: Bool { activeCallCount > 0 }

    // VoIP caller name resolution:
    // Telephony packets for VoIP calls often have no contactName.
    // The actual caller name arrives via the VoIP app's notification (NotificationPlugin).
    // These two flags cross-reference the two sources.
    private var callerUnknown = false
    private var pendingVoIPCaller: (name: String, time: Date)?

    /// Reset all call state on disconnect — prevents stale flags from bleeding into next connection
    func resetOnDisconnect() {
        callTimeoutTask?.cancel()
        callTimeoutTask = nil
        mediaPausedByUs = false
        wasPlayingMedia = false
        currentCallId = nil
        activeCallCount = 0
        callStartTime = nil
        callEndedTime = nil
        callerUnknown = false
        pendingVoIPCaller = nil
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
            let hadActiveCall = activeCallCount > 0
            if hadActiveCall {
                activeCallCount = max(0, activeCallCount - 1)
            }
            callTimeoutTask?.cancel()
            callTimeoutTask = nil
            callerUnknown = false
            pendingVoIPCaller = nil

            if activeCallCount == 0 {
                // Last call ended — safe to resume media
                resumeMediaIfNeeded()
                currentCallId = nil
                callStartTime = nil
                if hadActiveCall {
                    callEndedTime = Date()
                    KLog.log("[Telephony] Last call ended (isCancel), cooldown active for 5s")
                } else {
                    KLog.log("[Telephony] isCancel with no active call — ignoring (no cooldown)")
                }
            } else {
                KLog.log("[Telephony] Call ended but \(activeCallCount) call(s) still active — media stays paused")
            }
            dismissCallNotification()
            return
        }

        switch event {
        case "ringing":
            // ringing is AUTHORITATIVE — the phone only sends it for new incoming calls.
            if activeCallCount > 0 {
                // Call waiting — new call while already in a call.
                // DON'T resume media — it should stay paused.
                KLog.log("[Telephony] New ringing during active call (call waiting), \(activeCallCount) active")
                dismissCallNotification()
            }
            activeCallCount += 1
            currentCallId = UUID().uuidString

            // VoIP caller name resolution
            var displayName = name
            if displayName == "Unknown", let pending = pendingVoIPCaller,
               Date().timeIntervalSince(pending.time) < 5 {
                displayName = pending.name
                callerUnknown = false
                pendingVoIPCaller = nil
                KLog.log("[Telephony] Used buffered VoIP caller name: [redacted]")
            } else {
                callerUnknown = (displayName == "Unknown")
            }

            // Only pause if this is the first call (not already paused)
            if !mediaPausedByUs {
                pauseMediaPlayback()
            }
            showCallNotification(title: "Incoming Call", body: displayName, isMissed: false)
            startCallTimeout()
        case "missedCall":
            callTimeoutTask?.cancel()
            callTimeoutTask = nil
            activeCallCount = max(0, activeCallCount - 1)
            callerUnknown = false
            pendingVoIPCaller = nil
            dismissCallNotification()
            showCallNotification(title: "Missed Call", body: name, isMissed: true)

            if activeCallCount == 0 {
                resumeMediaIfNeeded()
                currentCallId = nil
                callStartTime = nil
                callEndedTime = Date()
            } else {
                KLog.log("[Telephony] Missed call but \(activeCallCount) call(s) still active — media stays paused")
            }
        case "talking":
            if activeCallCount == 0 {
                // "talking" without prior "ringing" = outgoing call OR stale event.
                if let ended = callEndedTime, Date().timeIntervalSince(ended) < 5 {
                    KLog.log("[Telephony] Ignoring 'talking' within \(Int(Date().timeIntervalSince(ended)))s of call end (stale)")
                } else {
                    // Real outgoing call
                    activeCallCount += 1
                    currentCallId = UUID().uuidString

                    var displayName = name
                    if displayName == "Unknown", let pending = pendingVoIPCaller,
                       Date().timeIntervalSince(pending.time) < 5 {
                        displayName = pending.name
                        callerUnknown = false
                        pendingVoIPCaller = nil
                        KLog.log("[Telephony] Used buffered VoIP caller name for outgoing: [redacted]")
                    } else {
                        callerUnknown = (displayName == "Unknown")
                    }

                    pauseMediaPlayback()
                    showCallNotification(title: "On Call", body: displayName, isMissed: false)
                    startCallTimeout()
                }
            } else {
                KLog.log("[Telephony] Duplicate 'talking' ignored (activeCallCount=\(activeCallCount))")
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

    /// Called by NotificationPlugin when a VoIP app's notification reveals the caller name.
    /// If we have an active call with unknown caller, update the notification seamlessly.
    func updateCallerName(_ name: String) {
        guard callerUnknown, currentCallId != nil, !name.isEmpty else { return }
        callerUnknown = false
        KLog.log("[Telephony] VoIP caller name resolved, updating notification")
        showCallNotification(title: "Incoming Call", body: name, isMissed: false)
    }

    /// Called by NotificationPlugin when a VoIP call notification arrives before the telephony packet.
    /// Buffers the caller name so the ringing/talking handler can pick it up.
    func bufferVoIPCaller(_ name: String) {
        guard !name.isEmpty else { return }
        pendingVoIPCaller = (name: name, time: Date())
        KLog.log("[Telephony] Buffered VoIP caller name for upcoming call")
    }

    func onCallEnded() {
        let hadActiveCall = activeCallCount > 0
        if hadActiveCall {
            activeCallCount = max(0, activeCallCount - 1)
        }
        callTimeoutTask?.cancel()
        callTimeoutTask = nil
        callerUnknown = false
        pendingVoIPCaller = nil

        if activeCallCount == 0 {
            // Last call ended — safe to resume
            resumeMediaIfNeeded()
            currentCallId = nil
            callStartTime = nil
            if hadActiveCall {
                callEndedTime = Date()
                KLog.log("[Telephony] Last call ended, cooldown active for 5s")
            } else {
                KLog.log("[Telephony] onCallEnded with no active call — ignoring (no cooldown)")
            }
        } else {
            KLog.log("[Telephony] Call ended but \(activeCallCount) call(s) still active — media stays paused")
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

        KLog.log("[Telephony] Posting notification: \(title) — \(id)")
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                KLog.log("[Telephony] Notification FAILED: \(error)")
            } else {
                KLog.log("[Telephony] Notification delivered: \(id)")
            }
        }
    }

    private func dismissCallNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["telephony-call-\(device.id)"])
    }

    // MARK: - Media Control (Hybrid: MediaRemote for pause decision, CoreAudio for resume safety)
    //
    // Why hybrid:
    // - CoreAudio isAudioPlaying() is synchronous + instant BUT catches ALL audio
    //   (system sounds, browser tabs, notification chimes) → false positives on pause
    // - MediaRemote GetNowPlayingInfo is media-player-specific (playbackRate > 0)
    //   BUT is async (callback) → can't use synchronously on MainActor
    //
    // Solution:
    // PAUSE: Async MediaRemote check → only pause if a real media player is playing
    // RESUME: Sync CoreAudio check → only resume if audio is NOT playing (our pause held)
    //
    // Race condition guard: capture callId before async → verify same call in callback

    private func loadMediaRemote() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY) else { return }
        mrSendCommand = unsafeBitCast(dlsym(handle, "MRMediaRemoteSendCommand"), to: (@convention(c) (UInt32, AnyObject?) -> Bool).self)
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            mrGetNowPlayingInfo = unsafeBitCast(sym, to: (@convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void).self)
        }
    }

    /// Synchronous CoreAudio check: is any audio output device active?
    /// Used for resume safety check only (not pause decision).
    private func isAudioOutputActive() -> Bool {
        var defaultDevice = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &defaultDevice
        )
        guard status == noErr, defaultDevice != 0 else { return false }

        var isRunning: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let runStatus = AudioObjectGetPropertyData(
            defaultDevice, &runningAddress, 0, nil, &runningSize, &isRunning
        )
        guard runStatus == noErr else { return false }
        return isRunning > 0
    }

    private func pauseMediaPlayback() {
        guard !mediaPausedByUs else {
            KLog.log("[Telephony] Already paused by us, skipping")
            return
        }

        let callId = currentCallId

        guard let getInfo = mrGetNowPlayingInfo else {
            // MediaRemote unavailable — fall back to CoreAudio (less precise but works)
            let audioPlaying = isAudioOutputActive()
            KLog.log("[Telephony] MediaRemote unavailable, CoreAudio fallback: \(audioPlaying)")
            mediaPausedByUs = true
            wasPlayingMedia = audioPlaying
            if audioPlaying, let send = mrSendCommand {
                let _ = send(1, nil)
                KLog.log("[Telephony] Paused via CoreAudio fallback")
            }
            return
        }

        // Async MediaRemote check — is a MEDIA PLAYER specifically playing?
        // Three outcomes:
        //   1. MediaRemote has info + playbackRate > 0 → media app playing → pause
        //   2. MediaRemote has info + playbackRate = 0 → media app paused → don't pause
        //   3. MediaRemote has NO info (empty dict) → no registered Now Playing app
        //      (e.g. YouTube in browser) → fall back to CoreAudio
        getInfo(DispatchQueue.global()) { [weak self] info in
            let isPlaying: Bool
            let hasNowPlayingApp = !info.isEmpty

            if hasNowPlayingApp {
                // A media app IS registered — trust MediaRemote's playback state
                let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
                isPlaying = rate > 0
            } else {
                // No registered Now Playing app — browser audio, web player, etc.
                // Fall back to CoreAudio (synchronous, catches all audio output)
                // This is safe to call from background queue
                var defaultDevice = AudioDeviceID(0)
                var size = UInt32(MemoryLayout<AudioDeviceID>.size)
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let st = AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &defaultDevice
                )
                if st == noErr, defaultDevice != 0 {
                    var isRunning: UInt32 = 0
                    var runningSize = UInt32(MemoryLayout<UInt32>.size)
                    var runningAddress = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    AudioObjectGetPropertyData(defaultDevice, &runningAddress, 0, nil, &runningSize, &isRunning)
                    isPlaying = isRunning > 0
                } else {
                    isPlaying = false
                }
            }

            Task { @MainActor in
                guard let self = self else { return }
                // Race guard: only proceed if same call is still active and we haven't paused yet
                guard self.currentCallId == callId, !self.mediaPausedByUs else {
                    KLog.log("[Telephony] Pause callback: call ended or already paused, skipping")
                    return
                }

                self.mediaPausedByUs = true
                self.wasPlayingMedia = isPlaying

                if isPlaying, let send = self.mrSendCommand {
                    let _ = send(1, nil) // MRMediaRemoteCommandPause = 1
                    if hasNowPlayingApp {
                        KLog.log("[Telephony] Paused media (MediaRemote: playbackRate > 0)")
                    } else {
                        KLog.log("[Telephony] Paused media (CoreAudio fallback: browser/web audio)")
                    }
                } else {
                    KLog.log("[Telephony] No media active (MediaRemote=\(hasNowPlayingApp ? "paused" : "empty"), CoreAudio=\(!hasNowPlayingApp ? "silent" : "n/a"))")
                }
            }
        }
    }

    private func resumeMediaIfNeeded() {
        KLog.log("[Telephony] Resume check: pausedByUs=\(mediaPausedByUs) wasPlaying=\(wasPlayingMedia)")
        guard mediaPausedByUs, wasPlayingMedia else {
            KLog.log("[Telephony] We didn't pause playing media, not resuming")
            mediaPausedByUs = false
            wasPlayingMedia = false
            return
        }

        // Sync CoreAudio check before resuming:
        // Audio IS playing → someone/something else resumed → don't interfere
        // Audio NOT playing → our pause is still in effect → safe to resume
        if isAudioOutputActive() {
            KLog.log("[Telephony] Audio already active (user or app resumed), skipping resume")
        } else if let send = mrSendCommand {
            let _ = send(0, nil) // MRMediaRemoteCommandPlay = 0
            KLog.log("[Telephony] Resumed media player")
        }
        mediaPausedByUs = false
        wasPlayingMedia = false
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
