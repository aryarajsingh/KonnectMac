import Foundation

class LanServer {
    private var serverSocket: Int32 = -1
    private let socketLock = NSLock()  // Guards `serverSocket` between stop() and acceptLoop()
    var actualPort: UInt16 = 0
    var onIncomingConnection: ((Int32, String) -> Void)?
    private var recentAcceptCount = 0
    private var lastAcceptReset = Date()
    private let rateLock = NSLock()  // Guards `recentAcceptCount` and `lastAcceptReset`

    func start(preferredPort: UInt16) {
        let portsToTry = [preferredPort] + Array(Config.minPort...Config.maxPort).filter { $0 != preferredPort }

        for port in portsToTry {
            serverSocket = socket(AF_INET, SOCK_STREAM, 0)
            guard serverSocket >= 0 else { continue }

            var reuse: Int32 = 1
            setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY.bigEndian

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if bindResult == 0 {
                if listen(serverSocket, 5) == 0 {
                    actualPort = port
                    KLog.log("[TCP] Server listening on port \(port)")
                    break
                }
            }
            Darwin.close(serverSocket)
            serverSocket = -1
        }

        guard serverSocket >= 0 else {
            KLog.log("[TCP] Failed to bind on any port")
            return
        }

        // Port is set by DeviceManager after start() returns

        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        socketLock.lock()
        if serverSocket >= 0 {
            Darwin.close(serverSocket)
            serverSocket = -1
        }
        socketLock.unlock()
    }

    private func acceptLoop() {
        while true {
            socketLock.lock()
            let sock = serverSocket
            socketLock.unlock()
            guard sock >= 0 else { break }

            var clientAddr = sockaddr_storage()
            var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)

            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(sock, $0, &addrLen)
                }
            }
            guard clientFd >= 0 else {
                let err = errno
                if err == EBADF || err == EINVAL {
                    KLog.log("[TCP] Accept loop ending: errno=\(err)")
                    break
                }
                usleep(100_000) // 100ms backoff on transient errors
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            withUnsafePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, addrLen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                }
            }
            let hostStr = String(cString: host)

            // Rate limit: max 20 connections per second to prevent resource exhaustion
            rateLock.lock()
            recentAcceptCount += 1
            let now = Date()
            if now.timeIntervalSince(lastAcceptReset) >= 1.0 {
                recentAcceptCount = 1
                lastAcceptReset = now
            }
            let shouldDrop = recentAcceptCount > 20
            rateLock.unlock()

            if shouldDrop {
                KLog.log("[TCP] Rate limit: dropping connection from \(hostStr)")
                Darwin.close(clientFd)
                usleep(100_000) // 100ms cooldown
                continue
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self, let callback = self.onIncomingConnection else {
                    // self is nil or no callback — close FD to prevent leak
                    Darwin.close(clientFd)
                    return
                }
                callback(clientFd, hostStr)
            }
        }
    }
}
