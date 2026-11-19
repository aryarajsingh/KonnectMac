# Apfelbindung — KDE Connect parity & release roadmap

Last reviewed: **October 2026**, against `kdeconnect-kde` (`master`) and
`kdeconnect-android` (`master`), and against the current state of this fork.

This document answers two questions:

1. **What is missing** to reach feature parity with the KDE Connect desktop client?
2. **What is missing** to make Apfelbindung properly distributable?

Status legend: ✅ done · 🚧 partial · ⏳ pending · ❌ not applicable on macOS
Effort: **S** ≈ 1 day · **M** ≈ 2–5 days · **L** ≈ 1–2 weeks · **XL** ≈ more than 2 weeks

---

## 1. Feature parity

**Score: 8 of 25 areas working, 2 of them partial. 16 pending, 1 not applicable.**

| # | Area | KDE Connect plugin / packet types | Status | Effort | macOS approach & notes |
|---|------|-----------------------------------|--------|--------|------------------------|
| 1 | Ping | `ping` · `kdeconnect.ping` | ✅ | — | — |
| 2 | Battery | `battery` · `kdeconnect.battery`, `.battery.request` | ✅ | — | — |
| 3 | Clipboard | `clipboard` · `kdeconnect.clipboard`, `.clipboard.connect`, `.clipboard.file` | 🚧 | M | Text sync and direction controls work; files and images are not supported |
| 4 | Notifications | `notifications` · `kdeconnect.notification`, `.notification.request`, `.notification.reply`, `.notification.action` | ✅ | — | Mirroring, inline reply, per-app receive filters and phone actions from the app's notification views |
| 5 | Telephony | `telephony` · `kdeconnect.telephony`, `.request_mute` | ✅ | — | Includes pause/resume via MediaRemote |
| 6 | SMS | `sms` · `kdeconnect.sms.request_conversations`, `.request_conversation`, `.request`, `.messages`, `.attachment_file`, `.request_attachment` | 🚧 | M | Conversations and sending work; **MMS attachments (`attachment_file` / `request_attachment` payloads) are not handled** |
| 7 | File transfer | `share` · `kdeconnect.share.request`, `.share.request.update` | ✅ | — | — |
| 8 | Find my phone | `findmyphone` · `kdeconnect.findmyphone.request` | ✅ | — | — |
| 9 | Find this device | `findthisdevice` · listens to `kdeconnect.findmyphone.request` | ⏳ | S | Play a loud sound / flash the screen; `NSSound` + `NSBeep`, raise output volume |
| 10 | Lock device | `lockdevice` · `kdeconnect.lock`, `.lock.request` | ⏳ | S/M | Lock the Mac on request and request a phone lock. No public lock API: private `SACLockScreenImmediate` or a synthetic ⌃⌘Q keystroke (needs Accessibility) |
| 11 | Connectivity report | `connectivity-report` · `kdeconnect.connectivity_report` | ⏳ | S | Parse `signalStrength` / `networkType` and show it in the device header |
| 12 | Contacts | `contacts` · `kdeconnect.contacts.request_all_uids_timestamps`, `.response_uids_timestamps`, `.request_vcards_by_uid`, `.response_vcards` | ⏳ | M | `Contacts.framework` (`NSContactsUsageDescription`); map phone numbers to names in SMS/notifications |
| 13 | Remote input | `mousepad`, `remotekeyboard`, `remotecontrol` · `kdeconnect.mousepad.request`, `.keyboardstate`, `.echo` | ⏳ | L | `CGEventPost(kCGHIDEventTap)` for mouse and keyboard; requires **Accessibility** permission (onboarding). Upstream has a working macOS implementation in `plugins/mousepad/macosremoteinput.mm` |
| 14 | Presenter | `presenter` · `kdeconnect.presenter` | ⏳ | M | Reuses the remote-input layer: arrow keys / page up / page down / F5; add a presentation window |
| 15 | Media control | `mpriscontrol` · `kdeconnect.mpris` | ⏳ | M | Phone controls the Mac player: `MRMediaRemoteSendCommand` (play, pause, next, previous) — the MediaRemote handle is already loaded in `TelephonyPlugin`. Needs a now-playing display |
| 16 | Media remote | `mprisremote` · `kdeconnect.mpris.request` | ⏳ | M | Reverse direction: show and control the phone's player (Android 13+ media session) |
| 17 | System volume | `systemvolume` · `kdeconnect.systemvolume`, `.request` | ⏳ | M | CoreAudio: `AudioObjectSetPropertyData` on the default output device. Upstream reference: `plugins/systemvolume/systemvolumeplugin-macos.cpp` |
| 18 | Remote system volume | `remotesystemvolume` · same packets, reverse | ⏳ | S | Send `kdeconnect.systemvolume.request` and render the phone's streams |
| 19 | Run commands | `runcommand` / `remotecommands` · `kdeconnect.runcommand`, `.request`, `.output` | ⏳ | M | `Process` with an explicit, user-managed command list. **Security-sensitive**: no shell interpolation, confirm destructive commands |
| 20 | SFTP | `sftp` · `kdeconnect.sftp.request` | ⏳ | L | No KIO on macOS. Options: optional `sshfs`/macFUSE integration, or an in-app SSH/SFTP client (would add a dependency). Low priority |
| 21 | Digitizer | `digitizer` · `kdeconnect.digitizer`, `.session` | ⏳ | L | Absolute `CGEvent` cursor positioning + tablet events. Niche; only worth it for drawing use cases |
| 22 | Send notifications | `sendnotifications` · `kdeconnect.notification` (outgoing) | ⏳ | L | macOS has **no public global notification observer**; only this app's notifications via `UNUserNotificationCenter`, or fragile Accessibility/private-API scraping. Mark experimental at best |
| 23 | Screensaver inhibit | `screensaver-inhibit` · reactive, no packet type | ⏳ | S | `IOPMAssertionCreateWithName` while remote input is active. Upstream has `screensaverinhibitplugin-macos.cpp` |
| 24 | Input sharing | `shareinputdevices` / `shareinputdevicesremote` · `kdeconnect.shareinputdevices`, `.request` | ⏳ | XL | KDE Connect 24.x feature (share keyboard/mouse between devices). Needs low-level HID capture; defer |
| 25 | Virtual monitor | `virtualmonitor` · `kdeconnect.virtualmonitor.request` | ❌ | — | No macOS equivalent of a virtual Wayland output; use Sidecar/AirPlay instead |

### Nice-to-have extras inside existing plugins

- **Clipboard files** (`kdeconnect.clipboard.file`): copy/paste images and files across devices.
- **SMS read state / delivery**: mark threads read, surface send failures.
- **Transfer robustness**: cancellation, progress, resumed transfers and large files for share/SMS.
- **Per-device plugin state**: verify toggles and plugin instances do not leak between devices.

---

## 2. Protocol and transport gaps

| Item | Status | Notes |
|------|--------|-------|
| Protocol v8 identity | ✅ | `protocolVersion: 8`, `timestamp` on `kdeconnect.pair` |
| v8 pairing verification key | ✅ | SHA-256 over sorted SPKIs + timestamp |
| Fresh TLS identity per connection | ✅ | Fixes `-9810` handshakes after sleep/wake |
| TLS `close_notify` on disconnect | ✅ | Peer notices the drop immediately |
| Reconnect with backoff + connect timeout | ✅ | `O_NONBLOCK` + `poll` (10 s), backoff reset on wake/network recovery |
| UDP discovery port | ✅ | Listens/announces on 1716, no periodic churn while paired |
| **v8 pre-TLS connection packet** | ⏳ | `targetDeviceId` + `targetProtocolVersion` written as a JSON line before the TLS handshake. Android tolerates its absence; **the KDE Connect desktop validates it** (`isValidConnectionPacket` in `lanlinkprovider.cpp`). Needed to pair with Linux desktops reliably |
| Multi-device | 🚧 | `DeviceManager` tracks several devices, but the UI assumes a single paired device (`pairedDevices.first` in several views) and plugin/settings state is not fully per-device |
| Capability accuracy | 🚧 | Notification request and action capabilities match the implemented packet directions; audit the remaining plugins |
| Pairing edge cases | 🚧 | Issue #3 (handshake stall) should be re-tested on a real phone with v8 before closing it |
| Security hardening | ⏳ | Certificate pinning exists; add explicit tests for unpair/repair and replayed pair packets |

---

## 3. Release readiness

| Item | Status | Notes |
|------|--------|-------|
| **Code signing** | ⏳ | Requires the Apple Developer Program (99 USD/year). Ad-hoc signing works for local use only |
| **Notarization** | ⏳ | Needs a hardened-runtime build. Test that `dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote")` still works after notarization |
| **Universal binary** | ⏳ | `ARCHS = $(ARCHS_STANDARD)` (arm64 + x86_64) and a real Intel test. Upstream issue #6 |
| **Homebrew cask** | ⏳ | `Casks/apfelbindung.rb` in a tap, then submit to homebrew-cask. Upstream issue #7 |
| **Update check** | ⏳ | GitHub Releases API + in-app download/install, keeping zero dependencies (or Sparkle, which adds one) |
| **Tests** | ⏳ | No test target yet. Add unit tests for packet JSON round-trip, v8 verification key, SMS/notification parsing, and a CI job running `xcodebuild test` |
| **Localization** | ⏳ | String Catalog with at least English and Spanish |
| **Permissions onboarding** | 🚧 | Notifications and OTP are covered; Accessibility (remote input), Contacts and Screen Recording (presenter preview) will need explicit steps |
| **Branding** | ⏳ | The app icon is still the upstream one |
| **Docs** | 🚧 | README + this roadmap exist; add a user guide, FAQ/troubleshooting and a KonnectMac migration note |
| **Privacy** | ⏳ | State clearly that traffic stays on the LAN, there is no telemetry, and what is logged |
| **Crash reporting** | ❌ | Deliberately omitted to stay dependency-free and private; the rotating log file is enough for now |

### Public availability checklist

1. Green CI on `stable` (`build.yml`) and a manual `.pkg` build (`release.yml`).
2. Universal binary built and smoke-tested on both Apple Silicon and Intel.
3. Signed `.pkg` + notarized app; right-click → Open no longer needed.
4. Homebrew cask installs the same notarized build.
5. Test matrix passed: Android 13/14/15/16 × macOS 14/15/26, LAN and Tailscale,
   sleep/wake, unpair/repair.
6. README, roadmap, user guide and privacy note published.
7. Release tagged (`v*`) and assets attached with SHA256 checksums.

---

## 4. Suggested milestones

| Milestone | Contents |
|-----------|----------|
| **v3.1 — Quick wins** | SMS attachments, clipboard files, connectivity report, find this device, lock device, screensaver inhibit, capability audit |
| **v3.2 — Audio & media** | System volume, remote system volume, media control (MPRIS), now-playing UI |
| **v3.3 — Remote input** | Mousepad + remote keyboard + presenter, Accessibility onboarding |
| **v4.0 — Full parity** | Run commands, contacts, media remote, v8 pre-TLS connection packet, multi-device UI, clipboard files |
| **Later / optional** | SFTP, digitizer, input sharing, send notifications (experimental) |

Release readiness (signing, notarization, universal binary, cask, updater, tests,
localization) runs in parallel and gates the first *public* release, not the internal ones.

---

## 5. Implementation notes

**Remote input (mousepad / keyboard / presenter).** Normalize the phone's `dx`/`dy` to the
active screen, create `CGEvent` mouse moves/clicks/scrolls and `CGEventKeyboardSetUnicodeString`
key events, post to `kCGHIDEventTap`. Check `CGPreflightPostEventAccess()` and request access
with `CGRequestPostEventAccess()` during onboarding. Reuse one input layer for presenter mode.

**System volume.** Query `kAudioHardwarePropertyDefaultOutputDevice`, then
`kAudioDevicePropertyVolumeScalar` (or the per-channel elements) and set it with
`AudioObjectSetPropertyData`. Listen for changes to keep the phone slider in sync. Upstream's
`systemvolumeplugin-macos.cpp` is the reference implementation.

**Media control.** `MRMediaRemoteSendCommand` accepts play/pause/toggle/next/previous;
`MRMediaRemoteGetNowPlayingInfo` provides title, artist and elapsed time. The framework is
private, so guard every call and degrade gracefully if a future macOS removes it.

**Lock device.** Prefer `SACLockScreenImmediate` (SecurityAgent) and fall back to a synthetic
⌃⌘Q keystroke when Accessibility is granted. Locking the *phone* is just a
`kdeconnect.lock.request` packet.

**Contacts.** `CNContactStore` with `NSContactsUsageDescription`; answer vCard requests and
build a phone→name index to enrich SMS threads and notifications. Cache it and refresh on
`CNContactStoreDidChange`.

**Run commands.** Store a JSON list (`name`, `command`, `args`, `confirm`) in
`Application Support`. Execute with `Process` (no shell), stream stdout/stderr, and reply with
`kdeconnect.runcommand.output`. Require an explicit confirmation for anything destructive.

**SFTP.** Avoid pulling in an SSH library unless there is demand. A pragmatic first step is
detecting `sshfs` (macFUSE) and offering "mount in Finder"; an in-app browser is a separate,
larger project.

**Send notifications (Mac → phone).** `UNUserNotificationCenter` only exposes this app's own
notifications. A global listener requires the Accessibility API or reading the Notification
Center database, both fragile and privacy-sensitive. Keep it out of scope until there is a
supported API.

---

## 6. Verification matrix

| Scenario | Expected |
|----------|----------|
| Pair over LAN | Verification key matches on both sides |
| Pair over Tailscale | Direct IP connection works without UDP broadcast |
| Mac sleeps / wakes | Reconnect within seconds, no manual restart, no re-pair |
| Phone reboots | Automatic reconnection once discovery resumes |
| Unpair / re-pair | New certificate pinned, old one rejected |
| Android 15+ | OTP/SMS visible after `appops` grant |
| Two phones | Both listed, independent plugin state and message threads |
| Large file transfer | Completes with correct checksum (or fails cleanly) |
