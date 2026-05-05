import Foundation
import AppKit

@MainActor
class PairingHandler {
    static func showPairingRequest(from device: Device, connection: KDEConnection, completion: @escaping (Bool) -> Void) {
        let verificationKey = VerificationKeyHelper.computeFromConnection(conn: connection)

        let alert = NSAlert()
        alert.messageText = "Pairing Request"
        alert.informativeText = "\(device.name) wants to pair.\n\nVerification key: \(verificationKey)\n\nMake sure this matches the key shown on \(device.name)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Accept")
        alert.addButton(withTitle: "Reject")
        alert.icon = NSImage(systemSymbolName: "link.badge.plus", accessibilityDescription: "Pairing")

        // Bring app to front so the alert is visible
        NSApp.activate()

        // runModal is acceptable here — pairing is a rare, user-initiated event.
        // The brief main thread block (until user clicks) is preferable to an invisible dialog.
        let response = alert.runModal()
        completion(response == .alertFirstButtonReturn)
    }
}
