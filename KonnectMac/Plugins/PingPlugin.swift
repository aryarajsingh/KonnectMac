import Foundation
import UserNotifications

@MainActor
class PingPlugin: PluginProtocol {
    let device: Device

    init(device: Device) { self.device = device }

    func canHandle(type: String) -> Bool { type == "kdeconnect.ping" }

    func handle(packet: NetworkPacket) {
        KLog.log("[Ping] Received from \(device.name)")
        let content = UNMutableNotificationContent()
        content.title = "Ping"
        content.body = "Ping from \(device.name)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "ping-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func sendPing() {
        let ping = NetworkPacket(type: "kdeconnect.ping")
        device.send(ping)
        KLog.log("[Ping] Sent to \(device.name)")
    }
}
