import Foundation
import AppKit

@MainActor
class FindMyPhonePlugin: PluginProtocol {
    let device: Device

    init(device: Device) { self.device = device }

    func canHandle(type: String) -> Bool { type == "kdeconnect.findmyphone.request" }

    func handle(packet: NetworkPacket) {
        KLog.log("[FindMyPhone] Request received from \(device.name) — playing alert sound")
        // Phone wants to find this Mac — play system alert sound
        NSSound.beep()
        // Also flash the screen (subtle visual indicator)
        if let screen = NSScreen.main {
            let flash = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            flash.backgroundColor = NSColor.white.withAlphaComponent(0.3)
            flash.level = .screenSaver
            flash.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { flash.orderOut(nil) }
        }
    }

    /// Send a find-my-phone request to the paired device.
    /// The phone toggles its own ring state on each request — we don't track state locally
    /// because we can't know when the phone stops ringing on its own.
    func ringPhone() {
        let packet = NetworkPacket(type: "kdeconnect.findmyphone.request")
        device.send(packet)
        KLog.log("[FindMyPhone] Sent ring request to \(device.name)")
    }
}
