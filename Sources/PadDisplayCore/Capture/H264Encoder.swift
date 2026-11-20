import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Hardware-accelerated low-latency H.264 / HEVC (H.265) encoder using Apple VideoToolbox.
/// Produces AVCC/HVCC frames + `avcC`/`hvcC` decoder config directly consumable by Safari WebCodecs `VideoDecoder`.
public final class H264Encoder: @unchecked Sendable {
    public typealias PacketHandler = @Sendable (EncodedFramePacket) -> Void

    public let codec: VideoCodec
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var width: Int = 0
    private var height: Int = 0
    private var bitrateBps: Int
    private var forceNextKeyframe: Bool = true
    private var latestConfigPacket: EncodedFramePacket?
    private var frameCounter: Int64 = 0
    private let onPacket: PacketHandler

    public init(codec: VideoCodec = .h264, bitrateBps: Int? = nil, onPacket: @escaping PacketHandler) {
        self.codec = codec
        // HEVC achieves sharper text at ~30% lower bitrate than H.264
        self.bitrateBps = bitrateBps ?? (codec == .hevc ? 9_000_000 : 12_000_000)
        self.onPacket = onPacket
    }

    deinit {
        invalidate()
    }

    public var cachedConfigPacket: EncodedFramePacket? {
        lock.withLock { latestConfigPacket }
    }

    public func requestKeyframe() {
        lock.withLock {
            forceNextKeyframe = true
        }
    }

    public func configure(width: Int, height: Int, fps: Int = 60, bitrateBps: Int? = nil) throws {
        lock.lock()
        defer { lock.unlock() }

        let targetBitrate = bitrateBps ?? self.bitrateBps
        if self.session != nil, self.width == width, self.height == height, self.bitrateBps == targetBitrate {
            return
        }

        invalidateLocked()

        self.width = width
        self.height = height
        self.bitrateBps = targetBitrate
        self.forceNextKeyframe = true
        self.latestConfigPacket = nil

        var newSession: VTCompressionSession?
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: false
        ]

        let cmCodec: CMVideoCodecType = (codec == .hevc) ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: cmCodec,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )

        guard status == noErr, let session = newSession else {
            throw NSError(domain: "PadDisplay.VideoEncoder", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Failed to create \(codec.rawValue) VTCompressionSession (OSStatus \(status))"
            ])
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        let profileLevel = (codec == .hevc)
            ? kVTProfileLevel_HEVC_Main_AutoLevel
            : kVTProfileLevel_H264_Main_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 2) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate as CFNumber)

        // Cap peak bitrate to 1.5x average per second for smooth Wi-Fi streaming
        let bytesPerSec = (targetBitrate / 8) * 3 / 2
        let dataRateLimits: [NSNumber] = [NSNumber(value: bytesPerSec), NSNumber(value: 1)]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    public func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        lock.lock()
        guard let session = self.session else {
            lock.unlock()
            return
        }
        let shouldForceKey = self.forceNextKeyframe
        self.forceNextKeyframe = false
        let pts = presentationTimeStamp.isValid ? presentationTimeStamp : CMTime(value: frameCounter, timescale: 60)
        frameCounter += 1
        let encWidth = self.width
        let encHeight = self.height
        lock.unlock()

        var frameProps: CFDictionary?
        if shouldForceKey {
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProps,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer else { return }
            self.handleEncodedSample(sampleBuffer, width: encWidth, height: encHeight)
        }
    }

    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        invalidateLocked()
    }

    private func invalidateLocked() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    private func handleEncodedSample(_ sampleBuffer: CMSampleBuffer, width: Int, height: Int) {
        let isKeyframe = Self.isKeyframe(sampleBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampUs: UInt64 = pts.isValid && pts.seconds.isFinite && pts.seconds >= 0
            ? UInt64(pts.seconds * 1_000_000)
            : UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)

        let atomKey = (codec == .hevc) ? "hvcC" : "avcC"
        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let configAtom = Self.extractConfigAtom(named: atomKey, from: formatDesc) {
            let configPayload = EncodedFramePacket.makeVideoConfigPayload(width: width, height: height, configBytes: configAtom)
            let configType: FrameType = (codec == .hevc) ? .hevcConfig : .h264Config
            let configPacket = EncodedFramePacket(type: configType, timestampUs: timestampUs, payload: configPayload)
            lock.withLock {
                self.latestConfigPacket = configPacket
            }
            onPacket(configPacket)
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer, totalLength > 0 else { return }

        let frameData = Data(bytes: ptr, count: totalLength)
        let frameType: FrameType
        switch (codec, isKeyframe) {
        case (.hevc, true): frameType = .hevcKeyframe
        case (.hevc, false): frameType = .hevcDelta
        case (.h264, true): frameType = .h264Keyframe
        case (.h264, false): frameType = .h264Delta
        }

        let packet = EncodedFramePacket(type: frameType, timestampUs: timestampUs, payload: frameData)
        onPacket(packet)
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        return !notSync
    }

    private static func extractConfigAtom(named key: String, from formatDescription: CMFormatDescription) -> Data? {
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any],
              let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Any],
              let atomData = atoms[key] as? Data else {
            return nil
        }
        return atomData
    }
}
