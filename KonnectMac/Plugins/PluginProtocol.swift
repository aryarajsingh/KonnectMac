import Foundation

@MainActor
protocol PluginProtocol {
    var device: Device { get }
    func canHandle(type: String) -> Bool
    func handle(packet: NetworkPacket)
}
