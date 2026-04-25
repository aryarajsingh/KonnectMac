import Foundation
import UserNotifications
import AppKit

@MainActor
class SharePlugin: PluginProtocol {
    let device: Device

    /// Tail of the per-device receive chain. Every new incoming-file packet awaits the
    /// previous receive's completion before connecting to the phone.
    ///
    /// This matches KDE Connect Android's `CompositeUploadFileJob` protocol: when the
    /// phone shares multiple files (Share Sheet always uses this path, even for one
    /// file, via SEND_MULTIPLE), it binds ONE listener on a single port and sends every
    /// share packet up front, then loops calling `accept()` to serve the files one at
    /// a time. If we connected in parallel, we'd race on that single port — only one
    /// connection would be accepted, the others would sit in the kernel backlog and
    /// fail their TLS handshakes with errSSLInternal (-9810). Worse, the phone's job
    /// state ends up wedged, breaking subsequent in-app shares too until the job
    /// times out on the phone side.
    ///
    /// The chain self-trims: each task only retains the immediately-previous task
    /// until its own `await` returns, so the in-memory chain never grows beyond two.
    private var receiveChain: Task<Void, Never>?

    init(device: Device) {
        self.device = device
        // Clean up stale .partial files older than 1 day
        Self.cleanupStalePartialFiles()
    }

    // MARK: - Tunables (single source of truth — no magic numbers buried in code)

    /// Window during which a transfer must make at least one byte of progress, or we abort.
    /// Covers genuinely slow networks while bailing out of permanent stalls.
    private static let stallTimeout: TimeInterval = 60

    /// Bound on the entire transfer (TLS handshake + bytes). Prevents zombie sockets
    /// from holding file handles and ports forever.
    private static let totalTimeout: TimeInterval = 30 * 60

    /// How long we wait for the phone to open the TCP connection back to us after
    /// we've sent the share packet. Generous because the phone may be queueing
    /// multiple incoming files.
    private static let acceptTimeout: TimeInterval = 120

    /// TLS handshake hard cap.
    private static let handshakeTimeout: TimeInterval = 20

    /// Per-syscall socket timeout. Short enough that the I/O callback returns
    /// often so the higher-level stall/total timeouts can be evaluated.
    private static let socketIOTimeout: TimeInterval = 10

    /// I/O chunk size. 64 KB matches typical TLS record sizes for TLS 1.2.
    private static let chunkSize = 65536

    /// Hard cap on a single file transfer (2 GB).
    private static let maxFileSize: Int64 = 2_147_483_648

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

            // Try multiple ways to extract port — phone implementations differ in JSON typing
            var port: UInt16? = nil
            if let pti = packet.payloadTransferInfo {
                if let p = pti["port"]?.value as? Int, let safePort = UInt16(exactly: p) { port = safePort }
                else if let p = pti["port"]?.value as? Int64, let safePort = UInt16(exactly: p) { port = safePort }
                else if let p = pti["port"]?.value as? Double, p > 0, p < 65536 { port = UInt16(p) }
                else if let s = pti["port"]?.value as? String, let parsed = UInt16(s) { port = parsed }
            }

            // Capture host eagerly — kdeConn can drop between this MainActor-hop and the Task
            let host = device.kdeConn?.host ?? ""

            guard let port = port else {
                KLog.log("[Share] Rejected file \(sanitized): missing/invalid port in payloadTransferInfo")
                return
            }
            guard payloadSize > 0 else {
                KLog.log("[Share] Rejected file \(sanitized): payloadSize=\(payloadSize)")
                return
            }
            guard !host.isEmpty else {
                KLog.log("[Share] Rejected file \(sanitized): no active connection host")
                showFileFailedNotification(filename: sanitized)
                return
            }

            // Chain after any in-flight receive so we connect to the phone's listener
            // sequentially. Phone's CompositeUploadFileJob expects exactly one TCP
            // connection at a time on the shared port — see `receiveChain` doc above.
            let previousTail = self.receiveChain
            let waitingForPrevious = previousTail != nil
            if waitingForPrevious {
                KLog.log("[Share] Queued \(sanitized) (\(payloadSize) bytes) from \(host):\(port) — waiting for previous receive")
            } else {
                KLog.log("[Share] Receiving \(sanitized) (\(payloadSize) bytes) from \(host):\(port)")
            }
            self.receiveChain = Task { [weak self] in
                _ = await previousTail?.value
                guard let self = self else { return }
                if waitingForPrevious {
                    KLog.log("[Share] Starting queued receive: \(sanitized)")
                }
                await self.receiveFile(host: host, port: port, filename: sanitized, expectedSize: payloadSize)
            }
        }
    }

    func sendFile(url: URL) {
        guard device.kdeConn != nil else {
            KLog.log("[Share] No connection to send file")
            showFileSendFailedNotification(filename: url.lastPathComponent, reason: "no active connection")
            return
        }

        let filename = url.lastPathComponent

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int64 else {
            KLog.log("[Share] Failed to read file attributes: \(filename)")
            showFileSendFailedNotification(filename: filename, reason: "could not read file")
            return
        }

        guard fileSize > 0 else {
            KLog.log("[Share] Refusing to send empty file: \(filename)")
            showFileSendFailedNotification(filename: filename, reason: "file is empty")
            return
        }

        guard fileSize <= Self.maxFileSize else {
            KLog.log("[Share] File too large: \(fileSize) bytes (max \(Self.maxFileSize))")
            showFileSendFailedNotification(filename: filename, reason: "file exceeds 2 GB limit")
            return
        }

        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            KLog.log("[Share] Failed to open file: \(filename)")
            showFileSendFailedNotification(filename: filename, reason: "could not open file")
            return
        }

        // Pre-load identity on main thread before dispatching to background
        guard let sendIdentity = CertificateManager.shared.getOrCreateIdentity() else {
            KLog.log("[Share] No identity available for file send")
            try? fileHandle.close()
            showFileSendFailedNotification(filename: filename, reason: "missing local identity")
            return
        }

        // Pre-load stored cert for peer validation
        let storedCert = Config.shared.loadPairedDeviceCert(id: device.id)

        // Create a BSD socket TLS listener
        let serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            KLog.log("[Share] Failed to create server socket: errno=\(errno)")
            try? fileHandle.close()
            showFileSendFailedNotification(filename: filename, reason: "socket() failed")
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
            KLog.log("[Share] Bind failed: errno=\(errno)")
            Darwin.close(serverFd)
            try? fileHandle.close()
            showFileSendFailedNotification(filename: filename, reason: "bind() failed")
            return
        }

        // Get assigned port
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(serverFd, $0, &addrLen)
            }
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)

        // Backlog 1: only one transfer per server socket. listen() must succeed
        // before we tell the phone where to connect.
        guard listen(serverFd, 1) == 0 else {
            KLog.log("[Share] listen() failed: errno=\(errno)")
            Darwin.close(serverFd)
            try? fileHandle.close()
            showFileSendFailedNotification(filename: filename, reason: "listen() failed")
            return
        }

        // Send share packet with port info AFTER listen() so phone can never beat us to it
        var sharePacket = NetworkPacket(type: "kdeconnect.share.request", body: [
            "filename": AnyCodable(filename)
        ])
        sharePacket.payloadSize = fileSize
        sharePacket.payloadTransferInfo = ["port": AnyCodable(Int(port))]
        device.send(sharePacket)
        KLog.log("[Share] Sending \(filename) (\(fileSize) bytes) on port \(port)")

        let deviceName = device.name

        // Accept connection and send file on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? fileHandle.close() }

            // Accept timeout — phone may be queueing multiple files behind this one
            var acceptTimeout = timeval(tv_sec: __darwin_time_t(Self.acceptTimeout), tv_usec: 0)
            setsockopt(serverFd, SOL_SOCKET, SO_RCVTIMEO, &acceptTimeout, socklen_t(MemoryLayout<timeval>.size))

            var clientAddr = sockaddr_storage()
            var clientLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverFd, $0, &clientLen)
                }
            }
            Darwin.close(serverFd)

            guard clientFd >= 0 else {
                KLog.log("[Share] Phone never connected for \(filename) (errno=\(errno)) — firewall or timeout?")
                Task { @MainActor in
                    self.showFileSendFailedNotification(filename: filename, reason: "phone did not connect (firewall?)")
                }
                return
            }

            // Critical: install per-syscall I/O timeouts BEFORE starting TLS handshake.
            // Without these, a phone that connects but never sends handshake bytes hangs
            // Darwin.read() forever, defeating any higher-level deadline check.
            Self.configureTransferSocket(fd: clientFd)

            // Setup TLS as server — must match KDEConnection's TLS config exactly
            guard let ctx = SSLCreateContext(nil, .serverSide, .streamType) else {
                Darwin.close(clientFd)
                Task { @MainActor in
                    self.showFileSendFailedNotification(filename: filename, reason: "TLS context creation failed")
                }
                return
            }
            let fdPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            defer { fdPtr.deallocate() }
            fdPtr.pointee = clientFd
            SSLSetIOFuncs(ctx, shareSSLRead, shareSSLWrite)
            SSLSetConnection(ctx, UnsafeMutableRawPointer(fdPtr))
            SSLSetClientSideAuthenticate(ctx, .tryAuthenticate)
            SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
            SSLSetSessionOption(ctx, .breakOnServerAuth, true)
            SSLSetSessionOption(ctx, .breakOnClientAuth, true)
            SSLSetCertificate(ctx, [sendIdentity] as CFArray)

            guard Self.runHandshake(ctx: ctx, role: "send") else {
                SSLClose(ctx); Darwin.close(clientFd)
                Task { @MainActor in
                    self.showFileSendFailedNotification(filename: filename, reason: "TLS handshake failed")
                }
                return
            }

            // Validate peer certificate matches the paired device
            if let storedCert = storedCert, storedCert.count > 1 {
                if !Self.validatePeer(ctx: ctx, expectedCertData: storedCert) {
                    KLog.log("[Share] File transfer peer cert mismatch — rejecting")
                    SSLClose(ctx); Darwin.close(clientFd)
                    Task { @MainActor in
                        self.showFileSendFailedNotification(filename: filename, reason: "peer certificate mismatch")
                    }
                    return
                }
            }

            // Stream file data in chunks with time-based stall detection
            let started = Date()
            var totalWritten: Int64 = 0
            var lastProgress = Date()
            var sendError: String? = nil

            outerLoop: while totalWritten < fileSize {
                if Date().timeIntervalSince(started) > Self.totalTimeout {
                    sendError = "exceeded total transfer timeout"
                    break
                }

                let chunk: Data
                do {
                    guard let read = try fileHandle.read(upToCount: Self.chunkSize), !read.isEmpty else {
                        sendError = "file ended before expected size (\(totalWritten)/\(fileSize) bytes)"
                        break
                    }
                    chunk = read
                } catch {
                    sendError = "file read failed: \(error)"
                    break
                }

                var chunkWritten = 0
                while chunkWritten < chunk.count {
                    var written = 0
                    let remaining = chunk.count - chunkWritten
                    let writeStatus = chunk.withUnsafeBytes { buf -> OSStatus in
                        guard let baseAddr = buf.baseAddress else { return errSecParam }
                        return SSLWrite(ctx, baseAddr + chunkWritten, remaining, &written)
                    }

                    if written > 0 {
                        chunkWritten += written
                        lastProgress = Date()
                    }

                    if writeStatus == errSecSuccess { continue }

                    if writeStatus == errSSLWouldBlock {
                        if Date().timeIntervalSince(lastProgress) > Self.stallTimeout {
                            sendError = "no progress for \(Int(Self.stallTimeout))s during send"
                            break outerLoop
                        }
                        // Only sleep if no progress this iteration — otherwise retry immediately
                        if written == 0 { usleep(2000) }
                        continue
                    }

                    sendError = "SSLWrite returned \(writeStatus)"
                    break outerLoop
                }

                totalWritten += Int64(chunkWritten)

                // Progress logging for large files (every ~5%)
                if fileSize > 5_000_000 {
                    let pct = totalWritten * 100 / fileSize
                    let prevPct = (totalWritten - Int64(chunkWritten)) * 100 / fileSize
                    if pct / 5 != prevPct / 5 {
                        KLog.log("[Share] \(filename): \(pct)% (\(totalWritten)/\(fileSize) bytes)")
                    }
                }
            }

            // Graceful close — SSLClose sends close-notify; SO_LINGER ensures
            // the kernel TCP stack drains the send buffer before sending FIN.
            Self.enableLinger(fd: clientFd)
            SSLClose(ctx)
            Darwin.close(clientFd)

            let elapsed = Date().timeIntervalSince(started)
            if let err = sendError {
                KLog.log("[Share] Send incomplete: \(filename) (\(totalWritten)/\(fileSize) bytes, \(String(format: "%.1f", elapsed))s) — \(err)")
                Task { @MainActor in
                    self.showFileSendFailedNotification(filename: filename, reason: err)
                }
            } else {
                let mbps = Double(totalWritten) / elapsed / 1_000_000
                KLog.log("[Share] Sent \(filename) → \(deviceName) (\(totalWritten) bytes, \(String(format: "%.1f", elapsed))s, \(String(format: "%.1f", mbps)) MB/s)")
                Task { @MainActor in self.showFileSentNotification(filename: filename) }
            }
        }
    }

    private func receiveFile(host: String, port: UInt16, filename: String, expectedSize: Int64) async {
        if expectedSize > Self.maxFileSize {
            KLog.log("[Share] File too large: \(expectedSize) bytes, max \(Self.maxFileSize)")
            showFileFailedNotification(filename: filename)
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
            KLog.log("[Share] File download failed for \(filename) (no bytes received)")
            try? FileManager.default.removeItem(at: partialURL)
            showFileFailedNotification(filename: filename)
            return
        }

        let complete = bytesWritten == Int(expectedSize)
        do {
            if complete {
                try FileManager.default.moveItem(at: partialURL, to: destURL)
                KLog.log("[Share] Saved \(destURL.lastPathComponent) (\(bytesWritten) bytes)")
                showFileReceivedNotification(filename: filename, path: destURL.path)
            } else {
                KLog.log("[Share] Partial: \(partialURL.lastPathComponent) (\(bytesWritten)/\(expectedSize) bytes)")
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
            KLog.log("[Share] Socket creation failed: errno=\(errno)")
            return 0
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            KLog.log("[Share] Invalid host IP: \(host)", level: .error)
            Darwin.close(fd)
            return 0
        }

        // Connect timeout — separate from per-I/O timeout so we fail fast if phone is unreachable
        var connectTimeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &connectTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &connectTimeout, socklen_t(MemoryLayout<timeval>.size))

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

        // Switch to data-transfer socket options (KEEPALIVE + per-I/O timeouts)
        Self.configureTransferSocket(fd: fd)

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
        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        SSLSetSessionOption(ctx, .breakOnClientAuth, true)

        if let identity = CertificateManager.shared.getOrCreateIdentity() {
            SSLSetCertificate(ctx, [identity] as CFArray)
        }

        guard Self.runHandshake(ctx: ctx, role: "receive") else {
            SSLClose(ctx); Darwin.close(fd)
            return 0
        }

        // Validate peer certificate matches the paired device
        if let storedCert = storedCertData, storedCert.count > 1 {
            if !Self.validatePeer(ctx: ctx, expectedCertData: storedCert) {
                KLog.log("[Share] File download peer cert mismatch — rejecting")
                SSLClose(ctx); Darwin.close(fd)
                return 0
            }
        }

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

        let started = Date()
        var totalReceived = 0
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        var lastProgress = Date()

        readLoop: while totalReceived < expectedSize {
            if Date().timeIntervalSince(started) > Self.totalTimeout {
                KLog.log("[Share] Receive exceeded total timeout at \(totalReceived)/\(expectedSize) bytes")
                break
            }

            var bytesRead = 0
            let toRead = min(buffer.count, expectedSize - totalReceived)
            let readStatus = SSLRead(ctx, &buffer, toRead, &bytesRead)

            // Always consume any data we got — partial reads with errSSLWouldBlock are normal
            if bytesRead > 0 {
                fileHandle.write(Data(buffer[0..<bytesRead]))
                totalReceived += bytesRead
                lastProgress = Date()

                if expectedSize > 5_000_000 {
                    let pct = totalReceived * 100 / expectedSize
                    let prevPct = (totalReceived - bytesRead) * 100 / expectedSize
                    if pct / 5 != prevPct / 5 {
                        KLog.log("[Share] Recv \(pct)% (\(totalReceived)/\(expectedSize) bytes)")
                    }
                }
            }

            switch readStatus {
            case errSecSuccess:
                if bytesRead == 0 {
                    // Clean EOF before expected size — peer ended early
                    KLog.log("[Share] EOF at \(totalReceived)/\(expectedSize) bytes")
                    break readLoop
                }
                // Got data — try again immediately for more
                continue

            case errSSLClosedGraceful, errSSLClosedAbort:
                if totalReceived < expectedSize {
                    KLog.log("[Share] Peer closed at \(totalReceived)/\(expectedSize) bytes")
                }
                break readLoop

            case errSSLWouldBlock:
                if Date().timeIntervalSince(lastProgress) > Self.stallTimeout {
                    KLog.log("[Share] No progress for \(Int(Self.stallTimeout))s at \(totalReceived)/\(expectedSize) bytes")
                    break readLoop
                }
                // If we made progress this iteration, retry immediately; otherwise back off briefly
                if bytesRead == 0 { usleep(5000) }
                continue

            default:
                KLog.log("[Share] SSLRead error \(readStatus) at \(totalReceived)/\(expectedSize) bytes")
                break readLoop
            }
        }

        SSLClose(ctx)
        Darwin.close(fd)

        let elapsed = Date().timeIntervalSince(started)
        let mbps = elapsed > 0 ? Double(totalReceived) / elapsed / 1_000_000 : 0
        KLog.log("[Share] Received \(totalReceived)/\(expectedSize) bytes in \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", mbps)) MB/s)")
        return totalReceived
    }

    // MARK: - Socket helpers (shared by send & receive)

    /// Configure a data-transfer socket: TCP_NODELAY for streaming, SO_KEEPALIVE
    /// for dead-peer detection, and short per-syscall timeouts so the I/O callback
    /// returns often enough for higher-level deadlines to kick in.
    private nonisolated static func configureTransferSocket(fd: Int32) {
        var nodelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))

        var keepAlive: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &keepAlive, socklen_t(MemoryLayout<Int32>.size))

        // Probe quickly (TCP layer) so a dead peer is noticed within ~30s
        var keepIdle: Int32 = 30
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, socklen_t(MemoryLayout<Int32>.size))

        var io = timeval(tv_sec: __darwin_time_t(socketIOTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &io, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &io, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Block close() up to 5s waiting for the kernel send buffer to drain — without
    /// this, the last TLS records of a large file can be discarded when we close.
    private nonisolated static func enableLinger(fd: Int32) {
        var lng = linger(l_onoff: 1, l_linger: 5)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &lng, socklen_t(MemoryLayout<linger>.size))
    }

    /// Run the TLS handshake with a hard deadline. Returns true on success.
    /// Per-syscall timeouts must already be set on the underlying fd, otherwise
    /// the I/O callback can hang indefinitely and bypass the deadline check.
    private nonisolated static func runHandshake(ctx: SSLContext, role: String) -> Bool {
        let deadline = Date().addingTimeInterval(handshakeTimeout)
        var attempts = 0
        while Date() < deadline {
            let status = SSLHandshake(ctx)
            attempts += 1
            switch status {
            case errSecSuccess:
                return true
            case errSSLWouldBlock, -9841, errSSLPeerAuthCompleted, errSSLClientCertRequested:
                // -9841 is errSSLServerAuthCompleted (private constant)
                continue
            default:
                KLog.log("[Share] \(role) TLS handshake failed: status=\(status) attempts=\(attempts)")
                return false
            }
        }
        KLog.log("[Share] \(role) TLS handshake timed out after \(attempts) attempts")
        return false
    }

    /// Validate that the TLS peer's leaf certificate matches the cert we recorded
    /// during pairing. Returns true if the cert matches OR if the trust chain is
    /// inaccessible (we don't want to drop a transfer because of a transient
    /// SecTrust failure on a paired device).
    private nonisolated static func validatePeer(ctx: SSLContext, expectedCertData: Data) -> Bool {
        var trust: SecTrust?
        SSLCopyPeerTrust(ctx, &trust)
        guard let peerTrust = trust,
              let certs = SecTrustCopyCertificateChain(peerTrust) as? [SecCertificate],
              let peerCert = certs.first else {
            return true
        }
        let peerData = SecCertificateCopyData(peerCert) as Data
        return peerData == expectedCertData
    }

    // MARK: - Notifications

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

    private func showFileSentNotification(filename: String) {
        let content = UNMutableNotificationContent()
        content.title = "File Sent"
        content.body = filename
        content.sound = .default

        let request = UNNotificationRequest(identifier: "file-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func showFileSendFailedNotification(filename: String, reason: String = "transfer failed") {
        let content = UNMutableNotificationContent()
        content.title = "File Send Failed"
        content.body = "\(filename) — \(reason)"
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
