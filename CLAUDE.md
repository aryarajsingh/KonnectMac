# KonnectMac — Development Guidelines

## Project
Native macOS KDE Connect client. Menu bar app (LSUIElement), zero third-party dependencies.
Swift/AppKit/SwiftUI. Protocol v7 compatible with KDE Connect Android v1.34+.

## Cardinal Rules

1. **Think before you act.** Never rush. Never ship half-baked fixes. If unsure, stop and reason through all cases before writing code.
2. **No fluff.** Every line of code must earn its place. No over-engineering, no unnecessary abstractions, no speculative features. Simple, direct, robust.
3. **Test every permutation.** There are finite states in this app. Enumerate them. A connection can be alive, stale, or dead. A notification can have an icon, a content image, or nothing. A call can be incoming, outgoing, or missed. Handle every case explicitly.
4. **Fix the root cause, not the symptom.** When something breaks, trace it to the actual bug. Don't patch around it. Don't add retry loops or delays to mask timing issues.
5. **Never break what works.** Before changing anything, understand what's currently working and why. Read the code. Read the logs. Verify assumptions.
6. **Quality is non-negotiable.** The UI must feel native macOS. Match system conventions. No dead buttons, no unresponsive states, no visual jank.
7. **Use agents and parallel investigation.** When debugging, launch multiple agents to research different hypotheses simultaneously. Don't go in circles trying one thing at a time.
8. **Clean slate testing.** When verifying a fix, do a full uninstall/reinstall cycle. Stale state from previous builds masks bugs.

## Tech Stack

- **Language:** Swift 5.9+, macOS 14+ (Sonoma)
- **UI:** SwiftUI (Onboarding, Preferences) + AppKit (NSMenu for menu bar, NSWindow for onboarding)
- **Networking:** BSD sockets + SecureTransport (not Network.framework — can't do TLS startTLS)
- **TLS:** SecureTransport SSLCreateContext, self-signed RSA-2048 certs via `/usr/bin/openssl`
- **Certificates:** PKCS12 file in ~/Library/Application Support/KonnectMac/ + app-specific keychain
- **Build:** Xcode project + xcodebuild CLI
- **Distribution:** .pkg installer via pkgbuild with postinstall scripts
- **Media Control:** MediaRemote private framework via dlsym (pause/resume on calls)

## Architecture

```
KonnectMac/
├── KonnectMacApp.swift          — App entry, AppDelegate, NSMenu menu bar, onboarding
├── OnboardingView.swift         — First-launch: notifications, login item, Tailscale
├── PreferencesView.swift        — Settings: General, Devices, About
├── Core/
│   ├── NetworkPacket.swift      — JSON packets + AnyCodable (handles all numeric types)
│   ├── Config.swift             — UserDefaults, capabilities, device identity
│   ├── Device.swift             — Device model, plugin routing
│   ├── DeviceManager.swift      — Discovery, connections, pairing, NWPathMonitor for WiFi
│   ├── CertificateManager.swift — openssl key+cert generation, P12 packaging, app keychain
│   └── Logger.swift             — Thread-safe file logging (~/Library/Application Support/KonnectMac/konnectmac.log)
├── Network/
│   ├── UDPDiscovery.swift       — BSD socket UDP broadcast + listen on 1714-1764
│   ├── LanServer.swift          — BSD socket TCP accept server
│   ├── KDEConnection.swift      — Full TLS connection lifecycle with retry loops
│   └── VerificationKeyHelper.swift — SHA256 pairing key from SPKI public keys
└── Plugins/ (7 plugins)
    ├── PingPlugin.swift         — Bidirectional ping
    ├── BatteryPlugin.swift      — Phone battery level + low alerts
    ├── NotificationPlugin.swift — Notification mirroring + icon caching + update detection
    ├── TelephonyPlugin.swift    — Call alerts + media pause/resume via MediaRemote
    ├── ClipboardPlugin.swift    — Bidirectional sync (128KB cap, echo prevention)
    ├── FindMyPhonePlugin.swift  — Ring phone + play sound when phone finds Mac
    └── SharePlugin.swift        — File transfer both directions over TLS
```

## Protocol Flow

1. **Discovery:** UDP broadcast identity on ports 1714-1764
2. **Connection:** Phone connects TCP → sends identity → TLS upgrade (crossover: TCP server = TLS client)
3. **Identity exchange:** Both sides send identity over TLS after handshake
4. **Pairing:** Exchange pair packets, verify SHA256 key from both SPKI public keys
5. **Communication:** JSON packets, newline-delimited, on the TLS channel

## Supported Plugins

| Plugin | Incoming | Outgoing |
|--------|----------|----------|
| Ping | kdeconnect.ping | kdeconnect.ping |
| Battery | kdeconnect.battery | kdeconnect.battery.request |
| Notifications | kdeconnect.notification | kdeconnect.notification.request |
| Telephony | kdeconnect.telephony | — |
| Clipboard | kdeconnect.clipboard | kdeconnect.clipboard |
| Find My Phone | kdeconnect.findmyphone.request | kdeconnect.findmyphone.request |
| File Transfer | kdeconnect.share.request | kdeconnect.share.request |

## Build & Deploy

```bash
# Build
xcodebuild -project KonnectMac.xcodeproj -scheme KonnectMac -configuration Debug build

# Package installer (BundleIsRelocatable must be false — see component plist)
BUILT="$(xcodebuild -project KonnectMac.xcodeproj -scheme KonnectMac -configuration Release \
  -showBuildSettings 2>/dev/null | grep ' BUILD_DIR' | awk '{print $3}')/Release"
TMPROOT=$(mktemp -d) && mkdir -p "$TMPROOT/Applications"
ditto "$BUILT/KonnectMac.app" "$TMPROOT/Applications/KonnectMac.app"
dot_clean "$TMPROOT"
pkgbuild --root "$TMPROOT" --component-plist Installer/component.plist \
  --identifier com.konnectmac.app --version 1.0 --install-location / \
  --scripts Installer/scripts ~/Desktop/KonnectMac.pkg
rm -rf "$TMPROOT"

# Clean install test
pkill -9 -f KonnectMac
rm -rf ~/Library/Application\ Support/KonnectMac
rm -rf ~/Library/Caches/KonnectMac
defaults delete com.konnectmac.app
```

## Pairing State Machine (Hardened)

The phone's pairing behavior is non-obvious. It reconnects TCP mid-pair, sends duplicate
pair packets, and sends pair=false as "initial state" on new connections. Every combination
is explicitly handled in `DeviceManager.handlePairPacket()`.

### `pair=true` received:

| Current State | Action |
|---|---|
| We have pending request | Accept → `completePairing()`, clear pending |
| Already paired (Config) | Silent re-confirm, refresh timestamp, no dialog |
| Not paired, no pending | Incoming request → show verification key dialog |

### `pair=false` received:

| Current State | Action |
|---|---|
| Paired, <10s since pairing | **Ignore** — phone's post-pair initial state, not real unpair |
| Paired, ≥10s | Real unpair → remove cert, close connection, set state to discovered |
| Pending request exists | **Wait** — phone clears old state before sending pair=true |
| Not paired, no pending | **Ignore** — no-op |

### Guards:

- **Duplicate `completePairing()` calls:** If already `.paired` + cert on disk → refresh timestamp only, skip cert save and plugin init
- **Re-send debounce:** pair packet re-sent on reconnect only if >5s since last send (prevents duplicate Android notifications)
- **30s timeout:** Clears pending state if phone never responds
- **10s grace period:** After `completePairing()`, all `pair=false` packets are ignored (phone sends these on new connections as initial state)

### Key insight:

The phone's TCP reconnect during pairing is **normal** (it establishes a new TLS session).
Don't treat it as an error. The old connection gets cleaned up, the new one continues pairing.
Never clear `pendingPairRequests` on disconnect — the reconnect will carry it forward.

## Known Gotchas

- **AnyCodable:** Bool must come first in encode (but AFTER Int64 in decode — Swift JSONDecoder decodes 1/0 as Bool)
- **UInt16:** Swift does NOT auto-bridge UInt16 to Int via `as?` — must handle explicitly in AnyCodable
- **SSLRead + ETIMEDOUT:** `SO_RCVTIMEO` returns errno=ETIMEDOUT, not EAGAIN — handle as non-fatal
- **SSLClose + SSLRead race:** disconnect() must only close fd; SSL cleanup on the connection queue
- **SSLWrite partial:** Must retry in a loop — single call can write fewer bytes than requested
- **MediaRemote:** `GetNowPlayingInfo` works from app context; `GetNowPlayingApplicationIsPlaying` does NOT — use GetNowPlayingInfo + check playbackRate instead
- **setActivationPolicy(.accessory):** Can kill SwiftUI apps — set up menu bar BEFORE closing onboarding
- **macOS notification icon:** Left side is always the posting app's icon (unchangeable). Android app icon goes as attachment (right side)
- **Keychain:** Login keychain prompts on every code signature change. Use app-specific keychain with empty password + never-lock settings
- **Ad-hoc signed apps:** Get generic icon in Notification Center until installed via .pkg
- **Notification icon vs content image:** Phone sends one payload per notification — sometimes the app icon, sometimes a content image (post thumbnail, profile pic). Classify by size: ≤256px and aspect ≤1.3 → app icon (cache per package). Larger/rectangular → content image (use once, don't cache). See `NotificationPlugin.downloadIconSync()`.
- **UNNotificationAttachment moves files:** It takes ownership of the file. Use hardlinks so the cache copy survives. Temp hardlinks go in the cache dir (same APFS volume).
- **Android 15 sensitive notifications:** OTP/SMS content hidden from notification listeners. Fix: `adb shell appops set org.kde.kdeconnect_tp RECEIVE_SENSITIVE_NOTIFICATIONS allow` (per-app, preserves smart replies) or disable "Enhanced notifications" globally (kills smart replies).
- **OTP detection:** `NotificationPlugin.extractOTP()` looks for keywords (otp, code, pin, verification, etc.) then extracts 4-8 digit codes or alphanumeric codes like G-482916. Adds "Copy Code" action button via `OTP_CODE` notification category.
- **Port 0 bug:** `UserDefaults.integer(forKey:)` returns 0 for missing keys, and `UInt16(exactly: 0)` succeeds (0 is valid UInt16). Always validate port is within 1714-1764 range, not just that the cast succeeds.
- **P12 empty password:** `SecPKCS12Import` with empty string password fails with `-25293 errSecAuthFailed` on some macOS versions. Use a non-empty password (e.g., "KonnectMac").
- **Installer BundleIsRelocatable:** Must be `false` in component plist. If `true`, macOS relocates the app to where the previous version was installed — if that location no longer exists (user deleted app), files are silently dropped.
- **Installer postinstall runs as root:** `$HOME` and `$USER` resolve to root, not the real user. Use `stat -f "%Su" /dev/console` to get the actual logged-in user. Directories created as root block the app from writing (lock file, identity, logs).
- **Single-instance lock:** Uses `flock()` on `.lock` file. `flock` auto-releases on process death (even SIGKILL). If lock acquisition fails for non-lock reasons (permissions, missing dir), allow launch anyway — don't block the user.
- **Onboarding focus:** Use `NSApp.activate(ignoringOtherApps: true)` + temporary `window.level = .floating` to ensure onboarding appears in foreground on first launch.
- **Notification rate limiting:** Max 10 notifications/second per device prevents flooding from rapid phone events.
- **Log privacy:** Never log OTP codes, notification body text, caller names/phone numbers, clipboard content, or shared text. Log byte counts and package names only.
- **Log levels:** DEBUG/INFO/WARN/ERROR — use `.error` for actual failures only. Logs stored in ~/Library/Application Support/KonnectMac/ (survives reboots), rotated at 5MB with 3 old files.
- **Media pause/resume:** Use `MRMediaRemoteGetNowPlayingInfo` with cached async state — never block MainActor with semaphore. Only pause if media player is actually playing (not system sounds). Double-check before resume.
- **Icon cache cleanup:** Runs at startup AND hourly. Prunes icons >30 days, tmp- hardlinks, content images in /tmp/ >1 hour.
- **Plugin flag reset on disconnect:** Battery (lowBatteryNotified), Clipboard (echo prevention), Telephony (all call state) — all reset in `handleDisconnection()` to prevent stale state on reconnect.

## Key Design Decisions

1. **BSD sockets over Network.framework** — NWConnection can't upgrade existing TCP to TLS
2. **SecureTransport over OpenSSL** — No dependencies, ships with macOS
3. **NSMenu over SwiftUI popover** — Popover buttons unreliable in status bar items
4. **App-specific keychain** — Eliminates login keychain password prompts across rebuilds/updates
5. **MediaRemote private framework** — Only way to check/control playback without Accessibility permission
6. **File-based P12 certificates** — Generated via openssl, imported into app keychain via SecPKCS12Import
7. **NWPathMonitor** — Detects WiFi changes for automatic reconnection
8. **Sleep/wake observer** — `NSWorkspace.didWakeNotification` triggers immediate broadcast + stale connection cleanup (faster than TCP keepalive 2+ min)
9. **Single-instance via flock()** — File lock auto-released on process death; graceful fallback if lock infrastructure fails
10. **Installer component plist** — `BundleIsRelocatable: false` prevents silent file drops on reinstall
