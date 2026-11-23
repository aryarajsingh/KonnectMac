import Foundation

/// Reconnect backoff for a paired device.
///
/// Only real TLS handshake failures may escalate the interval; a transport failure
/// (TCP connect refused/timeout, Tailscale down) must not poison the LAN reconnect
/// path (finding A2). The formula is the one the code already used:
/// 20s, 40s, 80s, 160s, capped at 300s.
struct ReconnectPolicy: Equatable {
    static let baseInterval: TimeInterval = 20
    static let maximumInterval: TimeInterval = 300

    private(set) var tlsFailures = 0
    private(set) var transportFailures = 0

    var interval: TimeInterval {
        guard tlsFailures > 0 else { return Self.baseInterval }
        return min(Self.baseInterval * pow(2.0, Double(tlsFailures - 1)), Self.maximumInterval)
    }

    mutating func recordTLSFailure() {
        tlsFailures += 1
    }

    /// Transport failures are counted separately and never move `interval`: a dead
    /// Tailscale route must not slow down the LAN reconnect path (finding A2).
    mutating func recordTransportFailure() {
        transportFailures += 1
    }

    mutating func reset() {
        tlsFailures = 0
        transportFailures = 0
    }
}
