import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

public struct CaptureDemand: Sendable, Equatable {
    public var needsH264: Bool
    public var needsHEVC: Bool
    public var needsJPEG: Bool

    public init(needsH264: Bool = false, needsHEVC: Bool = false, needsJPEG: Bool = false) {
        self.needsH264 = needsH264
        self.needsHEVC = needsHEVC
        self.needsJPEG = needsJPEG
    }
}

/// Captures a macOS virtual display via ScreenCaptureKit and feeds H.264 / JPEG encoders.
public final class DisplayCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public enum CaptureError: LocalizedError {
        case displayNotFound(CGDirectDisplayID)

        public var errorDescription: String? {
            switch self {
            case .displayNotFound(let id):
                return "Virtual display (ID \(id)) did not appear in ScreenCaptureKit. Ensure Screen Recording permission is granted."
            }
        }
    }

    private let sampleQueue = DispatchQueue(label: "com.paddisplay.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var demand = CaptureDemand()
    private var frameCountInWindow = 0
    private var lastFPSReportTime = DispatchTime.now().uptimeNanoseconds

    public let h264Encoder: H264Encoder
    public let hevcEncoder: H264Encoder
    public let jpegEncoder: JPEGEncoder
    public var onFPSUpdate: (@Sendable (Double) -> Void)?
    public var onError: (@Sendable (String) -> Void)?

    public init(
        onH264Packet: @escaping H264Encoder.PacketHandler,
        onHEVCPacket: @escaping H264Encoder.PacketHandler,
        onJPEGPacket: @escaping JPEGEncoder.PacketHandler
    ) {
        self.h264Encoder = H264Encoder(codec: .h264, bitrateBps: 12_000_000, onPacket: onH264Packet)
        self.hevcEncoder = H264Encoder(codec: .hevc, bitrateBps: 9_000_000, onPacket: onHEVCPacket)
        self.jpegEncoder = JPEGEncoder(maxFPS: 24, quality: 0.65, onPacket: onJPEGPacket)
        super.init()
    }

    public func updateDemand(_ newDemand: CaptureDemand) {
        let (h264BecameActive, hevcBecameActive) = lock.withLock { () -> (Bool, Bool) in
            let wasH264 = demand.needsH264
            let wasHEVC = demand.needsHEVC
            demand = newDemand
            return (!wasH264 && newDemand.needsH264, !wasHEVC && newDemand.needsHEVC)
        }
        if h264BecameActive {
            h264Encoder.requestKeyframe()
        }
        if hevcBecameActive {
            hevcEncoder.requestKeyframe()
        }
    }

    public func start(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, fps: Int = 60) async throws {
        await stop()

        // macOS can take ~100-400ms to expose a freshly created CGVirtualDisplay in SCShareableContent.
        var targetDisplay: SCDisplay?
        for _ in 0..<10 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let found = content.displays.first(where: { $0.displayID == displayID }) {
                targetDisplay = found
                break
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }

        guard let targetDisplay else {
            throw CaptureError.displayNotFound(displayID)
        }

        try h264Encoder.configure(width: pixelWidth, height: pixelHeight, fps: fps)
        try? hevcEncoder.configure(width: pixelWidth, height: pixelHeight, fps: fps)

        let filter = SCContentFilter(display: targetDisplay, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 3

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await newStream.startCapture()

        lock.withLock {
            self.stream = newStream
        }
    }

    public func stop() async {
        let existing = lock.withLock { () -> SCStream? in
            let s = self.stream
            self.stream = nil
            return s
        }
        if let existing {
            try? await existing.stopCapture()
        }
        h264Encoder.invalidate()
        hevcEncoder.invalidate()
        onFPSUpdate?(0)
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // Ignore blank/idle status frames from ScreenCaptureKit
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        let currentDemand = lock.withLock { demand }
        guard currentDemand.needsH264 || currentDemand.needsHEVC || currentDemand.needsJPEG else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if currentDemand.needsH264 {
            h264Encoder.encode(pixelBuffer: pixelBuffer, presentationTimeStamp: pts)
        }
        if currentDemand.needsHEVC {
            hevcEncoder.encode(pixelBuffer: pixelBuffer, presentationTimeStamp: pts)
        }
        if currentDemand.needsJPEG {
            jpegEncoder.encode(pixelBuffer: pixelBuffer, presentationTimeStamp: pts)
        }

        recordFrameForFPS()
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("Capture stopped: \(error.localizedDescription)")
    }

    private func recordFrameForFPS() {
        let now = DispatchTime.now().uptimeNanoseconds
        let reportedFPS: Double? = lock.withLock {
            frameCountInWindow += 1
            let elapsed = now - lastFPSReportTime
            guard elapsed >= 1_000_000_000 else { return nil }
            let fps = Double(frameCountInWindow) / (Double(elapsed) / 1_000_000_000.0)
            frameCountInWindow = 0
            lastFPSReportTime = now
            return fps
        }
        if let reportedFPS {
            onFPSUpdate?(reportedFPS)
        }
    }
}
