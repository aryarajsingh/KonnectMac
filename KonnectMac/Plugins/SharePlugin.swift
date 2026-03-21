import Foundation
import UserNotifications
import AppKit

@MainActor
class SharePlugin: PluginProtocol {
    let device: Device

    init(device: Device) {
        self.device = device
        // Clean up stale .partial files older than 1 day
        Self.cleanupStalePartialFiles()
    }

    private static var lastCleanupTime = Date.distantPast
    private static let cleanupLock = NSLock()
    private static func cleanupStalePartialFiles() {
        cleanupLock.lock()
        guard Date().timeIntervalSince(lastCleanupTime) > 3600 else { cleanupLock.unlock(); return }
        lastCleanupTime = Date()
        cleanupLock.unlock()
        let downloadPath = Config.shared.downloadDirectory
        let downloadsDir = URL(fileURLWithPath: downloadPath, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: downloadsDir.path) else { return }
        let oneDayAgo = Date().addingTimeInterval(-24 * 60 * 60)
        for file in files where file.hasSuffix(".partial") {
            let fullPath = downloadsDir.appendingPathComponent(file).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
               let modDate = attrs[.modificationDate] as? Date, modDate < oneDayAgo {
                try? FileManager.default.removeItem(atPath: fullPath)
                KLog.log("[Share] Cleaned up stale partial file: \(file)")
            }
        }
    }

    func canHandle(type: String) -> Bool { type == "kdeconnect.share.request" }

    func handle(packet: NetworkPacket) {
        if let url = packet.body["url"]?.value as? String {
            KLog.log("[Share] Received URL: \(url)")
            if let nsurl = URL(string: url),
               let scheme = nsurl.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(nsurl)
            } else {
                KLog.log("[Share] Rejected non-HTTP URL scheme: \(url)")
            }
            return
        }

        if let text = packet.body["text"]?.value as? String {
            KLog.log("[Share] Received text (\(text.utf8.count) bytes)")
            // Prevent ClipboardPlugin from echoing this text back to the phone
            if let clipboardPlugin = device.plugins["clipboard"] as? ClipboardPlugin {
                clipboardPlugin.lastReceivedContent = text
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }

        if let filename = packet.body["filename"]?.value as? String {
            let sanitized = sanitizeFilename(filename)
            let payloadSize = packet.payloadSize ?? 0

            // Debug: log raw payloadTransferInfo
            if let pti = packet.payloadTransferInfo {
                KLog.log("[Share] payloadTransferInfo keys: \(pti.keys.joined(separator: ", ")), values: \(pti.mapValues { "\($0.value)" })")
            } else {
                KLog.log("[Share] payloadTransferInfo is nil")
            }

            // Try multiple ways to extract port
            var port: UInt16? = nil
            if let pti = packet.payloadTransferInfo {
                if let p = pti["port"]?.value as? Int, let safePort = UInt16(exactly: p) { port = safePort }
                else if let p = pti["port"]?.value as? Int64, let safePort = UInt16(exactly: p) { port = safePort }
                else if let p = pti["port"]?.value as? Double, p > 0, p < 65536 { port = UInt16(p) }
                else if let s = pti["port"]?.value as? String, let parsed = UInt16(s) { port = parsed }
            }

            KLog.log("[Share] Receiving file: \(sanitized) (\(payloadSize) bytes) port=\(port ?? 0)")

            guard let port = port, payloadSize > 0 else { return }
            let host = device.kdeConn?.host ?? ""

            Task {
                await receiveFile(host: host, port: port, filename: sanitized, expectedSize: payloadSize)
            }
        }
    }

    func sendFile(url: URL) {
        guard device.kdeConn != nil else {
            KLog.log("[Share] No connection to send file")
            return
        }

        let filename = url.lastPathComponent

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int64 else {
            KLog.log("[Share] Failed to read file attributes: \(filename)")
            return
        }

        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            KLog.log("[Share] Failed to open file: \(filename)")
            return
        }

        KLog.log("[Share] Preparing to send \(filename) (\(fileSize) bytes)")

        // Create a BSD socket TLS listener
        let serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            KLog.log("[Share] Failed to create server socket")
            return
        }

        var reuse: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // OS picks port
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            KLog.log("[Share] Bind failed")
            Darwin.close(serverFd)
            return
        }

        // Get assigned port
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(serverFd, $0, &addrLen)
            }
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)

        listen(serverFd, 1)

        // Send share packet with port info
        var sharePacket = NetworkPacket(type: "kdeconnect.share.request", body: [
            "filename": AnyCodable(filename)
        ])
        sharePacket.payloadSize = fileSize
        sharePacket.payloadTransferInfo = ["port": AnyCodable(Int(port))]
        device.send(sharePacket)
        KLog.log("[Share] Sent share packet for \(filename) on port \(port)")

        // Accept connection and send file on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? fileHandle.close() }

            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(serverFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var clientAddr = sockaddr_storage()
            var clientLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverFd, $0, &clientLen)
                }
            }
            Darwin.close(serverFd)

            guard clientFd >= 0 else {
                KLog.log("[Share] No client connected within timeout")
                return
            }

            // Setup TLS as server
            guard let ctx = SSLCreateContext(nil, .serverSide, .streamType) else {
                Darwin.close(clientFd)
                return
            }
            let fdPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            defer { fdPtr.deallocate() }
            fdPtr.pointee = clientFd
            SSLSetIOFuncs(ctx, shareSSLRead, shareSSLWrite)
            SSLSetConnection(ctx, UnsafeMutableRawPointer(fdPtr))
            SSLSetSessionOption(ctx, .breakOnClientAuth, true)

            if let identity = CertificateManager.shared.getOrCreateIdentity() {
                SSLSetCertificate(ctx, [identity] as CFArray)
            }

            // TLS handshake with timeout
            var status: OSStatus
            let hsDeadline = Date().addingTimeInterval(15)
            repeat {
                status = SSLHandshake(ctx)
                if Date() > hsDeadline {
                    KLog.log("[Share] Send TLS handshake timed out")
                    break
                }
            } while status == errSSLWouldBlock || status == -9841 || status == errSSLPeerAuthCompleted || status == errSSLClientCertRequested

            guard status == errSecSuccess else {
                KLog.log("[Share] TLS handshake failed: \(status)")
                SSLClose(ctx); Darwin.close(clientFd)
                return
            }

            // Validate peer certificate matches the paired device
            if let storedCert = Config.shared.loadPairedDeviceCert(id: self.device.id),
               storedCert.count > 1 {
                var trust: SecTrust?
                SSLCopyPeerTrust(ctx, &trust)
                if let peerTrust = trust,
                   let certs = SecTrustCopyCertificateChain(peerTrust) as? [SecCertificate],
                   let peerCert = certs.first {
                    let peerData = SecCertificateCopyData(peerCert) as Data
                    if peerData != storedCert {
                        KLog.log("[Share] File transfer peer cert mismatch — rejecting")
                        SSLClose(ctx); Darwin.close(clientFd)
                        return
                    }
                }
            }

            // Stream file data in 64KB chunks
            let chunkSize = 65536
            var totalWritten: Int64 = 0
            var sendError = false

            while totalWritten < fileSize {
                guard let chunk = try? fileHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    break
                }

                var chunkWritten = 0
                chunk.withUnsafeBytes { buf in
                    guard let baseAddr = buf.baseAddress else { return }
                    var retries = 0
                    while chunkWritten < chunk.count {
                        var written = 0
                        let remaining = chunk.count - chunkWritten
                        let writeStatus = SSLWrite(ctx, baseAddr + chunkWritten, remaining, &written)
                        if written > 0 { chunkWritten += written; retries = 0 }
                        if writeStatus == errSSLWouldBlock && written == 0 {
                            retries += 1
                            if retries > 5000 {
                                KLog.log("[Share] SSLWrite stuck for 5s during send, aborting")
                                sendError = true
                                return
                            }
                            usleep(1000)
                            continue
                        }
                        if writeStatus != errSecSuccess && writeStatus != errSSLWouldBlock {
                            sendError = true
                            return
                        }
                    }
                }

                totalWritten += Int64(chunkWritten)

                if sendError { break }

                // Progress logging for large files
                if fileSize > 1_000_000 && totalWritten % 1_000_000 < Int64(chunkSize) {
                    KLog.log("[Share] Send progress: \(totalWritten)/\(fileSize) bytes (\(totalWritten * 100 / fileSize)%)")
                }
            }

            SSLClose(ctx)
            Darwin.close(clientFd)
            // fdPtr.deallocate() handled by defer
            KLog.log("[Share] File sent via TLS: \(filename) (\(totalWritten) bytes)")
        }
    }

    private func receiveFile(host: String, port: UInt16, filename: String, expectedSize: Int64) async {
        let maxFileSize: Int64 = 2_147_483_648
        if expectedSize > maxFileSize {
            KLog.log("[Share] File too large: \(expectedSize) bytes, max \(maxFileSize)")
            return
        }

        let downloadPath = Config.shared.downloadDirectory
        let downloadsDir = URL(fileURLWithPath: downloadPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        // Validate downloads directory is writable
        guard FileManager.default.isWritableFile(atPath: downloadsDir.path) else {
            KLog.log("[Share] Downloads directory not writable: \(downloadsDir.path)")
            showFileFailedNotification(filename: filename)
            return
        }

        var destURL = downloadsDir.appendingPathComponent(filename)

        // Handle duplicate filenames
        var counter = 1
        while FileManager.default.fileExists(atPath: destURL.path) {
            let name = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            if ext.isEmpty {
                destURL = downloadsDir.appendingPathComponent("\(name) (\(counter))")
            } else {
                destURL = downloadsDir.appendingPathComponent("\(name) (\(counter)).\(ext)")
            }
            counter += 1
        }

        // Use .partial extension during download
        let partialURL = destURL.appendingPathExtension("partial")

        // Load stored cert on MainActor before dispatching to background
        let storedCert = Config.shared.loadPairedDeviceCert(id: device.id)

        let bytesWritten = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.downloadFileStreaming(host: host, port: port, expectedSize: Int(expectedSize), destURL: partialURL, storedCertData: storedCert)
                continuation.resume(returning: result)
            }
        }

        guard bytesWritten > 0 else {
            KLog.log("[Share] File download failed for \(filename)")
            try? FileManager.default.removeItem(at: partialURL)
            showFileFailedNotification(filename: filename)
            return
        }

        let complete = bytesWritten == Int(expectedSize)
        do {
            if complete {
                try FileManager.default.moveItem(at: partialURL, to: destURL)
                KLog.log("[Share] File saved: \(destURL.path) (\(bytesWritten)/\(expectedSize) bytes)")
                showFileReceivedNotification(filename: filename, path: destURL.path)
            } else {
                KLog.log("[Share] Partial file: \(partialURL.path) (\(bytesWritten)/\(expectedSize) bytes)")
                showFileReceivedNotification(filename: filename, path: partialURL.path, partial: true, received: bytesWritten, expected: Int(expectedSize))
            }
        } catch {
            KLog.log("[Share] Failed to finalize file: \(error)")
            try? FileManager.default.removeItem(at: partialURL)
            showFileFailedNotification(filename: filename)
        }
    }

    /// Stream file download directly to disk via FileHandle — no in-memory accumulation
    private nonisolated func downloadFileStreaming(host: String, port: UInt16, expectedSize: Int, destURL: URL, storedCertData: Data?) -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            KLog.log("[Share] Socket creation failed")
            return 0
        }

        var nodelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            KLog.log("[Share] Invalid host IP: \(host)", level: .error)
            Darwin.close(fd)
            return 0
        }

        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            KLog.log("[Share] Connect to \(host):\(port) failed: errno=\(errno)")
            Darwin.close(fd)
            return 0
        }

        KLog.log("[Share] Connected to \(host):\(port) for file download")

        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            KLog.log("[Share] SSLCreateContext failed")
            Darwin.close(fd)
            return 0
        }
        let fdPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        defer { fdPtr.deallocate() }
        fdPtr.pointee = fd
        SSLSetIOFuncs(ctx, shareSSLRead, shareSSLWrite)
        SSLSetConnection(ctx, UnsafeMutableRawPointer(fdPtr))
        SSLSetSessionOption(ctx, .breakOnServerAuth, true)

        if let identity = CertificateManager.shared.getOrCreateIdentity() {
            SSLSetCertificate(ctx, [identity] as CFArray)
        }

        var status: OSStatus
        var attempts = 0
        let hsDeadline = Date().addingTimeInterval(15)
        repeat {
            status = SSLHandshake(ctx)
            attempts += 1
            if Date() > hsDeadline {
                KLog.log("[Share] Receive TLS handshake timed out after \(attempts) attempts")
                break
            }
        } while status == errSSLWouldBlock || status == errSSLPeerAuthCompleted || status == errSSLClientCertRequested

        guard status == errSecSuccess else {
            KLog.log("[Share] File TLS handshake failed after \(attempts) attempts: \(status)")
            SSLClose(ctx); Darwin.close(fd)
            return 0
        }

        // Validate peer certificate matches the paired device
        if let storedCert = storedCertData, storedCert.count > 1 {
            var trust: SecTrust?
            SSLCopyPeerTrust(ctx, &trust)
            if let peerTrust = trust,
               let certs = SecTrustCopyCertificateChain(peerTrust) as? [SecCertificate],
               let peerCert = certs.first {
                let peerData = SecCertificateCopyData(peerCert) as Data
                if peerData != storedCert {
                    KLog.log("[Share] File download peer cert mismatch — rejecting")
                    SSLClose(ctx); Darwin.close(fd)
                    return 0
                }
            }
        }

        KLog.log("[Share] File TLS established, streaming \(expectedSize) bytes to disk")

        // Create file and open FileHandle for streaming writes
        guard FileManager.default.createFile(atPath: destURL.path, contents: nil) else {
            KLog.log("[Share] Failed to create output file: \(destURL.path)", level: .error)
            SSLClose(ctx); Darwin.close(fd)
            return 0
        }
        guard let fileHandle = try? FileHandle(forWritingTo: destURL) else {
            KLog.log("[Share] Failed to open output file for writing: \(destURL.path)", level: .error)
            SSLClose(ctx); Darwin.close(fd)
            return 0
        }
        defer { try? fileHandle.close() }

        var totalReceived = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        var consecutiveErrors = 0
        let maxConsecutiveErrors = 10

        while totalReceived < expectedSize {
            var bytesRead = 0
            let toRead = min(buffer.count, expectedSize - totalReceived)
            let readStatus = SSLRead(ctx, &buffer, toRead, &bytesRead)

            if bytesRead > 0 {
                fileHandle.write(Data(buffer[0..<bytesRead]))
                totalReceived += bytesRead
                consecutiveErrors = 0

                if expectedSize > 1_000_000 && totalReceived % 1_000_000 < 65536 {
                    KLog.log("[Share] Progress: \(totalReceived)/\(expectedSize) bytes (\(totalReceived * 100 / expectedSize)%)")
                }
            }

            if readStatus == errSSLClosedGraceful || readStatus == errSSLClosedAbort {
                KLog.log("[Share] Peer closed after \(totalReceived)/\(expectedSize) bytes")
                break
            }

            if readStatus == errSSLWouldBlock {
                consecutiveErrors += 1
                if consecutiveErrors >= maxConsecutiveErrors {
                    KLog.log("[Share] Too many timeouts after \(totalReceived)/\(expectedSize) bytes")
                    break
                }
                usleep(10_000)
                continue
            }

            if readStatus != errSecSuccess {
                consecutiveErrors += 1
                KLog.log("[Share] SSLRead status \(readStatus) after \(totalReceived)/\(expectedSize) bytes (attempt \(consecutiveErrors))")
                if consecutiveErrors >= maxConsecutiveErrors {
                    KLog.log("[Share] Giving up after \(consecutiveErrors) consecutive errors")
                    break
                }
                usleep(10_000)
                continue
            }

            if bytesRead == 0 && readStatus == errSecSuccess {
                KLog.log("[Share] EOF after \(totalReceived)/\(expectedSize) bytes")
                break
            }
        }

        SSLClose(ctx)
        Darwin.close(fd)
        // fdPtr.deallocate() handled by defer

        KLog.log("[Share] Downloaded \(totalReceived)/\(expectedSize) bytes")
        return totalReceived
    }

    private func showFileReceivedNotification(filename: String, path: String, partial: Bool = false, received: Int = 0, expected: Int = 0) {
        let content = UNMutableNotificationContent()
        if partial {
            content.title = "File Partially Received"
            content.body = "\(filename) — \(received / 1024)KB of \(expected / 1024)KB"
        } else {
            content.title = "File Received"
            content.body = filename
        }
        content.sound = .default
        content.categoryIdentifier = "FILE_RECEIVED"
        content.userInfo = ["filePath": path]

        let request = UNNotificationRequest(identifier: "file-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func showFileFailedNotification(filename: String) {
        let content = UNMutableNotificationContent()
        content.title = "File Transfer Failed"
        content.body = filename
        content.sound = .default

        let request = UNNotificationRequest(identifier: "file-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func sanitizeFilename(_ name: String) -> String {
        var s = name.precomposedStringWithCanonicalMapping
        s = s.replacingOccurrences(of: "..", with: "_")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "\\", with: "_")
        s = s.replacingOccurrences(of: ":", with: "_")
        s = s.replacingOccurrences(of: "\0", with: "")
        while s.hasPrefix(".") { s = String(s.dropFirst()) }
        if s.isEmpty { s = "download" }
        // Truncate to APFS 255-byte filename limit (preserving extension)
        if s.utf8.count > 250 {
            let ext = (s as NSString).pathExtension
            let stem = (s as NSString).deletingPathExtension
            let maxStemBytes = 250 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
            var truncated = stem
            while truncated.utf8.count > maxStemBytes {
                truncated = String(truncated.dropLast())
            }
            s = ext.isEmpty ? truncated : "\(truncated).\(ext)"
        }
        return s
    }
}

// Shared SSL callbacks — handle ETIMEDOUT as non-fatal (critical for SO_RCVTIMEO)
private func shareSSLRead(connection: SSLConnectionRef, data: UnsafeMutableRawPointer, dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let fdPtr = connection.assumingMemoryBound(to: Int32.self)
    let requested = dataLength.pointee
    let n = Darwin.read(fdPtr.pointee, data, requested)
    if n > 0 {
        dataLength.pointee = n
        return n < requested ? errSSLWouldBlock : errSecSuccess
    }
    if n == 0 {
        dataLength.pointee = 0
        return errSSLClosedGraceful
    }
    dataLength.pointee = 0
    let e = errno
    if e == EAGAIN || e == EWOULDBLOCK || e == ETIMEDOUT || e == EINTR {
        return errSSLWouldBlock
    }
    return errSecIO
}

private func shareSSLWrite(connection: SSLConnectionRef, data: UnsafeRawPointer, dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let fdPtr = connection.assumingMemoryBound(to: Int32.self)
    let requested = dataLength.pointee
    let n = Darwin.write(fdPtr.pointee, data, requested)
    if n > 0 {
        dataLength.pointee = n
        return n < requested ? errSSLWouldBlock : errSecSuccess
    }
    if n == 0 {
        dataLength.pointee = 0
        return errSSLClosedGraceful
    }
    dataLength.pointee = 0
    let e = errno
    if e == EAGAIN || e == EWOULDBLOCK || e == ETIMEDOUT || e == EINTR {
        return errSSLWouldBlock
    }
    return errSecIO
}
