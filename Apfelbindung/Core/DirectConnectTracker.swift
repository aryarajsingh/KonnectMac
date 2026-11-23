import Foundation

/// Observable outcome of a manual "Connect by IP" attempt.
/// Published by `DeviceManager` and consumed by both settings panels so the UI
/// reports the real connection state instead of a 10s timer (finding A6).
enum DirectConnectStatus: Equatable {
    case idle
    case connecting(host: String)
    case connected(host: String, deviceName: String)
    case failed(host: String)

    var host: String? {
        switch self {
        case .idle:
            return nil
        case .connecting(let host), .failed(let host):
            return host
        case .connected(let host, _):
            return host
        }
    }
}

/// One outbound direct-connect attempt (Tailscale/VPN).
struct DirectConnectAttempt: Equatable {
    let id: UUID
    let host: String
    let port: UInt16
    /// True for attempts the user asked for ("Connect" button). Background probes
    /// (periodic tailnet dials) don't publish `Connecting` and don't paint the manual
    /// panel red when they fail, unless they had actually connected and the live
    /// session dropped. A click while a probe is in flight promotes it (see
    /// `DirectConnectTracker.promoteCurrent`), so this flag must be mutable.
    var announcesFailure: Bool

    /// Key used by `DeviceManager.connections` while the attempt is in flight.
    ///
    /// Unique per attempt (finding A1): the previous code reused `direct_<host>`, so
    /// a later attempt to the same host overwrote the previous entry and the previous
    /// attempt's 15s identity timeout could disconnect/remove the new one.
    var key: String { "direct_\(host)_\(id.uuidString)" }
}

/// What a direct-connect timeout should do to the live connection.
enum DirectConnectCleanup: Equatable {
    case ignore
    case disconnect
}

/// Tracks in-flight direct-connect attempts so a stale timeout or callback can never
/// touch a newer attempt (finding A1) and so the UI can show the real state (A6).
final class DirectConnectTracker {
    private struct Entry {
        enum Phase {
            case connecting
            case connected
        }

        // Mutable: `promoteCurrent` flips `announcesFailure` on the stored copy, while
        // callers keep an immutable pre-promotion snapshot.
        var attempt: DirectConnectAttempt
        var phase: Phase
    }

    private(set) var status: DirectConnectStatus = .idle

    /// Live attempt per host key, keyed by the attempt's unique connection key.
    private var entries: [String: Entry] = [:]
    /// The attempt that currently owns each host. A newer attempt replaces the owner
    /// without destroying the older entry (whose socket may still be closing).
    private var currentByHost: [String: UUID] = [:]

    /// Registers a new attempt. Returns the attempt token the caller must pass to
    /// `isCurrent`, `markConnected`, `markFailed`, `cleanupTimeout` and `finish`.
    ///
    /// A user-initiated attempt takes over the panel immediately. A background probe
    /// leaves `status` untouched, so it neither flashes `Connecting` nor erases a
    /// previous `Failed`/`Connected` state (A6 refinement).
    func begin(host: String, port: UInt16, announcesFailure: Bool = true) -> DirectConnectAttempt {
        let attempt = DirectConnectAttempt(id: UUID(), host: host, port: port, announcesFailure: announcesFailure)
        entries[attempt.key] = Entry(attempt: attempt, phase: .connecting)
        currentByHost[host] = attempt.id
        if announcesFailure {
            status = .connecting(host: host)
        }
        return attempt
    }

    /// Promotes the handshaking attempt for `host` to user-initiated after a click:
    /// publishes `.connecting` and makes its eventual failure visible. Returns false
    /// when there is no in-flight attempt to promote.
    @discardableResult
    func promoteCurrent(host: String) -> Bool {
        guard let id = currentByHost[host],
              let key = entries.first(where: { $0.value.attempt.id == id && $0.value.phase == .connecting })?.key else {
            return false
        }
        entries[key]?.attempt.announcesFailure = true
        status = .connecting(host: host)
        return true
    }

    /// True while `attempt` is still the current attempt for its host.
    /// Checks identity, not just key existence, so a reused key cannot alias them.
    func isCurrent(_ attempt: DirectConnectAttempt) -> Bool {
        entries[attempt.key]?.attempt.id == attempt.id && currentByHost[attempt.host] == attempt.id
    }

    /// True while a connection attempt to `host` is still handshaking.
    func isConnecting(host: String) -> Bool {
        guard let id = currentByHost[host] else { return false }
        return entries.values.contains { $0.attempt.id == id && $0.phase == .connecting }
    }

    /// Marks the attempt as connected (TLS established). Idempotent.
    @discardableResult
    func markConnected(_ attempt: DirectConnectAttempt, deviceName: String) -> Bool {
        guard isCurrent(attempt) else { return false }
        entries[attempt.key]?.phase = .connected
        status = .connected(host: attempt.host, deviceName: deviceName)
        return true
    }

    /// Marks the attempt as failed and forgets it. A stale attempt is discarded
    /// without touching the published status. A background probe that never connected
    /// leaves the panel untouched (idle, or a previous Failed/Connected state); a
    /// promoted probe or a connection that had been live reports `Failed`.
    @discardableResult
    func markFailed(_ attempt: DirectConnectAttempt) -> Bool {
        guard let entry = entries[attempt.key], entry.attempt.id == attempt.id else { return false }
        entries.removeValue(forKey: attempt.key)
        guard currentByHost[attempt.host] == attempt.id else { return false }
        currentByHost.removeValue(forKey: attempt.host)
        // Read the stored flag: a probe promoted by a later click must report failure,
        // even though the caller holds the pre-promotion attempt copy.
        if entry.attempt.announcesFailure || entry.phase == .connected {
            status = .failed(host: attempt.host)
        }
        return true
    }

    /// Called when the 15s identity timeout fires. Only the attempt that scheduled
    /// the timeout may clean up, and only while it is still handshaking.
    @discardableResult
    func cleanupTimeout(_ attempt: DirectConnectAttempt) -> DirectConnectCleanup {
        // `isCurrent` also verifies that this attempt still owns its host: a timeout from
        // a superseded in-flight attempt must not remove the newer attempt's slot (A1).
        guard let entry = entries[attempt.key], isCurrent(attempt), entry.phase == .connecting else {
            return .ignore
        }
        entries.removeValue(forKey: attempt.key)
        currentByHost.removeValue(forKey: attempt.host)
        // A silent probe timeout leaves the panel as-is; a promoted one reports failure.
        if entry.attempt.announcesFailure {
            status = .failed(host: attempt.host)
        }
        return .disconnect
    }

    /// Already live on another connection: report connected without keeping an attempt.
    func noteConnected(host: String, deviceName: String) {
        entries = entries.filter { $0.value.attempt.host != host }
        currentByHost.removeValue(forKey: host)
        status = .connected(host: host, deviceName: deviceName)
    }

    /// Ends an attempt successfully without changing the published status (used when
    /// the new connection is discarded because a live one already exists).
    func finish(_ attempt: DirectConnectAttempt) {
        guard let entry = entries[attempt.key], entry.attempt.id == attempt.id else { return }
        entries.removeValue(forKey: attempt.key)
        if currentByHost[attempt.host] == attempt.id {
            currentByHost.removeValue(forKey: attempt.host)
        }
    }

    /// Drops the attempt without reporting a failure (e.g. replaced before dial).
    func cancel(_ attempt: DirectConnectAttempt) {
        guard let entry = entries[attempt.key], entry.attempt.id == attempt.id else { return }
        entries.removeValue(forKey: attempt.key)
        guard currentByHost[attempt.host] == attempt.id else { return }
        currentByHost.removeValue(forKey: attempt.host)
        if case .connecting(let host) = status, host == attempt.host {
            status = .idle
        }
    }

    /// Forgets a reported connected/failed state for `host` (e.g. its live session
    /// ended and no other connection is up).
    func clearStatus(host: String) {
        guard status.host == host else { return }
        status = .idle
    }
}

/// Resolves the TCP port for a direct (Tailscale/VPN) dial (finding A4).
enum DirectConnectPort {
    /// Duplicated from `Config` on purpose: this type is compiled standalone by the
    /// logic-test harness, which does not link `Config` (it imports ServiceManagement).
    static let defaultPort: UInt16 = 1716
    static let minimumPort: UInt16 = 1716
    static let maximumPort: UInt16 = 1764

    /// Uses the port learned from UDP discovery when it is inside the KDE Connect
    /// TCP range; otherwise falls back to the protocol default.
    static func resolve(learnedPort: UInt16) -> UInt16 {
        (learnedPort >= minimumPort && learnedPort <= maximumPort) ? learnedPort : defaultPort
    }

    static func resolve(learnedPort: Int) -> UInt16 {
        guard let port = UInt16(exactly: learnedPort) else { return defaultPort }
        return resolve(learnedPort: port)
    }
}
