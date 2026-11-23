import Foundation

// Logic regression harness for the Tailscale recovery bug slice.
// Compiled with swiftc alongside the pure logic types — no XCTest target needed.
//
//   swiftc -o /tmp/apfelbindung-logic-tests \
//     Apfelbindung/Core/DirectConnectTracker.swift \
//     Apfelbindung/Core/ReconnectPolicy.swift \
//     Apfelbindung/Core/KeepAliveProfile.swift \
//     Tools/LogicTests/main.swift
//   /tmp/apfelbindung-logic-tests

private var failures = 0
private var checks = 0

private func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        let extra = detail()
        print("FAIL  \(name)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

private func checkEqual<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    check(name, actual == expected, "expected \(expected), got \(actual)")
}

// MARK: - T1 (A1): a stale identity timeout must not touch the new attempt

private func testStaleAttemptTimeout() {
    print("\nT1 — stale direct-connect timeout (A1)")
    let tracker = DirectConnectTracker()
    let attemptA = tracker.begin(host: "100.104.247.78", port: 1716)
    checkEqual("T1 begin A → connecting", tracker.status, .connecting(host: "100.104.247.78"))

    // A times out at TCP level and is reported failed; a new attempt B starts.
    _ = tracker.markFailed(attemptA)
    let attemptB = tracker.begin(host: "100.104.247.78", port: 1716)
    checkEqual("T1 begin B → connecting", tracker.status, .connecting(host: "100.104.247.78"))

    // A's 15s identity timeout now fires in the middle of B's handshake.
    let cleanup = tracker.cleanupTimeout(attemptA)
    checkEqual("T1 stale timeout is ignored", cleanup, .ignore)
    check("T1 attempt B is still current", tracker.isCurrent(attemptB))
    check("T1 attempt B is still connecting", tracker.isConnecting(host: "100.104.247.78"))
    checkEqual("T1 status still reports B connecting", tracker.status, .connecting(host: "100.104.247.78"))
}

// MARK: - T2 (A2): only real TLS failures escalate the reconnect backoff

private func testReconnectBackoff() {
    print("\nT2 — reconnect backoff (A2)")
    var policy = ReconnectPolicy()
    checkEqual("T2 fresh interval is 20s", policy.interval, 20)

    // Tailscale/TCP timeouts are transport failures, not handshake failures.
    policy.recordTransportFailure()
    checkEqual("T2 one transport failure → 20s", policy.interval, 20)
    policy.recordTransportFailure()
    checkEqual("T2 two transport failures → 20s", policy.interval, 20)
    policy.recordTransportFailure()
    checkEqual("T2 three transport failures → 20s", policy.interval, 20)

    // Real TLS failures escalate with the existing schedule (20s, 40s, 80s, …).
    // The first failure keeps the 20s base because the deployed formula is
    // `20 * 2^(failures-1)`; the plan's "40, 80, …" is the sequence from the second.
    policy.recordTLSFailure()
    checkEqual("T2 first TLS failure → 20s (existing schedule)", policy.interval, 20)
    policy.recordTLSFailure()
    checkEqual("T2 second TLS failure → 40s", policy.interval, 40)
    policy.recordTLSFailure()
    checkEqual("T2 third TLS failure → 80s", policy.interval, 80)
    policy.recordTLSFailure()
    checkEqual("T2 fourth TLS failure → 160s", policy.interval, 160)
    policy.recordTLSFailure()
    checkEqual("T2 fifth TLS failure → 300s", policy.interval, 300)
    policy.recordTLSFailure()
    checkEqual("T2 interval stays capped at 300s", policy.interval, 300)

    // A transport failure must not lower or raise an accumulated TLS backoff.
    policy.recordTransportFailure()
    checkEqual("T2 transport failure keeps the TLS backoff", policy.interval, 300)

    policy.reset()
    checkEqual("T2 reset → 20s", policy.interval, 20)
    checkEqual("T2 reset clears TLS failures", policy.tlsFailures, 0)
    checkEqual("T2 reset clears transport failures", policy.transportFailures, 0)
}

// MARK: - T3 (A4): direct dial uses the TCP port learned from discovery

private func testDirectConnectPort() {
    print("\nT3 — direct-connect port resolution (A4)")
    checkEqual("T3 learned 1717 is used", DirectConnectPort.resolve(learnedPort: UInt16(1717)), 1717)
    checkEqual("T3 learned 1764 (max) is used", DirectConnectPort.resolve(learnedPort: UInt16(1764)), 1764)
    checkEqual("T3 learned 0 falls back to 1716", DirectConnectPort.resolve(learnedPort: UInt16(0)), 1716)
    checkEqual("T3 learned 1715 falls back to 1716", DirectConnectPort.resolve(learnedPort: UInt16(1715)), 1716)
    checkEqual("T3 learned 1765 falls back to 1716", DirectConnectPort.resolve(learnedPort: UInt16(1765)), 1716)
    checkEqual("T3 negative learned port falls back to 1716", DirectConnectPort.resolve(learnedPort: -1), 1716)
    checkEqual("T3 out-of-range Int falls back to 1716", DirectConnectPort.resolve(learnedPort: 70_000), 1716)
}

// MARK: - T4 (A7): keepalive profile depends on the route

private func testKeepAliveProfile() {
    print("\nT4 — keepalive profile (A7)")
    let tailscale = KeepAliveProfile.forHost("100.104.247.78")
    checkEqual("T4 tailnet idle is 60s", tailscale.idle, 60)
    checkEqual("T4 tailnet interval is 15s", tailscale.interval, 15)
    checkEqual("T4 tailnet probe count is 4", tailscale.count, 4)

    let lan = KeepAliveProfile.forHost("192.168.8.244")
    checkEqual("T4 LAN idle is 30s", lan.idle, 30)
    checkEqual("T4 LAN interval is 10s", lan.interval, 10)
    checkEqual("T4 LAN probe count is 3", lan.count, 3)

    check("T4 100.x is detected as tailnet", KeepAliveProfile.isTailscaleHost("100.64.0.1"))
    check("T4 192.168.x is not tailnet", !KeepAliveProfile.isTailscaleHost("192.168.8.244"))
}

// MARK: - T5 (A6): published state transitions

private func testDirectConnectStatus() {
    print("\nT5 — direct-connect status (A6)")
    let tracker = DirectConnectTracker()
    checkEqual("T5 initial state is idle", tracker.status, .idle)

    let attemptA = tracker.begin(host: "100.64.0.2", port: 1716)
    checkEqual("T5 begin → connecting", tracker.status, .connecting(host: "100.64.0.2"))
    _ = tracker.markConnected(attemptA, deviceName: "Pixel")
    checkEqual("T5 connected carries the device name", tracker.status, .connected(host: "100.64.0.2", deviceName: "Pixel"))

    let attemptB = tracker.begin(host: "100.64.0.2", port: 1716)
    checkEqual("T5 new attempt → connecting", tracker.status, .connecting(host: "100.64.0.2"))
    _ = tracker.markFailed(attemptA)
    checkEqual("T5 stale failure does not overwrite the current state", tracker.status, .connecting(host: "100.64.0.2"))
    _ = tracker.markFailed(attemptB)
    checkEqual("T5 current failure → failed", tracker.status, .failed(host: "100.64.0.2"))

    let attemptC = tracker.begin(host: "192.168.1.9", port: 1716)
    checkEqual("T5 timeout cleanup → disconnect", tracker.cleanupTimeout(attemptC), .disconnect)
    checkEqual("T5 timeout cleanup → failed", tracker.status, .failed(host: "192.168.1.9"))
    checkEqual("T5 a second timeout on the same attempt is ignored", tracker.cleanupTimeout(attemptC), .ignore)

    // A background tailnet probe the user never triggered must not paint the manual
    // panel red. A probe that had connected still reports failure when the session dies.
    let autoTracker = DirectConnectTracker()
    let probe = autoTracker.begin(host: "100.64.0.9", port: 1716, announcesFailure: false)
    _ = autoTracker.markFailed(probe)
    checkEqual("T5 failed background probe returns to idle", autoTracker.status, .idle)

    let connectedProbe = autoTracker.begin(host: "100.64.0.9", port: 1716, announcesFailure: false)
    _ = autoTracker.markConnected(connectedProbe, deviceName: "Pixel")
    _ = autoTracker.markFailed(connectedProbe)
    checkEqual("T5 a dropped live probe still reports failure", autoTracker.status, .failed(host: "100.64.0.9"))
}

// MARK: - Run

testStaleAttemptTimeout()
testReconnectBackoff()
testDirectConnectPort()
testKeepAliveProfile()
testDirectConnectStatus()

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("RESULT: RED — \(failures) failing check(s)")
    exit(1)
}
print("RESULT: GREEN — all checks passed")
exit(0)
