import Foundation
import UserNotifications

@MainActor
class BatteryPlugin: PluginProtocol {
    let device: Device
    private var lowBatteryNotified = false
    private var chargingConfirmCount = 0

    init(device: Device) { self.device = device }

    /// Reset state on disconnect — ensures fresh low-battery alerts on reconnect
    func resetOnDisconnect() {
        lowBatteryNotified = false
        chargingConfirmCount = 0
    }

    func canHandle(type: String) -> Bool {
        type == "kdeconnect.battery"
    }

    func handle(packet: NetworkPacket) {
        // currentCharge may arrive as Int, Double, Int64, or String
        if let v = packet.body["currentCharge"]?.value {
            if let i = v as? Int { device.batteryLevel = min(100, max(0, i)) }
            else if let d = v as? Double { device.batteryLevel = min(100, max(0, Int(d))) }
            else if let i = v as? Int64 { device.batteryLevel = min(100, max(0, Int(i))) }
            else if let s = v as? String, let i = Int(s) { device.batteryLevel = min(100, max(0, i)) }
        }
        if let v = packet.body["isCharging"]?.value {
            if let b = v as? Bool { device.batteryCharging = b }
            else if let i = v as? Int { device.batteryCharging = i != 0 }
            else if let d = v as? Double { device.batteryCharging = d != 0 }
        }
        var thresholdLow = 0
        if let v = packet.body["thresholdEvent"]?.value {
            if let i = v as? Int { thresholdLow = i }
            else if let i = v as? Int64 { thresholdLow = Int(i) }
            else if let d = v as? Double { thresholdLow = Int(d) }
        }

        let rawCharge = packet.body["currentCharge"]?.value
        KLog.log("[Battery] \(device.name): \(device.batteryLevel)% charging=\(device.batteryCharging) rawType=\(type(of: rawCharge)) raw=\(String(describing: rawCharge))")

        if thresholdLow == 1 && !lowBatteryNotified && device.batteryLevel >= 0 {
            lowBatteryNotified = true
            let content = UNMutableNotificationContent()
            content.title = "\(device.name) — Low Battery"
            content.body = "Battery at \(device.batteryLevel)%"
            content.sound = .default
            let request = UNNotificationRequest(identifier: "battery-low-\(device.id)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
        if device.batteryCharging {
            chargingConfirmCount += 1
            if chargingConfirmCount >= 2 { lowBatteryNotified = false }
        } else {
            chargingConfirmCount = 0
        }
    }

}
