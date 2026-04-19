import Foundation

struct SMSConversation: Identifiable, Equatable {
    let id: Int64
    var name: String
    var phoneNumber: String
    var lastMessage: String
    var lastMessageDate: Date
    var unreadCount: Int

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct SMSMessage: Identifiable, Equatable {
    let id: Int64
    let threadId: Int64
    let address: String
    let body: String
    let date: Date
    let type: Int
    let read: Bool

    var isFromMe: Bool { type == 2 }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

@MainActor
class SMSStore: ObservableObject {
    static let shared = SMSStore()

    @Published var conversations: [SMSConversation] = []
    @Published var messages: [Int64: [SMSMessage]] = [:]
    @Published var isLoadingConversations = false
    @Published var isLoadingMessages: Int64? = nil

    private init() {}

    func processMessages(_ rawMessages: [Any]) {
        var convos: [Int64: SMSConversation] = [:]
        var threadMessages: [Int64: [SMSMessage]] = [:]

        for raw in rawMessages {
            guard let msg = raw as? [String: Any] else { continue }
            guard let threadId = int64Value(msg, key: "thread_id") else { continue }

            let msgId = int64Value(msg, key: "_id") ?? Int64(Date().timeIntervalSince1970 * 1000)
            let address = msg["address"] as? String ?? ""
            let body = msg["body"] as? String ?? ""
            let dateMs = (msg["date"] as? Double) ?? Double(int64Value(msg, key: "date") ?? 0)
            let date = Date(timeIntervalSince1970: dateMs / 1000)
            let type = (msg["type"] as? Int) ?? 1
            let read = (msg["read"] as? Bool) ?? true
            let contactName = msg["contactName"] as? String ?? msg["contact_name"] as? String
            let name = (contactName?.isEmpty ?? true) ? address : contactName!

            let sms = SMSMessage(id: msgId, threadId: threadId, address: address, body: body, date: date, type: type, read: read)

            if threadMessages[threadId] == nil {
                threadMessages[threadId] = []
            }
            threadMessages[threadId]?.append(sms)

            if convos[threadId] == nil {
                convos[threadId] = SMSConversation(
                    id: threadId, name: name, phoneNumber: address,
                    lastMessage: body, lastMessageDate: date, unreadCount: read ? 0 : 1
                )
            } else {
                if date > convos[threadId]!.lastMessageDate {
                    convos[threadId]?.lastMessage = body
                    convos[threadId]?.lastMessageDate = date
                    if !(name.isEmpty || name == address) { convos[threadId]?.name = name }
                }
                if !read { convos[threadId]?.unreadCount += 1 }
            }
        }

        conversations = convos.values.sorted { $0.lastMessageDate > $1.lastMessageDate }

        for (threadId, msgs) in threadMessages {
            let sorted = msgs.sorted { $0.date < $1.date }
            if messages[threadId] != nil {
                let existing = messages[threadId]!
                let existingIds = Set(existing.map { $0.id })
                let newMsgs = sorted.filter { !existingIds.contains($0.id) }
                messages[threadId] = existing + newMsgs
                messages[threadId]?.sort { $0.date < $1.date }
            } else {
                messages[threadId] = sorted
            }
        }
    }

    func addSentMessage(threadId: Int64, phoneNumber: String, body: String) {
        let msg = SMSMessage(
            id: Int64(Date().timeIntervalSince1970 * 1000),
            threadId: threadId, address: phoneNumber,
            body: body, date: Date(), type: 2, read: true
        )
        if messages[threadId] != nil {
            messages[threadId]?.append(msg)
        } else {
            messages[threadId] = [msg]
        }
        if let idx = conversations.firstIndex(where: { $0.id == threadId }) {
            conversations[idx].lastMessage = body
            conversations[idx].lastMessageDate = Date()
        }
    }

    func reset() {
        conversations = []
        messages = [:]
        isLoadingConversations = false
        isLoadingMessages = nil
    }

    private func int64Value(_ dict: [String: Any], key: String) -> Int64? {
        if let v = dict[key] as? Int64 { return v }
        if let v = dict[key] as? Int { return Int64(v) }
        if let v = dict[key] as? Double { return Int64(v) }
        return nil
    }
}
