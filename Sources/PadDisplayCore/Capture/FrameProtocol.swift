import Foundation

public enum VideoCodec: String, CaseIterable, Identifiable, Sendable {
    case hevc = "HEVC (H.265)"
    case h264 = "H.264"

    public var id: String { rawValue }
    public var wireName: String {
        switch self {
        case .hevc: return "hevc"
        case .h264: return "h264"
        }
    }
}

public struct PerformanceTuning: Sendable, Equatable {
    public let h264BitrateBps: Int
    public let hevcBitrateBps: Int
    public let jpegMaxFPS: Int
    public let jpegQuality: Double
    public let jpegScaleFactor: Double

    public init(
        h264BitrateBps: Int,
        hevcBitrateBps: Int,
        jpegMaxFPS: Int,
        jpegQuality: Double,
        jpegScaleFactor: Double
    ) {
        self.h264BitrateBps = h264BitrateBps
        self.hevcBitrateBps = hevcBitrateBps
        self.jpegMaxFPS = jpegMaxFPS
        self.jpegQuality = jpegQuality
        self.jpegScaleFactor = jpegScaleFactor
    }
}

public enum PerformanceProfile: String, CaseIterable, Identifiable, Sendable {
    case auto = "Auto"
    case ultraLowLatency = "Ultra-Low"
    case balanced = "Balanced"
    case sharpText = "Sharp"

    public var id: String { rawValue }

    public func resolvedTuning(isUSB: Bool = false, congested: Bool = false) -> PerformanceTuning {
        switch self {
        case .auto:
            if congested {
                return PerformanceProfile.ultraLowLatency.resolvedTuning(isUSB: isUSB, congested: false)
            }
            if isUSB {
                return PerformanceTuning(
                    h264BitrateBps: 20_000_000,
                    hevcBitrateBps: 15_000_000,
                    jpegMaxFPS: 60,
                    jpegQuality: 0.65,
                    jpegScaleFactor: 1.0
                )
            }
            return PerformanceProfile.balanced.resolvedTuning(isUSB: false, congested: false)
        case .ultraLowLatency:
            return PerformanceTuning(
                h264BitrateBps: 8_000_000,
                hevcBitrateBps: 6_000_000,
                jpegMaxFPS: 60,
                jpegQuality: 0.45,
                jpegScaleFactor: 0.75
            )
        case .balanced:
            return PerformanceTuning(
                h264BitrateBps: 12_000_000,
                hevcBitrateBps: 9_000_000,
                jpegMaxFPS: 45,
                jpegQuality: 0.55,
                jpegScaleFactor: 1.0
            )
        case .sharpText:
            return PerformanceTuning(
                h264BitrateBps: 20_000_000,
                hevcBitrateBps: 16_000_000,
                jpegMaxFPS: 35,
                jpegQuality: 0.75,
                jpegScaleFactor: 1.0
            )
        }
    }
}

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
    /// HEVC HEVCDecoderConfigurationRecord (`hvcC`) + 4-byte width + 4-byte height prefix:
    /// `[width: UInt32 BE][height: UInt32 BE][hvcC bytes...]`
    case hevcConfig = 0x05
    /// HEVC IDR keyframe in HVCC length-prefixed NALU format.
    case hevcKeyframe = 0x06
    /// HEVC non-IDR delta frame in HVCC length-prefixed NALU format.
    case hevcDelta = 0x07
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

    /// Helper for building `h264Config` (`avcC`) or `hevcConfig` (`hvcC`) payload:
    /// `[width: UInt32 BE][height: UInt32 BE][configBytes]`
    public static func makeVideoConfigPayload(width: Int, height: Int, configBytes: Data) -> Data {
        var payload = Data(capacity: 8 + configBytes.count)
        var wBE = UInt32(width).bigEndian
        var hBE = UInt32(height).bigEndian
        withUnsafeBytes(of: &wBE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &hBE) { payload.append(contentsOf: $0) }
        payload.append(configBytes)
        return payload
    }

    public static func makeH264ConfigPayload(width: Int, height: Int, avcC: Data) -> Data {
        makeVideoConfigPayload(width: width, height: height, configBytes: avcC)
    }

    public static func makeHEVCConfigPayload(width: Int, height: Int, hvcC: Data) -> Data {
        makeVideoConfigPayload(width: width, height: height, configBytes: hvcC)
    }
}
