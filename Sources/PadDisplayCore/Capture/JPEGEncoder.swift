import Foundation
import CoreImage
import CoreVideo
import CoreMedia

/// Fast hardware-backed JPEG encoder used for zero-setup HTTP (`ws://`) fallback mode.
/// Applies FPS throttling and backpressure dropping so frames never queue up.
public final class JPEGEncoder: @unchecked Sendable {
    public typealias PacketHandler = @Sendable (EncodedFramePacket) -> Void

    private let context: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let queue = DispatchQueue(label: "com.paddisplay.jpeg-encoder", qos: .userInteractive)
    private let lock = NSLock()
    private var isEncoding = false
    private var lastEncodedTime: UInt64 = 0
    private let minIntervalNs: UInt64
    private let quality: CGFloat
    private let onPacket: PacketHandler

    public init(maxFPS: Int = 24, quality: CGFloat = 0.65, onPacket: @escaping PacketHandler) {
        self.context = CIContext(options: [.useSoftwareRenderer: false])
        self.minIntervalNs = UInt64(1_000_000_000 / max(1, maxFPS))
        self.quality = quality
        self.onPacket = onPacket
    }

    public func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldEncode: Bool = lock.withLock {
            if isEncoding || (now - lastEncodedTime) < minIntervalNs {
                return false
            }
            isEncoding = true
            lastEncodedTime = now
            return true
        }
        guard shouldEncode else { return }

        // Retain CVPixelBuffer for async encoding off the ScreenCaptureKit callback thread.
        nonisolated(unsafe) let retainedBuffer = pixelBuffer
        let pts = presentationTimeStamp

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.withLock { self.isEncoding = false }
            }

            let ciImage = CIImage(cvPixelBuffer: retainedBuffer)
            let options: [CIImageRepresentationOption: Any] = [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: self.quality
            ]
            guard let jpegData = self.context.jpegRepresentation(of: ciImage, colorSpace: self.colorSpace, options: options) else {
                return
            }

            let timestampUs: UInt64 = pts.isValid && pts.seconds.isFinite && pts.seconds >= 0
                ? UInt64(pts.seconds * 1_000_000)
                : UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)

            let packet = EncodedFramePacket(type: .jpegFrame, timestampUs: timestampUs, payload: jpegData)
            self.onPacket(packet)
        }
    }
}
