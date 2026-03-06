import Foundation

struct FramePacket {
    static let magic: UInt32 = 0x54524252 // "TRBR"

    let sequenceNumber: UInt32
    let timestamp: UInt64
    let isKeyframe: Bool
    let qualityLevel: QualityLevel
    let deltaPercent: UInt8  // 0-100, frame delta as percentage
    let parameterSets: [Data]?
    let frameData: Data

    func serialize() -> Data {
        var packet = Data()

        // Header: magic(4) + seq(4) + ts(8) + flags(1) + quality(1) + delta(1) = 19 bytes
        appendUInt32(&packet, Self.magic)
        appendUInt32(&packet, sequenceNumber)
        appendUInt64(&packet, timestamp)
        packet.append(isKeyframe ? 1 : 0)
        packet.append(qualityLevel.rawValue)
        packet.append(deltaPercent)

        // Parameter sets (keyframes only)
        if isKeyframe, let paramSets = parameterSets {
            packet.append(UInt8(paramSets.count))
            for ps in paramSets {
                appendUInt16(&packet, UInt16(ps.count))
                packet.append(ps)
            }
        }

        // Frame data
        appendUInt32(&packet, UInt32(frameData.count))
        packet.append(frameData)

        // Wrap with length prefix for TCP framing
        var framed = Data()
        appendUInt32(&framed, UInt32(packet.count))
        framed.append(packet)
        return framed
    }

    static func deserialize(from data: Data) -> FramePacket? {
        guard data.count >= 19 else { return nil }
        var offset = 0

        let magic = readUInt32(data, offset: &offset)
        guard magic == Self.magic else { return nil }

        let seq = readUInt32(data, offset: &offset)
        let ts = readUInt64(data, offset: &offset)
        let flags = data[offset]; offset += 1
        let isKey = (flags & 1) != 0
        let quality = QualityLevel(rawValue: data[offset]) ?? .quality; offset += 1
        let delta = data[offset]; offset += 1

        var paramSets: [Data]?
        if isKey {
            guard offset < data.count else { return nil }
            let count = Int(data[offset]); offset += 1
            var sets = [Data]()
            for _ in 0..<count {
                guard offset + 2 <= data.count else { return nil }
                let size = Int(readUInt16(data, offset: &offset))
                guard offset + size <= data.count else { return nil }
                sets.append(data.subdata(in: offset..<offset+size))
                offset += size
            }
            paramSets = sets
        }

        guard offset + 4 <= data.count else { return nil }
        let frameSize = Int(readUInt32(data, offset: &offset))
        guard offset + frameSize <= data.count else { return nil }
        let frameData = data.subdata(in: offset..<offset+frameSize)

        return FramePacket(
            sequenceNumber: seq,
            timestamp: ts,
            isKeyframe: isKey,
            qualityLevel: quality,
            deltaPercent: delta,
            parameterSets: paramSets,
            frameData: frameData
        )
    }
}

// MARK: - Binary helpers

private func appendUInt16(_ data: inout Data, _ value: UInt16) {
    var v = value.bigEndian
    data.append(Data(bytes: &v, count: 2))
}

private func appendUInt32(_ data: inout Data, _ value: UInt32) {
    var v = value.bigEndian
    data.append(Data(bytes: &v, count: 4))
}

private func appendUInt64(_ data: inout Data, _ value: UInt64) {
    var v = value.bigEndian
    data.append(Data(bytes: &v, count: 8))
}

private func readUInt16(_ data: Data, offset: inout Int) -> UInt16 {
    let value = data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    offset += 2
    return value
}

private func readUInt32(_ data: Data, offset: inout Int) -> UInt32 {
    let value = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    offset += 4
    return value
}

private func readUInt64(_ data: Data, offset: inout Int) -> UInt64 {
    let value = data.subdata(in: offset..<offset+8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
    offset += 8
    return value
}
