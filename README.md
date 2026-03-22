<p align="center">
  <img src="KonnectMac/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="KonnectMac Icon">
</p>

<h1 align="center">KonnectMac</h1>

<p align="center">
  <strong>Connect your Android phone to your Mac.</strong><br>
  A native macOS KDE Connect client. Zero dependencies.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?logo=swift" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/KDE%20Connect-Protocol%20v7-green" alt="Protocol v7">
  <img src="https://img.shields.io/badge/dependencies-zero-brightgreen" alt="Zero Dependencies">
  <img src="https://img.shields.io/badge/license-GPL%20v3-blue" alt="GPL v3">
</p>

---

## What is KonnectMac?

KonnectMac is a **native macOS menu bar app** that connects your Android phone to your Mac using the [KDE Connect](https://kdeconnect.kde.org/) protocol. It works with the official KDE Connect Android app (v1.34+) available on [Google Play](https://play.google.com/store/apps/details?id=org.kde.kdeconnect_tp) and [F-Droid](https://f-droid.org/packages/org.kde.kdeconnect_tp/).

No Electron. No web views. No third-party dependencies. Pure Swift + AppKit + SwiftUI.

## Features

| Feature | Description |
|---------|-------------|
| **Notification Mirroring** | See your phone notifications on your Mac with app icons and OTP auto-detection with one-tap copy |
| **Call Alerts** | Incoming/outgoing call notifications with automatic media pause and resume |
| **Clipboard Sync** | Bidirectional clipboard sharing between Mac and phone |
| **File Transfer** | Send and receive files over encrypted TLS — drag to menu bar icon or use right-click Services menu |
| **Battery Monitor** | Phone battery level in the menu bar with low battery alerts |
| **Find My Phone** | Ring your phone from your Mac |
| **Ping** | Bidirectional ping to test connectivity |

## How It Works

```
Mac                              Phone
 │                                 │
 ├──── UDP Broadcast ────────────► │  Discovery (ports 1714-1764)
 │ ◄──── TCP Connect ─────────────┤  Phone connects to Mac
 │                                 │
 ├──── TLS Handshake ────────────► │  Encrypted channel (self-signed certs)
 │ ◄──── Identity Exchange ───────┤  Both sides identify
 │                                 │
 ├──── Pair Request ─────────────► │  SHA256 verification key
 │ ◄──── Pair Accept ─────────────┤  Certificate pinned
 │                                 │
 │ ◄═══ Encrypted JSON Packets ══►│  Notifications, clipboard, files...
```

## Installation

### Build from Source
```bash
git clone https://github.com/aryarajsingh/KonnectMac.git
cd KonnectMac
xcodebuild -project KonnectMac.xcodeproj -scheme KonnectMac -configuration Release build
```

### Requirements
- macOS 14 (Sonoma) or later
- [KDE Connect](https://play.google.com/store/apps/details?id=org.kde.kdeconnect_tp) on your Android phone
- Both devices on the same WiFi network (or connected via [Tailscale](https://tailscale.com/))

## Setup

1. **Install** KonnectMac and KDE Connect on your phone
2. **Launch** KonnectMac — the onboarding wizard guides you through permissions
3. **Pair** — your phone appears automatically, click to pair and verify the security key
4. **Done** — look for the antenna icon in your menu bar

### OTP/SMS Visibility (Android 15+)

Android 15 hides sensitive notification content from third-party apps. The onboarding wizard covers this, but you can also fix it manually:

```bash
# Install ADB tools
brew install android-platform-tools

# Enable sensitive notifications for KDE Connect (preserves smart replies)
adb shell appops set org.kde.kdeconnect_tp RECEIVE_SENSITIVE_NOTIFICATIONS allow
```

## Architecture

```
KonnectMac/
├── KonnectMacApp.swift          — App entry, menu bar, onboarding
├── OnboardingView.swift         — First-launch setup wizard
├── PreferencesView.swift        — Settings: General, Devices, About
├── MenuBarView.swift            — Menu bar popover UI
├── Core/
│   ├── NetworkPacket.swift      — JSON packet serialization
│   ├── Config.swift             — UserDefaults, capabilities, identity
│   ├── Device.swift             — Device model
│   ├── DeviceManager.swift      — Discovery, connections, pairing
│   ├── CertificateManager.swift — TLS certificate generation & keychain
│   └── Logger.swift             — Thread-safe file logging with rotation
├── Network/
│   ├── UDPDiscovery.swift       — BSD socket UDP broadcast
│   ├── LanServer.swift          — BSD socket TCP server
│   ├── KDEConnection.swift      — Full TLS connection lifecycle
│   └── VerificationKeyHelper.swift — SHA256 pairing verification
├── Pairing/
│   └── PairingHandler.swift     — Pairing state machine & verification
└── Plugins/
    ├── PluginProtocol.swift     — Plugin interface
    ├── PingPlugin.swift         — Bidirectional ping
    ├── BatteryPlugin.swift      — Battery level & alerts
    ├── NotificationPlugin.swift — Notification mirroring & OTP detection
    ├── TelephonyPlugin.swift    — Call alerts & media control
    ├── ClipboardPlugin.swift    — Clipboard sync
    ├── FindMyPhonePlugin.swift  — Ring phone
    └── SharePlugin.swift        — File transfer
```

## Tech Stack

| Component | Choice | Why |
|-----------|--------|-----|
| Language | Swift 5.9+ | Native, fast, type-safe |
| UI | SwiftUI + AppKit | SwiftUI for views, AppKit for menu bar & windows |
| Networking | BSD Sockets | Network.framework can't do TLS startTLS |
| TLS | SecureTransport | Ships with macOS, no dependencies |
| Certificates | openssl CLI + Keychain | Self-signed RSA-2048, app-specific keychain |
| Media Control | MediaRemote (private) | Only way to pause/resume without Accessibility |

## Security

- **End-to-end TLS** on all channels (main connection, file transfers, icon downloads)
- **Certificate pinning** after pairing — rejects impersonators
- **SHA256 verification key** displayed during pairing for visual confirmation
- **App-specific keychain** — no login keychain prompts
- **No sensitive data in logs** — OTP codes, notification text, caller names, clipboard content are never logged

## Branches

| Branch | Purpose |
|--------|---------|
| `stable` | Production releases |
| `beta` | Testing builds |
| `alpha` | Active development |

## License

KonnectMac is open source under the [GNU General Public License v3.0](LICENSE).

You are free to view, modify, and build from source.

Copyright © 2026 Aryaraj Singh.

---

<p align="center">
  Built with care for the Mac.
</p>
