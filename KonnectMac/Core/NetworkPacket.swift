import Foundation

struct NetworkPacket: Codable {
    var id: Int64
    var type: String
    var body: [String: AnyCodable]
    var payloadSize: Int64?
    var payloadTransferInfo: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case id, type, body, payloadSize, payloadTransferInfo
    }

    init(type: String, body: [String: AnyCodable] = [:]) {
        self.id = Int64(Date().timeIntervalSince1970 * 1000)
        self.type = type
        self.body = body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let intId = try? container.decode(Int64.self, forKey: .id) {
            self.id = intId
        } else if let strId = try? container.decode(String.self, forKey: .id) {
            self.id = Int64(strId) ?? Int64(Date().timeIntervalSince1970 * 1000)
        } else {
            self.id = Int64(Date().timeIntervalSince1970 * 1000)
        }
        self.type = try container.decode(String.self, forKey: .type)
        self.body = try container.decodeIfPresent([String: AnyCodable].self, forKey: .body) ?? [:]
        self.payloadSize = try container.decodeIfPresent(Int64.self, forKey: .payloadSize)
        self.payloadTransferInfo = try container.decodeIfPresent([String: AnyCodable].self, forKey: .payloadTransferInfo)
    }

    func serialize() -> Data? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        return json + Data([0x0A])
    }

    static func deserialize(from data: Data) -> NetworkPacket? {
        guard data.count <= 131072 else {
            KLog.log("[Packet] Rejected oversized packet: \(data.count) bytes")
            return nil
        }
        do {
            return try JSONDecoder().decode(NetworkPacket.self, from: data)
        } catch {
            let desc = String(describing: error)
            let truncated = desc.count > 200 ? String(desc.prefix(200)) + "..." : desc
            KLog.log("[Packet] JSON parse error: \(truncated)", level: .error)
            return nil
        }
    }

    @MainActor static func identityPacket() -> NetworkPacket {
        let config = Config.shared
        return NetworkPacket(type: "kdeconnect.identity", body: [
            "deviceId": AnyCodable(config.deviceId),
            "deviceName": AnyCodable(config.deviceName),
            "deviceType": AnyCodable(config.deviceType),
            "protocolVersion": AnyCodable(7),
            "tcpPort": AnyCodable(config.tcpPort),
            "incomingCapabilities": AnyCodable(config.incomingCapabilities),
            "outgoingCapabilities": AnyCodable(config.outgoingCapabilities)
        ])
    }

    static func pairPacket(pair: Bool) -> NetworkPacket {
        return NetworkPacket(type: "kdeconnect.pair", body: [
            "pair": AnyCodable(pair)
        ])
    }
}

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // IMPORTANT: Int64 MUST come before Bool. Swift's JSONDecoder decodes JSON 1/0 as Bool,
        // which would corrupt numeric fields like batteryLevel, tcpPort when they equal 0 or 1.
        if let i = try? container.decode(Int64.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if let s = try? container.decode(String.self) { value = s }
        else if let a = try? container.decode([AnyCodable].self) { value = a.map { $0.value } }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = dict.mapValues { $0.value } }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // IMPORTANT: Bool MUST come first in encode. In Swift, Bool does NOT conform to
        // BinaryInteger, so `true as? Int` fails. But `1 as? Bool` also fails. So order
        // matters less here, but Bool first is conventional.
        // All integer types must be handled explicitly — Swift does NOT auto-bridge
        // UInt16/UInt32/etc to Int via `as?` pattern matching.
        switch value {
        case let b as Bool: try container.encode(b)
        case let i as Int: try container.encode(i)
        case let i as Int8: try container.encode(Int(i))
        case let i as Int16: try container.encode(Int(i))
        case let i as Int32: try container.encode(Int(i))
        case let i as Int64: try container.encode(i)
        case let u as UInt: try container.encode(u)
        case let u as UInt8: try container.encode(Int(u))
        case let u as UInt16: try container.encode(Int(u))
        case let u as UInt32: try container.encode(Int(u))
        case let u as UInt64: try container.encode(u)
        case let f as Float: try container.encode(Double(f))
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        case let a as [Any]: try container.encode(a.map { AnyCodable($0) })
        case let dict as [String: Any]: try container.encode(dict.mapValues { AnyCodable($0) })
        default: try container.encodeNil()
        }
    }
}
