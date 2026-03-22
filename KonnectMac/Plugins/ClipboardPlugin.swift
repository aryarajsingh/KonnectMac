import Foundation
import AppKit

@MainActor
class ClipboardPlugin: PluginProtocol {
    let device: Device
    private var lastSentContent = ""
    var lastReceivedContent = ""
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
        startMonitoring()
    }

    func stop() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        // Clear echo prevention flags — stale values prevent sync after reconnect
        lastSentContent = ""
        lastReceivedContent = ""
    }

    func canHandle(type: String) -> Bool {
        type == "kdeconnect.clipboard" || type == "kdeconnect.clipboard.connect"
    }

    func handle(packet: NetworkPacket) {
        guard let content = packet.body["content"]?.value as? String else { return }
        guard content.utf8.count <= 131072 else { KLog.log("[Clipboard] Rejected oversized incoming: \(content.utf8.count) bytes"); return }
        guard content != lastReceivedContent else { return }
        guard content != lastSentContent else { return }

        lastReceivedContent = content
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        lastChangeCount = pasteboard.changeCount

        KLog.log("[Clipboard] Received from \(device.name): \(content.utf8.count) bytes")
    }

    private func startMonitoring() {
        lastChangeCount = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard let content = pasteboard.string(forType: .string) else { return }
        guard content != lastReceivedContent else { return }
        guard content != lastSentContent else { return }
        // Cap clipboard sync at 128KB to prevent OOM on the phone
        guard content.utf8.count <= 131072 else {
            KLog.log("[Clipboard] Skipping oversized clipboard: \(content.utf8.count) bytes")
            return
        }

        lastSentContent = content
        let packet = NetworkPacket(type: "kdeconnect.clipboard", body: ["content": AnyCodable(content)])
        device.send(packet)
        KLog.log("[Clipboard] Sent to \(device.name) (\(content.utf8.count) bytes)")
    }
}
