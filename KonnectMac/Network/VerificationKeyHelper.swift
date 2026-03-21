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

        KLog.log("[VerKey] Local SPKI: \(localSPKI.count) bytes, Peer SPKI: \(peerSPKI.count) bytes")

        // Compare unsigned byte-wise, larger goes first
        let localArr = [UInt8](localSPKI)
        let peerArr = [UInt8](peerSPKI)

        let concatenated: Data
        if compareUnsigned(localArr, peerArr) > 0 {
            concatenated = localSPKI + peerSPKI
        } else {
            concatenated = peerSPKI + localSPKI
        }

        let hash = sha256(data: concatenated)
        let hexChars = hash.prefix(4).map { String(format: "%02X", $0) }.joined()

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

    // MARK: - SPKI Extraction

    private static func extractSPKI(fromIdentity identity: SecIdentity) -> Data? {
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let certificate = cert else { return nil }
        return extractSPKI(fromCertificate: certificate)
    }

    private static func extractSPKI(fromCertificate cert: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(cert) else { return nil }
        guard let rawKeyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }

        let attrs = SecKeyCopyAttributes(key) as? [String: Any]
        let keyTypeAttr = attrs?[kSecAttrKeyType as String] as? String

        if keyTypeAttr == (kSecAttrKeyTypeRSA as String) || rawKeyData.count > 100 {
            return buildRSASPKI(rawKey: rawKeyData)
        } else {
            return buildECSPKI(rawKey: rawKeyData)
        }
    }

    private static func buildRSASPKI(rawKey: Data) -> Data {
        // RSA SPKI: SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { raw key } }
        let rsaOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        let nullParam: [UInt8] = [0x05, 0x00]

        var algorithmSeq = Data()
        algorithmSeq.append(contentsOf: rsaOID)
        algorithmSeq.append(contentsOf: nullParam)
        let wrappedAlgorithm = wrapInSequence(algorithmSeq)

        let bitString = wrapInBitString(rawKey)

        return wrapInSequence(wrappedAlgorithm + bitString)
    }

    private static func buildECSPKI(rawKey: Data) -> Data {
        // EC SPKI: SEQUENCE { SEQUENCE { OID ecPublicKey, OID prime256v1 }, BIT STRING { raw key } }
        let ecOID: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        let p256OID: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]

        var algorithmSeq = Data()
        algorithmSeq.append(contentsOf: ecOID)
        algorithmSeq.append(contentsOf: p256OID)
        let wrappedAlgorithm = wrapInSequence(algorithmSeq)

        let bitString = wrapInBitString(rawKey)

        return wrapInSequence(wrappedAlgorithm + bitString)
    }

    // MARK: - ASN.1 Helpers

    private static func wrapInSequence(_ data: Data) -> Data {
        var result = Data([0x30])
        result.append(contentsOf: derLength(data.count))
        result.append(data)
        return result
    }

    private static func wrapInBitString(_ data: Data) -> Data {
        var content = Data([0x00]) // no unused bits
        content.append(data)
        var result = Data([0x03])
        result.append(contentsOf: derLength(content.count))
        result.append(content)
        return result
    }

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 128 {
            return [UInt8(length)]
        } else if length < 256 {
            return [0x81, UInt8(length)]
        } else {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        }
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
