import Foundation

/// TCP keepalive profile for a KDE Connect link (finding A7).
///
/// A peer that leaves the LAN without sending a FIN (phone Wi-Fi off, Doze) is only
/// noticed by the TCP keepalive probes. The LAN profile is short enough to fail over
/// to Tailscale inside the 75s budget; the Tailscale profile keeps the upstream
/// kdeconnect-kde values so a dozing phone is not woken every few seconds.
struct KeepAliveProfile: Equatable {
    let idle: Int32
    let interval: Int32
    let count: Int32

    /// LAN / Wi-Fi peers: 30s idle + 10s × 3 probes ≈ 60s to detect a vanished peer.
    static let standard = KeepAliveProfile(idle: 30, interval: 10, count: 3)

    /// Tailscale peers (100.x.x.x): upstream kdeconnect-kde profile, ~120s worst case.
    static let tailscale = KeepAliveProfile(idle: 60, interval: 15, count: 4)

    static func isTailscaleHost(_ host: String) -> Bool {
        host.hasPrefix("100.")
    }

    static func forHost(_ host: String) -> KeepAliveProfile {
        isTailscaleHost(host) ? .tailscale : .standard
    }
}
