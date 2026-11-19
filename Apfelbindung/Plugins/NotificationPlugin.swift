import Darwin
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers
import UserNotifications

@MainActor
class NotificationPlugin: PluginProtocol {
    let device: Device

    // Android may send only payloadHash on subsequent updates. Never infer
    // that a payload is an app icon: it may be a sender avatar or a photo.
    private static let imageCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    private var pendingImages = Set<String>()

    init(device: Device) {
        self.device = device
    }

    func canHandle(type: String) -> Bool { type == "kdeconnect.notification" }

    func requestNotifications() {
        guard device.connectionState == .paired else { return }
        device.send(NetworkPacket(type: "kdeconnect.notification.request", body: ["request": AnyCodable(true)]))
    }

    func handle(packet: NetworkPacket) {
        guard let remoteId = packet.body["id"]?.value as? String, !remoteId.isEmpty else { return }
        let isCancel = packet.body["isCancel"]?.value as? Bool ?? false
        let androidPrefix = "org.kde.kdeconnect_tp::"
        let notificationId = isCancel && remoteId.hasPrefix(androidPrefix)
            ? String(remoteId.dropFirst(androidPrefix.count)) : remoteId
        let id = NotificationItem.ID(deviceId: device.id, remoteId: notificationId)
        let appName = packet.body["appName"]?.value as? String ?? "Unknown"
        let parts = notificationId.split(separator: "|", omittingEmptySubsequences: false)
        let packageName = packet.body["packageName"]?.value as? String
            ?? (parts.count >= 2 && !parts[1].isEmpty ? String(parts[1]) : "app:\(appName)")
        let title = packet.body["title"]?.value as? String ?? ""
        let text = packet.body["text"]?.value as? String ?? ""
        let store = NotificationStore.shared

        if isCancel { store.remove(id: id) }
        else { Config.shared.recordNotificationApp(packageName, name: appName, for: device.id) }

        // Telephony is a separate plugin; its call state is not a mirrored notification.
        if handleCall(packageName: packageName, id: notificationId, appName: appName,
                      title: title, text: text, isCancel: isCancel) || isCancel { return }
        guard Config.shared.receivesNotifications(from: packageName, for: device.id) else { return }

        let size = packet.payloadSize ?? 0
        let rawPort = packet.payloadTransferInfo?["port"]?.value
        let port = (rawPort as? Int64 ?? (rawPort as? Int).map { Int64($0) }).flatMap { UInt16(exactly: $0) }
        let validTransfer = size > 0 && size <= 1_048_576 && port.map { $0 > 0 } == true
        let hash = (packet.body["payloadHash"]?.value as? String).flatMap {
            !$0.isEmpty && $0.utf8.count <= 128 ? $0 : nil
        }
        let imageKey = hash.map { "hash:\($0)" } ?? (validTransfer ? "transfer:\(UUID().uuidString)" : nil)
        let previous = store.item(id: id)
        let content = NotificationItem.Content(
            appName: appName, title: title, text: text,
            ticker: packet.body["ticker"]?.value as? String ?? "",
            packageName: packageName,
            replyId: packet.body["requestReplyId"]?.value as? String,
            actions: (packet.body["actions"]?.value as? [String] ?? []).filter { !$0.isEmpty },
            isClearable: packet.body["isClearable"]?.value as? Bool ?? true,
            imageKey: imageKey
        )
        let image = imageKey.flatMap { key -> Data? in
            if previous?.content.imageKey == key, let data = previous?.imageData { return data }
            return Self.imageCache.object(forKey: cacheKey(key)).map { $0 as Data }
        }
        let waiting = imageKey.map { pendingImages.contains($0) } ?? false
        let duplicate = previous?.content == content
        if duplicate && (previous?.imageData != nil || waiting || (!validTransfer && image == nil)) { return }

        let item = NotificationItem(
            id: id, content: content, timestamp: previous?.timestamp ?? Date(),
            silent: duplicate || (packet.body["silent"]?.value as? Bool ?? false), imageData: image
        )
        // Clear a previous system notification before waiting on a new image.
        // Otherwise Notification Center can keep showing the old image.
        if previous != nil && !duplicate { store.removeSystemNotification(id: id) }
        store.upsert(item)

        if image == nil, let key = imageKey {
            if waiting { return }
            if validTransfer, let port, pendingImages.count < 32,
               let host = device.kdeConn?.host,
               let cert = Config.shared.loadPairedDeviceCert(id: device.id) {
                pendingImages.insert(key)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let data = Self.downloadImage(host: host, port: port, size: Int(size), pinnedCert: cert)
                    Task { @MainActor [weak self] in self?.finishImage(key: key, data: data) }
                }
                return
            }
        }
        if !item.silent { postNotification(item) }
    }

    private func cacheKey(_ key: String) -> NSString {
        "\(device.id.utf8.count):\(device.id)\(key)" as NSString
    }

    private func finishImage(key: String, data: Data?) {
        pendingImages.remove(key)
        guard device.connectionState == .paired,
              (device.plugins["notification"] as? NotificationPlugin) === self else { return }
        if let data, key.hasPrefix("hash:") {
            Self.imageCache.setObject(data as NSData, forKey: cacheKey(key), cost: data.count)
        }
        let store = NotificationStore.shared
        // Only apply this image to current entries still referencing it. A
        // newer packet, cancellation, or locally hidden item can't be undone.
        for var item in store.notifications where item.id.deviceId == device.id
            && item.content.imageKey == key && item.imageData == nil {
            if let data {
                item.imageData = data
                store.upsert(item)
            }
            if !item.silent { postNotification(item) }
        }
    }

    private static let voipPackages: Set<String> = [
        "com.whatsapp", "com.whatsapp.w4b", "com.google.android.apps.meetings",
        "com.google.android.apps.tachyon", "us.zoom.videomeetings", "org.telegram.messenger",
        "com.skype.raider", "com.skype.m2", "com.discord", "com.microsoft.teams",
        "com.facebook.orca", "com.viber.voip", "com.linecorp.LINEAPP"
    ]

    private func handleCall(packageName: String, id: String, appName: String, title: String,
                            text: String, isCancel: Bool) -> Bool {
        guard let telephony = device.plugins["telephony"] as? TelephonyPlugin else { return false }
        let combined = (title + " " + text).lowercased()
        let isCallHistory = ["missed", "ended", "rejected", "declined"].contains { combined.contains($0) }
        let dialers = ["com.samsung.android.dialer", "com.android.dialer",
                       "com.google.android.dialer", "com.android.server.telecom"]
        if id.contains("incallui") || dialers.contains(packageName) {
            if isCancel { telephony.onCallEnded() }
            else if !isCallHistory { telephony.onCallStarted(caller: title.isEmpty ? text : title) }
            return !isCallHistory
        }
        guard Self.voipPackages.contains(packageName) else { return false }
        if isCancel || isCallHistory {
            if telephony.hasActiveCall { telephony.onCallEnded() }
            return false
        }
        guard ["incoming", "calling", "ringing", "video call", "voice call", "audio call", "call from"]
            .contains(where: { combined.contains($0) }) else { return false }
        let caller = title.isEmpty || title == appName
            ? ["is calling", "Incoming voice call", "Incoming video call", "Incoming call"]
                .reduce(text) { $0.replacingOccurrences(of: $1, with: "") }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : title
        let name = caller.isEmpty ? text : caller
        if telephony.hasActiveCall {
            telephony.updateCallerName(name)
        } else {
            telephony.bufferVoIPCaller(name)
            telephony.onCallStarted(caller: name)
        }
        return true
    }

    private func postNotification(_ item: NotificationItem) {
        let content = UNMutableNotificationContent()
        content.title = item.appName
        if item.title != item.appName { content.subtitle = item.title }
        content.body = item.text.isEmpty ? item.ticker : item.text
        content.sound = .default
        content.threadIdentifier = "app-\(item.id.deviceId)-\(item.content.packageName)"

        if let otpCode = Self.extractOTP(from: content.body) {
            content.categoryIdentifier = "OTP_CODE"
            content.userInfo = ["otpCode": otpCode, "deviceId": item.id.deviceId]
        } else if let replyId = item.content.replyId, !replyId.isEmpty {
            content.categoryIdentifier = "NOTIFICATION_REPLY"
            content.userInfo = ["replyId": replyId, "deviceId": item.id.deviceId]
        }

        var attachmentURL: URL?
        if let data = item.imageData {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("apfelbindung-\(UUID().uuidString).png")
            do {
                try data.write(to: url)
                content.attachments = [try UNNotificationAttachment(identifier: "image", url: url)]
                attachmentURL = url
            } catch {
                try? FileManager.default.removeItem(at: url)
                KLog.log("[Notification] Could not create image attachment")
            }
        }

        let request = UNNotificationRequest(identifier: item.id.systemIdentifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [attachmentURL] error in
            if let url = attachmentURL { try? FileManager.default.removeItem(at: url) }
            if let error { KLog.log("[Notification] Delivery error: \(error)") }
        }
    }

    // MARK: - Image transfer

    nonisolated private static func downloadImage(host: String, port: UInt16, size: Int, pinnedCert: Data) -> Data? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0,
              let ctx = SSLCreateContext(nil, .clientSide, .streamType),
              let identity = CertificateManager.shared.getOrCreateIdentity() else { return nil }
        let fdPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        fdPtr.pointee = fd
        defer { SSLClose(ctx); fdPtr.deallocate() }
        SSLSetIOFuncs(ctx, imageSSLRead, imageSSLWrite)
        SSLSetConnection(ctx, UnsafeMutableRawPointer(fdPtr))
        SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        SSLSetCertificate(ctx, [identity] as CFArray)

        let clock = ContinuousClock()
        var deadline = clock.now + .seconds(10)
        var status = SSLHandshake(ctx)
        while clock.now < deadline {
            if status == errSSLPeerAuthCompleted {
                var trust: SecTrust?
                SSLCopyPeerTrust(ctx, &trust)
                guard let trust,
                      let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                      let cert = chain.first, SecCertificateCopyData(cert) as Data == pinnedCert else { return nil }
                break
            }
            guard status == errSSLWouldBlock || status == errSSLClientCertRequested else { return nil }
            status = SSLHandshake(ctx)
        }
        guard status == errSSLPeerAuthCompleted, clock.now < deadline else { return nil }
        repeat {
            status = SSLHandshake(ctx)
        } while clock.now < deadline && (status == errSSLWouldBlock || status == errSSLClientCertRequested)
        guard status == errSecSuccess else { return nil }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: min(size, 65_536))
        deadline = clock.now + .seconds(10)
        while received.count < size && clock.now < deadline {
            var bytesRead = 0
            let length = min(buffer.count, size - received.count)
            status = SSLRead(ctx, &buffer, length, &bytesRead)
            received.append(contentsOf: buffer.prefix(bytesRead))
            if status != errSecSuccess && status != errSSLWouldBlock { break }
        }
        guard received.count == size else { return nil }

        // Decode and normalize to a bounded PNG, regardless of the original format.
        let options: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: 384
        ]
        guard let source = CGImageSourceCreateWithData(received as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              (1...4096).contains(width), (1...4096).contains(height),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let result = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), let bytes = CFDataGetBytePtr(result) else { return nil }
        return Data(bytes: bytes, count: CFDataGetLength(result))
    }

    private static func extractOTP(from text: String) -> String? {
        let lowered = text.lowercased()
        let keywords = ["otp", "code", "pin", "verification", "verify", "2fa",
                        "one-time", "one time", "passcode", "password", "authentication"]
        guard keywords.contains(where: { lowered.contains($0) }) else { return nil }
        for pattern in [#"(?<!\d)(\d{4,8})(?!\d)"#, #"(?i)(?:code|otp|pin)[\s:]+(?:is\s+)?([A-Z0-9][\w-]{3,9})"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range])
        }
        return nil
    }

    static func registerNotificationCategories() {
        let reply = UNTextInputNotificationAction(identifier: "REPLY_ACTION", title: "Reply", options: [])
        let mute = UNNotificationAction(identifier: "MUTE_RINGER", title: "Mute Ringer", options: [])
        let finder = UNNotificationAction(identifier: "SHOW_IN_FINDER", title: "Show in Finder", options: [.foreground])
        let copy = UNNotificationAction(identifier: "COPY_OTP", title: "Copy Code", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "NOTIFICATION_REPLY", actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: "CALL_ACTIONS", actions: [mute], intentIdentifiers: []),
            UNNotificationCategory(identifier: "FILE_RECEIVED", actions: [finder], intentIdentifiers: []),
            UNNotificationCategory(identifier: "OTP_CODE", actions: [copy], intentIdentifiers: [])
        ])
    }
}

private func imageSSLRead(connection: SSLConnectionRef, data: UnsafeMutableRawPointer,
                          dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let requested = dataLength.pointee
    let count = Darwin.read(connection.assumingMemoryBound(to: Int32.self).pointee, data, requested)
    return imageSSLResult(count, requested: requested, dataLength: dataLength)
}

private func imageSSLWrite(connection: SSLConnectionRef, data: UnsafeRawPointer,
                           dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let requested = dataLength.pointee
    let count = Darwin.write(connection.assumingMemoryBound(to: Int32.self).pointee, data, requested)
    return imageSSLResult(count, requested: requested, dataLength: dataLength)
}

private func imageSSLResult(_ count: Int, requested: Int, dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    dataLength.pointee = max(count, 0)
    if count > 0 { return count < requested ? errSSLWouldBlock : errSecSuccess }
    if count == 0 { return errSSLClosedGraceful }
    return [EAGAIN, EWOULDBLOCK, ETIMEDOUT, EINTR].contains(errno) ? errSSLWouldBlock : errSecIO
}
