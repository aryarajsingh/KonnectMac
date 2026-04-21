import Foundation

struct SMSConversation: Identifiable, Equatable, Codable {
    let id: Int64
    var name: String
    var phoneNumber: String
    var lastMessage: String
    var lastMessageDate: Date
    var unreadCount: Int

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct SMSMessage: Identifiable, Equatable, Codable {
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

    private let cacheDir: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDir = appSupport.appendingPathComponent("KonnectMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Process incoming messages

    func processMessages(_ rawMessages: [Any]) {
        var newConvos: [Int64: SMSConversation] = [:]
        var newThreadMessages: [Int64: [SMSMessage]] = [:]
        var parsed = 0
        var skipped = 0

        for raw in rawMessages {
            guard let msg = raw as? [String: Any] else {
                skipped += 1
                continue
            }

            let threadId = int64Value(msg, key: "threadId")
                ?? int64Value(msg, key: "thread_id")
                ?? addressBasedThreadId(msg)
            guard threadId > 0 else {
                skipped += 1
                continue
            }

            let msgId = int64Value(msg, key: "id")
                ?? int64Value(msg, key: "_id")
                ?? Int64(Date().timeIntervalSince1970 * 1000) + Int64(parsed)
            let address = msg["address"] as? String ?? ""
            let body = msg["body"] as? String ?? ""
            let dateMs = (msg["date"] as? Double) ?? Double(int64Value(msg, key: "date") ?? 0)
            let date = Date(timeIntervalSince1970: dateMs / 1000)
            let type = (msg["type"] as? Int)
                ?? (int64Value(msg, key: "type") != nil ? Int(int64Value(msg, key: "type")!) : 1)
            let read = (msg["read"] as? Bool)
                ?? (int64Value(msg, key: "read") != nil ? int64Value(msg, key: "read")! == 1 : true)
            let contactName = msg["contactName"] as? String
                ?? msg["contact_name"] as? String
                ?? msg["name"] as? String
            let rawName = (contactName?.isEmpty ?? true) ? address : contactName!
            let displayName = rawName.isEmpty ? extractSender(from: body) : rawName

            let sms = SMSMessage(id: msgId, threadId: threadId, address: address, body: body, date: date, type: type, read: read)

            if newThreadMessages[threadId] == nil { newThreadMessages[threadId] = [] }
            newThreadMessages[threadId]?.append(sms)

            if newConvos[threadId] == nil {
                newConvos[threadId] = SMSConversation(
                    id: threadId, name: displayName, phoneNumber: address,
                    lastMessage: body, lastMessageDate: date, unreadCount: read ? 0 : 1
                )
            } else {
                if date > newConvos[threadId]!.lastMessageDate {
                    newConvos[threadId]?.lastMessage = body
                    newConvos[threadId]?.lastMessageDate = date
                    if !displayName.isEmpty && displayName != address { newConvos[threadId]?.name = displayName }
                }
                if !read { newConvos[threadId]?.unreadCount += 1 }
            }
            parsed += 1
        }

        KLog.log("[SMS] Processed \(parsed) msgs, skipped \(skipped), threads: \(newConvos.keys.sorted())")

        if parsed == 0, let first = rawMessages.first, let msg = first as? [String: Any] {
            KLog.log("[SMS] Sample keys: \(msg.keys.sorted())")
            for k in msg.keys.sorted() { KLog.log("[SMS]   \(k) = \(String(describing: msg[k]).prefix(60))") }
        }

        if !newConvos.isEmpty {
            var existingConvos = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
            for (id, convo) in newConvos { existingConvos[id] = convo }
            conversations = existingConvos.values.sorted { $0.lastMessageDate > $1.lastMessageDate }
        }

        for (threadId, msgs) in newThreadMessages {
            let sorted = msgs.sorted { $0.date < $1.date }
            if messages[threadId] != nil {
                let existing = messages[threadId]!
                let existingIds = Set(existing.map { $0.id })
                let newMsgs = sorted.filter { !existingIds.contains($0.id) }
                messages[threadId] = (existing + newMsgs).sorted { $0.date < $1.date }
            } else {
                messages[threadId] = sorted
            }
        }

        scheduleSave()
    }

    func addSentMessage(threadId: Int64, phoneNumber: String, body: String) {
        let msg = SMSMessage(
            id: Int64(Date().timeIntervalSince1970 * 1000),
            threadId: threadId, address: phoneNumber,
            body: body, date: Date(), type: 2, read: true
        )
        if messages[threadId] != nil { messages[threadId]?.append(msg) }
        else { messages[threadId] = [msg] }
        if let idx = conversations.firstIndex(where: { $0.id == threadId }) {
            conversations[idx].lastMessage = body
            conversations[idx].lastMessageDate = Date()
        }
        scheduleSave()
    }

    // MARK: - Auto-load from device

    func requestConversationsIfNeeded() {
        guard conversations.isEmpty, !isLoadingConversations else { return }
        if let device = DeviceManager.shared.devices.values.first(where: { $0.connectionState == .paired }),
           let plugin = device.plugins["sms"] as? SMSPlugin {
            plugin.requestConversations()
        }
    }

    // MARK: - Cache

    func loadCache() {
        let url = cacheDir.appendingPathComponent("sms_cache.json")
        guard let data = try? Data(contentsOf: url) else { return }
        struct Cache: Codable {
            let conversations: [SMSConversation]
            let messages: [Int64: [SMSMessage]]
        }
        guard let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        conversations = cache.conversations
        messages = cache.messages
        KLog.log("[SMS] Loaded \(conversations.count) conversations from cache")
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            saveCacheNow()
        }
    }

    private func saveCacheNow() {
        struct Cache: Codable {
            let conversations: [SMSConversation]
            let messages: [Int64: [SMSMessage]]
        }
        let cache = Cache(conversations: conversations, messages: messages)
        let url = cacheDir.appendingPathComponent("sms_cache.json")
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: url, options: .atomic)
            KLog.log("[SMS] Saved \(conversations.count) conversations to cache")
        }
    }

    func reset() {
        conversations = []
        messages = [:]
        isLoadingConversations = false
        isLoadingMessages = nil
        let url = cacheDir.appendingPathComponent("sms_cache.json")
        try? FileManager.default.removeItem(at: url)
    }

    private func int64Value(_ dict: [String: Any], key: String) -> Int64? {
        if let v = dict[key] as? Int64 { return v }
        if let v = dict[key] as? Int { return Int64(v) }
        if let v = dict[key] as? Double { return Int64(v) }
        if let v = dict[key] as? String, let i = Int64(v) { return i }
        return nil
    }

    private func addressBasedThreadId(_ msg: [String: Any]) -> Int64 {
        let address = msg["address"] as? String ?? ""
        var hasher = Hasher()
        hasher.combine(address)
        return Int64(hasher.finalize() & 0x7FFFFFFFFFFFFFFF)
    }

    private func extractSender(from body: String) -> String {
        let patterns: [(String, (String) -> String)] = [
            ("\\[([^\\]]+)\\]", { $0 }),
            ("^([A-Za-z0-9]+):\\s", { $0 }),
            ("^(\\S+?)\\s+(?:Product|Order|Recall|Tus|Tu código|codigo)", { $0 }),
        ]
        for (pattern, extract) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: body, options: [], range: NSRange(body.startIndex..., in: body)),
               let range = Range(match.range(at: 1), in: body) {
                let sender = String(body[range])
                if sender.count >= 2 && sender.count <= 30 { return sender }
            }
        }
        let words = body.prefix(30).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if let first = words.first, first.count >= 2 { return first }
        return "Unknown"
    }
}
