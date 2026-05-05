import Foundation
import UserNotifications
import AppKit
import Security

@MainActor
class NotificationPlugin: PluginProtocol {
    let device: Device

    // STATIC state — survives plugin recreation across reconnections.
    // Without this, every reconnection wipes the dedup set (causing duplicate notifications)
    // and the icon cache (causing re-downloads and missing icons).
    private static var shownNotificationIds = Set<String>()
    private static var shownNotificationOrder: [String] = []
    private static var notificationContentHash: [String: String] = [:]
    private static var iconCache: [String: String] = [:]
    private static var pendingIconDownloads: [String: [(String?) -> Void]] = [:]
    private static var cacheLoaded = false
    private static var lastCacheCleanup = Date()

    // Rate limiting: max 10 notifications per second per device
    private static var rateLimitCount = 0
    private static var rateLimitWindowStart = Date.distantPast

    private static let cacheDir: String = {
        let path = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KonnectMac/AppIcons").path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    private let filteredPackages = Set([
        "android", "com.android.systemui", "com.android.providers",
        "com.android.settings", "com.android.vending",
        "org.kde.kdeconnect_tp"  // Never mirror KDE Connect's own notifications (pairing dialogs, connection status)
    ])

    private let filteredTitles = Set([
        "USB debugging connected", "Android System", "System UI"
    ])

    // VoIP apps — their call notifications contain the actual caller name
    // Used to cross-reference with telephony events that arrive without contactName
    static let voipPackages = Set([
        "com.whatsapp", "com.whatsapp.w4b",
        "com.google.android.apps.meetings",   // Google Meet
        "com.google.android.apps.tachyon",     // Google Duo / Meet calling
        "us.zoom.videomeetings",
        "org.telegram.messenger",
        "com.skype.raider", "com.skype.m2",
        "com.discord",
        "com.microsoft.teams",
        "com.facebook.orca",                   // Messenger
        "com.viber.voip",
        "com.linecorp.LINEAPP",
    ])

    // Apps that ship the sender's profile picture as the notification icon payload
    // instead of the actual app icon. We must never cache these — the payload is per-
    // notification (a different person every time), and caching one would freeze that
    // person's face as the "app icon" forever.
    //
    // Coverage rule of thumb: any app that's primarily a per-sender DM channel
    // (email, messaging, social DMs) belongs here. Apps that send their own brand icon
    // (news, banking, shopping) do NOT.
    //
    // For every package listed here, we also fall back to the SF Symbol icon defined
    // in `knownAppIcons` below. If a package is here without a matching SF Symbol,
    // notifications from it will be iconless.
    static let senderPicturePackages = Set([
        // Email
        "com.google.android.gm", "com.microsoft.office.outlook",
        "com.yahoo.mobile.client.android.mail", "com.samsung.android.email.provider",
        "com.android.email", "com.google.android.gm.lite",
        "email.titan.app",  // Titan — sends sender's profile pic as the icon payload
        // Messaging
        "com.whatsapp", "com.whatsapp.w4b",
        "org.telegram.messenger", "org.thunderdog.challegram",
        "com.facebook.orca",  // Messenger
        "com.discord", "com.snapchat.android",
        "org.thoughtcrime.securesms",  // Signal
        "com.microsoft.teams", "com.Slack",
        "com.google.android.apps.dynamite",  // Google Chat
        "com.linecorp.LINEAPP",
        // Social with DMs
        "com.instagram.android",
        "com.facebook.katana",
        "com.twitter.android", "com.x.android",  // X (formerly Twitter)
        "com.linkedin.android",
        "com.reddit.frontpage",
        // Carrier / SMS apps that send contact pics
        "com.google.android.apps.messaging",
        "com.samsung.android.messaging",
    ])

    /// Helper to construct an NSColor from a hex literal — keeps the brand color
    /// table below readable.
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >>  8) & 0xFF) / 255,
                blue:  CGFloat( hex        & 0xFF) / 255,
                alpha: 1.0)
    }

    /// Real brand assets — bundled in `Assets.xcassets/BrandIcons/`.
    ///
    /// Two flavors, distinguished by `color`:
    /// - `color: <some>`: monochrome white-on-transparent SVG from simple-icons
    ///   (CC0 / public domain). At runtime we composite the white logo onto a
    ///   rounded brand-colored square. This is what most entries use because the
    ///   simple-icons SVGs are tiny and uniform.
    /// - `color: nil`: the asset is already a complete app icon (e.g. fetched from
    ///   the Google Play Store) with its own background, padding, and rounded
    ///   corners. We render it as-is, no compositing.
    private static let brandAssets: [String: (asset: String, color: NSColor?)] = [
        // Email
        "com.google.android.gm":            ("gmail",          rgb(0xEA4335)),
        "com.google.android.gm.lite":       ("gmail",          rgb(0xEA4335)),
        "email.titan.app":                  ("titan",          nil),  // full app icon
        // Messaging
        "com.whatsapp":                     ("whatsapp",       rgb(0x25D366)),
        "com.whatsapp.w4b":                 ("whatsapp",       rgb(0x25D366)),
        "org.telegram.messenger":           ("telegram",       rgb(0x26A5E4)),
        "org.thunderdog.challegram":        ("telegram",       rgb(0x26A5E4)),
        "com.facebook.orca":                ("messenger",      rgb(0x006AFF)),
        "com.discord":                      ("discord",        rgb(0x5865F2)),
        "com.snapchat.android":             ("snapchat",       rgb(0xFFFC00)),
        "org.thoughtcrime.securesms":       ("signal",         rgb(0x3A76F0)),
        "com.google.android.apps.dynamite": ("googlechat",     rgb(0x00897B)),
        "com.linecorp.LINEAPP":             ("line",           rgb(0x00B900)),
        // Social
        "com.instagram.android":            ("instagram",      rgb(0xE4405F)),
        "com.facebook.katana":              ("facebook",       rgb(0x1877F2)),
        "com.twitter.android":              ("x",              rgb(0x000000)),
        "com.x.android":                    ("x",              rgb(0x000000)),
        "com.reddit.frontpage":             ("reddit",         rgb(0xFF4500)),
        // Carrier SMS
        "com.google.android.apps.messaging":("googlemessages", rgb(0x1A73E8)),
        // Media / shopping / productivity
        "com.google.android.youtube":       ("youtube",        rgb(0xFF0000)),
        "com.spotify.music":                ("spotify",        rgb(0x1DB954)),
        "com.google.android.apps.maps":     ("googlemaps",     rgb(0x4285F4)),
        "com.google.android.calendar":      ("googlecalendar", rgb(0x4285F4)),
        "com.google.android.apps.docs":     ("googledrive",    rgb(0x4285F4)),
    ]

    /// SF Symbol fallbacks for apps where we don't have a real bundled brand asset.
    /// Used only when `brandAssets` doesn't contain the package — a small set covering
    /// dialers and a few other things.
    private static let knownAppIcons: [String: (symbol: String, color: NSColor)] = [
        // Email (no simple-icons asset for these — Outlook/Yahoo are not on simple-icons CDN.
        // Titan moved to brandAssets above with its real Play Store icon.)
        "com.microsoft.office.outlook":      ("envelope.fill", .systemBlue),
        "com.yahoo.mobile.client.android.mail": ("envelope.fill", .systemPurple),
        "com.samsung.android.email.provider": ("envelope.fill", .systemBlue),
        // Messaging (LinkedIn, Teams, Slack are also missing from CDN)
        "com.linkedin.android":              ("briefcase.fill", .systemBlue),
        "com.microsoft.teams":               ("person.2.fill", rgb(0x6264A7)),
        "com.Slack":                         ("number.square.fill", rgb(0x4A154B)),
        // Shopping
        "com.amazon.mShop.android.shopping": ("cart.fill", .systemOrange),
        // Dialers
        "com.google.android.dialer":         ("phone.fill", .systemGreen),
        "com.samsung.android.dialer":        ("phone.fill", .systemGreen),
        "com.samsung.android.messaging":     ("message.fill", .systemBlue),
    ]

    private static var fallbackIconCache: [String: String] = [:]

    /// Generate a fallback icon for a package. Prefers a real bundled brand logo
    /// (Instagram, WhatsApp, etc.) over an SF Symbol, but falls back to SF Symbol when
    /// no brand asset is bundled. Result is rendered to a 64×64 PNG and cached on disk.
    private static func fallbackIcon(for packageName: String) -> String? {
        if let cached = fallbackIconCache[packageName] { return cached }

        // Path 1: real brand asset (preferred).
        if let brand = brandAssets[packageName] {
            return renderBrandIcon(packageName: packageName, assetName: brand.asset, background: brand.color)
        }

        // Path 2: SF Symbol fallback for the long tail.
        if let info = knownAppIcons[packageName] {
            return renderSFSymbolIcon(packageName: packageName, symbolName: info.symbol, background: info.color)
        }

        return nil
    }

    /// Render a bundled brand asset to a 64×64 PNG.
    ///
    /// If `background` is non-nil, treats the asset as a monochrome white logo and
    /// composites it onto a rounded brand-colored square (the simple-icons pipeline).
    /// If `background` is nil, the asset is already a complete app icon — we just
    /// scale it to 64×64 and write it out.
    private static func renderBrandIcon(packageName: String, assetName: String, background: NSColor?) -> String? {
        guard let logo = NSImage(named: assetName) else {
            KLog.log("[Notification] Brand asset '\(assetName)' missing for \(packageName)")
            return nil
        }
        let size = NSSize(width: 64, height: 64)
        let finalImage = NSImage(size: size, flipped: false) { rect in
            if let bg = background {
                // Monochrome logo + brand-color background (simple-icons style).
                let bgRect = rect.insetBy(dx: 2, dy: 2)
                let path = NSBezierPath(roundedRect: bgRect, xRadius: 14, yRadius: 14)
                bg.setFill()
                path.fill()
                // Inset 14px on each side gives a 36×36 logo area in a 64×64 icon —
                // roughly Apple HIG proportions for an iOS-style app icon.
                let logoRect = NSRect(x: 14, y: 14, width: 36, height: 36)
                logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            } else {
                // Asset is already a full app icon — render edge to edge.
                logo.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }

        return writeIconPng(finalImage, packageName: packageName)
    }

    /// Render an SF Symbol on a brand-colored rounded square — used for apps where we
    /// don't have a bundled logo asset.
    private static func renderSFSymbolIcon(packageName: String, symbolName: String, background: NSColor) -> String? {
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 36, weight: .medium)
        guard let configured = image.withSymbolConfiguration(config) else { return nil }

        let size = NSSize(width: 64, height: 64)
        let finalImage = NSImage(size: size, flipped: false) { rect in
            let bgRect = rect.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: bgRect, xRadius: 14, yRadius: 14)
            background.setFill()
            path.fill()

            NSColor.white.setFill()
            let symbolRect = NSRect(x: 14, y: 14, width: 36, height: 36)
            configured.draw(in: symbolRect, from: .zero, operation: .sourceAtop, fraction: 1.0)
            return true
        }

        return writeIconPng(finalImage, packageName: packageName)
    }

    /// Write a rendered icon to disk and remember the path. Shared by both renderers.
    private static func writeIconPng(_ image: NSImage, packageName: String) -> String? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }

        let cachePath = cacheDir + "/fallback-\(packageName.replacingOccurrences(of: ".", with: "_")).png"
        do {
            try pngData.write(to: URL(fileURLWithPath: cachePath))
            fallbackIconCache[packageName] = cachePath
            return cachePath
        } catch {
            KLog.log("[Notification] Failed to write fallback icon for \(packageName): \(error)")
            return nil
        }
    }

    init(device: Device) {
        self.device = device
        if !Self.cacheLoaded {
            Self.cacheLoaded = true
            Self.loadIconCacheFromDisk()
        }
        Self.registerNotificationCategories()
        Self.periodicCacheCleanupIfNeeded()
    }

    func canHandle(type: String) -> Bool {
        type == "kdeconnect.notification"
    }

    func handle(packet: NetworkPacket) {
        let isCancel = packet.body["isCancel"]?.value as? Bool ?? false
        let notifId = packet.body["id"]?.value as? String ?? UUID().uuidString
        let packageName = extractPackageName(from: notifId)
        let isIncallUI = notifId.contains("incallui") || packageName.contains("incallui")
            || packageName == "com.samsung.android.dialer" || packageName == "com.android.dialer"
            || packageName == "com.google.android.dialer"
            || packageName == "com.android.server.telecom"

        // VoIP call apps — their notifications contain the actual caller name
        // (telephony packets for VoIP calls have no contactName)
        let isVoIPCall = Self.voipPackages.contains(packageName)

        // Handle call UI notifications separately — these drive media pause/resume
        if isIncallUI {
            let title = packet.body["title"]?.value as? String ?? ""
            let text = packet.body["text"]?.value as? String ?? ""
            let combined = (title + " " + text).lowercased()

            // Dialer packages send BOTH active call UI AND post-call notifications
            // (e.g., "Missed call", call log entries). Only active calls should
            // trigger the telephony state machine.
            let isMissedOrHistory = combined.contains("missed") || combined.contains("ended")
                || combined.contains("rejected") || combined.contains("declined")

            if isCancel {
                KLog.log("[Notification] Call UI dismissed (incallui cancel)")
                if let telephony = device.plugins["telephony"] as? TelephonyPlugin {
                    telephony.onCallEnded()
                }
            } else if isMissedOrHistory {
                // Post-call notification from dialer — NOT an active call.
                // Let it fall through to normal notification display.
                KLog.log("[Notification] Dialer history notification (not active call)")
            } else {
                KLog.log("[Notification] Call UI appeared")
                if let telephony = device.plugins["telephony"] as? TelephonyPlugin {
                    telephony.onCallStarted(caller: title.isEmpty ? text : title)
                }
            }
            return
        }

        // VoIP calls (WhatsApp, Meet, Telegram, etc.):
        // Their notifications contain the actual caller name that telephony packets lack.
        // Cross-reference with telephony to resolve "Unknown caller" → real name.
        if isVoIPCall && !isCancel {
            let title = packet.body["title"]?.value as? String ?? ""
            let text = packet.body["text"]?.value as? String ?? ""
            let appName = packet.body["appName"]?.value as? String ?? ""
            let combined = (title + " " + text).lowercased()

            // Detect active call keywords
            let isCallNotif = combined.contains("incoming") || combined.contains("calling")
                || combined.contains("ringing") || combined.contains("video call")
                || combined.contains("voice call") || combined.contains("audio call")
                || combined.contains("call from")

            if isCallNotif {
                // Extract caller name: title is usually the caller, unless title = app name
                let caller: String
                if !title.isEmpty && title != appName {
                    caller = title
                } else if !text.isEmpty {
                    // Some apps put name in text: "John is calling" → extract "John"
                    let stripped = text
                        .replacingOccurrences(of: "is calling", with: "")
                        .replacingOccurrences(of: "Incoming voice call", with: "")
                        .replacingOccurrences(of: "Incoming video call", with: "")
                        .replacingOccurrences(of: "Incoming call", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    caller = stripped.isEmpty ? text : stripped
                } else {
                    caller = "Unknown"
                }

                KLog.log("[Notification] VoIP call detected from \(packageName)")
                if let telephony = device.plugins["telephony"] as? TelephonyPlugin {
                    if telephony.hasActiveCall {
                        // Telephony packet arrived first — update the "Unknown" name
                        telephony.updateCallerName(caller)
                    } else {
                        // VoIP notification arrived first — buffer for when telephony comes
                        telephony.bufferVoIPCaller(caller)
                        // Also start the call via onCallStarted (in case no telephony packet follows)
                        telephony.onCallStarted(caller: caller)
                    }
                }
                return
            }

            // VoIP call ended
            let isCallEnded = combined.contains("missed") || combined.contains("ended")
                || combined.contains("declined")
            if isCallEnded {
                if let telephony = device.plugins["telephony"] as? TelephonyPlugin, telephony.hasActiveCall {
                    telephony.onCallEnded()
                }
                // Fall through to show as normal notification (missed call info)
            }
        }

        // VoIP call cancel = call UI dismissed
        if isVoIPCall && isCancel {
            if let telephony = device.plugins["telephony"] as? TelephonyPlugin, telephony.hasActiveCall {
                telephony.onCallEnded()
            }
        }

        // Non-VoIP notification during an active call with unknown caller:
        // If a VoIP package sends a notification (without call keywords) during an active unknown call,
        // the title is likely the caller name. This handles apps not in our keyword list.
        if !isVoIPCall && !isCancel && Self.voipPackages.contains(packageName) == false {
            // Not a VoIP app — skip caller name extraction
        } else if isVoIPCall && !isCancel {
            // Already handled above
        }

        if isCancel {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["notif-\(notifId)"])
            Self.shownNotificationIds.remove(notifId)
            Self.shownNotificationOrder.removeAll { $0 == notifId }
            Self.notificationContentHash.removeValue(forKey: notifId)
            return
        }

        // Rate limiting: max 10 notifications per second per device
        let now = Date()
        if now.timeIntervalSince(Self.rateLimitWindowStart) > 1.0 {
            Self.rateLimitCount = 0
            Self.rateLimitWindowStart = now
        }
        Self.rateLimitCount += 1
        if Self.rateLimitCount > 10 {
            KLog.log("[Notification] Rate limit exceeded (\(Self.rateLimitCount)/s), dropping \(notifId)")
            return
        }

        let appName = packet.body["appName"]?.value as? String ?? "Unknown"
        let title = packet.body["title"]?.value as? String ?? ""
        let text = packet.body["text"]?.value as? String ?? ""
        let ticker = packet.body["ticker"]?.value as? String ?? ""

        // Deduplication with update detection
        let contentHash = "\(appName)\(title)\(text)"
        if Self.shownNotificationIds.contains(notifId) {
            // Allow through if content changed (notification update)
            if Self.notificationContentHash[notifId] == contentHash { return }
            KLog.log("[Notification] Update detected for \(notifId)")
        }

        // Filter system notifications — exact package name match only
        if filteredPackages.contains(where: { packageName.hasPrefix($0) || packageName == $0 }) {
            KLog.log("[Notification] Filtered (package): \(packageName)")
            return
        }
        if filteredTitles.contains(title) || filteredTitles.contains(appName) {
            KLog.log("[Notification] Filtered (title/appName): \(appName) - \(title)")
            return
        }

        let isNew = Self.shownNotificationIds.insert(notifId).inserted
        if isNew {
            Self.shownNotificationOrder.append(notifId)
        }
        Self.notificationContentHash[notifId] = contentHash

        // Cap at 500 entries to prevent unbounded memory growth
        if Self.shownNotificationOrder.count > 500 {
            let toRemove = Self.shownNotificationOrder.prefix(250)
            for id in toRemove {
                Self.shownNotificationIds.remove(id)
                Self.notificationContentHash.removeValue(forKey: id)
            }
            Self.shownNotificationOrder.removeFirst(250)
        }

        // Only show reply button for notifications that support it
        // KDE Connect sends requestReplyId for repliable notifications (messaging apps)
        let requestReplyId = packet.body["requestReplyId"]?.value as? String
        let repliable = packet.body["repliable"]?.value as? Bool ?? false
        let replyId: String? = (requestReplyId != nil || repliable) ? notifId : nil

        let hasPayload = (packet.payloadSize ?? 0) > 0
        let payloadPort: UInt16? = {
            guard let portVal = packet.payloadTransferInfo?["port"]?.value else { return nil }
            if let i = portVal as? Int, let safePort = UInt16(exactly: i) { return safePort }
            if let i = portVal as? Int64, let safePort = UInt16(exactly: i) { return safePort }
            if let d = portVal as? Double, d > 0, d < 65536 { return UInt16(d) }
            if let s = portVal as? String, let parsed = UInt16(s) { return parsed }
            return nil
        }()

        KLog.log("[Notification] \(appName) - \(title.prefix(20))... hasIcon=\(hasPayload) port=\(payloadPort.map{String($0)} ?? "nil") pkg=\(packageName)")

        // Check icon cache first, then fallback to SF Symbol icons for known apps
        if let cachedPath = Self.iconCache[packageName] {
            KLog.log("[Notification] Cache hit for \(packageName)")
            postNotification(id: notifId, appName: appName, title: title, text: text, ticker: ticker, iconPath: cachedPath, replyId: replyId)
        } else if let fallbackPath = Self.fallbackIcon(for: packageName) {
            KLog.log("[Notification] Using fallback icon for \(packageName)")
            postNotification(id: notifId, appName: appName, title: title, text: text, ticker: ticker, iconPath: fallbackPath, replyId: replyId)

            // Still try to download the real icon if available (will replace fallback on next notification)
            if hasPayload, let port = payloadPort, Self.pendingIconDownloads[packageName] == nil, !Self.senderPicturePackages.contains(packageName) {
                Self.pendingIconDownloads[packageName] = []
                let storedCert = Config.shared.loadPairedDeviceCert(id: device.id)
                downloadIcon(host: (device.kdeConn?.host ?? ""), port: port, expectedSize: Int(packet.payloadSize ?? 0), packageName: packageName, storedCertData: storedCert) { iconPath in
                    Task { @MainActor in
                        Self.pendingIconDownloads.removeValue(forKey: packageName)
                    }
                }
            }
        } else if hasPayload, let port = payloadPort {
            // Post notification IMMEDIATELY without icon — don't make user wait for download
            postNotification(id: notifId, appName: appName, title: title, text: text, ticker: ticker, iconPath: nil, replyId: replyId)

            // Download icon in background. If successful, re-post with icon (same ID = in-place update)
            if Self.pendingIconDownloads[packageName] == nil {
                Self.pendingIconDownloads[packageName] = []
                let storedCert = Config.shared.loadPairedDeviceCert(id: device.id)
                let capturedNotifId = notifId
                let capturedAppName = appName
                let capturedTitle = title
                let capturedText = text
                let capturedTicker = ticker
                let capturedReplyId = replyId
                downloadIcon(host: (device.kdeConn?.host ?? ""), port: port, expectedSize: Int(packet.payloadSize ?? 0), packageName: packageName, storedCertData: storedCert) { [weak self] iconPath in
                    Task { @MainActor in
                        // ALWAYS clear pending state — even on failure — so future notifications can retry
                        Self.pendingIconDownloads.removeValue(forKey: packageName)
                        // Re-post notification with icon (same ID = in-place update)
                        if let iconPath = iconPath {
                            self?.postNotification(id: capturedNotifId, appName: capturedAppName, title: capturedTitle, text: capturedText, ticker: capturedTicker, iconPath: iconPath, replyId: capturedReplyId)
                        } else {
                            KLog.log("[Notification] Icon download failed for \(packageName), will retry on next notification")
                        }
                    }
                }
            }
        } else {
            postNotification(id: notifId, appName: appName, title: title, text: text, ticker: ticker, iconPath: nil, replyId: replyId)
        }
    }

    func getCachedIconPath(packageName: String) -> String? {
        return Self.iconCache[packageName]
    }

    private func postNotification(id: String, appName: String, title: String, text: String, ticker: String, iconPath: String?, replyId: String?) {
        let content = UNMutableNotificationContent()
        content.title = appName
        if !title.isEmpty && title != appName {
            content.subtitle = title
        }
        content.body = text.isEmpty ? ticker : text
        content.sound = .default
        content.threadIdentifier = "app-\(appName)"

        // OTP detection — check body text for verification codes
        if let otpCode = Self.extractOTP(from: content.body) {
            content.categoryIdentifier = "OTP_CODE"
            content.userInfo = ["otpCode": otpCode, "deviceId": device.id]
            KLog.log("[Notification] OTP detected (\(otpCode.count) chars)")
        } else if let replyId = replyId {
            content.categoryIdentifier = "NOTIFICATION_REPLY"
            content.userInfo = ["replyId": replyId, "deviceId": device.id]
        }

        if let iconPath = iconPath {
            // UNNotificationAttachment MOVES the file, destroying the original.
            // Hardlink in the same cache dir (same APFS volume = guaranteed to work).
            // When macOS moves the link, the original cache file stays (refcount > 0).
            let linkPath = Self.cacheDir + "/tmp-\(UUID().uuidString).png"
            do {
                // Prefer hardlink (zero-copy, same APFS volume). Fall back to copy if hardlink fails.
                do {
                    try FileManager.default.linkItem(atPath: iconPath, toPath: linkPath)
                } catch {
                    KLog.log("[Notification] Hardlink failed, falling back to copy: \(error)")
                    try FileManager.default.copyItem(atPath: iconPath, toPath: linkPath)
                }
                let attachment = try UNNotificationAttachment(identifier: "icon", url: URL(fileURLWithPath: linkPath), options: [
                    UNNotificationAttachmentOptionsTypeHintKey: "public.png",
                    UNNotificationAttachmentOptionsThumbnailClippingRectKey: CGRect(x: 0, y: 0, width: 1, height: 1).dictionaryRepresentation
                ])
                content.attachments = [attachment]
            } catch {
                KLog.log("[Notification] Attachment error: \(error)")
                try? FileManager.default.removeItem(atPath: linkPath)
            }
        }

        let request = UNNotificationRequest(identifier: "notif-\(id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                KLog.log("[Notification] BLOCKED: not authorized (status=\(settings.authorizationStatus.rawValue)). Enable in System Settings > Notifications > KonnectMac")
                return
            }
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    KLog.log("[Notification] Delivery error: \(error)")
                } else {
                    KLog.log("[Notification] Delivered: notif-\(id) (alertStyle=\(settings.alertStyle.rawValue))")
                }
            }
        }
    }

    // MARK: - Icon Download via BSD Socket + SecureTransport

    private func downloadIcon(host: String, port: UInt16, expectedSize: Int, packageName: String, storedCertData: Data?, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Retry on transient TLS handshake failures — phone-side upload TLS endpoint
            // gets into bad states intermittently and a fresh socket usually clears it.
            // Up to 3 attempts with short backoff; icons aren't critical so we don't try
            // as hard as the file-share path.
            let maxAttempts = 3
            for attempt in 1...maxAttempts {
                if attempt > 1 {
                    let backoffMs: UInt32 = 200 * UInt32(1 << (attempt - 1)) // 400ms, 800ms
                    KLog.log("[Notification] Icon retry \(attempt)/\(maxAttempts) for \(packageName) after \(backoffMs)ms")
                    usleep(backoffMs * 1000)
                }
                if let iconPath = self.downloadIconSync(host: host, port: port, expectedSize: expectedSize, packageName: packageName, storedCertData: storedCertData) {
                    completion(iconPath)
                    return
                }
            }
            completion(nil)
        }
    }

    private func downloadIconSync(host: String, port: UInt16, expectedSize: Int, packageName: String, storedCertData: Data?) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var nodelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            KLog.log("[Notification] Invalid icon host IP: \(host)")
            Darwin.close(fd)
            return nil
        }

        // Connect timeout (5s) prevents blocking GCD thread for 75s on unreachable ports
        var connectTimeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &connectTimeout, socklen_t(MemoryLayout<timeval>.size))

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            KLog.log("[Notification] Icon connect failed for \(packageName) at \(host):\(port): errno=\(errno)")
            Darwin.close(fd)
            return nil
        }

        // Read/handshake timeout
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        KLog.log("[Notification] Icon TLS connecting to \(host):\(port)")

        // Get a fresh, single-use SecIdentity for this handshake — see TransferIdentity
        // doc in CertificateManager. Sharing the cached identity across many short-lived
        // TLS handshakes corrupts SecureTransport's per-identity session cache and every
        // subsequent handshake fails with errSSLInternal (-9810) until app restart.
        guard let transferId = CertificateManager.shared.freshTransferIdentity() else {
            KLog.log("[Notification] Could not create fresh TLS identity")
            Darwin.close(fd)
            return nil
        }
        return withExtendedLifetime(transferId) { () -> String? in
            self.downloadIconTLSAndRead(
                fd: fd,
                identity: transferId.identity,
                expectedSize: expectedSize,
                packageName: packageName,
                storedCertData: storedCertData
            )
        }
    }

    private func downloadIconTLSAndRead(fd: Int32, identity: SecIdentity, expectedSize: Int, packageName: String, storedCertData: Data?) -> String? {
        // Setup TLS
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            Darwin.close(fd)
            return nil
        }

        let fdPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        defer { fdPtr.deallocate() }
        fdPtr.pointee = fd
        TLSHelpers.configure(ctx, TLSContextConfig(isServer: false, identity: identity, fdPtr: fdPtr))

        guard TLSHelpers.runHandshake(ctx, role: "Notification icon") else {
            SSLClose(ctx); Darwin.close(fd)
            return nil
        }

        // Validate peer certificate matches the paired device
        if let storedCert = storedCertData, storedCert.count > 1 {
            if !TLSHelpers.validatePeer(ctx, expectedCertData: storedCert) {
                KLog.log("[Notification] Icon download peer cert mismatch — rejecting")
                SSLClose(ctx); Darwin.close(fd)
                return nil
            }
        }

        KLog.log("[Notification] Icon TLS connected")

        // Read data — cap at 1MB to prevent memory exhaustion from malicious payloads
        let maxIconSize = 1_048_576
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: min(expectedSize, 65536))
        let maxSize = min(max(expectedSize, 65536), maxIconSize)

        while received.count < maxSize {
            var bytesRead = 0
            let toRead = min(buffer.count, maxSize - received.count)
            let readStatus = SSLRead(ctx, &buffer, toRead, &bytesRead)

            if bytesRead > 0 {
                received.append(Data(buffer[0..<bytesRead]))
            }

            if readStatus == errSSLClosedGraceful || readStatus == errSSLClosedAbort {
                break
            }
            if readStatus != errSecSuccess && readStatus != errSSLWouldBlock {
                break
            }
            if bytesRead == 0 && readStatus != errSSLWouldBlock {
                break
            }
        }

        SSLClose(ctx)
        Darwin.close(fd)

        guard !received.isEmpty else {
            KLog.log("[Notification] Icon download got 0 bytes")
            return nil
        }

        KLog.log("[Notification] Icon downloaded: \(received.count) bytes for \(packageName)")

        // Validate: must be a valid image
        guard let image = NSImage(data: received), image.size.width > 0, image.size.height > 0 else {
            KLog.log("[Notification] Icon data is not a valid image for \(packageName)")
            return nil
        }

        let w = image.size.width
        let h = image.size.height
        let aspectRatio = max(w, h) / max(min(w, h), 1)

        // Distinguish app icons from content images:
        // App icons: small (≤256px), roughly square (aspect ≤1.3)
        // Content images: larger, often rectangular (profile pics, thumbnails, post images)
        // If it looks like a content image, use it for THIS notification only (don't cache)
        //
        // DM-capable apps (email, messaging, social DMs) send the SENDER'S profile pic
        // as the icon payload, not the app icon. These change per notification — never
        // cache them. See `senderPicturePackages` above for the full list.
        let isSenderPicApp = Self.senderPicturePackages.contains(packageName)
        let looksLikeAppIcon = !isSenderPicApp && max(w, h) <= 256 && aspectRatio <= 1.3
        if !looksLikeAppIcon {
            KLog.log("[Notification] Content image detected (\(Int(w))x\(Int(h)) ratio=\(String(format: "%.2f", aspectRatio))) for \(packageName) — using but not caching")
            // Write to a temp file for this notification, don't cache as the app icon
            let tempPath = NSTemporaryDirectory() + "konnect-content-\(UUID().uuidString).png"
            do {
                try received.write(to: URL(fileURLWithPath: tempPath))
            } catch {
                KLog.log("[Notification] Content image write failed: \(error)")
                return nil
            }
            return tempPath
        }

        KLog.log("[Notification] App icon validated (\(Int(w))x\(Int(h))) for \(packageName)")

        // Cache by package name
        // Ensure cache directory exists before every write (it may have been purged since app launch)
        let cacheURL = URL(fileURLWithPath: Self.cacheDir)
        do {
            try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        } catch {
            KLog.log("[Notification] Icon cache directory creation FAILED: \(error.localizedDescription)")
            return nil
        }

        // Sanitize packageName to prevent path traversal
        let safePackageName = packageName
            .replacingOccurrences(of: "..", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        let fileURL = cacheURL.appendingPathComponent("\(safePackageName).png")
        let cachePath = fileURL.path
        do {
            try received.write(to: fileURL)
        } catch {
            KLog.log("[Notification] Icon cache WRITE FAILED: \(error.localizedDescription) path=\(cachePath)")
            return nil
        }

        // Verify the file was actually written and has content
        let fm = FileManager.default
        if fm.fileExists(atPath: cachePath),
           let attrs = try? fm.attributesOfItem(atPath: cachePath),
           let fileSize = attrs[.size] as? Int, fileSize > 0 {
            Task { @MainActor in
                Self.iconCache[packageName] = cachePath
            }
            KLog.log("[Notification] Icon cached: \(fileSize) bytes -> \(cachePath)")
        } else {
            KLog.log("[Notification] Icon cache VERIFY FAILED: file missing or empty at \(cachePath)")
            try? fm.removeItem(atPath: cachePath)
            return nil
        }

        return cachePath
    }

    private func extractPackageName(from notifId: String) -> String {
        // Format: "0|com.whatsapp|12345|null|10123"
        let parts = notifId.split(separator: "|")
        if parts.count >= 2 {
            return String(parts[1])
        }
        return notifId
    }

    /// Periodic cleanup: removes stale tmp- hardlinks, content images in /tmp/, and icons older than 30 days.
    /// Runs at most once per hour to avoid filesystem thrashing.
    private static func periodicCacheCleanupIfNeeded() {
        guard Date().timeIntervalSince(lastCacheCleanup) > 3600 else { return }
        lastCacheCleanup = Date()

        // Clean tmp- hardlinks in cache dir (left by UNNotificationAttachment)
        let cacheDirURL = URL(fileURLWithPath: cacheDir)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDir) {
            let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            var cleaned = 0
            for file in files where file.hasSuffix(".png") {
                if file.hasPrefix("tmp-") {
                    try? FileManager.default.removeItem(atPath: cacheDirURL.appendingPathComponent(file).path)
                    cleaned += 1
                } else {
                    // Prune old icon cache files at runtime too (not just startup)
                    let path = cacheDirURL.appendingPathComponent(file).path
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                       let modDate = attrs[.modificationDate] as? Date, modDate < thirtyDaysAgo {
                        let name = String(file.dropLast(4))
                        try? FileManager.default.removeItem(atPath: path)
                        iconCache.removeValue(forKey: name)
                        cleaned += 1
                    }
                }
            }
            if cleaned > 0 { KLog.log("[Notification] Periodic cleanup: removed \(cleaned) stale cache files") }
        }

        // Clean content image temp files in /tmp/ (konnect-content-*.png and konnect-sf-*.png)
        let tmpDir = NSTemporaryDirectory()
        if let tmpFiles = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) {
            var cleaned = 0
            let oneHourAgo = Date().addingTimeInterval(-3600)
            for file in tmpFiles where file.hasPrefix("konnect-") && file.hasSuffix(".png") {
                let path = tmpDir + file
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let modDate = attrs[.modificationDate] as? Date, modDate < oneHourAgo {
                    try? FileManager.default.removeItem(atPath: path)
                    cleaned += 1
                }
            }
            if cleaned > 0 { KLog.log("[Notification] Periodic cleanup: removed \(cleaned) temp icon files from /tmp/") }
        }
    }

    private static func loadIconCacheFromDisk() {
        let cacheDirURL = URL(fileURLWithPath: cacheDir)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDir) else {
            KLog.log("[Notification] Icon cache directory not found or empty")
            return
        }
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        var pruned = 0
        var purgedSenderPics = 0
        var purgedFallbacks = 0
        for file in files where file.hasSuffix(".png") {
            // Clean up hardlink temp files left by UNNotificationAttachment
            if file.hasPrefix("tmp-") {
                try? FileManager.default.removeItem(atPath: cacheDirURL.appendingPathComponent(file).path)
                pruned += 1
                continue
            }
            let name = String(file.dropLast(4))
            let fileURL = cacheDirURL.appendingPathComponent(file)
            let path = fileURL.path

            // Wipe any pre-rendered fallback PNGs from previous app versions. The new
            // version may render this same package with a real bundled brand asset
            // instead of the old SF Symbol — re-render on first use rather than serve
            // a stale icon from disk.
            if name.hasPrefix("fallback-") {
                try? FileManager.default.removeItem(atPath: path)
                purgedFallbacks += 1
                continue
            }

            // Migration: any cached icon for a package now in `senderPicturePackages` is
            // a stale sender profile pic from a previous app version that didn't know to
            // skip caching it. Delete it so the brand fallback shows instead.
            if Self.senderPicturePackages.contains(name) {
                try? FileManager.default.removeItem(atPath: path)
                purgedSenderPics += 1
                continue
            }

            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let fileSize = attrs[.size] as? Int, fileSize > 0 {
                // Prune icons older than 30 days
                if let modDate = attrs[.modificationDate] as? Date, modDate < thirtyDaysAgo {
                    try? FileManager.default.removeItem(atPath: path)
                    pruned += 1
                    continue
                }
                iconCache[name] = path
            } else {
                // Clean up empty/corrupt cache files
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        if pruned > 0 { KLog.log("[Notification] Pruned \(pruned) stale icon cache files (>30 days)") }
        if purgedSenderPics > 0 { KLog.log("[Notification] Purged \(purgedSenderPics) stale sender-pic caches (now use brand fallback)") }
        if purgedFallbacks > 0 { KLog.log("[Notification] Purged \(purgedFallbacks) pre-rendered fallback icons (will re-render with current asset version)") }
        KLog.log("[Notification] Loaded \(iconCache.count) cached icons from disk")
    }

    // MARK: - OTP Extraction

    /// Extracts OTP/verification codes from notification text.
    /// Handles: "OTP is 482916", "Code: 5678", "verification code 1234",
    /// "Your code is 839201", "PIN: 4829", "2FA code: 192837", etc.
    private static func extractOTP(from text: String) -> String? {
        let lowered = text.lowercased()

        // Must contain a keyword suggesting this is a code/OTP
        let keywords = ["otp", "code", "pin", "verification", "verify", "2fa",
                        "one-time", "one time", "passcode", "password", "authentication"]
        guard keywords.contains(where: { lowered.contains($0) }) else { return nil }

        // Extract 4-8 digit numeric codes (most common OTP format)
        // Look for standalone digit sequences not part of longer numbers
        let pattern = #"(?<!\d)(\d{4,8})(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            // Also try alphanumeric codes like "G-482916" or "ABC-1234"
            // Matches separators like "code: X", "code X", "code is X", "pin is X"
            let alphaPattern = #"(?i)(?:code|otp|pin)[\s:]+(?:is\s+)?([A-Z0-9][\w-]{3,9})"#
            guard let alphaRegex = try? NSRegularExpression(pattern: alphaPattern),
                  let alphaMatch = alphaRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let alphaRange = Range(alphaMatch.range(at: 1), in: text) else {
                return nil
            }
            return String(text[alphaRange])
        }
        return String(text[range])
    }

    // MARK: - Notification Categories

    static func registerNotificationCategories() {
        let replyAction = UNTextInputNotificationAction(identifier: "REPLY_ACTION", title: "Reply", options: [])
        let replyCategory = UNNotificationCategory(identifier: "NOTIFICATION_REPLY", actions: [replyAction], intentIdentifiers: [])

        let muteAction = UNNotificationAction(identifier: "MUTE_RINGER", title: "Mute Ringer", options: [])
        let callCategory = UNNotificationCategory(identifier: "CALL_ACTIONS", actions: [muteAction], intentIdentifiers: [])

        let showInFinderAction = UNNotificationAction(identifier: "SHOW_IN_FINDER", title: "Show in Finder", options: [.foreground])
        let fileCategory = UNNotificationCategory(identifier: "FILE_RECEIVED", actions: [showInFinderAction], intentIdentifiers: [])

        let copyCodeAction = UNNotificationAction(identifier: "COPY_OTP", title: "Copy Code", options: [])
        let otpCategory = UNNotificationCategory(identifier: "OTP_CODE", actions: [copyCodeAction], intentIdentifiers: [])

        UNUserNotificationCenter.current().setNotificationCategories([replyCategory, callCategory, fileCategory, otpCategory])
    }
}

