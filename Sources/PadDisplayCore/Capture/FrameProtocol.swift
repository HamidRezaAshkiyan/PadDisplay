import Foundation

/// Compact binary framing protocol shared between PadDisplay Mac server and iPad Safari WebClient.
///
/// Layout:
/// - Byte 0: FrameType (`UInt8`)
/// - Bytes 1..8: Presentation timestamp in microseconds (`UInt64`, big-endian)
/// - Bytes 9..N: Payload bytes
public enum FrameType: UInt8, Sendable {
    /// H.264 AVCDecoderConfigurationRecord (`avcC`) + 4-byte width + 4-byte height prefix:
    /// `[width: UInt32 BE][height: UInt32 BE][avcC bytes...]`
    case h264Config = 0x01
    /// H.264 IDR keyframe in AVCC length-prefixed NALU format.
    case h264Keyframe = 0x02
    /// H.264 non-IDR delta frame in AVCC length-prefixed NALU format.
    case h264Delta = 0x03
    /// Standalone JPEG image frame (zero-setup HTTP fallback mode).
    case jpegFrame = 0x04
}

public struct EncodedFramePacket: Sendable, Equatable {
    public let type: FrameType
    public let timestampUs: UInt64
    public let payload: Data

    public static let headerSize = 9

    public init(type: FrameType, timestampUs: UInt64, payload: Data) {
        self.type = type
        self.timestampUs = timestampUs
        self.payload = payload
    }

    public func serialize() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(type.rawValue)
        var tsBE = timestampUs.bigEndian
        withUnsafeBytes(of: &tsBE) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    public static func deserialize(_ data: Data) -> EncodedFramePacket? {
        guard data.count >= headerSize,
              let type = FrameType(rawValue: data[data.startIndex]) else {
            return nil
        }
        let tsStart = data.index(after: data.startIndex)
        let tsEnd = data.index(tsStart, offsetBy: 8)
        var tsBE: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &tsBE) { dest in
            data.copyBytes(to: dest, from: tsStart..<tsEnd)
        }
        let payload = data.subdata(in: tsEnd..<data.endIndex)
        return EncodedFramePacket(type: type, timestampUs: UInt64(bigEndian: tsBE), payload: payload)
    }

    /// Helper for building `h264Config` payload: `[width: UInt32 BE][height: UInt32 BE][avcC]`
    public static func makeH264ConfigPayload(width: Int, height: Int, avcC: Data) -> Data {
        var payload = Data(capacity: 8 + avcC.count)
        var wBE = UInt32(width).bigEndian
        var hBE = UInt32(height).bigEndian
        withUnsafeBytes(of: &wBE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &hBE) { payload.append(contentsOf: $0) }
        payload.append(avcC)
        return payload
    }
}
