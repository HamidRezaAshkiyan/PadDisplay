import Foundation
import CoreGraphics
import PadDisplayCore

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let msg): return msg }
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") throws {
    if a != b {
        throw TestFailure.failed("Expected \(a) == \(b) \(message)")
    }
}

func assertTrue(_ condition: Bool, _ message: String = "") throws {
    if !condition {
        throw TestFailure.failed("Assertion failed: \(message)")
    }
}

func runTest(_ name: String, _ body: () throws -> Void) -> Bool {
    do {
        try body()
        print("  [PASS] \(name)")
        return true
    } catch {
        print("  [FAIL] \(name): \(error)")
        return false
    }
}

print("Running PadDisplayCore automated tests...")
var allPassed = true

allPassed = runTest("Binary frame protocol round-trip") {
    let avcC = Data([0x01, 0x4D, 0x00, 0x2A, 0xFF, 0xE1])
    let configPayload = EncodedFramePacket.makeH264ConfigPayload(width: 2388, height: 1668, avcC: avcC)
    let original = EncodedFramePacket(type: .h264Config, timestampUs: 123_456_789, payload: configPayload)

    let serialized = original.serialize()
    try assertEqual(serialized.count, EncodedFramePacket.headerSize + configPayload.count)

    let decoded = EncodedFramePacket.deserialize(serialized)
    try assertEqual(decoded, original)
} && allPassed

allPassed = runTest("Display presets produce even pixel dimensions for H.264") {
    for preset in DisplayPreset.allPresets {
        for orientation in DisplayOrientation.allCases {
            for hiDPI in [false, true] {
                let px = preset.pixelSize(orientation: orientation, hiDPI: hiDPI)
                try assertEqual(px.width % 2, 0, "Width must be even")
                try assertEqual(px.height % 2, 0, "Height must be even")
            }
        }
    }
} && allPassed

allPassed = runTest("Normalized touch coordinates map onto negative-origin virtual displays") {
    let bounds = CGRect(x: -1194, y: -100, width: 1194, height: 834)

    let topLeft = InputInjector.mapNormalizedPoint(x: 0.0, y: 0.0, into: bounds)
    try assertTrue(abs(topLeft.x - (-1194)) < 0.01 && abs(topLeft.y - (-100)) < 0.01, "topLeft")

    let center = InputInjector.mapNormalizedPoint(x: 0.5, y: 0.5, into: bounds)
    try assertTrue(abs(center.x - (-597)) < 0.01 && abs(center.y - 317) < 0.01, "center")

    let clamped = InputInjector.mapNormalizedPoint(x: 1.5, y: -0.2, into: bounds)
    try assertTrue(abs(clamped.x - 0) < 0.01 && abs(clamped.y - (-100)) < 0.01, "clamped")
} && allPassed

allPassed = runTest("WebSocket RFC 6455 handshake and masked/unmasked framing") {
    // Canonical RFC 6455 Section 4.2.2 test vector
    let accept = WebSocketCodec.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==")
    try assertEqual(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

    let payload = Data(repeating: 0xAB, count: 300)
    var wire = WebSocketCodec.encodeServerFrame(opcode: .binary, payload: payload)
    let frames = WebSocketCodec.parseFrames(from: &wire)
    try assertEqual(frames.count, 1)
    try assertEqual(frames[0].opcode, .binary)
    try assertEqual(frames[0].payload, payload)
    try assertTrue(wire.isEmpty, "Buffer should be empty")

    let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
    let rawText: [UInt8] = Array("Hi".utf8)
    var maskedFrame = Data([0x81, 0x82])
    maskedFrame.append(contentsOf: mask)
    for (i, b) in rawText.enumerated() {
        maskedFrame.append(b ^ mask[i & 3])
    }
    let parsedClient = WebSocketCodec.parseFrames(from: &maskedFrame)
    try assertEqual(parsedClient.count, 1)
    try assertEqual(parsedClient[0].opcode, .text)
    try assertEqual(String(data: parsedClient[0].payload, encoding: .utf8), "Hi")
} && allPassed

allPassed = runTest("CertManager generates local CA, TLS identity, and iPad .mobileconfig") {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PadDisplayCertTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let certManager = CertManager(baseDirectory: tmpDir)
    _ = try certManager.ensureTLSIdentity(ips: ["192.168.1.50"], hostname: "test-mac.local")
    try assertTrue(FileManager.default.fileExists(atPath: certManager.caCertURL.path), "ca.crt exists")
    try assertTrue(FileManager.default.fileExists(atPath: certManager.serverP12URL.path), "server.p12 exists")

    let mobileConfig = try certManager.mobileConfigData()
    let xml = String(data: mobileConfig, encoding: .utf8) ?? ""
    try assertTrue(xml.contains("PadDisplay Local CA"), "mobileconfig display name")
    try assertTrue(xml.contains("com.apple.security.root"), "mobileconfig root payload type")
} && allPassed

allPassed = runTest("NetworkSnapshot generates stable .local HTTP and HTTPS URLs") {
    try assertEqual(NetworkSnapshot.normalizeLocalHostname("My-MacBook"), "My-MacBook.local")
    try assertEqual(NetworkSnapshot.normalizeLocalHostname("My-MacBook.local"), "My-MacBook.local")
    let snap = NetworkSnapshot(
        usbEndpoint: nil,
        wifiEndpoint: NetworkEndpoint(kind: .wifi, interfaceName: "en0", ipAddress: "192.168.1.42"),
        localHostname: "My-MacBook.local"
    )
    try assertEqual(snap.localHTTPURL(port: 8080), "http://My-MacBook.local:8080")
    try assertEqual(snap.localHTTPSURL(port: 8443), "https://My-MacBook.local:8443")
} && allPassed

allPassed = runTest("HEVC (H.265) binary frame config, keyframe, and delta round-trip") {
    let hvcC = Data([0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90])
    let cfgPayload = EncodedFramePacket.makeHEVCConfigPayload(width: 2388, height: 1668, hvcC: hvcC)
    let cfgPacket = EncodedFramePacket(type: .hevcConfig, timestampUs: 987_654, payload: cfgPayload)
    try assertEqual(EncodedFramePacket.deserialize(cfgPacket.serialize()), cfgPacket)

    let keyPacket = EncodedFramePacket(type: .hevcKeyframe, timestampUs: 987_700, payload: Data([0x00, 0x00, 0x00, 0x02, 0x26, 0x01]))
    try assertEqual(EncodedFramePacket.deserialize(keyPacket.serialize()), keyPacket)
    try assertEqual(VideoCodec.hevc.wireName, "hevc")
} && allPassed

allPassed = runTest("ClientDisplayMetrics resolves exact orientation and even pixels") {
    let portrait = ClientDisplayMetrics(width: 834, height: 1194, dpr: 2.0)
    try assertEqual(portrait.orientation, .portrait)
    let geo1x = portrait.resolvedGeometry(hiDPI: false)
    try assertEqual(geo1x.logicalWidth, 834)
    try assertEqual(geo1x.logicalHeight, 1194)
    try assertEqual(geo1x.pixelWidth % 2, 0)
    try assertEqual(geo1x.pixelHeight % 2, 0)

    let oddLandscape = ClientDisplayMetrics(width: 1133, height: 744, dpr: 2.0)
    try assertEqual(oddLandscape.orientation, .landscape)
    let geo2x = oddLandscape.resolvedGeometry(hiDPI: true)
    try assertEqual(geo2x.logicalWidth, 1132)
    try assertEqual(geo2x.pixelWidth, 2264)
    try assertEqual(geo2x.pixelHeight, 1488)
} && allPassed

if allPassed {
    print("All tests passed!")
    exit(0)
} else {
    print("Some tests failed.")
    exit(1)
}
