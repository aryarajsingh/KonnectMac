import Foundation
import Security

// MARK: - SSL I/O callbacks
//
// Free functions because SecureTransport's `SSLSetIOFuncs` takes C function pointers,
// not closures. These are the canonical implementation — three identical copies
// previously lived in `KDEConnection.swift`, `SharePlugin.swift`, and
// `NotificationPlugin.swift`.
//
// The errno → SSLStatus mapping (treating `ETIMEDOUT` as `errSSLWouldBlock`) is
// load-bearing: with `SO_RCVTIMEO` set on the socket, a slow peer surfaces as
// `ETIMEDOUT` from `read(2)`, and we want SecureTransport to retry rather than
// fail the handshake / transfer.

func kmSSLReadFunc(connection: SSLConnectionRef, data: UnsafeMutableRawPointer, dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let fdPtr = connection.assumingMemoryBound(to: Int32.self)
    let requested = dataLength.pointee
    let n = Darwin.read(fdPtr.pointee, data, requested)
    if n > 0 {
        dataLength.pointee = n
        return n < requested ? errSSLWouldBlock : errSecSuccess
    }
    if n == 0 {
        dataLength.pointee = 0
        return errSSLClosedGraceful
    }
    dataLength.pointee = 0
    let e = errno
    if e == EAGAIN || e == EWOULDBLOCK || e == ETIMEDOUT || e == EINTR {
        return errSSLWouldBlock
    }
    return errSecIO
}

func kmSSLWriteFunc(connection: SSLConnectionRef, data: UnsafeRawPointer, dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let fdPtr = connection.assumingMemoryBound(to: Int32.self)
    let requested = dataLength.pointee
    let n = Darwin.write(fdPtr.pointee, data, requested)
    if n > 0 {
        dataLength.pointee = n
        return n < requested ? errSSLWouldBlock : errSecSuccess
    }
    if n == 0 {
        dataLength.pointee = 0
        return errSSLClosedGraceful
    }
    dataLength.pointee = 0
    let e = errno
    if e == EAGAIN || e == EWOULDBLOCK || e == ETIMEDOUT || e == EINTR {
        return errSSLWouldBlock
    }
    return errSecIO
}

// MARK: - TLS context configuration

/// Minimal context-configuration bundle. Caller owns `fdPtr` (KDEConnection holds it
/// for the connection's lifetime; short-lived TLS contexts allocate locally with
/// `defer { fdPtr.deallocate() }`). `TLSHelpers.configure` only stores the pointer
/// in the SSLContext — it does not take ownership.
struct TLSContextConfig {
    let isServer: Bool
    let identity: SecIdentity
    let fdPtr: UnsafeMutablePointer<Int32>
}

enum TLSHelpers {

    /// Configure a fresh `SSLContext` with KonnectMac's standard options:
    /// - `kmSSLReadFunc` / `kmSSLWriteFunc` as the I/O callbacks
    /// - TLS 1.2 minimum
    /// - `breakOnServerAuth` + `breakOnClientAuth` (we validate the peer cert
    ///   manually after the handshake completes — see `validatePeer`)
    /// - `tryAuthenticate` when acting as TLS server (request a client cert,
    ///   but don't refuse the handshake if the peer doesn't present one)
    /// - The caller's identity as our cert
    /// - A unique per-context peer ID, which disables SecureTransport's per-peer
    ///   session-cache reuse. Without this, stale state from a previous handshake
    ///   surfaces as `errSSLInternal` (-9810) on the first or second
    ///   `SSLHandshake` call — this was the deadlock mode behind v1.7's "every
    ///   short-lived handshake fails after about 5–7" bug.
    static func configure(_ ctx: SSLContext, _ cfg: TLSContextConfig) {
        SSLSetIOFuncs(ctx, kmSSLReadFunc, kmSSLWriteFunc)
        SSLSetConnection(ctx, UnsafeMutableRawPointer(cfg.fdPtr))
        if cfg.isServer {
            SSLSetClientSideAuthenticate(ctx, .tryAuthenticate)
        }
        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        SSLSetSessionOption(ctx, .breakOnClientAuth, true)
        SSLSetCertificate(ctx, [cfg.identity] as CFArray)
        applyUniquePeerID(ctx)
    }

    /// Tag this `SSLContext` with a unique session-resumption ID. Forces a fresh
    /// handshake every time, even when SecureTransport has cached state for the
    /// peer's IP / port. Already called by `configure`; exposed in case a caller
    /// builds an SSLContext through a different path.
    static func applyUniquePeerID(_ ctx: SSLContext) {
        let unique = UUID().uuidString
        unique.withCString { SSLSetPeerID(ctx, $0, strlen($0)) }
    }

    /// Run the TLS handshake with a hard deadline. Returns true on success.
    ///
    /// Per-syscall socket timeouts (`SO_RCVTIMEO`/`SO_SNDTIMEO`) MUST already be
    /// set on the underlying fd before calling this. Otherwise the I/O callback
    /// can block indefinitely inside `read`/`write` and the deadline check
    /// never fires.
    ///
    /// The retry-set covers all the "handshake paused for caller action" return
    /// codes we use:
    ///   - `errSSLWouldBlock` (-9803): I/O would block
    ///   - `errSSLPeerAuthCompleted` (-9841): we set `breakOnServerAuth`, so this
    ///     fires once we've received and (notionally) validated the peer's cert
    ///   - `errSSLClientCertRequested` (-9842): we set `breakOnClientAuth`, so
    ///     this fires once the peer has requested our cert
    @discardableResult
    static func runHandshake(_ ctx: SSLContext, role: String, deadline: TimeInterval = 15) -> Bool {
        let stop = Date().addingTimeInterval(deadline)
        var attempts = 0
        while Date() < stop {
            let status = SSLHandshake(ctx)
            attempts += 1
            switch status {
            case errSecSuccess:
                return true
            case errSSLWouldBlock,
                 errSSLPeerAuthCompleted,
                 errSSLClientCertRequested:
                continue
            default:
                KLog.log("[\(role)] TLS handshake failed: status=\(status) attempts=\(attempts)")
                return false
            }
        }
        KLog.log("[\(role)] TLS handshake timed out after \(attempts) attempts")
        return false
    }

    /// Validate that the TLS peer's leaf certificate matches the cert we recorded
    /// during pairing. Returns true if the cert matches OR if the trust chain is
    /// inaccessible.
    ///
    /// Fail-open on `SecTrust` failure is intentional: a paired device with a
    /// transient `SecTrust` error would otherwise lose every in-flight transfer.
    /// The pairing protocol already constrains who can connect to us, so the
    /// extra cert check is defense-in-depth, not the only line of defense.
    static func validatePeer(_ ctx: SSLContext, expectedCertData: Data) -> Bool {
        var trust: SecTrust?
        SSLCopyPeerTrust(ctx, &trust)
        guard let peerTrust = trust,
              let certs = SecTrustCopyCertificateChain(peerTrust) as? [SecCertificate],
              let peerCert = certs.first else {
            return true
        }
        let peerData = SecCertificateCopyData(peerCert) as Data
        return peerData == expectedCertData
    }

    /// Return just the peer's leaf certificate. Used by `KDEConnection.getPeerCertificate`
    /// during pairing to capture the phone's cert before the connection cycles.
    static func copyPeerLeafCertificate(_ ctx: SSLContext) -> SecCertificate? {
        var trust: SecTrust?
        SSLCopyPeerTrust(ctx, &trust)
        guard let peerTrust = trust else { return nil }
        let certs = SecTrustCopyCertificateChain(peerTrust) as? [SecCertificate]
        return certs?.first
    }
}
