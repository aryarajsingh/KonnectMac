import Foundation
import AppKit

@MainActor
class ClipboardPlugin: PluginProtocol {
    let device: Device
    // All plugins share one Mac pasteboard. Track its origin by change count,
    // not by text (which the user can legitimately copy again later).
    private static var observedChangeCount = NSPasteboard.general.changeCount
    private static var updateTimestamp: Int64 = 0
    private static var remoteChangeCount: Int?
    private var clipboardTimer: Timer?
    private var lastChangeCount = 0

    init(device: Device) {
        self.device = device
    }

    deinit {
        // Timer invalidation must happen on the thread that created it (main thread).
        // Since deinit can run on any thread, schedule it on main.
        if let timer = clipboardTimer {
            DispatchQueue.main.async { timer.invalidate() }
        }
    }

    func start() {
        guard clipboardTimer == nil else { return }
        Self.observeLocalChange()
        lastChangeCount = Self.observedChangeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkClipboard() }
        }
        if Config.shared.clipboardEnabled(.send, for: device.id),
           Self.updateTimestamp > 0, Self.remoteChangeCount != Self.observedChangeCount {
            sendCurrentClipboard(timestamp: Self.updateTimestamp)
        }
    }

    func stop() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
    }

    func canHandle(type: String) -> Bool {
        type == "kdeconnect.clipboard" || type == "kdeconnect.clipboard.connect"
    }

    func handle(packet: NetworkPacket) {
        guard Config.shared.clipboardEnabled(.receive, for: device.id) else { return }
        guard let content = packet.body["content"]?.value as? String else { return }
        guard content.utf8.count <= 131072 else { return }
        Self.observeLocalChange()
        var remoteTimestamp: Int64?
        if packet.type == "kdeconnect.clipboard.connect" {
            let value = packet.body["timestamp"]?.value
            let timestamp = value as? Int64 ?? (value as? Int).map { Int64($0) }
            guard let timestamp, timestamp > 0, timestamp >= Self.updateTimestamp else { return }
            remoteTimestamp = min(timestamp, Self.nowMilliseconds())
        }

        if Self.applyRemoteText(content, timestamp: remoteTimestamp) {
            KLog.log("[Clipboard] Received from \(device.name): \(content.utf8.count) bytes")
        }
    }

    @discardableResult
    static func applyRemoteText(_ text: String, timestamp: Int64? = nil) -> Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.string(forType: .string) != text else { return false }
        pasteboard.clearContents()
        let written = pasteboard.setString(text, forType: .string)
        observedChangeCount = pasteboard.changeCount
        remoteChangeCount = observedChangeCount
        updateTimestamp = timestamp ?? nowMilliseconds()
        return written
    }

    private static func observeLocalChange() {
        let count = NSPasteboard.general.changeCount
        guard count != observedChangeCount else { return }
        observedChangeCount = count
        remoteChangeCount = nil
        updateTimestamp = nowMilliseconds()
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func checkClipboard() {
        guard clipboardTimer != nil else { return }
        Self.observeLocalChange()
        let count = Self.observedChangeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard Self.remoteChangeCount != count,
              Config.shared.clipboardEnabled(.send, for: device.id) else { return }
        sendCurrentClipboard()
    }

    func sendCurrentClipboard() {
        sendCurrentClipboard(timestamp: nil)
    }

    private func sendCurrentClipboard(timestamp: Int64?) {
        guard device.connectionState == .paired,
              let content = NSPasteboard.general.string(forType: .string) else { return }
        // Cap clipboard sync at 128KB to prevent OOM on the phone
        guard content.utf8.count <= 131072 else {
            KLog.log("[Clipboard] Skipping oversized clipboard: \(content.utf8.count) bytes")
            return
        }

        var body = ["content": AnyCodable(content)]
        if let timestamp { body["timestamp"] = AnyCodable(timestamp) }
        let type = timestamp == nil ? "kdeconnect.clipboard" : "kdeconnect.clipboard.connect"
        let packet = NetworkPacket(type: type, body: body)
        device.send(packet)
        KLog.log("[Clipboard] Sent to \(device.name) (\(content.utf8.count) bytes)")
    }
}
