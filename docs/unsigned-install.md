# Installing an unsigned build

Apfelbindung is distributed as an **ad-hoc signed, non-notarized** `.pkg`. macOS Gatekeeper
will warn on the first install. This is expected, not a corrupted download.

> Only download releases from
> **[github.com/rockmadehome/Apfelbindung/releases](https://github.com/rockmadehome/Apfelbindung/releases)**
> and verify the SHA256 checksum published with the release.

## 1. Verify the download

```bash
shasum -a 256 ~/Downloads/Apfelbindung-3.0.1.pkg
```

Compare the output with the `.pkg.sha256` file attached to the same release.

## 2. Allow the installer

### Option A — System Settings (recommended)

1. Double-click the `.pkg`. macOS blocks it.
2. Open **System Settings → Privacy & Security**.
3. Scroll to **Security** and click **Open Anyway** next to the Apfelbindung warning.
4. Authenticate and confirm.

### Option B — Finder

1. Control-click (or right-click) the `.pkg`.
2. Choose **Open**.
3. Click **Open** in the confirmation dialog.

### Option C — Terminal

```bash
xattr -d com.apple.quarantine ~/Downloads/Apfelbindung-3.0.1.pkg
sudo installer -pkg ~/Downloads/Apfelbindung-3.0.1.pkg -target /
```

If Terminal says the quarantine attribute does not exist, the file was not quarantined;
continue with the `installer` command.

## 3. First launch

1. Open **Apfelbindung** from `/Applications`.
2. Allow **Local Network** access when prompted.
3. Allow **Notifications** when prompted.
4. Complete onboarding and pair with KDE Connect on your phone.

If macOS blocks the app on first launch, repeat the **Open Anyway** flow for
`/Applications/Apfelbindung.app`.

## Troubleshooting

### “Apfelbindung is damaged and can’t be opened”

This is Gatekeeper’s generic message for a quarantined unsigned app. Remove the quarantine
flag and open it again:

```bash
xattr -dr com.apple.quarantine /Applications/Apfelbindung.app
open /Applications/Apfelbindung.app
```

### “Apfelbindung-3.0.1.pkg cannot be opened because it is from an unidentified developer”

Use **System Settings → Privacy & Security → Open Anyway**, or Option C above.

### The app opens but notifications do not appear

macOS treats a new bundle ID as a new app. Open **System Settings → Notifications →
Apfelbindung** and enable notifications. If it is not listed, quit and reopen the app, then
accept the permission prompt.

### The app does not find the phone

This is unrelated to signing. Check that both devices are on the same network, that KDE
Connect is installed on the phone, and that Local Network access is allowed for Apfelbindung.

## Uninstall

```bash
./uninstall.sh
```

Or remove `/Applications/Apfelbindung.app` and `~/Library/Application Support/Apfelbindung`
manually.
