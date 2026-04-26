import Foundation
import Security

/// Manages TLS identity using PKCS12 import.
/// Generates key+cert via openssl (ships with macOS), packages into .p12,
/// imports with SecPKCS12Import. Zero keychain prompts.
class CertificateManager {
    static let shared = CertificateManager()
    private var cachedIdentity: SecIdentity?
    private let lock = NSLock()
    private let p12Password = "KonnectMac"
    private var appKeychain: SecKeychain?

    private let appSupportDir: URL = {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("KonnectMac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var p12Path: URL { appSupportDir.appendingPathComponent("identity.p12") }

    // MARK: - Public

    func getOrCreateIdentity() -> SecIdentity? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedIdentity { return cached }

        // Generate p12 if it doesn't exist
        if !FileManager.default.fileExists(atPath: p12Path.path) {
            generateP12()
        }

        // Import from p12
        guard let identity = importP12() else {
            KLog.log("[Cert] Failed to import identity")
            return nil
        }

        cachedIdentity = identity
        KLog.log("[Cert] Identity ready")
        return identity
    }

    func identityExists() -> Bool {
        FileManager.default.fileExists(atPath: p12Path.path)
    }

    /// A SecIdentity scoped to a single short-lived TLS handshake.
    ///
    /// Why this exists: when many SSLContexts share the long-lived `cachedIdentity`
    /// from `getOrCreateIdentity()`, SecureTransport accumulates internal state per
    /// SecIdentity (session cache, in-flight crypto state). After 5–7 short-lived
    /// handshakes (file shares, notification icon downloads), every subsequent
    /// handshake to the phone fails with errSSLInternal (-9810) until the app
    /// restarts. The long-lived KDEConnection control channel keeps working only
    /// because it never re-handshakes after pairing.
    ///
    /// Each `TransferIdentity` owns a private in-memory keychain that holds an
    /// independent SecIdentity for one TLS context. When the handle is released
    /// (via `withExtendedLifetime` or normal Swift ARC after the TLS context is
    /// closed), the keychain file is unlinked from disk.
    final class TransferIdentity {
        let identity: SecIdentity
        private let keychain: SecKeychain
        private let keychainPath: String

        init(identity: SecIdentity, keychain: SecKeychain, path: String) {
            self.identity = identity
            self.keychain = keychain
            self.keychainPath = path
        }

        deinit {
            // Order matters: SecKeychainDelete clears the keychain from launchd's
            // search list and removes the file. Don't double-delete the file
            // (SecKeychainDelete already does it) but try anyway in case it failed.
            SecKeychainDelete(keychain)
            try? FileManager.default.removeItem(atPath: keychainPath)
            try? FileManager.default.removeItem(atPath: keychainPath + "-db")
        }
    }

    /// Create a fresh, single-use SecIdentity backed by its own private keychain.
    /// The caller MUST keep the returned `TransferIdentity` alive for the entire
    /// lifetime of the SSLContext that uses `.identity` — otherwise the underlying
    /// keychain entries get torn down while SecureTransport is still using them.
    /// The conventional pattern is `withExtendedLifetime(transferId) { … TLS code … }`.
    func freshTransferIdentity() -> TransferIdentity? {
        // Make sure the master P12 exists first (calls into the same generator path
        // as the cached identity, so first-launch + share works the same).
        if !FileManager.default.fileExists(atPath: p12Path.path) {
            // Trigger generation via getOrCreateIdentity (which also caches the result —
            // that's fine, we still create a separate fresh identity below).
            _ = getOrCreateIdentity()
        }

        guard let p12Data = try? Data(contentsOf: p12Path) else {
            KLog.log("[Cert] freshTransferIdentity: cannot read P12", level: .error)
            return nil
        }

        // Per-call keychain so SecureTransport can't share state across handshakes.
        let tempPath = NSTemporaryDirectory() + "konnectmac-xfer-\(UUID().uuidString).keychain"

        var keychain: SecKeychain?
        let password = "" as NSString
        let createStatus = SecKeychainCreate(tempPath, 0, password.utf8String, false, nil, &keychain)
        guard createStatus == errSecSuccess, let kc = keychain else {
            KLog.log("[Cert] freshTransferIdentity: SecKeychainCreate failed: \(createStatus)", level: .error)
            return nil
        }

        // Never lock — empty password means no prompts; lockOnSleep=false so wake doesn't lock.
        var settings = SecKeychainSettings(
            version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1),
            lockOnSleep: DarwinBoolean(false),
            useLockInterval: DarwinBoolean(false),
            lockInterval: UInt32.max
        )
        SecKeychainSetSettings(kc, &settings)
        SecKeychainUnlock(kc, 0, password.utf8String, true)

        let options: [String: Any] = [
            kSecImportExportPassphrase as String: p12Password,
            kSecImportExportKeychain as String: kc
        ]

        var items: CFArray?
        let importStatus = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard importStatus == errSecSuccess,
              let arr = items as? [[String: Any]],
              let first = arr.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            KLog.log("[Cert] freshTransferIdentity: P12 import failed status=\(importStatus)", level: .error)
            SecKeychainDelete(kc)
            try? FileManager.default.removeItem(atPath: tempPath)
            try? FileManager.default.removeItem(atPath: tempPath + "-db")
            return nil
        }

        // swiftlint:disable:next force_cast — SecPKCS12Import guarantees SecIdentity for this key
        let identity = identityRef as! SecIdentity
        return TransferIdentity(identity: identity, keychain: kc, path: tempPath)
    }

    // MARK: - P12 Generation via openssl

    private func generateP12() {
        let deviceId = Config.shared.deviceId
        let keyPath = NSTemporaryDirectory() + "konnectmac-key.pem"
        let certPath = NSTemporaryDirectory() + "konnectmac-cert.pem"

        KLog.log("[Cert] Starting cert generation for device \(deviceId)")

        // Set restrictive umask so temp key/cert files are created with 600 permissions
        let previousUmask = umask(0o077)

        // Generate key + self-signed cert
        let genResult = shell(
            "/usr/bin/openssl", "req", "-x509",
            "-newkey", "rsa:2048",
            "-keyout", keyPath,
            "-out", certPath,
            "-days", "3650",
            "-nodes",
            "-subj", "/CN=\(deviceId)/O=KonnectMac"
        )

        guard genResult == 0 else {
            KLog.log("[Cert] openssl req failed: \(genResult)", level: .error)
            umask(previousUmask)
            cleanup(keyPath, certPath)
            return
        }

        KLog.log("[Cert] Key and cert generated, creating P12")

        // Package into PKCS12
        let p12Result = shell(
            "/usr/bin/openssl", "pkcs12", "-export",
            "-out", p12Path.path,
            "-inkey", keyPath,
            "-in", certPath,
            "-passout", "pass:\(p12Password)"
        )

        // Restore umask
        umask(previousUmask)

        if p12Result == 0 {
            // Restrict permissions
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12Path.path)
            KLog.log("[Cert] P12 created successfully for \(deviceId)")
        } else {
            KLog.log("[Cert] openssl pkcs12 failed: \(p12Result)", level: .error)
        }

        cleanup(keyPath, certPath)
    }

    private func cleanup(_ paths: String...) {
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func shell(_ args: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    // MARK: - App Keychain

    private func getOrCreateAppKeychain() -> SecKeychain? {
        if let existing = appKeychain { return existing }

        let keychainPath = appSupportDir.appendingPathComponent("konnectmac.keychain").path

        // Delete and recreate the keychain on each launch.
        // This avoids errSecDuplicateItem (-26276) from previous imports
        // and ensures a clean state. The keychain only holds our TLS identity
        // imported from the P12 — it's ephemeral.
        if FileManager.default.fileExists(atPath: keychainPath) {
            if let kc = appKeychain { SecKeychainDelete(kc) }
            try? FileManager.default.removeItem(atPath: keychainPath)
            // Also remove the -db variant (macOS may create SQLite keychains)
            try? FileManager.default.removeItem(atPath: keychainPath + "-db")
            appKeychain = nil
        }

        var keychain: SecKeychain?
        let password = "" as NSString
        let createStatus = SecKeychainCreate(
            keychainPath,
            0,
            password.utf8String,
            false,
            nil,
            &keychain
        )
        if createStatus != errSecSuccess {
            KLog.log("[Cert] SecKeychainCreate failed: \(createStatus)")
            return nil
        }

        guard let kc = keychain else { return nil }

        // Prevent locking
        var settings = SecKeychainSettings(
            version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1),
            lockOnSleep: DarwinBoolean(false),
            useLockInterval: DarwinBoolean(false),
            lockInterval: UInt32.max
        )
        SecKeychainSetSettings(kc, &settings)

        // Unlock with empty password
        let emptyPass = "" as NSString
        SecKeychainUnlock(kc, 0, emptyPass.utf8String, true)

        appKeychain = kc
        KLog.log("[Cert] App keychain created fresh at \(keychainPath)")
        return kc
    }

    // MARK: - P12 Import

    private func importP12() -> SecIdentity? {
        guard let p12Data = try? Data(contentsOf: p12Path) else {
            KLog.log("[Cert] Cannot read p12 file", level: .error)
            return nil
        }

        guard let keychain = getOrCreateAppKeychain() else {
            KLog.log("[Cert] No keychain available", level: .error)
            return nil
        }

        KLog.log("[Cert] Importing P12 into app keychain")

        let options: [String: Any] = [
            kSecImportExportPassphrase as String: p12Password,
            kSecImportExportKeychain as String: keychain
        ]

        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess else {
            KLog.log("[Cert] P12 import failed: \(status)", level: .error)
            return nil
        }

        guard let arr = items as? [[String: Any]],
              let first = arr.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            KLog.log("[Cert] No identity in P12", level: .error)
            return nil
        }

        // swiftlint:disable:next force_cast — SecPKCS12Import guarantees SecIdentity for this key
        let identity = identityRef as! SecIdentity
        // Validate the identity by extracting its certificate
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, cert != nil else {
            KLog.log("[Cert] Identity validation failed — no certificate", level: .error)
            return nil
        }

        KLog.log("[Cert] Identity loaded from keychain successfully")
        return identity
    }

    // MARK: - Cleanup

    func cleanupOldKeychainItems() {
        // Remove stale temp keychains from previous experiments
        let tmpDir = NSTemporaryDirectory()
        if let files = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) {
            for file in files where file.hasPrefix("konnectmac") && file.hasSuffix(".keychain") {
                try? FileManager.default.removeItem(atPath: tmpDir + file)
            }
        }

        // Remove old temp keychains from app support dir (not the current one)
        let currentKeychainName = "konnectmac.keychain"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: appSupportDir.path) {
            for file in files where file.hasSuffix(".keychain") && file != currentKeychainName {
                try? FileManager.default.removeItem(atPath: appSupportDir.appendingPathComponent(file).path)
            }
        }
    }
}
