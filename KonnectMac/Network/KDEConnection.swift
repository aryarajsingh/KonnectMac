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

    var onIdentityReceived: ((NetworkPacket) -> Void)?
    var onTLSReady: (() -> Void)?
    var onPacketReceived: ((NetworkPacket) -> Void)?
    var onDisconnected: (() -> Void)?

    deinit {
        // Safety net: if connectionLoop never ran (object deallocated before queue executes),
        // clean up any remaining fd and SSL resources.
        if _fd >= 0 { Darwin.close(_fd); _fd = -1 }
        if let ctx = sslContext { SSLClose(ctx); sslContext = nil }
        sslFdPtr?.deallocate()
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

            var nodelay: Int32 = 1
            setsockopt(self._fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))

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
        var nosigpipe: Int32 = 1
        setsockopt(_fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var keepAlive: Int32 = 1
        setsockopt(_fd, SOL_SOCKET, SO_KEEPALIVE, &keepAlive, socklen_t(MemoryLayout<Int32>.size))
        var keepIdle: Int32 = 10
        setsockopt(_fd, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, socklen_t(MemoryLayout<Int32>.size))
        var keepIntvl: Int32 = 5
        setsockopt(_fd, IPPROTO_TCP, TCP_KEEPINTVL, &keepIntvl, socklen_t(MemoryLayout<Int32>.size))
        var keepCnt: Int32 = 3
        setsockopt(_fd, IPPROTO_TCP, TCP_KEEPCNT, &keepCnt, socklen_t(MemoryLayout<Int32>.size))
    }

    private func connectionLoop() {
        if !isIncoming {
            guard let data = cachedIdentityData else {
                disconnect()
                return
            }
            _ = rawWrite(data)
            KLog.log("[KDEConn] Sent identity to \(host):\(port)")
        } else {
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

        guard running else {
            KLog.log("[KDEConn] Aborting before TLS — connection disconnected")
            cleanupSSL()
            let currentFd = _fd
            _fd = -1
            if currentFd >= 0 { Darwin.close(currentFd) }
            return
        }

        let isTLSServer = !isIncoming

        guard setupTLS(isServer: isTLSServer) else {
            KLog.log("[KDEConn] TLS setup failed for \(host)")
            cleanupSSL()
            disconnect()
            return
        }

        guard running else {
            KLog.log("[KDEConn] Aborting TLS handshake — connection disconnected")
            cleanupSSL()
            let currentFd = _fd
            _fd = -1
            if currentFd >= 0 { Darwin.close(currentFd) }
            return
        }

        // Set socket timeout for handshake (10s max)
        var handshakeTimeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &handshakeTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(_fd, SOL_SOCKET, SO_SNDTIMEO, &handshakeTimeout, socklen_t(MemoryLayout<timeval>.size))

        // Perform TLS handshake
        // SecureTransport returns informational status codes that require continuing:
        // -9841 (errSSLServerAuthCompleted / errSSLPeerAuthCompleted)
        // -9810 (errSSLPeerAuthCompleted on some macOS versions)
        // -9851 (errSSLClientCertRequested)
        // These are NOT errors — they signal that an auth phase completed and the
        // handshake should be continued by calling SSLHandshake again.
        // IMPORTANT: use literal values because the named constants may not match
        // across macOS SDK versions.
        KLog.log("[KDEConn] Starting TLS handshake with \(host) (server=\(isTLSServer))")
        var handshakeResult: OSStatus = errSecSuccess
        var attempts = 0
        let handshakeDeadline = Date().addingTimeInterval(15)
        repeat {
            handshakeResult = SSLHandshake(sslContext!)
            attempts += 1
            KLog.log("[KDEConn] Handshake attempt \(attempts): \(handshakeResult)")
            if Date() > handshakeDeadline {
                KLog.log("[KDEConn] Handshake timed out after \(attempts) attempts")
                break
            }
        } while handshakeResult == errSSLWouldBlock
                || handshakeResult == -9841
                || handshakeResult == -9851
                || handshakeResult == -9810

        guard handshakeResult == errSecSuccess else {
            KLog.log("[KDEConn] TLS handshake failed: \(handshakeResult) for \(host) after \(attempts) attempts (isTLSServer=\(isTLSServer))")
            cleanupSSL()
            let failedFd = _fd
            _fd = -1
            if failedFd >= 0 { Darwin.close(failedFd) }
            _running = false
            DispatchQueue.main.async { [weak self] in
                self?.onDisconnected?()
            }
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
                if Int(idleSincePacket) % 15 == 0 && idleSincePacket > 1 {
                    KLog.log("[KDEConn] Idle \(Int(idleSincePacket))s on \(host) (running=\(_running), fd=\(_fd))")
                }
            }
        }

        _running = false
        KLog.log("[KDEConn] Connection loop exited for \(host) (fd=\(_fd)) — cleaning up SSL")
        // SSLClose must happen BEFORE fd close so TLS close_notify is sent on valid socket
        cleanupSSL()
        KLog.log("[KDEConn] SSL cleaned up for \(host), closing fd")
        let currentFd = _fd
        _fd = -1
        if currentFd >= 0 { Darwin.close(currentFd) }
        KLog.log("[KDEConn] Connection fully closed for \(host), calling onDisconnected")
        DispatchQueue.main.async { [weak self] in
            KLog.log("[KDEConn] onDisconnected firing for \(self?.host ?? "?")")
            self?.onDisconnected?()
        }
    }

    private func setupTLS(isServer: Bool) -> Bool {
        guard let ctx = SSLCreateContext(nil, isServer ? .serverSide : .clientSide, .streamType) else { return false }
        sslContext = ctx

        SSLSetIOFuncs(ctx, sslReadFunc, sslWriteFunc)
        let fdPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        fdPtr.pointee = _fd
        sslFdPtr = fdPtr
        SSLSetConnection(ctx, UnsafeMutableRawPointer(fdPtr))

        if isServer {
            SSLSetClientSideAuthenticate(ctx, .tryAuthenticate)
        }

        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        SSLSetSessionOption(ctx, .breakOnClientAuth, true)

        guard let identity = CertificateManager.shared.getOrCreateIdentity() else { return false }
        let certs = [identity] as CFArray
        SSLSetCertificate(ctx, certs)

        return true
    }

    private func readTLSPacket() -> NetworkPacket? {
        guard let ctx = sslContext, _running else { return nil }

        var buffer = [UInt8](repeating: 0, count: 65536)
        var bytesRead = 0
        let status = SSLRead(ctx, &buffer, buffer.count, &bytesRead)

        if bytesRead > 0 {
            readBuffer.append(Data(buffer[0..<bytesRead]))
            KLog.log("[KDEConn] SSLRead: \(bytesRead) bytes (status=\(status), bufferTotal=\(readBuffer.count))")
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
                KLog.log("[KDEConn] SSLRead error: \(status) for \(host) — disconnecting")
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
                    _running = false
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

        KLog.log("[KDEConn] disconnect() called for \(host) (fd=\(_fd), wasRunning=\(_running))")
        running = false
        sslFdPtr?.pointee = -1
        KLog.log("[KDEConn] disconnect() done for \(host), running=\(_running)")
    }

    private func cleanupSSL() {
        if let ctx = sslContext { SSLClose(ctx) }
        // Null the pointer BEFORE deallocating to prevent use-after-free:
        // disconnect() may read sslFdPtr from the main thread concurrently.
        // If we deallocate first then null, there's a window where sslFdPtr
        // is non-nil but points to freed memory.
        let ptr = sslFdPtr
        sslFdPtr = nil
        ptr?.deallocate()
        sslContext = nil
        _tlsEstablished = false
    }

    func getPeerCertificate() -> SecCertificate? {
        guard let ctx = sslContext else { return nil }
        var trust: SecTrust?
        SSLCopyPeerTrust(ctx, &trust)
        guard let peerTrust = trust else { return nil }
        let certs = SecTrustCopyCertificateChain(peerTrust) as? [SecCertificate]
        return certs?.first
    }
}

// MARK: - SSL I/O callbacks (free functions required by SecureTransport)

private func sslReadFunc(connection: SSLConnectionRef, data: UnsafeMutableRawPointer, dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let fdPtr = connection.assumingMemoryBound(to: Int32.self)
    let fd = fdPtr.pointee
    let requested = dataLength.pointee

    let n = Darwin.read(fd, data, requested)
    if n > 0 {
        dataLength.pointee = n
        return n < requested ? errSSLWouldBlock : errSecSuccess
    } else if n == 0 {
        dataLength.pointee = 0
        return errSSLClosedGraceful
    } else {
        dataLength.pointee = 0
        let err = errno
        if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
            return errSSLWouldBlock
        }
        return errSecIO
    }
}

private func sslWriteFunc(connection: SSLConnectionRef, data: UnsafeRawPointer, dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let fdPtr = connection.assumingMemoryBound(to: Int32.self)
    let fd = fdPtr.pointee
    let requested = dataLength.pointee

    let n = Darwin.write(fd, data, requested)
    if n > 0 {
        dataLength.pointee = n
        return n < requested ? errSSLWouldBlock : errSecSuccess
    } else if n == 0 {
        dataLength.pointee = 0
        return errSSLClosedGraceful
    } else {
        dataLength.pointee = 0
        let err = errno
        if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
            return errSSLWouldBlock
        }
        return errSecIO
    }
}
