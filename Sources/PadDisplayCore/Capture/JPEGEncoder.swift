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
    private var minIntervalNs: UInt64
    private var quality: CGFloat
    private var scaleFactor: CGFloat
    private var smoothedEncodeMs: Double = 0
    private var lastLatencyReportNs: UInt64 = 0
    private let onPacket: PacketHandler
    public var onEncodeLatencyUpdate: (@Sendable (Double) -> Void)?

    public init(maxFPS: Int = 45, quality: CGFloat = 0.55, scaleFactor: CGFloat = 1.0, onPacket: @escaping PacketHandler) {
        self.context = CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false,
            .priorityRequestLow: false
        ])
        self.minIntervalNs = UInt64(1_000_000_000 / max(1, maxFPS))
        self.quality = quality
        self.scaleFactor = min(max(scaleFactor, 0.5), 1.0)
        self.onPacket = onPacket
    }

    public func updateSettings(maxFPS: Int, quality: CGFloat, scaleFactor: CGFloat = 1.0) {
        lock.withLock {
            self.minIntervalNs = UInt64(1_000_000_000 / max(1, min(maxFPS, 60)))
            self.quality = min(max(quality, 0.25), 0.95)
            self.scaleFactor = min(max(scaleFactor, 0.5), 1.0)
        }
    }

    public func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        let now = DispatchTime.now().uptimeNanoseconds
        let params: (quality: CGFloat, scale: CGFloat)? = lock.withLock {
            if isEncoding || (now &- lastEncodedTime) < minIntervalNs {
                return nil
            }
            isEncoding = true
            lastEncodedTime = now
            return (quality, scaleFactor)
        }
        guard let params else { return }

        // Retain CVPixelBuffer for async encoding off the ScreenCaptureKit callback thread.
        nonisolated(unsafe) let retainedBuffer = pixelBuffer
        let pts = presentationTimeStamp

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.withLock { self.isEncoding = false }
            }

            let encodeStartNs = DispatchTime.now().uptimeNanoseconds
            var ciImage = CIImage(cvPixelBuffer: retainedBuffer)
            if params.scale < 0.99 {
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: params.scale, y: params.scale))
            }
            let options: [CIImageRepresentationOption: Any] = [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: params.quality
            ]
            guard let jpegData = self.context.jpegRepresentation(of: ciImage, colorSpace: self.colorSpace, options: options) else {
                return
            }

            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- encodeStartNs) / 1_000_000.0
            self.recordEncodeLatency(elapsedMs)

            let timestampUs: UInt64 = pts.isValid && pts.seconds.isFinite && pts.seconds >= 0
                ? UInt64(pts.seconds * 1_000_000)
                : UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)

            let packet = EncodedFramePacket(type: .jpegFrame, timestampUs: timestampUs, payload: jpegData)
            self.onPacket(packet)
        }
    }

    private func recordEncodeLatency(_ sampleMs: Double) {
        let now = DispatchTime.now().uptimeNanoseconds
        let report: Double? = lock.withLock {
            smoothedEncodeMs = smoothedEncodeMs == 0 ? sampleMs : (smoothedEncodeMs * 0.8 + sampleMs * 0.2)
            guard now &- lastLatencyReportNs >= 500_000_000 else { return nil }
            lastLatencyReportNs = now
            return smoothedEncodeMs
        }
        if let report {
            onEncodeLatencyUpdate?(report)
        }
    }
}
