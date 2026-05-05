import Foundation
import os
import Security

class KDEConnection {
    private var _fd: Int32 = -1
    let host: String
    let port: UInt16
    let isIncoming: Bool
    var remoteDeviceId: String?
    private var _running = false
    private var _tlsEstablished = false
    private var _lastPacketTime = Date()
    // Lock ordering: pendingWriteLock -> stateLock (never acquire stateLock then pendingWriteLock)
    private let stateLock = OSAllocatedUnfairLock(initialState: ())
    private var sslContext: SSLContext?

    var fd: Int32 {
        get { stateLock.withLock { _fd } }
        set { stateLock.withLock { _fd = newValue } }
    }

    var running: Bool {
        get { stateLock.withLock { _running } }
        set { stateLock.withLock { _running = newValue } }
    }

    var tlsEstablished: Bool {
        get { stateLock.withLock { _tlsEstablished } }
        set { stateLock.withLock { _tlsEstablished = newValue } }
    }

    var lastPacketTime: Date {
        get { stateLock.withLock { _lastPacketTime } }
        set { stateLock.withLock { _lastPacketTime = newValue } }
    }
    private var sslFdPtr: UnsafeMutablePointer<Int32>?
    private var readBuffer = Data()
    private var pendingWriteData = Data()
    private let pendingWriteLock = NSLock()
    private var disconnectOnce = false
    private let queue = DispatchQueue(label: "kdeconnection", qos: .userInitiated)
    /// Per-connection TLS identity. Held for the lifetime of this KDEConnection so the
    /// underlying private keychain survives until SSLClose has fully released the cert/key
    /// references. See the doc on `CertificateManager.TransferIdentity` for why we
    /// can't share the cached SecIdentity across multiple SSLContexts (it gets into a
    /// state SecureTransport never recovers from after sleep/wake or repeated handshakes).
    private var transferIdentity: CertificateManager.TransferIdentity?

    var onIdentityReceived: ((NetworkPacket) -> Void)?
    var onTLSReady: (() -> Void)?
    var onPacketReceived: ((NetworkPacket) -> Void)?
    var onDisconnected: (() -> Void)?
    // TCP keepalive handles connection liveness — no app-level pings needed

    deinit {
        // Safety net: if connectionLoop never ran (object deallocated before queue executes),
        // clean up any remaining fd and SSL resources.
        if _fd >= 0 { Darwin.close(_fd); _fd = -1 }
        // Order matters: SSLContext must be released BEFORE the TransferIdentity (whose
        // deinit deletes the underlying keychain). Setting sslContext = nil drops our
        // strong reference, which lets SecureTransport release its hold on the cert/key
        // before the keychain disappears.
        if let ctx = sslContext { SSLClose(ctx); sslContext = nil }
        sslFdPtr?.deallocate()
        transferIdentity = nil
    }

    init(host: String, port: UInt16, isIncoming: Bool) {
        self.host = host
        self.port = port
        self.isIncoming = isIncoming
    }

    init(fd: Int32, host: String, port: UInt16, isIncoming: Bool) {
        self._fd = fd
        self.host = host
        self.port = port
        self.isIncoming = isIncoming
    }

    func send(_ packet: NetworkPacket) {
        guard let data = packet.serialize() else { return }
        pendingWriteLock.lock()
        // Cap write queue at 1MB to prevent unbounded memory growth
        if pendingWriteData.count + data.count > 1_048_576 {
            pendingWriteLock.unlock()
            KLog.log("[KDEConn] Write queue full (>1MB), dropping packet")
            return
        }
        pendingWriteData.append(data)
        pendingWriteLock.unlock()
    }

    var cachedIdentityData: Data?

    func connectAndRun() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self._fd = socket(AF_INET, SOCK_STREAM, 0)
            guard self._fd >= 0 else { return }

            SocketHelpers.enableNoDelay(fd: self._fd)

            // Set connect timeout to 10 seconds to prevent blocking GCD threads
            // on unreachable hosts (default TCP timeout is ~75 seconds)
            var connectTimeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(self._fd, SOL_SOCKET, SO_SNDTIMEO, &connectTimeout, socklen_t(MemoryLayout<timeval>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = self.port.bigEndian
            guard inet_pton(AF_INET, self.host, &addr.sin_addr) == 1 else {
                KLog.log("[KDEConn] Invalid IP: \(self.host)")
                Darwin.close(self._fd)
                self._fd = -1
                return
            }

            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(self._fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                KLog.log("[KDEConn] Connect to \(self.host):\(self.port) failed: \(String(cString: strerror(errno)))")
                Darwin.close(self._fd)
                self._fd = -1
                DispatchQueue.main.async { [weak self] in
                    self?.onDisconnected?()
                }
                return
            }

            self.enableKeepAlive()
            self._running = true
            self.connectionLoop()
        }
    }

    func startIncoming() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.enableKeepAlive()
            self._running = true
            self.connectionLoop()
        }
    }

    private func enableKeepAlive() {
        SocketHelpers.enableControlKeepAlive(fd: _fd)
    }

    private func connectionLoop() {
        if !isIncoming {
            // Outgoing: send identity over raw TCP, then TLS
            guard let data = cachedIdentityData else {
                disconnect()
                return
            }
            _ = rawWrite(data)
            KLog.log("[KDEConn] Sent identity to \(host):\(port)")
        } else {
            // Incoming: read phone's identity over raw TCP
            var rawTimeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &rawTimeout, socklen_t(MemoryLayout<timeval>.size))
            if let identityData = readRawLine() {
                if let packet = NetworkPacket.deserialize(from: identityData) {
                    remoteDeviceId = packet.body["deviceId"]?.value as? String
                    KLog.log("[KDEConn] Received identity from \(remoteDeviceId ?? "unknown") at \(host)")
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.onIdentityReceived?(packet)
                    }
                }
            }
        }

        // KDE Connect crossover rule: TCP server = TLS client, TCP client = TLS server
        // For incoming connections (we are TCP server) → we are TLS client
        // For outgoing connections (we are TCP client) → we are TLS server
        let isTLSServer = !isIncoming

        // Setup TLS
        guard setupTLS(isServer: isTLSServer) else {
            KLog.log("[KDEConn] TLS setup failed for \(host)")
            cleanupSSL()
            disconnect()
            return
        }

        // Set socket timeout for handshake (10s max)
        var handshakeTimeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &handshakeTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(_fd, SOL_SOCKET, SO_SNDTIMEO, &handshakeTimeout, socklen_t(MemoryLayout<timeval>.size))

        // Perform TLS handshake. TLSHelpers.runHandshake handles the retry-set
        // (errSSLWouldBlock, errSSLPeerAuthCompleted, errSSLClientCertRequested)
        // and logs failures with the role label.
        KLog.log("[KDEConn] Starting TLS handshake with \(host) (server=\(isTLSServer))")
        guard TLSHelpers.runHandshake(sslContext!, role: "KDEConn") else {
            cleanupSSL()
            disconnect()
            return
        }

        _tlsEstablished = true
        _lastPacketTime = Date()  // Reset idle timer from TLS establishment, not connection creation
        KLog.log("[KDEConn] TLS established with \(host) (server=\(isTLSServer))")

        // Send identity over TLS
        if let data = cachedIdentityData, let ctx = sslContext {
            var totalWritten = 0
            var writeRetries = 0
            data.withUnsafeBytes { buf in
                guard let baseAddr = buf.baseAddress else { return }
                while totalWritten < data.count {
                    var written = 0
                    let status = SSLWrite(ctx, baseAddr + totalWritten, data.count - totalWritten, &written)
                    if written > 0 { totalWritten += written; writeRetries = 0 }
                    if status == errSSLWouldBlock {
                        writeRetries += 1
                        if writeRetries > 5000 {
                            KLog.log("[KDEConn] SSLWrite stuck sending identity, aborting")
                            break
                        }
                        usleep(1000)
                        continue
                    }
                    if status != errSecSuccess {
                        KLog.log("[KDEConn] SSLWrite error: \(status) (wrote \(totalWritten)/\(data.count))")
                        break
                    }
                }
            }
            KLog.log("[KDEConn] Sent identity over TLS (\(totalWritten) bytes)")
        }

        // Set socket timeout for read loop
        var timeout = timeval(tv_sec: 0, tv_usec: 500000)
        setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        DispatchQueue.main.async { [weak self] in
            self?.onTLSReady?()
        }

        // Main read loop — use locked `running` getter to prevent data race with disconnect()
        while running {
            drainWriteQueue()

            if let packet = readTLSPacket() {
                _lastPacketTime = Date()
                if packet.type == "kdeconnect.identity" {
                    remoteDeviceId = packet.body["deviceId"]?.value as? String
                    KLog.log("[KDEConn] Received TLS identity from \(remoteDeviceId ?? "unknown")")
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.onIdentityReceived?(packet)
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.onPacketReceived?(packet)
                    }
                }
            } else {
                // readTLSPacket returned nil — timeout, skip, or error
                let idleSincePacket = Date().timeIntervalSince(_lastPacketTime)
                // Log every 15s of idle to track connection health
                if Int(idleSincePacket) % 15 == 0 && idleSincePacket > 1 {
                    KLog.log("[KDEConn] Idle \(Int(idleSincePacket))s on \(host) (running=\(_running), fd=\(_fd))")
                }
                // TCP keepalive (60s idle, 15s probe, 4 retries) detects dead connections
                // at the OS level. When the phone truly dies, TCP probes fail and SSLRead
                // returns an error — which our read loop handles above.
                // We do NOT kill the connection based on app-level idle time because
                // a paired phone can be legitimately idle for minutes (screen off, no activity).
            }
        }

        _running = false
        // SSLClose must happen BEFORE fd close so TLS close_notify is sent on valid socket
        cleanupSSL()
        let currentFd = _fd
        _fd = -1
        if currentFd >= 0 { Darwin.close(currentFd) }
        DispatchQueue.main.async { [weak self] in
            self?.onDisconnected?()
        }
    }

    private func setupTLS(isServer: Bool) -> Bool {
        guard let ctx = SSLCreateContext(nil, isServer ? .serverSide : .clientSide, .streamType) else { return false }
        sslContext = ctx

        // Allocate fdPtr that the connection holds for its lifetime. `disconnect()`
        // sets `sslFdPtr.pointee = -1` to short-circuit any in-flight SSL I/O, and
        // `cleanupSSL()` deallocates it. This lifetime story is critical and unchanged.
        let fdPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        fdPtr.pointee = _fd
        sslFdPtr = fdPtr

        // Use a fresh single-use SecIdentity for THIS connection's TLS handshake.
        //
        // The cached identity from getOrCreateIdentity() gets into a broken state after
        // sleep/wake (SecureTransport's per-identity internal state ends up referencing
        // a stale snapshot of the keychain) — every subsequent handshake then fails
        // with errSSLInternal (-9810) until the app restarts. That's the bug that
        // blocked re-pairing after the phone unpaired and the Mac slept overnight:
        // the control-channel TLS could never re-establish, so the pair packets to
        // re-add the cert never got exchanged.
        //
        // The TransferIdentity owns its own private keychain and is held by `self` for
        // the entire lifetime of this KDEConnection — released (and the keychain
        // unlinked) when the connection ends.
        guard let transferId = CertificateManager.shared.freshTransferIdentity() else {
            KLog.log("[KDEConn] Could not create fresh TLS identity")
            return false
        }
        transferIdentity = transferId

        TLSHelpers.configure(ctx, TLSContextConfig(
            isServer: isServer,
            identity: transferId.identity,
            fdPtr: fdPtr
        ))
        return true
    }

    private func readTLSPacket() -> NetworkPacket? {
        guard let ctx = sslContext, _running else { return nil }

        var buffer = [UInt8](repeating: 0, count: 65536)
        var bytesRead = 0
        let status = SSLRead(ctx, &buffer, buffer.count, &bytesRead)

        if bytesRead > 0 {
            readBuffer.append(Data(buffer[0..<bytesRead]))
            KLog.log("[KDEConn] SSLRead: \(bytesRead) bytes (status=\(status), bufferTotal=\(readBuffer.count))", level: .debug)
        }

        if readBuffer.count > 1_048_576 {
            KLog.log("[KDEConn] Read buffer exceeded max size (\(readBuffer.count) bytes) from \(host), disconnecting", level: .error)
            _running = false
            return nil
        }

        if status != errSecSuccess && status != errSSLWouldBlock {
            if status == errSSLClosedGraceful || status == -9806 {
                KLog.log("[KDEConn] Peer closed connection to \(host)")
            } else {
                KLog.log("[KDEConn] SSLRead error: \(status) for \(host)")
            }
            _running = false
            return nil
        }

        if let idx = readBuffer.firstIndex(of: 0x0A) {
            let line = Data(readBuffer[readBuffer.startIndex..<idx])
            readBuffer = Data(readBuffer[(idx + 1)...])
            if let packet = NetworkPacket.deserialize(from: line) {
                return packet
            }
            // Invalid JSON — skip this line, don't kill connection
            KLog.log("[KDEConn] Skipped invalid packet (\(line.count) bytes)")
        }

        return nil
    }

    private func drainWriteQueue() {
        pendingWriteLock.lock()
        guard !pendingWriteData.isEmpty else {
            pendingWriteLock.unlock()
            return
        }
        let data = pendingWriteData
        pendingWriteData = Data()
        pendingWriteLock.unlock()

        guard let ctx = sslContext else { return }
        var totalWritten = 0
        var writeRetries = 0
        data.withUnsafeBytes { buf in
            guard let baseAddr = buf.baseAddress else { return }
            while totalWritten < data.count {
                var written = 0
                let status = SSLWrite(ctx, baseAddr + totalWritten, data.count - totalWritten, &written)
                if written > 0 { totalWritten += written; writeRetries = 0 }
                if status == errSSLWouldBlock {
                    writeRetries += 1
                    if writeRetries > 5000 {
                        KLog.log("[KDEConn] SSLWrite stuck for 5s, aborting (wrote \(totalWritten)/\(data.count))")
                        break
                    }
                    usleep(1000)
                    continue
                }
                if status != errSecSuccess {
                    KLog.log("[KDEConn] SSLWrite error: \(status) (wrote \(totalWritten)/\(data.count))")
                    break
                }
            }
        }
    }

    private func rawWrite(_ data: Data) -> Int {
        return data.withUnsafeBytes { buf in
            Darwin.write(_fd, buf.baseAddress, data.count)
        }
    }

    private func readRawLine() -> Data? {
        var buffer = [UInt8](repeating: 0, count: 1)
        var result = Data()
        let deadline = Date().addingTimeInterval(5)

        while Date() < deadline {
            let n = Darwin.read(_fd, &buffer, 1)
            if n <= 0 { break }
            if buffer[0] == 0x0A { return result }
            result.append(buffer[0])
            if result.count > 65536 { break }
        }
        return nil
    }

    func disconnect() {
        pendingWriteLock.lock()
        if disconnectOnce { pendingWriteLock.unlock(); return }
        disconnectOnce = true
        pendingWriteLock.unlock()

        // Only signal the connection loop to stop — do NOT close the fd here.
        // The connectionLoop owns the fd lifecycle: it calls cleanupSSL() then closes fd.
        // Closing fd here would race with SSL callbacks that may be mid-read/write,
        // and the OS could reassign the fd number to a new socket before SSLClose runs.
        // Setting sslFdPtr to -1 makes SSL callbacks fail immediately with EBADF,
        // which causes SSLRead to return errSecIO, which exits the read loop.
        running = false
        sslFdPtr?.pointee = -1
    }

    private func cleanupSSL() {
        if let ctx = sslContext { SSLClose(ctx) }
        sslFdPtr?.deallocate()
        sslFdPtr = nil
        sslContext = nil
        _tlsEstablished = false
        // Release the per-connection TLS identity AFTER the SSLContext has been dropped,
        // so the underlying keychain isn't unlinked while SecureTransport still holds
        // cert/key references to it.
        transferIdentity = nil
    }

    func getPeerCertificate() -> SecCertificate? {
        guard let ctx = sslContext else { return nil }
        return TLSHelpers.copyPeerLeafCertificate(ctx)
    }
}
