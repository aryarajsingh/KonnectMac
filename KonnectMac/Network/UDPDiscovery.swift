import Foundation

class UDPDiscovery {
    private var listenSocket: Int32 = -1
    private var broadcastSocket: Int32 = -1
    private var listening = false
    private let listenLock = NSLock()  // Guards `listening` and `listenSocket` across threads
    var onIdentityReceived: ((NetworkPacket, String) -> Void)?

    deinit { stop() }

    func startListening(port: UInt16) {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            KLog.log("[UDP] Failed to create listen socket")
            return
        }

        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else {
            KLog.log("[UDP] Bind failed: \(String(cString: strerror(errno)))")
            Darwin.close(sock)
            return
        }

        listenLock.lock()
        listenSocket = sock
        listening = true
        listenLock.unlock()
        KLog.log("[UDP] Listening on port \(port)")

        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.receiveLoop()
        }
    }

    func broadcast(packet: NetworkPacket) {
        if broadcastSocket < 0 {
            broadcastSocket = socket(AF_INET, SOCK_DGRAM, 0)
            guard broadcastSocket >= 0 else {
                KLog.log("[UDP] Failed to create broadcast socket")
                return
            }
            var broadcast: Int32 = 1
            setsockopt(broadcastSocket, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
            // Non-blocking: sendto must never stall the main thread if the kernel buffer
            // is momentarily full (e.g., during a network transition at startup).
            var flags = fcntl(broadcastSocket, F_GETFL)
            fcntl(broadcastSocket, F_SETFL, flags | O_NONBLOCK)
        }

        guard let data = packet.serialize() else { return }

        let addresses = getBroadcastAddresses() + ["255.255.255.255"]
        KLog.log("[UDP] Broadcasting to \(addresses) on ports \(Config.minPort)-\(Config.maxPort)")
        for addr in addresses {
            var sockAddr = sockaddr_in()
            sockAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sockAddr.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, addr, &sockAddr.sin_addr) == 1 else {
                KLog.log("[UDP] inet_pton failed for broadcast address: \(addr)")
                continue
            }
            for port in Config.minPort...Config.maxPort {
                sockAddr.sin_port = UInt16(port).bigEndian

                _ = data.withUnsafeBytes { buf in
                    withUnsafePointer(to: &sockAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(broadcastSocket, buf.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }

    func sendTo(packet: NetworkPacket, host: String, port: UInt16) {
        if broadcastSocket < 0 {
            broadcastSocket = socket(AF_INET, SOCK_DGRAM, 0)
        }
        guard let data = packet.serialize() else { return }

        var sockAddr = sockaddr_in()
        sockAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sockAddr.sin_family = sa_family_t(AF_INET)
        sockAddr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &sockAddr.sin_addr) == 1 else {
            KLog.log("[UDP] inet_pton failed for host: \(host)")
            return
        }

        _ = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &sockAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(broadcastSocket, buf.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func stop() {
        listenLock.lock()
        listening = false
        if listenSocket >= 0 { Darwin.close(listenSocket); listenSocket = -1 }
        listenLock.unlock()
        if broadcastSocket >= 0 { Darwin.close(broadcastSocket); broadcastSocket = -1 }
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            listenLock.lock()
            let isListening = listening
            let sock = listenSocket
            listenLock.unlock()
            guard isListening, sock >= 0 else { break }

            var senderAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let n = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(sock, &buffer, buffer.count, 0, $0, &addrLen)
                }
            }
            guard n > 0 else { continue }

            let host = String(cString: inet_ntoa(senderAddr.sin_addr))
            let data = Data(buffer[0..<n])

            if let packet = NetworkPacket.deserialize(from: data) {
                DispatchQueue.main.async { [weak self] in
                    self?.onIdentityReceived?(packet, host)
                }
            }
        }
    }

    private func getBroadcastAddresses() -> [String] {
        var addresses = [String]()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return addresses }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            if addr.sa_family == UInt8(AF_INET) && (flags & (IFF_UP | IFF_BROADCAST)) != 0 {
                if let dstaddr = ptr.pointee.ifa_dstaddr {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(dstaddr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    let broadcastIP = String(cString: hostname)
                    if broadcastIP != "0.0.0.0" {
                        addresses.append(broadcastIP)
                    }
                }
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }
        return addresses
    }
}
