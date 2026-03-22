import Foundation
import Security
import CommonCrypto

class VerificationKeyHelper {

    static func computeVerificationKey(localIdentity: SecIdentity, peerCertificate: SecCertificate) -> String {
        guard let localSPKI = extractSPKI(fromIdentity: localIdentity),
              let peerSPKI = extractSPKI(fromCertificate: peerCertificate) else {
            KLog.log("[VerKey] Failed to extract SPKI")
            return "Unknown"
        }

        let localArr = [UInt8](localSPKI)
        let peerArr = [UInt8](peerSPKI)

        KLog.log("[VerKey] Local SPKI: \(localSPKI.count) bytes, Peer SPKI: \(peerSPKI.count) bytes")

        // Compare unsigned byte-wise, larger goes first (matches Android Arrays.compareUnsigned
        // and Qt QByteArray::operator<)
        let concatenated: Data
        if compareUnsigned(localArr, peerArr) > 0 {
            concatenated = localSPKI + peerSPKI
        } else {
            concatenated = peerSPKI + localSPKI
        }

        let hash = sha256(data: concatenated)
        let hexChars = hash.prefix(4).map { String(format: "%02x", $0) }.joined().uppercased()

        KLog.log("[VerKey] Computed: \(hexChars)")
        return hexChars
    }

    @MainActor static func computeFromConnection(conn: KDEConnection) -> String {
        guard let identity = CertificateManager.shared.getOrCreateIdentity() else { return "Unknown" }

        // Try to get peer cert from the connection's SSL context
        if let peerCert = conn.getPeerCertificate() {
            return computeVerificationKey(localIdentity: identity, peerCertificate: peerCert)
        }

        // Try to find connection from DeviceManager
        if let deviceId = conn.remoteDeviceId {
            for (_, c) in DeviceManager.shared.connections {
                if c.remoteDeviceId == deviceId, let cert = c.getPeerCertificate() {
                    return computeVerificationKey(localIdentity: identity, peerCertificate: cert)
                }
            }
        }

        KLog.log("[VerKey] No peer certificate available")
        return "Unknown"
    }

    // MARK: - SPKI Extraction (from certificate DER)
    //
    // Extracts SubjectPublicKeyInfo directly from the X.509 certificate's DER encoding.
    // This is the same approach as:
    //   - Android: certificate.publicKey.encoded (returns DER-encoded SPKI)
    //   - Desktop Qt: certificate.publicKey().toDer()
    //
    // By parsing the actual certificate DER, we get byte-for-byte identical SPKI
    // regardless of key type (RSA, EC, etc.), without manual ASN.1 reconstruction.

    private static func extractSPKI(fromIdentity identity: SecIdentity) -> Data? {
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let certificate = cert else { return nil }
        return extractSPKI(fromCertificate: certificate)
    }

    private static func extractSPKI(fromCertificate cert: SecCertificate) -> Data? {
        let certDER = SecCertificateCopyData(cert) as Data
        return extractSPKIFromDER(certDER)
    }

    /// Parse X.509 certificate DER to extract the SubjectPublicKeyInfo field.
    ///
    /// X.509 structure:
    /// ```
    /// SEQUENCE {                           -- Certificate
    ///   SEQUENCE {                         -- TBSCertificate
    ///     [0] EXPLICIT INTEGER version     -- optional, v3 = 2
    ///     INTEGER serialNumber
    ///     SEQUENCE signatureAlgorithm
    ///     SEQUENCE issuer
    ///     SEQUENCE validity
    ///     SEQUENCE subject
    ///     SEQUENCE subjectPublicKeyInfo    ← THIS
    ///     ...
    ///   }
    ///   ...
    /// }
    /// ```
    private static func extractSPKIFromDER(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var offset = 0

        // Outer SEQUENCE (Certificate)
        guard skipTag(&offset, bytes: bytes, expected: 0x30) else { return nil }

        // TBSCertificate SEQUENCE
        guard skipTag(&offset, bytes: bytes, expected: 0x30) else { return nil }

        // Field 1: version [0] EXPLICIT (optional — present in v3 certs)
        if offset < bytes.count && bytes[offset] == 0xA0 {
            guard skipTLV(&offset, bytes: bytes) else { return nil }
        }

        // Field 2: serialNumber INTEGER
        guard skipTLV(&offset, bytes: bytes) else { return nil }

        // Field 3: signature AlgorithmIdentifier SEQUENCE
        guard skipTLV(&offset, bytes: bytes) else { return nil }

        // Field 4: issuer Name SEQUENCE
        guard skipTLV(&offset, bytes: bytes) else { return nil }

        // Field 5: validity SEQUENCE
        guard skipTLV(&offset, bytes: bytes) else { return nil }

        // Field 6: subject Name SEQUENCE
        guard skipTLV(&offset, bytes: bytes) else { return nil }

        // Field 7: subjectPublicKeyInfo SEQUENCE — this is what we want
        let spkiStart = offset
        guard skipTLV(&offset, bytes: bytes) else { return nil }
        let spkiEnd = offset

        return Data(bytes[spkiStart..<spkiEnd])
    }

    // MARK: - DER Parsing Helpers

    /// Skip a tag byte and parse the length, advancing offset past both.
    /// Returns true if the tag matches expected (or if expected is 0, any tag).
    private static func skipTag(_ offset: inout Int, bytes: [UInt8], expected: UInt8) -> Bool {
        guard offset < bytes.count else { return false }
        let tag = bytes[offset]
        if expected != 0 && tag != expected { return false }
        offset += 1
        guard let length = parseDERLength(&offset, bytes: bytes) else { return false }
        // Don't advance past the content — caller decides
        _ = length
        return true
    }

    /// Skip an entire TLV (tag + length + value), advancing offset past all of it.
    private static func skipTLV(_ offset: inout Int, bytes: [UInt8]) -> Bool {
        guard offset < bytes.count else { return false }
        offset += 1 // skip tag
        guard let length = parseDERLength(&offset, bytes: bytes) else { return false }
        guard offset + length <= bytes.count else { return false }
        offset += length
        return true
    }

    /// Parse a DER length field, advancing offset past it. Returns the length value.
    private static func parseDERLength(_ offset: inout Int, bytes: [UInt8]) -> Int? {
        guard offset < bytes.count else { return nil }
        let first = bytes[offset]
        offset += 1

        if first < 0x80 {
            return Int(first)
        } else if first == 0x81 {
            guard offset < bytes.count else { return nil }
            let length = Int(bytes[offset])
            offset += 1
            return length
        } else if first == 0x82 {
            guard offset + 1 < bytes.count else { return nil }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            return length
        } else if first == 0x83 {
            guard offset + 2 < bytes.count else { return nil }
            let length = Int(bytes[offset]) << 16 | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            offset += 3
            return length
        }
        return nil
    }

    // MARK: - Comparison

    private static func compareUnsigned(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let len = max(a.count, b.count)
        for i in 0..<len {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv ? 1 : -1 }
        }
        return 0
    }

    private static func sha256(data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buf in
            CC_SHA256(buf.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }
}
