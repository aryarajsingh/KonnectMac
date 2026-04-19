import Foundation
import Network
import AppKit

@MainActor
class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    @Published var devices: [String: Device] = [:]
    var connections: [String: KDEConnection] = [:]
    private var connectingDeviceIds = Set<String>()
    private var tlsEstablishedDeviceIds = Set<String>()
    @Published var pendingPairRequests = Set<String>() // devices WE sent pair request to
    private var pendingIncomingPairDevices = Set<String>() // devices showing incoming pair dialog (prevents duplicate notifications)
    private var lastPairRequestTime: [String: Date] = [:] // deviceId -> when we last sent pair request
    private var lastReconnectAttemptTime: [String: Date] = [:] // deviceId -> last outbound reconnect attempt
    private var lastHeartbeatSent: [String: Date] = [:] // deviceId -> last heartbeat sent

    private let udpDiscovery = UDPDiscovery()
    private let tcpServer = LanServer()
    private var broadcastTimer: Timer?
    private var healthCheckTimer: Timer?
    private var networkMonitor: NWPathMonitor?
    private var sleepWakeObserver: NSObjectProtocol?
    private var willSleepObserver: NSObjectProtocol?
    private var networkDebounceTask: Task<Void, Never>?
    private var wakeRecoveryUntil: Date?
    private var isAsleep = false

    private init() {}

    private var inWakeRecoveryWindow: Bool {
        if let until = wakeRecoveryUntil {
            return Date() < until
        }
        return false
    }

    func start() {
        KLog.log("[DeviceManager] Starting...")

        // Start TCP server first (claims the port)
        tcpServer.onIncomingConnection = { [weak self] fd, host in
            self?.handleIncomingSocket(fd: fd, host: host)
        }
        tcpServer.start(preferredPort: Config.shared.tcpPort)
        Config.shared.tcpPort = tcpServer.actualPort

        // Start UDP discovery
        udpDiscovery.onIdentityReceived = { [weak self] packet, host in
            self?.handleDiscoveredIdentity(packet: packet, host: host)
        }
        udpDiscovery.startListening(port: Config.shared.tcpPort)

        // Broadcast identity periodically
        broadcastIdentity()
        startBroadcastTimer()

        // Monitor network changes (WiFi switch, VPN connect, etc.)
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self = self else { return }
                let hasWiFi = path.availableInterfaces.contains { $0.type == .wifi }
                KLog.log("[Network] Path changed — status=\(path.status), wifi=\(hasWiFi)")

                // Debounce: cancel any pending network reaction, wait 2s for stability.
                // macOS fires rapid bursts of path changes during WiFi switches —
                // without debouncing, each triggers reconnection attempts that cascade-fail.
                self.networkDebounceTask?.cancel()
                self.networkDebounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                    guard !Task.isCancelled else { return }

                    if !hasWiFi {
                        self.disconnectNonReachableConnections()
                    }

                    if path.status == .satisfied {
                        self.broadcastIdentity()
                        if !self.inWakeRecoveryWindow {
                            self.reconnectPairedDevices()
                        }
                    }
                }
            }
        }
        networkMonitor?.start(queue: DispatchQueue(label: "network-monitor"))

        // Observe sleep/wake to force immediate reconnection on wake
        willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                KLog.log("[DeviceManager] System going to sleep — shutting down")
                self.isAsleep = true
                self.broadcastTimer?.invalidate()
                self.broadcastTimer = nil
                self.healthCheckTimer?.invalidate()
                self.healthCheckTimer = nil
                self.networkDebounceTask?.cancel()
                self.restartTransportServices(stopOnly: true)
                for (_, conn) in self.connections {
                    let fd = conn.fd
                    if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
                    conn.disconnect()
                }
            }
        }

        sleepWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                KLog.log("[DeviceManager] System woke from sleep — reconnecting")
                self.forceDisconnectAll()
                CertificateManager.shared.invalidateCache()
                self.restartTransportServices()
                self.isAsleep = false
                self.wakeRecoveryUntil = Date().addingTimeInterval(30)

                self.startBroadcastTimer()

                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.broadcastIdentity()

                for attempt in 1...12 {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    let connected = self.connections.values.contains { $0.running && $0.tlsEstablished }
                    if connected {
                        self.wakeRecoveryUntil = nil
                        break
                    }

                    if self.inWakeRecoveryWindow {
                        KLog.log("[DeviceManager] Wake retry \(attempt) — discovery phase")
                        self.broadcastIdentity()
                        continue
                    }

                    KLog.log("[DeviceManager] Wake retry \(attempt) — fallback direct reconnect")
                    self.broadcastIdentity()
                    self.reconnectPairedDevices(force: true)
                }

                self.wakeRecoveryUntil = nil
            }
        }

        // Load paired devices
        loadPairedDevices()

        KLog.log("[DeviceManager] Started on port \(Config.shared.tcpPort)")
    }

    private func startBroadcastTimer() {
        broadcastTimer?.invalidate()
        broadcastTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.broadcastIdentity()
                if self?.inWakeRecoveryWindow == false {
                    self?.reconnectPairedDevices()
                }
            }
        }

        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkConnectionHealth()
            }
        }
    }

    func broadcastIdentity() {
        guard !isAsleep else { return }
        let identity = NetworkPacket.identityPacket()
        udpDiscovery.broadcast(packet: identity)

        // Direct connect to Tailscale/VPN IP — only for non-LAN IPs (100.x.x.x etc.)
        // Connecting to a WiFi IP every 15s creates useless connections that block incoming ones
        let tailscaleIP = Config.shared.tailscaleIP
        if !tailscaleIP.isEmpty && tailscaleIP.hasPrefix("100.") {
            connectDirectToHost(host: tailscaleIP, port: Config.defaultPort)
        }
    }

    /// Actively reconnect to paired devices using their last known IP.
    /// Called on wake and after network changes — don't wait for the phone to hear our broadcast.
    private func reconnectPairedDevices(force: Bool = false) {
        guard !isAsleep else { return }
        guard force || !inWakeRecoveryWindow else { return }

        for device in devices.values where Config.shared.isPaired(deviceId: device.id) {
            // Skip if already connected
            if let conn = connections[device.id], conn.running {
                continue
            }

            // Throttle reconnect attempts. After wake, multiple triggers can overlap
            // (wake task, path monitor, broadcast timer), which can spam TLS handshakes
            // every few seconds and keep the phone in a failed loop.
            if let lastAttempt = lastReconnectAttemptTime[device.id],
               Date().timeIntervalSince(lastAttempt) < 20 {
                continue
            }

            // Try last known IP
            if let ip = Config.shared.savedDeviceIP(for: device.id), !ip.isEmpty {
                lastReconnectAttemptTime[device.id] = Date()
                KLog.log("[DeviceManager] Reconnecting to \(device.name) at \(ip)")
                // Reconnect via device-bound outgoing flow so remoteDeviceId is known
                // before early post-TLS packets arrive.
                connectOutgoing(device: device, host: ip, port: Config.defaultPort)
            }
        }
    }

    // MARK: - Connection Health Check

    /// Periodically check active connections for liveness.
    /// Sends a battery request as heartbeat when idle > 10s (throttled to every 10s).
    /// Disconnects connections idle > 45s — peer is not responding to heartbeats.
    private func checkConnectionHealth() {
        guard !isAsleep else { return }
        let now = Date()

        for (deviceId, conn) in connections {
            guard conn.running, conn.tlsEstablished else { continue }
            let idle = now.timeIntervalSince(conn.lastPacketTime)
            let deviceName = devices[deviceId]?.name ?? String(deviceId.prefix(8))

            if idle > 45 {
                KLog.log("[Health] \(deviceName): idle \(Int(idle))s — disconnecting (fd=\(conn.fd))")
                conn.disconnect()
                lastHeartbeatSent.removeValue(forKey: deviceId)
            } else if idle > 10, Config.shared.isPaired(deviceId: deviceId) {
                let lastSent = lastHeartbeatSent[deviceId].map { now.timeIntervalSince($0) } ?? .infinity
                if lastSent > 10 {
                    if let device = devices[deviceId] {
                        let heartbeat = NetworkPacket(type: "kdeconnect.battery.request", body: ["request": AnyCodable(true)])
                        device.send(heartbeat)
                        lastHeartbeatSent[deviceId] = now
                        KLog.log("[Health] \(deviceName): idle \(Int(idle))s — sending heartbeat")
                    }
                }
            }
        }
    }

    // MARK: - UDP Discovery Handler

    private func handleDiscoveredIdentity(packet: NetworkPacket, host: String) {
        guard !isAsleep else { return }
        guard packet.type == "kdeconnect.identity" else { return }
        guard let deviceId = packet.body["deviceId"]?.value as? String else { return }
        guard deviceId != Config.shared.deviceId else { return }

        let deviceName = packet.body["deviceName"]?.value as? String ?? "Unknown"
        let deviceType = packet.body["deviceType"]?.value as? String ?? "phone"
        let tcpPort = packet.body["tcpPort"]?.value as? Int ?? Int(Config.minPort)

        // Check if already connected or being connected.
        if tlsEstablishedDeviceIds.contains(deviceId) {
            // Verify the connection is actually alive — after sleep/wake it may be stale
            if let conn = connections.values.first(where: { $0.remoteDeviceId == deviceId }),
               isSocketAlive(conn.fd) {
                return
            }
            // Stale connection — clean it up and allow reconnection
            KLog.log("[Discovery] Stale connection for \(deviceName), allowing reconnect")
            for (key, conn) in connections where conn.remoteDeviceId == deviceId {
                conn.disconnect()
                connections.removeValue(forKey: key)
            }
            tlsEstablishedDeviceIds.remove(deviceId)
        }
        if connectingDeviceIds.contains(deviceId) { return }
        for (_, conn) in connections {
            if conn.host == host && isSocketAlive(conn.fd) {
                return
            }
        }

        // Validate tcpPort is within valid range (prevents crash from malicious identity)
        guard let safePort = UInt16(exactly: tcpPort), safePort >= Config.minPort, safePort <= Config.maxPort else {
            KLog.log("[Discovery] Invalid tcpPort \(tcpPort) from \(deviceName), ignoring")
            return
        }

        let device = getOrCreateDevice(id: deviceId, name: deviceName, type: deviceType)
        device.tcpPort = safePort
        if device.connectionState == .disconnected {
            self.updateDeviceState(device, to: .discovered)
        }

        // Save name on discovery
        Config.shared.saveDeviceName(deviceName, for: deviceId)

        KLog.log("[Discovery] Found: \(deviceName) at \(host):\(safePort)")
        connectOutgoing(device: device, host: host, port: safePort)
    }

    // MARK: - Incoming TCP Connection

    private let maxConnections = 50

    private func handleIncomingSocket(fd: Int32, host: String) {
        if isAsleep {
            Darwin.close(fd)
            return
        }
        // Reject if too many concurrent connections (prevents resource exhaustion)
        if connections.count >= maxConnections {
            KLog.log("[TCP] Connection limit reached (\(maxConnections)), rejecting from \(host)")
            Darwin.close(fd)
            return
        }

        // Connection replacement rules:
        // - Pending pair → accept (phone sends pair=true on new connections)
        // - Running + pre-TLS handshake → prefer incoming (break dual-outgoing races)
        // - Running + TLS established + live + idle >10s → accept (peer detected dead connection, reconnecting)
        // - Running + TLS established + live + idle ≤10s → reject incoming (healthy connection)
        // - Running + dead socket → accept incoming
        // - Not running → accept incoming

        for (key, conn) in connections {
            // Match by host (same network path) OR by device ID (same device, different network)
            let sameHost = conn.host == host
            let sameDevice = conn.remoteDeviceId != nil && tlsEstablishedDeviceIds.contains(conn.remoteDeviceId!)
            guard sameHost || sameDevice else { continue }

            let deviceId = conn.remoteDeviceId
            let hasPendingPair = deviceId.map { pendingPairRequests.contains($0) } ?? false
            let deviceForConn = deviceId.flatMap { devices[$0] }
            let isPaired = deviceForConn?.connectionState == .paired

            if hasPendingPair {
                KLog.log("[TCP] Accepting during pending pair from \(host)")
                conn.disconnect()
                connections.removeValue(forKey: key)
                if let devId = deviceId { tlsEstablishedDeviceIds.remove(devId) }
                break
            }

            if conn.running {
                if isSocketAlive(conn.fd) {
                    if !conn.tlsEstablished {
                        // Existing connection is alive but still handshaking (common right
                        // after wake when both sides initiate). Prefer incoming to avoid
                        // both sides ending up as TLS server on parallel outgoing sockets.
                        KLog.log("[TCP] Replacing in-progress connection from \(host) with incoming (fd=\(conn.fd))")
                        conn.disconnect()
                        connections.removeValue(forKey: key)
                        if let devId = deviceId { tlsEstablishedDeviceIds.remove(devId) }
                        break
                    }

                    // TLS established and socket looks alive, but if idle >10s the peer
                    // has detected the dead connection and is reconnecting. isSocketAlive()
                    // returns true for half-open TCP connections because getsockopt(SO_ERROR)
                    // only flags errors already detected by the kernel — a peer that silently
                    // dropped won't show up until keepalive probes fail (10-25s).
                    let idle = Date().timeIntervalSince(conn.lastPacketTime)
                    if idle > 10 {
                        KLog.log("[TCP] Accepting incoming from \(host) — existing connection idle \(Int(idle))s (fd=\(conn.fd))")
                        conn.disconnect()
                        connections.removeValue(forKey: key)
                        if let devId = deviceId { tlsEstablishedDeviceIds.remove(devId) }
                        break
                    }

                    KLog.log("[TCP] Rejecting incoming from \(host) — existing TLS connection fd=\(conn.fd) (idle \(Int(idle))s)")
                    Darwin.close(fd)
                    return
                }
                KLog.log("[TCP] Replacing stale connection from \(host) (fd=\(conn.fd), paired=\(isPaired))")
                conn.disconnect()
                connections.removeValue(forKey: key)
                if let devId = deviceId { tlsEstablishedDeviceIds.remove(devId) }
                break
            }

            // Connection not running → dead, replace it
            KLog.log("[TCP] Replacing dead connection from \(host)")
            connections.removeValue(forKey: key)
            if let devId = deviceId { tlsEstablishedDeviceIds.remove(devId) }
            break
        }

        let conn = KDEConnection(fd: fd, host: host, port: 0, isIncoming: true)

        conn.cachedIdentityData = NetworkPacket.identityPacket().serialize()
        let tempKey = "incoming_\(fd)"
        connections[tempKey] = conn

        conn.onIdentityReceived = { [weak self, weak conn] packet in
            guard let self = self, let conn = conn else { return }
            guard let deviceId = packet.body["deviceId"]?.value as? String else { return }

            let deviceName = packet.body["deviceName"]?.value as? String ?? "Unknown"
            let deviceType = packet.body["deviceType"]?.value as? String ?? "phone"

            conn.remoteDeviceId = deviceId

            // Check if we already have an outgoing connection to this device — prefer incoming
            if let existingConn = self.connections[deviceId], existingConn !== conn {
                KLog.log("[TCP] Replacing outgoing with incoming for \(deviceName)")
                existingConn.disconnect()
                self.connections.removeValue(forKey: deviceId)
                self.tlsEstablishedDeviceIds.remove(deviceId)
            }

            // Re-key from temp to device ID
            self.connections.removeValue(forKey: tempKey)
            self.connections[deviceId] = conn

            let device = self.getOrCreateDevice(id: deviceId, name: deviceName, type: deviceType)
            Config.shared.saveDeviceName(deviceName, for: deviceId)
            Config.shared.saveDeviceType(deviceType, for: deviceId)

            if device.connectionState == .disconnected {
                self.updateDeviceState(device, to: .discovered)
            }
        }

        conn.onTLSReady = { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            guard let deviceId = conn.remoteDeviceId else {
                KLog.log("[Link] TLS ready but no remote ID yet")
                return
            }
            self.finalizeConnection(deviceId: deviceId, conn: conn)
        }

        conn.onPacketReceived = { [weak self, weak conn] packet in
            guard let conn = conn else { return }
            self?.handlePacket(packet, fromConnection: conn)
        }

        conn.onDisconnected = { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            self.handleDisconnection(conn: conn)
        }

        conn.startIncoming()

        // Timeout: if identity hasn't arrived in 10 seconds, clean up orphan connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak conn] in
            guard let self = self else { return }
            if self.connections[tempKey] != nil {
                KLog.log("[TCP] Incoming connection from \(host) timed out waiting for identity, cleaning up")
                conn?.disconnect()
                self.connections.removeValue(forKey: tempKey)
            }
        }
    }

    // MARK: - Outgoing Connection

    private func connectOutgoing(device: Device, host: String, port: UInt16) {
        guard !connectingDeviceIds.contains(device.id) else { return }
        guard device.connectionState != .paired || connections[device.id] == nil else { return }

        connectingDeviceIds.insert(device.id)

        let conn = KDEConnection(host: host, port: port, isIncoming: false)
        conn.remoteDeviceId = device.id

        conn.cachedIdentityData = NetworkPacket.identityPacket().serialize()
        connections[device.id] = conn

        conn.onTLSReady = { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            self.connectingDeviceIds.remove(device.id)
            self.finalizeConnection(deviceId: device.id, conn: conn)
        }

        conn.onIdentityReceived = { [weak self, weak conn] packet in
            guard let self = self, let conn = conn else { return }
            guard self.devices[device.id] != nil else { return }
            if let deviceId = packet.body["deviceId"]?.value as? String {
                conn.remoteDeviceId = deviceId
                let name = packet.body["deviceName"]?.value as? String ?? device.name
                Config.shared.saveDeviceName(name, for: deviceId)
                self.finalizeConnection(deviceId: deviceId, conn: conn)
            }
        }

        conn.onPacketReceived = { [weak self, weak conn] packet in
            guard let self = self, let conn = conn else { return }
            guard self.devices[device.id] != nil else { return }
            self.handlePacket(packet, fromConnection: conn)
        }

        conn.onDisconnected = { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            self.connectingDeviceIds.remove(device.id)
            self.handleDisconnection(conn: conn)
        }

        conn.connectAndRun()
    }

    // MARK: - Direct Host Connection (Tailscale/VPN)

    /// Connect directly to a host by IP — creates a full KDEConnection with TLS handshake.
    /// Used for Tailscale/VPN where UDP broadcast doesn't work.
    /// Unlike the old fire-and-close approach, this keeps the socket open for the full protocol.
    private func connectDirectToHost(host: String, port: UInt16) {
        // Already have a running connection to this host? Skip.
        for (_, conn) in connections {
            if conn.host == host && conn.running {
                KLog.log("[DirectConnect] Skipped \(host) — already connected")
                return
            }
        }

        let tempKey = "direct_\(host)"

        // Already connecting? Skip.
        if connectingDeviceIds.contains(tempKey) {
            KLog.log("[DirectConnect] Skipped \(host) — connect already in progress")
            return
        }
        connectingDeviceIds.insert(tempKey)

        KLog.log("[DirectConnect] Initiating full connection to \(host):\(port)")

        let conn = KDEConnection(host: host, port: port, isIncoming: false)

        conn.cachedIdentityData = NetworkPacket.identityPacket().serialize()
        connections[tempKey] = conn

        conn.onIdentityReceived = { [weak self, weak conn] packet in
            guard let self = self, let conn = conn else { return }
            guard let deviceId = packet.body["deviceId"]?.value as? String else { return }

            let deviceName = packet.body["deviceName"]?.value as? String ?? "Unknown"
            let deviceType = packet.body["deviceType"]?.value as? String ?? "phone"

            conn.remoteDeviceId = deviceId

            // Re-key from temp to real device ID
            self.connections.removeValue(forKey: tempKey)

            // If we already have a running, finalized connection to this device, discard this one.
            // But if the existing connection is on a network that's no longer reachable
            // (e.g. WiFi dropped), replace it — don't wait for TCP keepalive.
            if let existing = self.connections[deviceId], existing !== conn, existing.running {
                if self.tlsEstablishedDeviceIds.contains(deviceId) {
                    // Check if the existing connection's host is still reachable
                    let existingSubnet = self.subnetPrefix(existing.host)
                    let currentIPs = self.getCurrentLocalIPs()
                    let existingReachable = existing.host.hasPrefix("100.") ||
                        currentIPs.contains { self.subnetPrefix($0) == existingSubnet }

                    if existingReachable {
                        KLog.log("[DirectConnect] Already connected to \(deviceName) via \(existing.host), discarding")
                        conn.disconnect()
                        self.connectingDeviceIds.remove(tempKey)
                        return
                    } else {
                        KLog.log("[DirectConnect] Existing connection to \(deviceName) via \(existing.host) is unreachable, replacing with \(host)")
                        existing.disconnect()
                        self.connections.removeValue(forKey: deviceId)
                        self.tlsEstablishedDeviceIds.remove(deviceId)
                    }
                }
            }

            self.connections[deviceId] = conn
            let device = self.getOrCreateDevice(id: deviceId, name: deviceName, type: deviceType)
            Config.shared.saveDeviceName(deviceName, for: deviceId)
            Config.shared.saveDeviceType(deviceType, for: deviceId)

            if device.connectionState == .disconnected {
                self.updateDeviceState(device, to: .discovered)
            }

            // If TLS is already established (identity arrived over TLS after handshake), finalize now
            if conn.tlsEstablished {
                self.connectingDeviceIds.remove(tempKey)
                self.finalizeConnection(deviceId: deviceId, conn: conn)
            }
        }

        conn.onTLSReady = { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            self.connectingDeviceIds.remove(tempKey)
            guard let deviceId = conn.remoteDeviceId else {
                // Normal for outgoing: identity arrives over TLS after handshake
                // onIdentityReceived will call finalizeConnection when it arrives
                return
            }
            self.finalizeConnection(deviceId: deviceId, conn: conn)
        }

        conn.onPacketReceived = { [weak self, weak conn] packet in
            guard let conn = conn else { return }
            self?.handlePacket(packet, fromConnection: conn)
        }

        conn.onDisconnected = { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            self.connectingDeviceIds.remove(tempKey)
            self.handleDisconnection(conn: conn)
        }

        conn.connectAndRun()

        // Timeout: if identity hasn't arrived in 15 seconds, clean up orphan connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak conn] in
            guard let self = self else { return }
            if self.connections[tempKey] != nil {
                KLog.log("[DirectConnect] Connection to \(host) timed out waiting for identity, cleaning up")
                conn?.disconnect()
                self.connections.removeValue(forKey: tempKey)
                self.connectingDeviceIds.remove(tempKey)
            }
        }
    }

    // MARK: - Connection Finalization

    private func finalizeConnection(deviceId: String, conn: KDEConnection) {
        // If we already have a different, fully finalized connection to this device, keep the existing one.
        // This prevents WiFi↔Tailscale flip-flopping — first to finalize wins.
        if let existing = connections[deviceId], existing !== conn, existing.running, tlsEstablishedDeviceIds.contains(deviceId) {
            KLog.log("[Link] Already have active connection to \(deviceId), discarding duplicate")
            conn.disconnect()
            return
        }
        // Clean up any stale/dead connection for this device
        if let existing = connections[deviceId], existing !== conn {
            KLog.log("[Link] Replacing dead connection to \(deviceId)")
            existing.disconnect()
        }

        tlsEstablishedDeviceIds.insert(deviceId)
        connectingDeviceIds.remove(deviceId)
        lastReconnectAttemptTime.removeValue(forKey: deviceId)
        connections[deviceId] = conn

        let device = getOrCreateDevice(id: deviceId, name: Config.shared.savedDeviceName(for: deviceId) ?? deviceId)
        device.kdeConn = conn

        if Config.shared.isPaired(deviceId: deviceId) {
            // Validate peer certificate matches stored cert (CVE-2025-32899 mitigation)
            if let storedCertData = Config.shared.loadPairedDeviceCert(id: deviceId),
               storedCertData.count > 1 { // >1 to skip old placeholder bytes
                if let peerCert = conn.getPeerCertificate() {
                    let peerData = SecCertificateCopyData(peerCert) as Data
                    if peerData != storedCertData {
                        KLog.log("[Security] Certificate mismatch for \(device.name) — rejecting impersonator")
                        conn.disconnect()
                        return
                    }
                } else {
                    KLog.log("[Security] No peer certificate from \(device.name) — rejecting")
                    conn.disconnect()
                    return
                }
            }
            self.updateDeviceState(device, to: .paired)
            initializePlugins(for: device)
            // Request battery status
            let batteryRequest = NetworkPacket(type: "kdeconnect.battery.request", body: ["request": AnyCodable(true)])
            device.send(batteryRequest)
        } else {
            self.updateDeviceState(device, to: .discovered)
        }

        // Save last known IP for reconnection after sleep/wake
        if Config.shared.isPaired(deviceId: deviceId) {
            Config.shared.saveDeviceIP(conn.host, for: deviceId)
        }

        KLog.log("[Link] Finalized connection to \(device.name) (\(deviceId))")

        // If we have a pending pair request for this device, re-send on the new connection
        // ONLY if enough time has passed since the last send (debounce).
        // The phone reconnects TCP during pairing (new TLS session). Without debouncing,
        // each reconnect triggers a re-send, causing duplicate pair notifications on Android.
        if pendingPairRequests.contains(deviceId) {
            let timeSinceLastSend = lastPairRequestTime[deviceId].map { Date().timeIntervalSince($0) } ?? .infinity
            if timeSinceLastSend > 5 {
                let pairPacket = NetworkPacket.pairPacket(pair: true)
                device.send(pairPacket)
                lastPairRequestTime[deviceId] = Date()
                KLog.log("[Pairing] Re-sent pair request to \(device.name) on new connection (fd=\(conn.fd))")
            } else {
                KLog.log("[Pairing] Skipping re-send to \(device.name) — last sent \(String(format: "%.1f", timeSinceLastSend))s ago")
            }
        }
    }

    // MARK: - Network Failover

    /// Disconnect connections whose host IPs are no longer reachable.
    /// Called when WiFi drops — kills stale WiFi connections immediately
    /// so Tailscale can take over without waiting for TCP keepalive (2+ min).
    private func disconnectNonReachableConnections() {
        let currentIPs = getCurrentLocalIPs()
        guard !currentIPs.isEmpty else {
            // No IPs at all — disconnect everything
            for (_, conn) in connections where conn.running {
                KLog.log("[Network] No network — disconnecting \(conn.host)")
                conn.disconnect()
            }
            return
        }

        // Check if each connection's host is on a reachable subnet.
        // Private WiFi IPs (192.168.x.x, 10.x.x.x, 172.16-31.x.x) that don't match
        // any current interface subnet are likely stale.
        for (_, conn) in connections where conn.running {
            let connHost = conn.host

            // Tailscale IPs (100.x.x.x) — always reachable if Tailscale is up
            if connHost.hasPrefix("100.") { continue }

            // Check if any local IP shares a /24 subnet with the connection host
            let connSubnet = subnetPrefix(connHost)
            let reachable = currentIPs.contains { subnetPrefix($0) == connSubnet }

            if !reachable {
                KLog.log("[Network] Connection to \(connHost) is no longer reachable, disconnecting")
                conn.disconnect()
            }
        }
    }

    /// Force-disconnect ALL connections and clear internal state.
    /// Used on wake to ensure a clean slate — after sleep,
    /// TCP connections are stale regardless of subnet reachability.
    private func forceDisconnectAll() {
        for (_, conn) in connections {
            let fd = conn.fd
            if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
            conn.disconnect()
        }
        connections.removeAll()
        tlsEstablishedDeviceIds.removeAll()
        connectingDeviceIds.removeAll()
        lastReconnectAttemptTime.removeAll()
        lastHeartbeatSent.removeAll()
        for device in devices.values {
            if let clipPlugin = device.plugins["clipboard"] as? ClipboardPlugin {
                clipPlugin.stop()
            }
            if let telPlugin = device.plugins["telephony"] as? TelephonyPlugin {
                if telPlugin.hasActiveCall { telPlugin.onCallEnded() }
                telPlugin.resetOnDisconnect()
            }
            if let batPlugin = device.plugins["battery"] as? BatteryPlugin {
                batPlugin.resetOnDisconnect()
            }
            device.kdeConn = nil
            if device.connectionState == .paired || device.connectionState == .discovered {
                updateDeviceState(device, to: .disconnected)
            }
        }
    }

    /// Recreate UDP and TCP sockets after sleep/wake.
    /// macOS can leave listening sockets unusable across suspend/resume,
    /// so reconnect logic needs fresh transport endpoints before broadcasting.
    private func restartTransportServices(stopOnly: Bool = false) {
        udpDiscovery.stop()
        tcpServer.stop()

        guard !stopOnly else { return }

        tcpServer.start(preferredPort: Config.shared.tcpPort)
        Config.shared.tcpPort = tcpServer.actualPort
        udpDiscovery.startListening(port: Config.shared.tcpPort)
        KLog.log("[DeviceManager] Restarted transport services on port \(Config.shared.tcpPort)")
    }

    private func getCurrentLocalIPs() -> [String] {
        var ips = [String]()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return ips }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let addr = ptr.pointee.ifa_addr.pointee
            let flags = Int32(ptr.pointee.ifa_flags)
            if addr.sa_family == UInt8(AF_INET) && (flags & IFF_UP) != 0 {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                if ip != "127.0.0.1" {
                    ips.append(ip)
                }
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }
        return ips
    }

    /// Returns first 3 octets of an IPv4 address for /24 subnet comparison
    private func subnetPrefix(_ ip: String) -> String {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return ip }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    // MARK: - Disconnection

    private func handleDisconnection(conn: KDEConnection) {
        let deviceId = conn.remoteDeviceId
        let deviceName = deviceId.flatMap { devices[$0]?.name } ?? "unknown"
        KLog.log("[Link] handleDisconnection called for \(deviceName) (deviceId=\(deviceId ?? "nil"), connRunning=\(conn.running), connFd=\(conn.fd))")
        if let id = deviceId {
            connectingDeviceIds.remove(id)
            lastHeartbeatSent.removeValue(forKey: id)

            // Only tear down device state if THIS conn is still the active one.
            // If connections[id] already points to a different (newer) conn, a replacement
            // is in progress — don't set the device to .disconnected or wipe tlsEstablished.
            // Without this guard, every 15s reconnect fires a spurious disconnect→reconnect
            // flash in the device list.
            if connections[id] === conn {
                connections.removeValue(forKey: id)
                // Capture whether TLS was established BEFORE clearing the set.
                // If TLS never happened (e.g. outgoing TCP connect was refused), the
                // device was never truly connected — don't flash it to .disconnected.
                let wasTLSEstablished = tlsEstablishedDeviceIds.remove(id) != nil

                if let device = devices[id] {
                    if wasTLSEstablished || device.connectionState == .paired {
                        // Real connection drop — stop plugins and update device state.
                        if let clipPlugin = device.plugins["clipboard"] as? ClipboardPlugin {
                            clipPlugin.stop()
                        }
                        if let telPlugin = device.plugins["telephony"] as? TelephonyPlugin {
                            if telPlugin.hasActiveCall { telPlugin.onCallEnded() }
                            telPlugin.resetOnDisconnect()
                        }
                        if let batPlugin = device.plugins["battery"] as? BatteryPlugin {
                            batPlugin.resetOnDisconnect()
                        }
                        // Don't clear pendingPairRequests on disconnect — the phone reconnects
                        // TCP mid-pair (normal behavior), and the reconnect carries pairing forward.
                        device.kdeConn = nil
                        device.batteryLevel = -1
                        device.batteryCharging = false
                        self.updateDeviceState(device, to: .disconnected)
                        self.devices[id] = device
                    }
                    // else: outgoing failed before TLS (Connection refused, timeout, etc.)
                    // Keep device in .discovered state — phone will connect incoming shortly.
                }
            } else {
                KLog.log("[Link] Stale disconnect for \(id) — replacement connection active, skipping state change")
            }
        }
        // Clean up temp keys
        for (key, c) in connections where c === conn {
            connections.removeValue(forKey: key)
        }
        KLog.log("[Link] Disconnected from \(deviceId ?? "unknown")")
    }

    // MARK: - Packet Handling

    private func handlePacket(_ packet: NetworkPacket, fromConnection conn: KDEConnection) {
        if packet.type == "kdeconnect.pair" {
            handlePairPacket(packet, fromConnection: conn)
            return
        }

        // Log every incoming packet type for debugging missing notifications
        if packet.type == "kdeconnect.notification" {
            let notifId = packet.body["id"]?.value as? String ?? "?"
            let appName = packet.body["appName"]?.value as? String ?? "?"
            let isCancel = packet.body["isCancel"]?.value as? Bool ?? false
            KLog.log("[Packet] notification from \(appName) id=\(notifId.prefix(60)) isCancel=\(isCancel)")
        }

        guard let deviceId = conn.remoteDeviceId, let device = devices[deviceId] else {
            KLog.log("[DeviceManager] Packet dropped: no device for connection \(conn.host)")
            return
        }
        device.handlePacket(packet)
    }

    // MARK: - Pairing

    func requestPairing(deviceId: String) {
        guard let device = devices[deviceId] else { return }

        pendingPairRequests.insert(deviceId)

        // Find the active connection — either device.kdeConn or from connections dict
        let conn = device.kdeConn ?? connections[deviceId]

        if let conn = conn, conn.running, conn.fd >= 0 {
            // Send pair request on the active connection
            let pairPacket = NetworkPacket.pairPacket(pair: true)
            conn.send(pairPacket)
            lastPairRequestTime[deviceId] = Date()
            KLog.log("[Pairing] Sent pair request to \(device.name) (fd=\(conn.fd))")
        } else {
            // No active connection — broadcast to trigger phone to connect, then retry
            KLog.log("[Pairing] No active connection to \(device.name), broadcasting and waiting")
            broadcastIdentity()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self, self.pendingPairRequests.contains(deviceId) else { return }
                let retryConn = device.kdeConn ?? self.connections[deviceId]
                if let c = retryConn, c.running, c.fd >= 0 {
                    let pairPacket = NetworkPacket.pairPacket(pair: true)
                    c.send(pairPacket)
                    self.lastPairRequestTime[deviceId] = Date()
                    KLog.log("[Pairing] Sent pair request to \(device.name) on retry (fd=\(c.fd))")
                } else {
                    KLog.log("[Pairing] Still no connection to \(device.name), will send on next connect")
                }
            }
        }

        // Auto-cancel after 30s if no response
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if self?.pendingPairRequests.contains(deviceId) == true {
                self?.pendingPairRequests.remove(deviceId)
                KLog.log("[Pairing] Pair request to \(device.name) timed out")
            }
        }
    }

    func verificationKey(for deviceId: String) -> String? {
        guard let conn = connections[deviceId] ?? device(for: deviceId)?.kdeConn else { return nil }
        let key = VerificationKeyHelper.computeFromConnection(conn: conn)
        return key.isEmpty ? nil : key
    }

    private func device(for id: String) -> Device? { devices[id] }

    func cancelPairing(deviceId: String) {
        pendingPairRequests.remove(deviceId)
        KLog.log("[Pairing] Cancelled pairing request for \(deviceId)")
    }

    func unpair(deviceId: String) {
        guard let device = devices[deviceId] else { return }
        let unpairPacket = NetworkPacket.pairPacket(pair: false)
        device.send(unpairPacket)
        Config.shared.removePairedDevice(id: deviceId)
        pendingPairRequests.remove(deviceId)
        recentlyPairedDevices.removeValue(forKey: deviceId)
        self.updateDeviceState(device, to: .discovered)
        device.plugins.removeAll()
        KLog.log("[Pairing] Unpaired from \(device.name)")
    }

    private func handlePairPacket(_ packet: NetworkPacket, fromConnection conn: KDEConnection) {
        guard let deviceId = conn.remoteDeviceId, let device = devices[deviceId] else {
            KLog.log("[Pairing] Pair packet dropped: no device for connection \(conn.host)")
            return
        }
        let pair = packet.body["pair"]?.value as? Bool ?? false
        KLog.log("[Pairing] Received pair=\(pair) from \(device.name) (isPaired=\(Config.shared.isPaired(deviceId: deviceId)), pending=\(pendingPairRequests.contains(deviceId)))")

        if pair {
            // If WE initiated the pairing, the phone's "pair: true" is acceptance — complete directly
            if pendingPairRequests.contains(deviceId) {
                KLog.log("[Pairing] Accepted by \(device.name)")
                pendingPairRequests.remove(deviceId)
                completePairing(device: device, conn: conn)
                return
            }

            // Already paired — this is a re-confirmation (phone reconnected, sent pair=true again).
            // Silently accept it. Don't show a pairing dialog.
            if Config.shared.isPaired(deviceId: deviceId) {
                KLog.log("[Pairing] Already paired with \(device.name), confirming re-pair silently")
                let response = NetworkPacket.pairPacket(pair: true)
                conn.send(response)
                completePairing(device: device, conn: conn)
                return
            }

            // Phone initiated — show dialog.
            // Guard: don't show duplicate dialogs. The phone re-sends pair=true on every
            // new connection (~15s cycle for unpaired devices). Without this guard, the user
            // gets a new notification every 15 seconds.
            if pendingIncomingPairDevices.contains(deviceId) {
                KLog.log("[Pairing] Already showing pair dialog for \(device.name), ignoring duplicate")
                return
            }
            pendingIncomingPairDevices.insert(deviceId)
            KLog.log("[Pairing] Request from \(device.name)")
            // Pre-capture cert now — conn.getPeerCertificate() may return nil later if
            // the phone's connection cycles during runModal() and SSL is cleaned up.
            let preCapturedCert = conn.getPeerCertificate()
            PairingHandler.showPairingRequest(from: device, connection: conn) { [weak self] accepted in
                guard let self = self else { return }
                // defer ensures cleanup even if something throws or returns early
                defer { self.pendingIncomingPairDevices.remove(deviceId) }
                // Re-fetch device — it may have been recreated during the dialog
                guard let device = self.devices[deviceId] else { return }
                if accepted {
                    // Use the CURRENT active connection — the original one captured
                    // in the closure is likely dead (unpaired connections cycle ~15s).
                    let activeConn = self.connections[deviceId] ?? conn
                    // Update device's connection reference — device.send() uses kdeConn,
                    // which may still point to the dead connection from before the dialog.
                    device.kdeConn = activeConn
                    let response = NetworkPacket.pairPacket(pair: true)
                    // Send directly on activeConn as belt-and-suspenders
                    activeConn.send(response)
                    KLog.log("[Pairing] Sent pair=true response to \(device.name) on fd=\(activeConn.fd)")
                    self.completePairing(device: device, conn: activeConn, preCapturedCert: preCapturedCert)
                } else {
                    let response = NetworkPacket.pairPacket(pair: false)
                    device.send(response)
                }
            }
        } else {
            // Unpair request from remote
            let wasPaired = Config.shared.isPaired(deviceId: deviceId)
            let hadPendingRequest = pendingPairRequests.contains(deviceId)

            if wasPaired {
                // Ignore pair=false within 10s of completing pairing — it's the phone's
                // new connection sending initial state, not an actual unpair request
                if let pairedAt = recentlyPairedDevices[deviceId],
                   Date().timeIntervalSince(pairedAt) < 10 {
                    KLog.log("[Pairing] Ignoring pair=false from \(device.name) — just paired \(Int(Date().timeIntervalSince(pairedAt)))s ago")
                    return
                }
                Config.shared.removePairedDevice(id: deviceId)
                self.updateDeviceState(device, to: .discovered)
                device.plugins.removeAll()
                recentlyPairedDevices.removeValue(forKey: deviceId)
                // Disconnect the TLS connection — unpaired device shouldn't keep the channel open
                conn.disconnect()
                connections.removeValue(forKey: deviceId)
                tlsEstablishedDeviceIds.remove(deviceId)
                KLog.log("[Pairing] \(device.name) unpaired by remote, connection closed")
            }

            if !wasPaired && !hadPendingRequest {
                KLog.log("[Pairing] Ignoring unpair from \(device.name) — not paired")
            } else if hadPendingRequest {
                // Phone sent pair=false while we have a pending request.
                // This is normal — the phone clears old state before responding.
                // Don't retry — just wait for the pair=true on this connection.
                KLog.log("[Pairing] Waiting for pair acceptance from \(device.name)")
            }
        }
    }

    private var recentlyPairedDevices: [String: Date] = [:] // deviceId -> when paired

    /// Prune entries older than 30s — only needed for the 10s grace period check
    private func pruneRecentlyPairedDevices() {
        let cutoff = Date().addingTimeInterval(-30)
        recentlyPairedDevices = recentlyPairedDevices.filter { $0.value > cutoff }
    }

    func completePairing(device: Device, conn: KDEConnection, preCapturedCert: SecCertificate? = nil) {
        // Guard against duplicate completePairing calls (reconnect re-confirmation, race conditions)
        if device.connectionState == .paired && Config.shared.isPaired(deviceId: device.id) {
            // Already fully paired — just refresh the timestamp
            recentlyPairedDevices[device.id] = Date()
            KLog.log("[Pairing] Already paired with \(device.name), refreshing state")
            return
        }

        recentlyPairedDevices[device.id] = Date()
        pruneRecentlyPairedDevices()
        // Always clear pending state — whether we initiated or phone did
        pendingPairRequests.remove(device.id)

        // Save peer certificate — REQUIRED for secure pairing.
        // Fall back to preCapturedCert if the connection cycled during a runModal() dialog.
        let peerCert = conn.getPeerCertificate() ?? preCapturedCert
        guard let peerCert = peerCert else {
            KLog.log("[Pairing] CRITICAL: No peer certificate from \(device.name) — refusing to pair. Connection has no trust anchor.")
            return
        }
        let certData = SecCertificateCopyData(peerCert) as Data
        Config.shared.savePairedDevice(id: device.id, certData: certData)
        KLog.log("[Pairing] Saved peer certificate for \(device.name) (\(certData.count) bytes)")

        Config.shared.saveDeviceName(device.name, for: device.id)
        Config.shared.saveDeviceType(device.type, for: device.id)

        self.updateDeviceState(device, to: .paired)
        initializePlugins(for: device)
        KLog.log("[Pairing] Completed with \(device.name)")

        // Request battery
        let batteryRequest = NetworkPacket(type: "kdeconnect.battery.request", body: ["request": AnyCodable(true)])
        device.send(batteryRequest)
    }

    // MARK: - Plugins

    private func initializePlugins(for device: Device) {
        let enabled = Config.shared.enabledPlugins(for: device.id)
        device.plugins.removeAll()

        if enabled.contains("ping") { device.plugins["ping"] = PingPlugin(device: device) }
        if enabled.contains("battery") { device.plugins["battery"] = BatteryPlugin(device: device) }
        if enabled.contains("notification") { device.plugins["notification"] = NotificationPlugin(device: device) }
        if enabled.contains("telephony") { device.plugins["telephony"] = TelephonyPlugin(device: device) }
        if enabled.contains("clipboard") {
            let clipPlugin = ClipboardPlugin(device: device)
            clipPlugin.start()
            device.plugins["clipboard"] = clipPlugin
        }
        if enabled.contains("findmyphone") { device.plugins["findmyphone"] = FindMyPhonePlugin(device: device) }
        if enabled.contains("share") { device.plugins["share"] = SharePlugin(device: device) }

        // Request all notifications
        let notifRequest = NetworkPacket(type: "kdeconnect.notification.request", body: ["request": AnyCodable(true)])
        device.send(notifRequest)
    }

    /// Call this when plugin toggles change so plugins are reloaded at runtime
    func reloadPlugins(for deviceId: String) {
        guard let device = devices[deviceId] else { return }
        initializePlugins(for: device)
        KLog.log("[DeviceManager] Reloaded plugins for \(device.name)")
    }

    // MARK: - Helpers

    /// Check if a socket fd is actually alive using a zero-byte write.
    /// After sleep/wake, the OS may keep the fd open but the TCP connection is dead —
    /// this detects it without blocking. Returns false if the fd is -1 or write fails.
    private func isSocketAlive(_ fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        var err: Int32 = 0
        var errLen = socklen_t(MemoryLayout<Int32>.size)
        let result = getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen)
        if result != 0 || err != 0 {
            KLog.log("[TCP] Socket fd=\(fd) dead: getsockopt result=\(result), error=\(err)")
            return false
        }
        return true
    }

    func getOrCreateDevice(id: String, name: String, type: String = "phone") -> Device {
        if let existing = devices[id] {
            if existing.name != name && name != id {
                existing.name = name
            }
            return existing
        }
        let savedName = Config.shared.savedDeviceName(for: id) ?? name
        let device = Device(id: id, name: savedName, type: type)
        devices[id] = device
        return device
    }

    /// Update device state and force SwiftUI refresh
    private func updateDeviceState(_ device: Device, to state: ConnectionState) {
        device.connectionState = state
        // Force dictionary mutation so @Published triggers SwiftUI update
        devices[device.id] = device
        objectWillChange.send()
    }

    private func loadPairedDevices() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSupport.appendingPathComponent("KonnectMac/PairedDevices")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }

        for file in files where file.hasSuffix(".der") {
            let deviceId = String(file.dropLast(4))
            let name = Config.shared.savedDeviceName(for: deviceId) ?? deviceId
            let device = getOrCreateDevice(id: deviceId, name: name)
            self.updateDeviceState(device, to: .disconnected)
            KLog.log("[DeviceManager] Loaded paired device: \(name)")
        }
    }

    /// Gracefully stop all services, timers, and connections. Called on app termination.
    func stopServices() {
        KLog.log("[DeviceManager] Stopping all services...")

        // Invalidate broadcast timer
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil

        // Remove sleep/wake observers
        if let observer = willSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            willSleepObserver = nil
        }
        if let observer = sleepWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sleepWakeObserver = nil
        }

        // Cancel network monitor
        networkMonitor?.cancel()
        networkMonitor = nil

        // Stop UDP discovery and TCP server
        udpDiscovery.stop()
        tcpServer.stop()

        // Close all connections gracefully
        for (_, conn) in connections {
            conn.disconnect()
        }
        connections.removeAll()
        tlsEstablishedDeviceIds.removeAll()
        connectingDeviceIds.removeAll()

        // Stop plugins for all devices
        for (_, device) in devices {
            if let clipPlugin = device.plugins["clipboard"] as? ClipboardPlugin {
                clipPlugin.stop()
            }
            device.plugins.removeAll()
            device.kdeConn = nil
        }

        KLog.log("[DeviceManager] All services stopped")
    }

    func connectToDirectIP(_ ip: String) {
        guard !ip.isEmpty else { return }
        connectDirectToHost(host: ip, port: Config.defaultPort)
    }
}
