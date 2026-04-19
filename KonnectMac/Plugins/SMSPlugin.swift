import Foundation

@MainActor
class SMSPlugin: PluginProtocol {
    let device: Device

    init(device: Device) {
        self.device = device
    }

    func canHandle(type: String) -> Bool {
        type == "kdeconnect.sms.messages"
    }

    func handle(packet: NetworkPacket) {
        guard let rawMessages = packet.body["messages"]?.value as? [Any] else {
            KLog.log("[SMS] No messages array in packet")
            return
        }
        KLog.log("[SMS] Received \(rawMessages.count) message(s)")
        SMSStore.shared.processMessages(rawMessages)

        if SMSStore.shared.isLoadingConversations {
            SMSStore.shared.isLoadingConversations = false
        }
        if let loadingThread = SMSStore.shared.isLoadingMessages {
            SMSStore.shared.isLoadingMessages = nil
        }
    }

    func requestConversations() {
        SMSStore.shared.isLoadingConversations = true
        let packet = NetworkPacket(type: "kdeconnect.sms.request_conversations", body: [:])
        device.send(packet)
        KLog.log("[SMS] Requested conversations")

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if SMSStore.shared.isLoadingConversations {
                SMSStore.shared.isLoadingConversations = false
                KLog.log("[SMS] Conversations request timed out")
            }
        }
    }

    func requestConversation(threadId: Int64) {
        SMSStore.shared.isLoadingMessages = threadId
        let packet = NetworkPacket(type: "kdeconnect.sms.request_conversation", body: [
            "threadID": AnyCodable(threadId),
            "rangeStartTimestamp": AnyCodable(Int64(0)),
            "numberToRequest": AnyCodable(Int64(50))
        ])
        device.send(packet)
        KLog.log("[SMS] Requested conversation \(threadId)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if SMSStore.shared.isLoadingMessages == threadId {
                SMSStore.shared.isLoadingMessages = nil
                KLog.log("[SMS] Conversation request timed out")
            }
        }
    }

    func sendSMS(threadId: Int64, phoneNumber: String, body: String) {
        let packet = NetworkPacket(type: "kdeconnect.sms.request", body: [
            "version": AnyCodable(2),
            "addresses": AnyCodable([["address": phoneNumber]]),
            "messageBody": AnyCodable(body)
        ])
        device.send(packet)
        SMSStore.shared.addSentMessage(threadId: threadId, phoneNumber: phoneNumber, body: body)
        KLog.log("[SMS] Sent SMS to \(phoneNumber)")
    }

    func resetOnDisconnect() {
        SMSStore.shared.reset()
    }

    func onDeviceReady() {
        SMSStore.shared.loadCache()
        SMSStore.shared.requestConversationsIfNeeded()
    }
}
