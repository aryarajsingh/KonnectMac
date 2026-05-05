import Foundation
import AppKit

/// All notification-icon classification and rendering logic. Extracted from
/// NotificationPlugin so that the plugin file stays focused on notification
/// handling (rate limiting, dedup, OTP detection, posting to UNUserNotificationCenter).
///
/// IconRenderer is purely a utility — it has no shared mutable state with the
/// plugin besides `cacheDir`, which the caller passes in (NotificationPlugin still
/// owns the cache directory lifecycle: creation, periodic cleanup, migration).
enum IconRenderer {

    // MARK: - "Don't trust the icon payload" list
    //
    // Apps that ship the sender's profile picture as the notification icon payload
    // instead of the actual app icon. We must never cache these — the payload is per-
    // notification (a different person every time), and caching one would freeze that
    // person's face as the "app icon" forever.
    //
    // Coverage rule of thumb: any app that's primarily a per-sender DM channel
    // (email, messaging, social DMs) belongs here. Apps that send their own brand icon
    // (news, banking, shopping) do NOT.
    //
    // For every package listed here, we also fall back to the brand asset / SF Symbol
    // icon defined below. If a package is here without a matching fallback,
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

    // MARK: - Brand asset / SF Symbol tables

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

    // MARK: - Public API

    private static var fallbackIconCache: [String: String] = [:]

    /// Generate a fallback icon for a package. Prefers a real bundled brand logo
    /// (Instagram, WhatsApp, etc.) over an SF Symbol, but falls back to SF Symbol when
    /// no brand asset is bundled. Result is rendered to a 64×64 PNG and cached on disk
    /// at `cacheDir/fallback-<package>.png`.
    static func fallbackIcon(for packageName: String, cacheDir: String) -> String? {
        if let cached = fallbackIconCache[packageName] { return cached }

        // Path 1: real brand asset (preferred).
        if let brand = brandAssets[packageName] {
            return renderBrandIcon(packageName: packageName, assetName: brand.asset, background: brand.color, cacheDir: cacheDir)
        }

        // Path 2: SF Symbol fallback for the long tail.
        if let info = knownAppIcons[packageName] {
            return renderSFSymbolIcon(packageName: packageName, symbolName: info.symbol, background: info.color, cacheDir: cacheDir)
        }

        return nil
    }

    // MARK: - Renderers (private)

    /// Render a bundled brand asset to a 64×64 PNG.
    ///
    /// If `background` is non-nil, treats the asset as a monochrome white logo and
    /// composites it onto a rounded brand-colored square (the simple-icons pipeline).
    /// If `background` is nil, the asset is already a complete app icon — we just
    /// scale it to 64×64 and write it out.
    private static func renderBrandIcon(packageName: String, assetName: String, background: NSColor?, cacheDir: String) -> String? {
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

        return writeIconPng(finalImage, packageName: packageName, cacheDir: cacheDir)
    }

    /// Render an SF Symbol on a brand-colored rounded square — used for apps where we
    /// don't have a bundled logo asset.
    private static func renderSFSymbolIcon(packageName: String, symbolName: String, background: NSColor, cacheDir: String) -> String? {
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

        return writeIconPng(finalImage, packageName: packageName, cacheDir: cacheDir)
    }

    /// Write a rendered icon to disk and remember the path. Shared by both renderers.
    private static func writeIconPng(_ image: NSImage, packageName: String, cacheDir: String) -> String? {
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
}
