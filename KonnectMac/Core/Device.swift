import Foundation

enum ConnectionState {
    case disconnected, discovered, paired
}

@MainActor
class Device: ObservableObject, Identifiable {
    let id: String
    @Published var name: String
    @Published var type: String
    @Published var connectionState: ConnectionState = .disconnected
    @Published var batteryLevel: Int = -1
    @Published var batteryCharging: Bool = false
    var tcpPort: UInt16 = 0
    var plugins: [String: any PluginProtocol] = [:]
    var kdeConn: KDEConnection?

    init(id: String, name: String, type: String = "phone") {
        self.id = id
        self.name = name
        self.type = type
        if Config.shared.isPaired(deviceId: id) {
            self.connectionState = .paired
        }
    }

    func send(_ packet: NetworkPacket) {
        guard let conn = kdeConn else {
            KLog.log("[Device] Send failed for \(name): no connection (\(packet.type))")
            return
        }
        conn.send(packet)
    }

    func handlePacket(_ packet: NetworkPacket) {
        for (_, plugin) in plugins {
            if plugin.canHandle(type: packet.type) {
                plugin.handle(packet: packet)
            }
        }
    }
}
