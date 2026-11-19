import Foundation
import UserNotifications

struct NotificationItem: Identifiable, Equatable {
    struct ID: Hashable {
        let deviceId: String
        let remoteId: String

        var systemIdentifier: String { "notif-\(deviceId.utf8.count):\(deviceId)\(remoteId)" }
    }

    struct Content: Equatable {
        let appName: String
        let title: String
        let text: String
        let ticker: String
        let packageName: String
        let replyId: String?
        let actions: [String]
        let isClearable: Bool
        let imageKey: String?
    }

    let id: ID
    let content: Content
    let timestamp: Date
    let silent: Bool
    var imageData: Data?

    var appName: String { content.appName }
    var title: String { content.title }
    var text: String { content.text }
    var ticker: String { content.ticker }
}

@MainActor
class NotificationStore: ObservableObject {
    static let shared = NotificationStore()

    @Published private(set) var notifications: [NotificationItem] = []

    private init() {}

    func item(id: NotificationItem.ID) -> NotificationItem? {
        notifications.first { $0.id == id }
    }

    func upsert(_ item: NotificationItem) {
        if let index = notifications.firstIndex(where: { $0.id == item.id }) {
            notifications[index] = item
        } else {
            notifications.insert(item, at: 0)
            if notifications.count > 200 { notifications.removeLast() }
        }
    }

    func dismiss(_ item: NotificationItem) {
        if item.content.isClearable {
            DeviceManager.shared.devices[item.id.deviceId]?.send(NetworkPacket(
                type: "kdeconnect.notification.request", body: ["cancel": AnyCodable(item.id.remoteId)]
            ))
        }
        remove(id: item.id)
    }

    func dismissAll() {
        for item in notifications { dismiss(item) }
    }

    func performAction(_ action: String, on item: NotificationItem) {
        guard let current = self.item(id: item.id),
              current.content.actions.contains(action),
              let device = DeviceManager.shared.devices[item.id.deviceId],
              device.connectionState == .paired, device.plugins["notification"] != nil else { return }
        device.send(NetworkPacket(type: "kdeconnect.notification.action", body: [
            "key": AnyCodable(item.id.remoteId),
            "action": AnyCodable(action)
        ]))
    }

    func hideNotifications(for deviceId: String, packageName: String? = nil) {
        for item in notifications where item.id.deviceId == deviceId
            && (packageName == nil || item.content.packageName == packageName) {
            remove(id: item.id)
        }
    }

    func remove(id: NotificationItem.ID) {
        removeSystemNotification(id: id)
        notifications.removeAll { $0.id == id }
    }

    func removeSystemNotification(id: NotificationItem.ID) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id.systemIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [id.systemIdentifier])
    }

    var count: Int { notifications.count }
}
