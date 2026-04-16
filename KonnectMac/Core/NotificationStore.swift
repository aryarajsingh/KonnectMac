import Foundation
import UserNotifications

struct NotificationItem: Identifiable, Equatable {
    let id: String
    let appName: String
    let title: String
    let text: String
    let ticker: String
    let packageName: String
    let deviceId: String
    let deviceName: String
    let timestamp: Date
    let iconPath: String?
    let replyId: String?
}

@MainActor
class NotificationStore: ObservableObject {
    static let shared = NotificationStore()

    @Published var notifications: [NotificationItem] = []

    private init() {}

    func add(id: String, appName: String, title: String, text: String, ticker: String,
             packageName: String, deviceId: String, deviceName: String,
             iconPath: String?, replyId: String?) {
        let existingTimestamp = notifications.first(where: { $0.id == id })?.timestamp
        let timestamp = existingTimestamp ?? Date()

        let item = NotificationItem(
            id: id, appName: appName, title: title, text: text, ticker: ticker,
            packageName: packageName, deviceId: deviceId, deviceName: deviceName,
            timestamp: timestamp, iconPath: iconPath, replyId: replyId
        )

        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            notifications[idx] = item
        } else {
            notifications.insert(item, at: 0)
        }

        if notifications.count > 200 {
            notifications.removeLast(notifications.count - 200)
        }
    }

    func dismiss(_ item: NotificationItem) {
        let cancelPacket = NetworkPacket(type: "kdeconnect.notification.request", body: [
            "cancel": AnyCodable(item.id)
        ])
        DeviceManager.shared.devices[item.deviceId]?.send(cancelPacket)

        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["notif-\(item.id)"])

        notifications.removeAll { $0.id == item.id }
    }

    func dismissAll() {
        for item in notifications {
            let cancelPacket = NetworkPacket(type: "kdeconnect.notification.request", body: [
                "cancel": AnyCodable(item.id)
            ])
            DeviceManager.shared.devices[item.deviceId]?.send(cancelPacket)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["notif-\(item.id)"])
        }
        notifications.removeAll()
    }

    func remove(id: String) {
        notifications.removeAll { $0.id == id }
    }

    var count: Int {
        notifications.count
    }
}
