# KonnectMac — Development Guidelines

## Project
Native macOS KDE Connect client. Menu bar app (LSUIElement), zero third-party dependencies.
Swift/AppKit/SwiftUI. Protocol v7 compatible with KDE Connect Android v1.34+.

## Commit Rules

- **NEVER add Co-Authored-By, or any mention of Claude, Anthropic, AI, LLM, GPT, or any AI tool in commit messages, code comments, or any tracked file.**
- **NEVER delete CLAUDE.md from disk.** It is gitignored — branch switches must not remove it. If `git rm --cached` is used, verify the local file still exists.
- Commit messages should be concise, describe the "why", and look like they were written by a human developer.

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
- **UI:** SwiftUI (Onboarding, Preferences, MenuBarView) + AppKit (NSMenu for menu bar, NSWindow for onboarding)
- **Networking:** BSD sockets + SecureTransport (not Network.framework — can't do TLS startTLS)
- **TLS:** SecureTransport SSLCreateContext, self-signed RSA-2048 certs via `/usr/bin/openssl`
- **Certificates:** PKCS12 file in ~/Library/Application Support/KonnectMac/ + app-specific keychain
- **Build:** Xcode project + xcodebuild CLI
- **Distribution:** .pkg installer via pkgbuild with postinstall scripts + GitHub Releases
- **Media Control:** MediaRemote private framework via dlsym (pause/resume on calls)

## Architecture

```
KonnectMac/
├── KonnectMacApp.swift          — App entry, AppDelegate, menu bar, onboarding, single-instance lock
├── OnboardingView.swift         — First-launch: notifications, login item, Tailscale, Android 15 OTP
├── PreferencesView.swift        — Settings: General, Devices, Plugins, About (with GitHub/Sponsor links)
├── MenuBarView.swift            — Menu bar popover: device cards, quick actions, status
├── Core/
│   ├── NetworkPacket.swift      — JSON packets + AnyCodable (handles all numeric types)
│   ├── Config.swift             — UserDefaults, capabilities, device identity, port validation
│   ├── Device.swift             — Device model, plugin routing, connection state
│   ├── DeviceManager.swift      — Discovery, connections, pairing, NWPathMonitor, sleep/wake, debounce
│   ├── CertificateManager.swift — openssl key+cert generation, P12 packaging, app keychain
│   └── Logger.swift             — Thread-safe file logging (~/Library/Application Support/KonnectMac/konnectmac.log)
├── Network/
│   ├── UDPDiscovery.swift       — BSD socket UDP broadcast + listen on 1714-1764
│   ├── LanServer.swift          — BSD socket TCP accept server (rate-limited 20/sec)
│   ├── KDEConnection.swift      — Full TLS connection lifecycle with retry loops
│   └── VerificationKeyHelper.swift — SHA256 pairing key from SPKI public keys
├── Pairing/
│   └── PairingHandler.swift     — Pairing dialog with verification key display
└── Plugins/ (7 plugins)
    ├── PluginProtocol.swift     — Plugin interface
    ├── PingPlugin.swift         — Bidirectional ping
    ├── BatteryPlugin.swift      — Phone battery level + low alerts + charging debounce
    ├── NotificationPlugin.swift — Notification mirroring + icon caching + OTP detection + VoIP calls
    ├── TelephonyPlugin.swift    — Call alerts + media pause/resume via MediaRemote + 5s cooldown
    ├── ClipboardPlugin.swift    — Bidirectional sync (128KB cap, echo prevention)
    ├── FindMyPhonePlugin.swift  — Ring phone + visual flash when phone finds Mac
    └── SharePlugin.swift        — File transfer both directions over TLS + stale cleanup
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
| Telephony | kdeconnect.telephony | kdeconnect.telephony.request_mute |
| Clipboard | kdeconnect.clipboard | kdeconnect.clipboard |
| Find My Phone | kdeconnect.findmyphone.request | kdeconnect.findmyphone.request |
| File Transfer | kdeconnect.share.request | kdeconnect.share.request |

## Build & Deploy

```bash
# Build
xcodebuild -project KonnectMac.xcodeproj -scheme KonnectMac -configuration Release build

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

**WARNING: This section documents hard-won behavior. Do NOT modify pairing code without
reading and understanding every case below. Every "fix" that ignores this section WILL
break pairing. The phone's behavior is non-obvious and counter-intuitive.**

The phone reconnects TCP mid-pair, sends duplicate pair packets, sends pair=false as
"initial state" on new connections, and mirrors its own KDE Connect notifications back
through the notification listener. Every combination is explicitly handled.

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
- **Duplicate dialog prevention:** `pendingIncomingPairDevices` set prevents showing multiple pair dialogs for the same device (phone re-sends pair=true every ~15s on new connections)
- **Filter `org.kde.kdeconnect_tp`:** KDE Connect's own notifications (pairing dialogs, connection status) must NEVER be mirrored. Without this filter, the mirrored notification confuses users and can trigger accidental pair cancellation via MenuBarView tap.

### Key insight:

The phone's TCP reconnect during pairing is **normal** (it establishes a new TLS session).
Don't treat it as an error. The old connection gets cleaned up, the new one continues pairing.
Never clear `pendingPairRequests` on disconnect — the reconnect will carry it forward.

### Critical: `device.kdeConn` vs `connections[deviceId]`

When the user accepts an incoming pair dialog (`PairingHandler.showPairingRequest` returns),
the connection captured in the closure is **dead** — unpaired connections cycle every ~15s,
and `runModal()` blocks for however long the user takes to click Accept.

**The pair=true response MUST be sent on the CURRENT active connection:**
1. `activeConn = self.connections[deviceId] ?? conn` — get the latest connection
2. `device.kdeConn = activeConn` — update the device's connection reference
3. `activeConn.send(response)` — send directly on the active connection (NOT `device.send()` which might still use the dead `kdeConn`)

Without step 2+3, the pair=true response goes into a dead connection's write queue and is
never flushed. The phone never receives our acceptance → times out → "device not paired."

### Verification Key (SPKI extraction)

KDE Connect Android (v1.34+) generates **EC P-256 keys** (not RSA-2048). The file is still
called `RsaHelper.kt` for historical reasons. Our verification key must match exactly.

**NEVER manually reconstruct SPKI from raw key data.** Instead, extract the SubjectPublicKeyInfo
directly from the X.509 certificate's DER encoding (`VerificationKeyHelper.extractSPKIFromDER`).
This guarantees byte-for-byte match with Android's `certificate.publicKey.encoded` and
Desktop's `certificate.publicKey().toDer()`.

- Local SPKI: 294 bytes (RSA-2048, our cert generated via openssl)
- Peer SPKI: 91 bytes (EC P-256, phone's cert)
- Both are valid — the SPKI comparison handles mixed key types correctly

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
- **Email app icons:** Gmail, Outlook etc. send sender profile pics, not app icons. These packages are in `emailPackages` set and never cached. Fallback SF Symbol icons used instead.
- **UNNotificationAttachment moves files:** It takes ownership of the file. Use hardlinks so the cache copy survives. Temp hardlinks go in the cache dir (same APFS volume).
- **Android 15 sensitive notifications:** OTP/SMS content hidden from notification listeners. Fix: `adb shell appops set org.kde.kdeconnect_tp RECEIVE_SENSITIVE_NOTIFICATIONS allow` (per-app, preserves smart replies) or disable "Enhanced notifications" globally (kills smart replies).
- **OTP detection:** `NotificationPlugin.extractOTP()` looks for keywords (otp, code, pin, verification, etc.) then extracts 4-8 digit codes or alphanumeric codes like G-482916. Adds "Copy Code" action button via `OTP_CODE` notification category.
- **Port 0 bug:** `UserDefaults.integer(forKey:)` returns 0 for missing keys, and `UInt16(exactly: 0)` succeeds (0 is valid UInt16). Always validate port is within 1714-1764 range, not just that the cast succeeds.
- **P12 empty password:** `SecPKCS12Import` with empty string password fails with `-25293 errSecAuthFailed` on some macOS versions. Use a non-empty password (e.g., "KonnectMac").
- **Installer BundleIsRelocatable:** Must be `false` in component plist. If `true`, macOS relocates the app to where the previous version was installed — if that location no longer exists (user deleted app), files are silently dropped.
- **Installer postinstall runs as root:** `$HOME` and `$USER` resolve to root, not the real user. Use `stat -f "%Su" /dev/console` to get the actual logged-in user. Directories created as root block the app from writing (lock file, identity, logs).
- **Installer payload — use ditto not cp:** `cp -R` copies AppleDouble `._` resource fork files which corrupt the installer payload. Always use `ditto` + `dot_clean`.
- **Single-instance lock:** Uses `flock()` on `.lock` file. `flock` auto-releases on process death (even SIGKILL). If lock acquisition fails for non-lock reasons (permissions, missing dir), allow launch anyway — don't block the user.
- **Onboarding focus:** Use `NSApp.activate(ignoringOtherApps: true)` + temporary `window.level = .floating` to ensure onboarding appears in foreground on first launch.
- **Menu bar icon disappears after rapid kill/relaunch:** macOS status bar needs time between process death and new item registration. Add 2-3 second delay between kill and relaunch.
- **Notification rate limiting:** Max 10 notifications/second per device prevents flooding from rapid phone events.
- **Log privacy:** Never log OTP codes, notification body text, caller names/phone numbers, clipboard content, or shared text. Log byte counts and package names only.
- **Log levels:** DEBUG/INFO/WARN/ERROR — use `.error` for actual failures only. Logs stored in ~/Library/Application Support/KonnectMac/ (survives reboots), rotated at 5MB with 3 old files.
- **Stable build has logging disabled:** Logger.swift on `stable` branch has no-op `KLog.log()`. Alpha/beta branches have full logging.
- **Media pause/resume:** Use `MRMediaRemoteGetNowPlayingInfo` with cached async state — never block MainActor with semaphore. Only pause if media player is actually playing (check playbackRate > 0, not CoreAudio which catches system sounds). Double-check before resume.
- **Telephony 5s cooldown:** After a call ends, ignore "talking" events and onCallStarted() for 5 seconds. Phone sends post-call dialer notifications that aren't real new calls. Only set cooldown when there was an actual active call.
- **Network path debounce:** macOS fires rapid bursts of path changes during WiFi switches. Wait 2 seconds for stability before reacting. Without debouncing, each triggers reconnection attempts that cascade-fail.
- **Icon cache cleanup:** Runs at startup AND hourly. Prunes icons >30 days, tmp- hardlinks, content images in /tmp/ >1 hour.
- **Plugin flag reset on disconnect:** Battery (lowBatteryNotified), Clipboard (echo prevention), Telephony (all call state) — all reset in `handleDisconnection()` to prevent stale state on reconnect.
- **Firewall:** When installing to /Applications via .pkg, the macOS firewall may only whitelist the old binary path. User must manually add `/Applications/KonnectMac.app` to firewall exceptions if discovery fails.

## Key Design Decisions

1. **BSD sockets over Network.framework** — NWConnection can't upgrade existing TCP to TLS
2. **SecureTransport over OpenSSL** — No dependencies, ships with macOS
3. **NSMenu over SwiftUI popover** — Popover buttons unreliable in status bar items
4. **App-specific keychain** — Eliminates login keychain password prompts across rebuilds/updates
5. **MediaRemote private framework** — Only way to check/control playback without Accessibility permission
6. **File-based P12 certificates** — Generated via openssl, imported into app keychain via SecPKCS12Import
7. **NWPathMonitor with 2s debounce** — Detects WiFi changes for automatic reconnection without cascade failures
8. **Sleep/wake observer** — `NSWorkspace.didWakeNotification` triggers immediate broadcast + stale connection cleanup (faster than TCP keepalive 2+ min)
9. **Single-instance via flock()** — File lock auto-released on process death; graceful fallback if lock infrastructure fails
10. **Installer component plist** — `BundleIsRelocatable: false` prevents silent file drops on reinstall
11. **Static notification caches** — Survive plugin recreation on reconnect; prevent duplicate notifications and icon re-downloads
12. **GPL v3 license** — Open source, prevents closed-source forks, compatible with KDE ecosystem

## Branch Strategy

| Branch | Logging | Purpose |
|--------|---------|---------|
| `alpha` | Full | Active development |
| `beta` | Full | Testing before promotion |
| `stable` | Disabled (no-op) | Public distribution via GitHub Releases |

Workflow: commit to alpha → merge to beta → merge to stable → tag release
