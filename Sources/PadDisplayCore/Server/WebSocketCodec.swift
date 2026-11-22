import Foundation
import CryptoKit

/// Minimal, standards-compliant RFC 6455 WebSocket handshake & framing codec.
public enum WebSocketOpcode: UInt8, Sendable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

public struct WebSocketFrame: Sendable, Equatable {
    public let fin: Bool
    public let opcode: WebSocketOpcode
    public let payload: Data

    public init(fin: Bool = true, opcode: WebSocketOpcode, payload: Data) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
    }
}

public enum WebSocketCodec {
    private static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Computes RFC 6455 `Sec-WebSocket-Accept` response header value.
    public static func acceptKey(for clientKey: String) -> String {
        let combined = clientKey.trimmingCharacters(in: .whitespacesAndNewlines) + magicGUID
        let digest = Insecure.SHA1.hash(data: Data(combined.utf8))
        return Data(digest).base64EncodedString()
    }

    /// Encodes a server-to-client WebSocket frame (unmasked per RFC 6455).
    public static func encodeServerFrame(opcode: WebSocketOpcode, payload: Data) -> Data {
        var out = Data(capacity: 10 + payload.count)
        let firstByte: UInt8 = 0x80 | opcode.rawValue
        out.append(firstByte)

        let len = payload.count
        if len < 126 {
            out.append(UInt8(len))
        } else if len <= 0xFFFF {
            out.append(126)
            var len16 = UInt16(len).bigEndian
            withUnsafeBytes(of: &len16) { out.append(contentsOf: $0) }
        } else {
            out.append(127)
            var len64 = UInt64(len).bigEndian
            withUnsafeBytes(of: &len64) { out.append(contentsOf: $0) }
        }
        out.append(payload)
        return out
    }

    /// Single-allocation encoder for a binary `EncodedFramePacket` WebSocket frame.
    /// Avoids allocating an intermediate serialized `Data` buffer before WebSocket framing.
    public static func encodeBinaryPacket(_ packet: EncodedFramePacket) -> Data {
        let payloadLen = EncodedFramePacket.headerSize + packet.payload.count
        let wsHeaderSize: Int
        if payloadLen < 126 {
            wsHeaderSize = 2
        } else if payloadLen <= 0xFFFF {
            wsHeaderSize = 4
        } else {
            wsHeaderSize = 10
        }

        var out = Data(capacity: wsHeaderSize + payloadLen)
        out.append(0x80 | WebSocketOpcode.binary.rawValue)

        if payloadLen < 126 {
            out.append(UInt8(payloadLen))
        } else if payloadLen <= 0xFFFF {
            out.append(126)
            var len16 = UInt16(payloadLen).bigEndian
            withUnsafeBytes(of: &len16) { out.append(contentsOf: $0) }
        } else {
            out.append(127)
            var len64 = UInt64(payloadLen).bigEndian
            withUnsafeBytes(of: &len64) { out.append(contentsOf: $0) }
        }

        out.append(packet.type.rawValue)
        var tsBE = packet.timestampUs.bigEndian
        withUnsafeBytes(of: &tsBE) { out.append(contentsOf: $0) }
        out.append(packet.payload)
        return out
    }

    /// Parses as many complete WebSocket frames as available from `buffer`, consuming parsed bytes.
    public static func parseFrames(from buffer: inout Data) -> [WebSocketFrame] {
        var frames: [WebSocketFrame] = []

        while true {
            guard buffer.count >= 2 else { break }

            let b0 = buffer[buffer.startIndex]
            let b1 = buffer[buffer.startIndex + 1]
            let fin = (b0 & 0x80) != 0
            let opcodeRaw = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var payloadLen = UInt64(b1 & 0x7F)

            var offset = 2
            if payloadLen == 126 {
                guard buffer.count >= offset + 2 else { break }
                payloadLen = (UInt64(buffer[buffer.startIndex + offset]) << 8)
                    | UInt64(buffer[buffer.startIndex + offset + 1])
                offset += 2
            } else if payloadLen == 127 {
                guard buffer.count >= offset + 8 else { break }
                var len64: UInt64 = 0
                for i in 0..<8 {
                    len64 = (len64 << 8) | UInt64(buffer[buffer.startIndex + offset + i])
                }
                payloadLen = len64
                offset += 8
            }

            let maskLen = masked ? 4 : 0
            let totalLen = offset + maskLen + Int(payloadLen)
            guard buffer.count >= totalLen else { break }

            var payload = Data(count: Int(payloadLen))
            if masked {
                let maskStart = buffer.startIndex + offset
                let m0 = buffer[maskStart]
                let m1 = buffer[maskStart + 1]
                let m2 = buffer[maskStart + 2]
                let m3 = buffer[maskStart + 3]
                let mask = [m0, m1, m2, m3]
                let dataStart = maskStart + 4
                for i in 0..<Int(payloadLen) {
                    payload[i] = buffer[dataStart + i] ^ mask[i & 3]
                }
            } else if payloadLen > 0 {
                let dataStart = buffer.startIndex + offset
                payload = buffer.subdata(in: dataStart..<(dataStart + Int(payloadLen)))
            }

            buffer.removeFirst(totalLen)

            if let opcode = WebSocketOpcode(rawValue: opcodeRaw) {
                frames.append(WebSocketFrame(fin: fin, opcode: opcode, payload: payload))
            }
        }

        return frames
    }
}
