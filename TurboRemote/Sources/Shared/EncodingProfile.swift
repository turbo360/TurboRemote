import Foundation

// MARK: - Connection Mode (client-selected)

enum ConnectionMode: UInt8, CaseIterable, Sendable {
    case studio     = 0
    case broadband  = 1
    case mobile     = 2
    case lowBandwidth = 3

    var label: String {
        switch self {
        case .studio:       return "Studio"
        case .broadband:    return "Broadband"
        case .mobile:       return "Mobile"
        case .lowBandwidth: return "Low BW"
        }
    }

    var icon: String {
        switch self {
        case .studio:       return "diamond.fill"
        case .broadband:    return "triangle.fill"
        case .mobile:       return "circle.inset.filled"
        case .lowBandwidth: return "chevron.down"
        }
    }

    var maxBitrateMbps: Double {
        switch self {
        case .studio:       return .infinity
        case .broadband:    return 80
        case .mobile:       return 30
        case .lowBandwidth: return 10
        }
    }

    var gradingSafe: Bool {
        switch self {
        case .studio, .broadband: return true
        case .mobile:             return false  // static only
        case .lowBandwidth:       return false
        }
    }
}

// MARK: - Encoding Quality Level (per-frame decision)

enum QualityLevel: UInt8, Sendable {
    case lossless  = 0  // < 2% delta, full bandwidth
    case highQuality = 1  // 2-15% delta
    case quality   = 2  // 15-40% delta or moderate bandwidth
    case lowBW     = 3  // > 40% delta or severe congestion
    case skipped   = 4  // no change detected

    var label: String {
        switch self {
        case .lossless:    return "LOSSLESS"
        case .highQuality: return "HI-Q"
        case .quality:     return "QUALITY"
        case .lowBW:       return "LOW BW"
        case .skipped:     return "IDLE"
        }
    }

    var badgeColor: (r: Double, g: Double, b: Double) {
        switch self {
        case .lossless:    return (0.2, 0.8, 0.3)   // green
        case .highQuality: return (0.3, 0.5, 1.0)   // blue
        case .quality:     return (1.0, 0.75, 0.2)   // amber
        case .lowBW:       return (1.0, 0.3, 0.3)    // red
        case .skipped:     return (0.5, 0.5, 0.5)    // grey
        }
    }

    var vtQuality: Float {
        switch self {
        case .lossless:    return 1.0
        case .highQuality: return 0.85
        case .quality:     return 0.65
        case .lowBW:       return 0.4
        case .skipped:     return 0
        }
    }
}

// MARK: - Control Message (client -> host)

struct ControlMessage {
    static let magic: UInt32 = 0x5452434D // "TRCM"

    enum MessageType: UInt8 {
        case modeChange = 1
        case auth       = 2
        case authResult = 3
    }

    // MARK: - Mode Change

    static func modeChangeData(_ mode: ConnectionMode) -> Data {
        return buildMessage(type: .modeChange, payload: Data([mode.rawValue]))
    }

    static func parseModeChange(from data: Data) -> ConnectionMode? {
        guard let (type, payload) = parseMessage(data), type == .modeChange, payload.count >= 1 else { return nil }
        return ConnectionMode(rawValue: payload[0])
    }

    // MARK: - Authentication

    static func authData(passphraseHash: Data) -> Data {
        return buildMessage(type: .auth, payload: passphraseHash)
    }

    static func parseAuth(from data: Data) -> Data? {
        guard let (type, payload) = parseMessage(data), type == .auth else { return nil }
        return payload
    }

    static func authResultData(_ success: Bool) -> Data {
        return buildMessage(type: .authResult, payload: Data([success ? 1 : 0]))
    }

    static func parseAuthResult(from data: Data) -> Bool? {
        guard let (type, payload) = parseMessage(data), type == .authResult, payload.count >= 1 else { return nil }
        return payload[0] == 1
    }

    // MARK: - Helpers

    private static func buildMessage(type: MessageType, payload: Data) -> Data {
        var msg = Data()
        var m = magic.bigEndian
        msg.append(Data(bytes: &m, count: 4))
        msg.append(type.rawValue)
        msg.append(payload)

        var framed = Data()
        var len = UInt32(msg.count).bigEndian
        framed.append(Data(bytes: &len, count: 4))
        framed.append(msg)
        return framed
    }

    private static func parseMessage(_ data: Data) -> (MessageType, Data)? {
        guard data.count >= 5 else { return nil }
        let m = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard m == magic else { return nil }
        guard let type = MessageType(rawValue: data[4]) else { return nil }
        let payload = data.count > 5 ? data.subdata(in: 5..<data.count) : Data()
        return (type, payload)
    }
}
