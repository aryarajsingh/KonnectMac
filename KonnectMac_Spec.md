# KonnectMac — Full Technical Specification
## A Native macOS KDE Connect Client

**Version:** 1.0
**Date:** March 2026
**Target:** MacBook Air M4, macOS 14+ (Sonoma/Sequoia/Tahoe)
**Architecture:** ARM64 only (Apple Silicon)

---

## 1. Mission Statement

Build a lightweight, native SwiftUI macOS menu bar app that implements the KDE Connect protocol v7 and pairs seamlessly with the stock KDE Connect Android app. Replace the buggy Qt-based macOS nightly with something clean, fast, and Apple-native.

### Design Principles

1. **Zero third-party dependencies.** Apple frameworks only: Network.framework, Security.framework, UserNotifications, NWConnection, etc.
2. **Menu bar citizen.** No dock icon. Lives in the status bar. Invisible until needed.
3. **Protocol-compatible.** Must pair with unmodified KDE Connect Android app (v1.34+, protocol v7).
4. **Security-first.** Fix known CVEs in the reference implementation. Do not trust identity packets over TLS data. Validate certificate pinning on every reconnection.
5. **Works over Tailscale.** Support both LAN broadcast discovery AND direct IP connection for VPN/Tailscale (100.100.10.0/24 subnet).
6. **Battery efficient.** No polling. Event-driven architecture. Idle CPU ≈ 0%.
7. **Auto-start.** Use SMAppService for Login Items. No Automator workaround.

---

## 2. KDE Connect Protocol v7 — Complete Reference

### 2.1 Packet Format

All communication uses JSON packets terminated by a newline (`\n` / 0x0A). Each packet has this structure:

```json
{
    "id": 1710000000000,
    "type": "kdeconnect.<plugin>",
    "body": { ... },
    "version": 7
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | Number | UNIX epoch timestamp in milliseconds. Some clients erroneously send as string — accept both. |
| `type` | String | Pattern: `kdeconnect.<plugin>` or `kdeconnect.<plugin>.<action>` |
| `body` | Object | Plugin-specific parameters |
| `version` | Number | Always `7` for current protocol |

**Payload transfers** add two extra fields:
```json
{
    "id": 0,
    "type": "kdeconnect.share.request",
    "body": { "filename": "photo.jpg" },
    "payloadSize": 1048576,
    "payloadTransferInfo": { "port": 1739 }
}
```
The sender opens a TCP port (specified in `payloadTransferInfo.port`) and waits for the receiver to connect and download `payloadSize` bytes over TLS.

### 2.2 Network Ports

| Port Range | Protocol | Purpose |
|-----------|----------|---------|
| 1714–1764 | UDP | Discovery broadcasts |
| 1714–1764 | TCP | Device communication (TLS) |
| 1739–1764 | TCP | Payload/file transfers (dynamic) |

Default discovery port: **1716** (UDP broadcast + TCP listen).
The app MUST listen on a TCP port within 1714–1764 and advertise it in the identity packet's `tcpPort` field.

### 2.3 Connection Flow

```
PHASE 1: DISCOVERY
──────────────────
Device A broadcasts UDP identity packet to 255.255.255.255:1716
Device B receives it, extracts tcpPort from the packet body
Device B opens TCP connection to Device A on the advertised tcpPort

PHASE 2: IDENTITY EXCHANGE (over raw TCP, before TLS)
─────────────────────────────────────────────────────
Device B sends its own identity packet over the TCP socket
Device A reads it and now both devices know each other's capabilities

PHASE 3: TLS HANDSHAKE
──────────────────────
The device with the LARGER deviceId acts as TLS server (presents cert)
The device with the SMALLER deviceId acts as TLS client
Both use self-signed 2048-bit RSA certificates
For UNPAIRED devices: all certificate errors are ignored during first connection
For PAIRED devices: certificate is pinned — verify against stored certificate

PHASE 4: PAIRING (if not already paired)
────────────────────────────────────────
Either device sends: {"type":"kdeconnect.pair","body":{"pair":true}}
Other device shows confirmation dialog to user
User accepts → responds with: {"type":"kdeconnect.pair","body":{"pair":true}}
Both devices store each other's TLS certificate persistently
Timeout: 30 seconds. Rejection: {"body":{"pair":false}}

PHASE 5: COMMUNICATION
──────────────────────
All subsequent packets flow over the TLS channel
Only packets from paired devices are processed
Unpaired device packets are rejected (except pair requests)
```

### 2.4 TLS Details

**Certificate generation:**
- Self-signed X.509
- RSA 2048-bit key
- CN = deviceId (UUID with underscores)
- Valid for 10 years
- Store private key in macOS Keychain
- Store paired device certificates in Keychain or app data directory

**Who acts as TLS server vs client:**
- Compare deviceId strings lexicographically
- LARGER deviceId = starts TLS in SERVER mode (presents certificate, waits for handshake)
- SMALLER deviceId = starts TLS in CLIENT mode (initiates handshake)
- This is CRITICAL — getting it backwards causes handshake failures

**Cipher suites (must match Android):**
- TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA (minimum for Android 4 compat)
- Modern cipher suites also accepted (AES-256-GCM, etc.)

**Security improvements over reference implementation:**
- Once TLS is established, IGNORE subsequent UDP identity packets for that deviceId (CVE-2025-32898 fix)
- Validate certificate on EVERY reconnection for paired devices, not just first
- Rate-limit incoming identity packets (max 5/second per source IP)
- Cap identity packet size at 8192 bytes

### 2.5 Tailscale / VPN Discovery

UDP broadcast does NOT work over Tailscale (no broadcast in WireGuard tunnels). Two approaches:

**Approach A — Direct IP connection (recommended):**
User enters Tailscale IP manually (e.g., 100.100.10.43). App sends identity packet directly via UDP unicast to that IP:1716, then follows normal TCP flow.

**Approach B — Periodic unicast sweep:**
If devices are in a known /24 subnet (100.100.10.0/24), app can send UDP identity to each IP in the range. Expensive but works for auto-discovery.

**Implementation:** Support both. Manual IP entry as primary. Optional subnet scan as secondary.

---

## 3. Plugin Specifications

### 3.1 Ping (`kdeconnect.ping`)

Simplest plugin. Bidirectional connectivity test.

**Outgoing (Mac → Android):**
```json
{"id":0,"type":"kdeconnect.ping","body":{}}
```
Optionally with message:
```json
{"id":0,"type":"kdeconnect.ping","body":{"message":"Hello from Mac!"}}
```

**Incoming (Android → Mac):**
Show macOS notification: "Ping from [deviceName]" with optional message body.

**Capabilities:**
- Incoming: `kdeconnect.ping`
- Outgoing: `kdeconnect.ping`

---

### 3.2 Battery (`kdeconnect.battery` / `kdeconnect.battery.request`)

**Incoming status update:**
```json
{
    "type": "kdeconnect.battery",
    "body": {
        "currentCharge": 72,
        "isCharging": true,
        "thresholdEvent": 0
    }
}
```

| Field | Type | Values |
|-------|------|--------|
| `currentCharge` | Number | 0–100, or -1 (no battery) |
| `isCharging` | Boolean | true/false |
| `thresholdEvent` | Number | 0 = normal, 1 = below threshold |

**Request update (Mac → Android):**
```json
{"type":"kdeconnect.battery.request","body":{"request":true}}
```

**UI:** Show battery % in menu bar dropdown next to device name. Show charging icon if `isCharging`. Low battery macOS notification if `thresholdEvent` = 1.

**Capabilities:**
- Incoming: `kdeconnect.battery`
- Outgoing: `kdeconnect.battery.request`

---

### 3.3 Notification Sync (`kdeconnect.notification`)

**Incoming notification:**
```json
{
    "type": "kdeconnect.notification",
    "body": {
        "id": "notification-uuid",
        "appName": "WhatsApp",
        "ticker": "John: Hey, how are you?",
        "title": "John",
        "text": "Hey, how are you?",
        "isClearable": true,
        "silent": false,
        "requestReplyId": "notification-uuid",
        "actions": ["Reply", "Mark as read"]
    }
}
```

If notification has an icon, it comes as a payload transfer (check `payloadSize` and `payloadTransferInfo`).

**Dismiss notification (Mac → Android):**
```json
{
    "type": "kdeconnect.notification.request",
    "body": {
        "cancel": "notification-uuid"
    }
}
```

**Request all active notifications:**
```json
{
    "type": "kdeconnect.notification.request",
    "body": {
        "request": true
    }
}
```

**UI:** Show as native macOS notification via UserNotifications framework. Use `appName` as subtitle, `title` as title, `text` as body. If `isClearable`, dismissing on Mac sends cancel to Android.

**Capabilities:**
- Incoming: `kdeconnect.notification`
- Outgoing: `kdeconnect.notification.request`, `kdeconnect.notification.reply`, `kdeconnect.notification.action`

---

### 3.4 Telephony (`kdeconnect.telephony`)

**Incoming call:**
```json
{
    "type": "kdeconnect.telephony",
    "body": {
        "event": "ringing",
        "phoneNumber": "+91XXXXXXXXXX",
        "contactName": "John Doe",
        "phoneThumbnail": "<base64>"
    }
}
```

| Event | Meaning |
|-------|---------|
| `ringing` | Incoming call (show notification with caller info) |
| `missedCall` | Missed call (show notification) |
| `talking` | Call answered (optional: dismiss ringing notification) |
| `isCancel` (in body) | Call ended / rejected |

**Mute ringer (Mac → Android):**
```json
{"type":"kdeconnect.telephony.request_mute","body":{}}
```

**UI:** Show macOS notification with caller name/number. Action button: "Mute Ringer". Auto-dismiss when call ends (`isCancel`).

**Capabilities:**
- Incoming: `kdeconnect.telephony`
- Outgoing: `kdeconnect.telephony.request_mute`

---

### 3.5 Clipboard (`kdeconnect.clipboard` / `kdeconnect.clipboard.connect`)

**Clipboard changed (bidirectional):**
```json
{
    "type": "kdeconnect.clipboard",
    "body": {
        "content": "copied text here"
    }
}
```

**Clipboard sync on connect:**
```json
{
    "type": "kdeconnect.clipboard.connect",
    "body": {
        "content": "current clipboard text",
        "timestamp": 1710000000000
    }
}
```
On connect, both devices exchange clipboard state. The one with the newer `timestamp` wins.

**Implementation:**
- Monitor macOS pasteboard via `NSPasteboard.general` using a polling timer (every 1 second) or `NSPasteboard.changeCount` observation
- When changeCount changes and content differs from last-received, send `kdeconnect.clipboard` packet
- When receiving, set pasteboard content but mark it so we don't echo it back
- Text only (KDE Connect clipboard plugin is text-only)

**Capabilities:**
- Incoming: `kdeconnect.clipboard`, `kdeconnect.clipboard.connect`
- Outgoing: `kdeconnect.clipboard`, `kdeconnect.clipboard.connect`

---

### 3.6 Find My Phone (`kdeconnect.findmyphone.request`)

**Ring phone (Mac → Android):**
```json
{"type":"kdeconnect.findmyphone.request","body":{}}
```
Second packet cancels the ring.

**UI:** "Find My Phone" button in menu bar dropdown. Toggle behavior — first click rings, second click stops.

**Capabilities:**
- Outgoing: `kdeconnect.findmyphone.request`

---

### 3.7 Share / File Transfer (`kdeconnect.share.request`)

**Incoming file:**
```json
{
    "type": "kdeconnect.share.request",
    "body": {
        "filename": "photo.jpg",
        "creationTime": 1710000000000,
        "lastModified": 1710000000000,
        "open": false,
        "numberOfFiles": 1,
        "totalPayloadSize": 1048576
    },
    "payloadSize": 1048576,
    "payloadTransferInfo": {
        "port": 1739
    }
}
```

**Transfer mechanism:**
1. Receive the share.request packet with `payloadTransferInfo`
2. Connect via TLS to the sender's IP on the specified port
3. Download exactly `payloadSize` bytes
4. Save to ~/Downloads/ (or configured folder)
5. Show macOS notification: "Received [filename] from [deviceName]"

**Incoming URL:**
```json
{
    "type": "kdeconnect.share.request",
    "body": {
        "url": "https://example.com"
    }
}
```
Open in default browser.

**Incoming text:**
```json
{
    "type": "kdeconnect.share.request",
    "body": {
        "text": "shared text content"
    }
}
```
Copy to clipboard.

**Capabilities:**
- Incoming: `kdeconnect.share.request`

---

## 4. Architecture

### 4.1 File Structure

```
KonnectMac/
├── KonnectMac.xcodeproj
├── KonnectMac/
│   ├── KonnectMacApp.swift           # App entry, menu bar setup, SMAppService
│   ├── MenuBarView.swift             # SwiftUI menu bar dropdown UI
│   ├── PairingView.swift             # Pairing confirmation dialog
│   ├── PreferencesView.swift         # Settings window
│   │
│   ├── Core/
│   │   ├── NetworkPacket.swift       # JSON packet model (Codable)
│   │   ├── DeviceManager.swift       # Manages all devices (discovered + paired)
│   │   ├── Device.swift              # Single device model + state machine
│   │   ├── DeviceLink.swift          # Active TLS connection to a device
│   │   ├── CertificateManager.swift  # Generate self-signed cert, Keychain CRUD
│   │   └── Config.swift              # Persistent config (deviceId, name, paired certs)
│   │
│   ├── Network/
│   │   ├── UDPDiscovery.swift        # UDP broadcast/listen on port 1716
│   │   ├── TCPServer.swift           # TCP listener for incoming connections
│   │   ├── TLSConnection.swift       # NWConnection with TLS, packet read/write
│   │   └── DirectConnect.swift       # Manual IP entry (for Tailscale)
│   │
│   ├── Pairing/
│   │   └── PairingHandler.swift      # Pair/unpair state machine, cert exchange
│   │
│   ├── Plugins/
│   │   ├── PluginProtocol.swift      # Protocol all plugins conform to
│   │   ├── PingPlugin.swift
│   │   ├── BatteryPlugin.swift
│   │   ├── NotificationPlugin.swift
│   │   ├── TelephonyPlugin.swift
│   │   ├── ClipboardPlugin.swift
│   │   ├── FindMyPhonePlugin.swift
│   │   └── SharePlugin.swift
│   │
│   ├── Resources/
│   │   ├── Assets.xcassets           # App icon, menu bar icon
│   │   └── Info.plist
│   │
│   └── Entitlements/
│       └── KonnectMac.entitlements   # Network server, outgoing connections
```

### 4.2 State Machine — Device Lifecycle

```
                    ┌─────────────┐
         UDP/Manual │  DISCOVERED │
         ──────────▶│  (unpaired) │
                    └──────┬──────┘
                           │ User initiates pair
                           ▼
                    ┌─────────────┐
                    │   PAIRING   │──── Timeout (30s) ──▶ DISCOVERED
                    │  (pending)  │──── Rejected ───────▶ DISCOVERED
                    └──────┬──────┘
                           │ Accepted (both sides)
                           ▼
                    ┌─────────────┐
      TCP connected │   PAIRED    │
      ─────────────▶│ (connected) │◀──── Reconnect
                    └──────┬──────┘
                           │ TCP disconnect
                           ▼
                    ┌─────────────┐
                    │   PAIRED    │
                    │(disconnected)│──── Re-discovery ──▶ PAIRED (connected)
                    └──────┬──────┘
                           │ User unpairs
                           ▼
                    ┌─────────────┐
                    │  FORGOTTEN  │──── Delete cert, remove from storage
                    └─────────────┘
```

### 4.3 Key Design Decisions

**Network.framework over BSD sockets:**
- Use `NWListener` for TCP server
- Use `NWConnection` for TCP+TLS client connections
- Use `NWParameters` with TLS options for certificate handling
- Use `NWConnectionGroup` or raw UDP via `NWConnection` for UDP broadcast

**UserNotifications for all alerts:**
- Request notification permission on first launch
- Use `UNUserNotificationCenter` for Android notifications, calls, file transfers
- Support actionable notifications (reply, dismiss, mute)

**Keychain for secrets:**
- Private key stored in Keychain with `kSecAttrAccessibleAfterFirstUnlock`
- Paired device certificates stored in Keychain tagged by deviceId
- DeviceId and name stored in UserDefaults

**Clipboard monitoring:**
- Poll `NSPasteboard.general.changeCount` every 1 second
- Compare with last-sent content hash to avoid echo loops
- Set a flag when applying remote clipboard to suppress re-send

---

## 5. UI Specification

### 5.1 Menu Bar Icon

- SF Symbol: `antenna.radiowaves.left.and.right` (when connected)
- SF Symbol: `antenna.radiowaves.left.and.right.slash` (when no device connected)
- Template rendering mode (adapts to light/dark automatically)

### 5.2 Menu Bar Dropdown

```
┌──────────────────────────────────┐
│  Samsung Galaxy S24 Ultra        │
│  🔋 72% ⚡ charging              │
│  ▸ Signal: 4G ████              │
│                                  │
│  ─────────────────────────────── │
│  📋 Clipboard Sync        [✓]   │
│  🔔 Notification Sync     [✓]   │
│  📞 Call Alerts            [✓]   │
│  ─────────────────────────────── │
│  🔔 Ping Device                  │
│  📱 Find My Phone                │
│  ─────────────────────────────── │
│  ⚙ Preferences...                │
│  ─────────────────────────────── │
│  Quit KonnectMac                 │
└──────────────────────────────────┘
```

### 5.3 Pairing Dialog

Native macOS alert style:
```
┌──────────────────────────────────────┐
│  ⚠ Pairing Request                   │
│                                      │
│  "Samsung Galaxy S24 Ultra" wants    │
│  to pair with this Mac.              │
│                                      │
│  Verification key:                   │
│  a7b3c9d2e1f4                        │
│                                      │
│        [ Reject ]    [ Accept ]      │
└──────────────────────────────────────┘
```

### 5.4 Preferences Window

- **General tab:** Device name, auto-start toggle, download folder picker
- **Devices tab:** List of paired devices with unpair button, manual IP connect field
- **Plugins tab:** Toggle each plugin on/off per device
- **About tab:** Version, links

---

## 6. Security Model

### 6.1 Improvements Over Reference Implementation

| CVE | Issue | Our Fix |
|-----|-------|---------|
| CVE-2025-32898 | Spoofed UDP identity overwrites device metadata on paired device | Once TLS established, ignore UDP identity for that deviceId |
| CVE-2025-32899 | Device impersonation via identity packet | Validate deviceId from TLS certificate CN, not from identity packet |
| CVE-2025-32900 | Race condition in pairing causes unexpected unpair | Serialize pairing operations with actor isolation |
| CVE-2025-32901 | Path traversal in some packet body fields | Sanitize all filename/path fields |
| CVE-2020-26164 | DoS via malformed packets, CPU loop | Cap packet size (8KB), enforce newline termination, timeout on incomplete reads |

### 6.2 macOS Permissions Required

| Permission | Why | Entitlement |
|-----------|-----|-------------|
| Network Server | TCP listener on 1714–1764 | `com.apple.security.network.server` |
| Outgoing Network | Connect to Android device | `com.apple.security.network.client` |
| Notifications | Show Android notifications on Mac | UserNotifications runtime permission |
| Accessibility (optional) | Clipboard monitoring in some apps | Not required for NSPasteboard |

### 6.3 macOS Firewall

The app MUST handle macOS firewall prompts gracefully. On first TCP listen, macOS will ask "Allow incoming connections?" — the app should guide the user to accept this.

---

## 7. Build Configuration

### 7.1 Xcode Project Settings

| Setting | Value |
|---------|-------|
| Bundle Identifier | `com.konnectmac.app` |
| Deployment Target | macOS 14.0 |
| Architectures | arm64 only |
| Swift Language Version | 5.9+ |
| App Category | `public.app-category.utilities` |
| LSUIElement | `true` (no dock icon) |
| Login Item | SMAppService.mainApp.register() |

### 7.2 Entitlements

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
```

Note: App Sandbox OFF. KDE Connect requires raw TCP/UDP socket access on specific ports which sandboxed apps cannot do. Distribution via Mac App Store is not possible; distribute as notarized DMG.

---

## 8. Build Phases

### Phase 1: Foundation (discovery + pairing + ping)
- Menu bar app shell
- UDP discovery (broadcast + listen)
- TCP server + client
- TLS handshake with certificate generation
- Pairing flow with confirmation dialog
- Ping plugin
- **Test:** Can see Android device, pair with it, send/receive pings

### Phase 2: Notifications + Telephony
- Notification plugin (receive + display + dismiss)
- Telephony plugin (incoming call, missed call, mute)
- **Test:** See Android notifications on Mac, get call alerts

### Phase 3: Clipboard + Battery
- Clipboard sync (bidirectional, text)
- Battery status display
- **Test:** Copy on phone appears on Mac and vice versa

### Phase 4: File Transfer + Find My Phone
- Share plugin (receive files, URLs, text)
- Find my phone (ring from Mac)
- **Test:** Send file from Android, arrives in ~/Downloads

### Phase 5: Polish
- Auto-start via SMAppService
- Preferences window
- Direct IP connect for Tailscale
- Error handling, reconnection logic
- Menu bar icon states
- **Test:** Full end-to-end daily use

---

## 9. Testing Checklist

- [ ] Discovery: Mac and Android see each other on same Wi-Fi
- [ ] Discovery: Mac and Android see each other via Tailscale IP
- [ ] Pairing: Initiate from Android, confirm on Mac
- [ ] Pairing: Initiate from Mac, confirm on Android
- [ ] Pairing: Reject works from both sides
- [ ] Unpair: Works from both sides
- [ ] Reconnect: After Mac sleep/wake, connection restores
- [ ] Reconnect: After network switch, connection restores
- [ ] Ping: Bidirectional
- [ ] Notifications: Android notification appears as macOS notification
- [ ] Notifications: Dismiss on Mac dismisses on Android
- [ ] Telephony: Incoming call shows caller name/number
- [ ] Telephony: Missed call notification
- [ ] Telephony: Mute ringer from Mac
- [ ] Clipboard: Copy on Mac → paste on Android
- [ ] Clipboard: Copy on Android → paste on Mac
- [ ] Clipboard: No echo loop
- [ ] Battery: Shows in menu dropdown
- [ ] Battery: Low battery alert
- [ ] File transfer: Receive file from Android → ~/Downloads
- [ ] File transfer: Receive URL → opens browser
- [ ] Find phone: Ring and cancel from Mac
- [ ] Auto-start: App launches on login
- [ ] LuLu firewall: Works after allowing KonnectMac

---

## 10. Known Edge Cases

1. **Android 15+ restricts sensitive notifications** — some notification content may be blank. Workaround: ADB permission `RECEIVE_SENSITIVE_NOTIFICATIONS`.
2. **Samsung kills background apps** — user must set KDE Connect to Unrestricted + Never Sleeping.
3. **macOS firewall prompt** — first run will trigger "allow incoming connections" dialog.
4. **Multiple network interfaces** — when on Wi-Fi + Tailscale, broadcast on all interfaces.
5. **Clipboard images** — KDE Connect clipboard is text-only. Images require ClipCascade.
6. **Large file transfers** — progress reporting via `kdeconnect.share.request.update` packets.
7. **Device name with special characters** — protocol forbids `"',;:.!?()[]<>` in deviceName (1–32 chars).

---

## Appendix A: Full Capability List

These are the packet types KonnectMac should advertise:

**Incoming capabilities:**
```json
[
    "kdeconnect.ping",
    "kdeconnect.pair",
    "kdeconnect.battery",
    "kdeconnect.notification",
    "kdeconnect.notification.action",
    "kdeconnect.notification.reply",
    "kdeconnect.telephony",
    "kdeconnect.clipboard",
    "kdeconnect.clipboard.connect",
    "kdeconnect.findmyphone.request",
    "kdeconnect.share.request",
    "kdeconnect.share.request.update",
    "kdeconnect.connectivity_report"
]
```

**Outgoing capabilities:**
```json
[
    "kdeconnect.ping",
    "kdeconnect.pair",
    "kdeconnect.battery.request",
    "kdeconnect.notification.request",
    "kdeconnect.notification.reply",
    "kdeconnect.notification.action",
    "kdeconnect.telephony.request_mute",
    "kdeconnect.clipboard",
    "kdeconnect.clipboard.connect",
    "kdeconnect.findmyphone.request",
    "kdeconnect.connectivity_report.request"
]
```

---

## Appendix B: Reference Implementations

| Project | Language | Status | Notes |
|---------|----------|--------|-------|
| kdeconnect-kde | C++/Qt | Active | Reference desktop implementation |
| kdeconnect-android | Java/Kotlin | Active | Reference mobile implementation |
| kdeconnect-ios | Swift | Active | iOS port — useful Swift reference |
| Valent | C/GLib | Active | GNOME implementation with excellent protocol docs |
| GSConnect | JavaScript | Active | GNOME Shell extension |
| Soduto | Swift (macOS) | Dead | Was native macOS, abandoned 2019 |

**Most useful for our implementation:**
- Valent protocol docs (JSON schemas for every packet type)
- kdeconnect-ios (Swift TLS + certificate handling patterns)
- kdeconnect-android source (ground truth for what Android sends/expects)

---

*This specification is the blueprint. Hand it to Claude Code as the first file in the project. Every implementation decision should reference this document.*
