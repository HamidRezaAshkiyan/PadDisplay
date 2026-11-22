import Foundation
import Network
import Security

public enum ClientStreamMode: String, Sendable {
    case h264
    case hevc
    case jpeg
}

public struct ServerClientSummary: Sendable, Equatable {
    public let h264Count: Int
    public let hevcCount: Int
    public let jpegCount: Int

    public var totalCount: Int { h264Count + hevcCount + jpegCount }

    public init(h264Count: Int = 0, hevcCount: Int = 0, jpegCount: Int = 0) {
        self.h264Count = h264Count
        self.hevcCount = hevcCount
        self.jpegCount = jpegCount
    }
}

public struct StreamTelemetry: Sendable, Equatable {
    public let bitrateMbps: Double
    public let latencyMs: Double
    public let droppedFrames: Int

    public init(bitrateMbps: Double = 0, latencyMs: Double = 0, droppedFrames: Int = 0) {
        self.bitrateMbps = bitrateMbps
        self.latencyMs = latencyMs
        self.droppedFrames = droppedFrames
    }

    public static func computeBitrateMbps(bytes: Int, elapsedSeconds: Double) -> Double {
        guard elapsedSeconds > 0, bytes > 0 else { return 0 }
        return (Double(bytes) * 8.0) / (elapsedSeconds * 1_000_000.0)
    }

    public var formattedSummary: String {
        let lat = latencyMs > 0 ? "\(Int(latencyMs.rounded())) ms" : "-- ms"
        let mbps = String(format: "%.1f Mbps", bitrateMbps)
        return "\(lat) • \(mbps) • \(droppedFrames) drop"
    }
}

public struct PendingClientRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let remoteAddress: String
    public let mode: ClientStreamMode

    public init(id: UUID, remoteAddress: String, mode: ClientStreamMode) {
        self.id = id
        self.remoteAddress = remoteAddress
        self.mode = mode
    }
}

/// Dual-port HTTP/WS (:8080) + HTTPS/WSS (:8443) server built purely on Apple's Network.framework.
public final class StreamingServer: @unchecked Sendable {
    public let httpPort: UInt16
    public let httpsPort: UInt16
    private let certManager: CertManager

    private let queue = DispatchQueue(label: "com.paddisplay.server", qos: .userInteractive)
    private let lock = NSLock()
    private var httpListener: NWListener?
    private var httpsListener: NWListener?
    private var connections: [UUID: ClientConnection] = [:]
    private var cachedH264Config: Data?
    private var cachedHEVCConfig: Data?
    private var displaySize: (width: Int, height: Int) = (1194, 834)
    private var preferredCodec: VideoCodec = .hevc
    private var httpsActive: Bool = false
    private var bytesSentInWindow: Int = 0
    private var lastTelemetryTick: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var latestBitrateMbps: Double = 0
    private var latestLatencyMs: Double = 0
    private var droppedFramesTotal: Int = 0
    private var requireAuth: Bool = true
    private var pinCode: String = StreamingServer.generatePIN()
    private var pendingApprovals: [UUID: PendingClientRequest] = [:]

    public var onClientsChanged: (@Sendable (ServerClientSummary) -> Void)?
    public var onRequestKeyframe: (@Sendable () -> Void)?
    public var onPointerEvent: (@Sendable (PointerEventMessage) -> Void)?
    public var onClientDisplayMetrics: (@Sendable (ClientDisplayMetrics) -> Void)?
    public var onTelemetryUpdate: (@Sendable (StreamTelemetry) -> Void)?
    public var onPendingApprovalsChanged: (@Sendable ([PendingClientRequest]) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    public init(httpPort: UInt16 = 8080, httpsPort: UInt16 = 8443, certManager: CertManager = CertManager()) {
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.certManager = certManager
    }

    public func updateDisplaySize(width: Int, height: Int) {
        lock.withLock { displaySize = (width, height) }
    }

    public func updatePreferredCodec(_ codec: VideoCodec) {
        lock.withLock { preferredCodec = codec }
    }

    public static func generatePIN() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    public static func verifyPIN(_ candidate: String, expected: String) -> Bool {
        let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return !expected.isEmpty && clean == expected
    }

    public func updateSecurity(requireAuth: Bool, pinCode: String) {
        lock.withLock {
            self.requireAuth = requireAuth
            self.pinCode = pinCode
        }
    }

    public func approveClient(_ id: UUID) {
        let client = lock.withLock { () -> ClientConnection? in
            pendingApprovals.removeValue(forKey: id)
            return connections[id]
        }
        notifyPendingApprovalsChanged()
        if let client {
            authorizeClient(client)
        }
    }

    public func denyClient(_ id: UUID) {
        let client = lock.withLock { () -> ClientConnection? in
            pendingApprovals.removeValue(forKey: id)
            return connections[id]
        }
        notifyPendingApprovalsChanged()
        if let client {
            let denied = WebSocketCodec.encodeServerFrame(
                opcode: .text,
                payload: Data("{\"cmd\":\"authDenied\"}".utf8)
            )
            client.sendControlFrame(denied)
            client.close()
        }
    }

    public var isHTTPSRunning: Bool {
        lock.withLock { httpsActive }
    }

    public func start(ips: [String], hostname: String) throws {
        stop()

        // 1. Plain HTTP + WS listener (zero-setup mode + .mobileconfig installer)
        let httpParams = NWParameters.tcp
        httpParams.allowLocalEndpointReuse = true
        let http = try NWListener(using: httpParams, on: NWEndpoint.Port(rawValue: httpPort)!)
        http.newConnectionHandler = { [weak self] nwConn in
            self?.accept(nwConn, isTLS: false)
        }
        http.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state {
                self?.onLog?("HTTP listener failed: \(err.localizedDescription)")
            }
        }
        http.start(queue: queue)
        lock.withLock { self.httpListener = http }

        // 2. HTTPS + WSS listener (60fps H.264 WebCodecs mode)
        do {
            let identity = try certManager.ensureTLSIdentity(ips: ips, hostname: hostname)
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)
            sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)

            let httpsParams = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            httpsParams.allowLocalEndpointReuse = true

            let https = try NWListener(using: httpsParams, on: NWEndpoint.Port(rawValue: httpsPort)!)
            https.newConnectionHandler = { [weak self] nwConn in
                self?.accept(nwConn, isTLS: true)
            }
            https.stateUpdateHandler = { [weak self] state in
                if case .failed(let err) = state {
                    self?.onLog?("HTTPS listener failed: \(err.localizedDescription)")
                }
            }
            https.start(queue: queue)
            lock.withLock {
                self.httpsListener = https
                self.httpsActive = true
            }
        } catch {
            lock.withLock { self.httpsActive = false }
            onLog?("HTTPS disabled (HTTP still active): \(error.localizedDescription)")
        }
    }

    public func stop() {
        let (http, https, activeConns) = lock.withLock {
            let h = self.httpListener
            let hs = self.httpsListener
            let c = Array(self.connections.values)
            self.httpListener = nil
            self.httpsListener = nil
            self.connections.removeAll()
            self.httpsActive = false
            self.bytesSentInWindow = 0
            self.latestBitrateMbps = 0
            self.latestLatencyMs = 0
            self.droppedFramesTotal = 0
            self.pendingApprovals.removeAll()
            return (h, hs, c)
        }
        http?.cancel()
        https?.cancel()
        for conn in activeConns {
            conn.close()
        }
        onTelemetryUpdate?(StreamTelemetry())
        notifyPendingApprovalsChanged()
        notifyClientsChanged()
    }

    public func broadcastH264(_ packet: EncodedFramePacket) {
        let wsFrame = WebSocketCodec.encodeServerFrame(opcode: .binary, payload: packet.serialize())
        if packet.type == .h264Config {
            lock.withLock { cachedH264Config = wsFrame }
        }

        let targets = lock.withLock {
            connections.values.filter { $0.wsMode == .h264 && $0.isAuthorized }
        }
        let isCritical = (packet.type == .h264Config || packet.type == .h264Keyframe)
        for client in targets {
            client.sendWebSocketFrame(wsFrame, isCritical: isCritical)
        }
    }

    public func broadcastHEVC(_ packet: EncodedFramePacket) {
        let wsFrame = WebSocketCodec.encodeServerFrame(opcode: .binary, payload: packet.serialize())
        if packet.type == .hevcConfig {
            lock.withLock { cachedHEVCConfig = wsFrame }
        }

        let targets = lock.withLock {
            connections.values.filter { $0.wsMode == .hevc && $0.isAuthorized }
        }
        let isCritical = (packet.type == .hevcConfig || packet.type == .hevcKeyframe)
        for client in targets {
            client.sendWebSocketFrame(wsFrame, isCritical: isCritical)
        }
    }

    public func broadcastJPEG(_ packet: EncodedFramePacket) {
        let wsFrame = WebSocketCodec.encodeServerFrame(opcode: .binary, payload: packet.serialize())
        let targets = lock.withLock {
            connections.values.filter { $0.wsMode == .jpeg && $0.isAuthorized }
        }
        for client in targets {
            client.sendWebSocketFrame(wsFrame, isCritical: false)
        }
    }

    // MARK: - Connection Lifecycle

    private func accept(_ nwConnection: NWConnection, isTLS: Bool) {
        let client = ClientConnection(
            nwConnection: nwConnection,
            isTLS: isTLS,
            queue: queue,
            server: self
        )
        lock.withLock { connections[client.id] = client }
        client.start()
    }

    fileprivate func removeClient(_ id: UUID) {
        let (removed, removedPending) = lock.withLock { () -> (ClientConnection?, Bool) in
            let r = connections.removeValue(forKey: id)
            let p = pendingApprovals.removeValue(forKey: id) != nil
            return (r, p)
        }
        if removedPending {
            notifyPendingApprovalsChanged()
        }
        if removed?.wsMode != nil {
            notifyClientsChanged()
        }
    }

    fileprivate func clientUpgradedToWebSocket(_ client: ClientConnection, mode: ClientStreamMode) {
        let needsAuth = lock.withLock { requireAuth }
        if !needsAuth {
            authorizeClient(client)
        } else {
            let prompt = WebSocketCodec.encodeServerFrame(
                opcode: .text,
                payload: Data("{\"cmd\":\"authRequired\"}".utf8)
            )
            client.sendControlFrame(prompt)
        }
    }

    private func authorizeClient(_ client: ClientConnection) {
        client.setAuthorized(true)
        let okFrame = WebSocketCodec.encodeServerFrame(
            opcode: .text,
            payload: Data("{\"cmd\":\"authOK\"}".utf8)
        )
        client.sendControlFrame(okFrame)
        notifyClientsChanged()

        if client.wsMode == .h264 {
            if let config = lock.withLock({ cachedH264Config }) {
                client.sendWebSocketFrame(config, isCritical: true)
            }
            onRequestKeyframe?()
        } else if client.wsMode == .hevc {
            if let config = lock.withLock({ cachedHEVCConfig }) {
                client.sendWebSocketFrame(config, isCritical: true)
            }
            onRequestKeyframe?()
        }
    }

    private func notifyPendingApprovalsChanged() {
        let list = lock.withLock { Array(pendingApprovals.values) }
        onPendingApprovalsChanged?(list)
    }

    fileprivate func recordSentBytes(_ count: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        let snapshot: StreamTelemetry? = lock.withLock {
            bytesSentInWindow += count
            let elapsedNs = now &- lastTelemetryTick
            guard elapsedNs >= 1_000_000_000 else { return nil }
            let elapsedSec = Double(elapsedNs) / 1_000_000_000.0
            latestBitrateMbps = StreamTelemetry.computeBitrateMbps(bytes: bytesSentInWindow, elapsedSeconds: elapsedSec)
            bytesSentInWindow = 0
            lastTelemetryTick = now
            return StreamTelemetry(
                bitrateMbps: latestBitrateMbps,
                latencyMs: latestLatencyMs,
                droppedFrames: droppedFramesTotal
            )
        }
        if let snapshot {
            onTelemetryUpdate?(snapshot)
        }
    }

    fileprivate func recordDroppedFrame() {
        lock.withLock { droppedFramesTotal += 1 }
    }

    fileprivate func handleWebSocketText(_ text: String, from client: ClientConnection) {
        guard let data = text.data(using: .utf8) else { return }

        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cmd = obj["cmd"] as? String {
            if cmd == "auth" {
                let candidate = (obj["pin"] as? String) ?? ""
                let expected = lock.withLock { pinCode }
                if Self.verifyPIN(candidate, expected: expected) {
                    authorizeClient(client)
                } else {
                    let fail = WebSocketCodec.encodeServerFrame(
                        opcode: .text,
                        payload: Data("{\"cmd\":\"authFailed\",\"reason\":\"Incorrect PIN\"}".utf8)
                    )
                    client.sendControlFrame(fail)
                }
                return
            } else if cmd == "requestApproval" {
                if let mode = client.wsMode {
                    let req = PendingClientRequest(
                        id: client.id,
                        remoteAddress: client.remoteAddress,
                        mode: mode
                    )
                    lock.withLock { pendingApprovals[client.id] = req }
                    notifyPendingApprovalsChanged()
                }
                return
            }

            // Gate all non-auth commands behind authorization
            guard client.isAuthorized else { return }

            if cmd == "keyframe" {
                onRequestKeyframe?()
            } else if cmd == "displayMetrics",
                      let w = (obj["width"] as? NSNumber)?.intValue,
                      let h = (obj["height"] as? NSNumber)?.intValue {
                let dpr = (obj["dpr"] as? NSNumber)?.doubleValue ?? 2.0
                onClientDisplayMetrics?(ClientDisplayMetrics(width: w, height: h, dpr: dpr))
            } else if cmd == "ping", let t = (obj["t"] as? NSNumber)?.doubleValue {
                let reportedRtt = (obj["rttMs"] as? NSNumber)?.doubleValue ?? 0
                let snap = lock.withLock { () -> StreamTelemetry in
                    if reportedRtt > 0 {
                        latestLatencyMs = reportedRtt / 2.0
                    }
                    return StreamTelemetry(
                        bitrateMbps: latestBitrateMbps,
                        latencyMs: latestLatencyMs,
                        droppedFrames: droppedFramesTotal
                    )
                }
                let pongJSON = String(
                    format: "{\"cmd\":\"pong\",\"t\":%.3f,\"bitrateMbps\":%.2f,\"dropped\":%d}",
                    t, snap.bitrateMbps, snap.droppedFrames
                )
                let pongFrame = WebSocketCodec.encodeServerFrame(opcode: .text, payload: Data(pongJSON.utf8))
                client.sendControlFrame(pongFrame)
                onTelemetryUpdate?(snap)
            }
            return
        }

        guard client.isAuthorized else { return }
        if let pointer = try? JSONDecoder().decode(PointerEventMessage.self, from: data) {
            onPointerEvent?(pointer)
        }
    }

    fileprivate func serveHTTPRequest(path: String) -> (status: String, contentType: String, extraHeaders: [String], body: Data) {
        let cleanPath = path.split(separator: "?").first.map(String.init) ?? "/"

        switch cleanPath {
        case "/", "/index.html":
            return loadWebAsset("index.html", contentType: "text/html; charset=utf-8")
        case "/app.js":
            return loadWebAsset("app.js", contentType: "application/javascript; charset=utf-8")
        case "/styles.css":
            return loadWebAsset("styles.css", contentType: "text/css; charset=utf-8")
        case "/manifest.json":
            return loadWebAsset("manifest.json", contentType: "application/manifest+json; charset=utf-8")
        case "/apple-touch-icon.png":
            return loadWebAsset("apple-touch-icon.png", contentType: "image/png")
        case "/icon-512.png":
            return loadWebAsset("icon-512.png", contentType: "image/png")
        case "/cert.mobileconfig":
            if let profile = try? certManager.mobileConfigData() {
                return (
                    "200 OK",
                    "application/x-apple-aspen-config",
                    ["Content-Disposition: attachment; filename=\"PadDisplayLocalCA.mobileconfig\""],
                    profile
                )
            }
            return ("500 Internal Server Error", "text/plain", [], Data("Failed to generate profile".utf8))
        case "/api/info":
            let (size, httpsOK, codec) = lock.withLock { (displaySize, httpsActive, preferredCodec) }
            let json = """
            {"httpPort":\(httpPort),"httpsPort":\(httpsPort),"httpsAvailable":\(httpsOK ? "true" : "false"),"width":\(size.width),"height":\(size.height),"preferredCodec":"\(codec.wireName)"}
            """
            return ("200 OK", "application/json", [], Data(json.utf8))
        default:
            return ("404 Not Found", "text/plain", [], Data("Not Found".utf8))
        }
    }

    private static let webResourceBundle: Bundle? = {
        let bundleName = "PadDisplay_PadDisplayCore.bundle"
        let candidates: [URL?] = [
            // Standard macOS .app bundle: Contents/Resources/PadDisplay_PadDisplayCore.bundle
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            // CLI / swift run: sibling of executable
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            // Framework / dynamic library resource locations
            Bundle(for: StreamingServer.self).resourceURL?.appendingPathComponent(bundleName),
            Bundle(for: StreamingServer.self).bundleURL.appendingPathComponent(bundleName)
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        if Bundle.main.url(forResource: "index.html", withExtension: nil, subdirectory: "WebClient") != nil {
            return Bundle.main
        }
        return nil
    }()

    public func loadWebAssetData(_ filename: String) -> Data? {
        guard let url = Self.webResourceBundle?.url(forResource: filename, withExtension: nil, subdirectory: "WebClient") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private func loadWebAsset(_ filename: String, contentType: String) -> (String, String, [String], Data) {
        if let data = loadWebAssetData(filename) {
            return ("200 OK", contentType, ["Cache-Control: no-cache"], data)
        }
        return ("404 Not Found", "text/plain", [], Data("Missing asset: \(filename)".utf8))
    }

    private func notifyClientsChanged() {
        let summary = lock.withLock { () -> ServerClientSummary in
            var h264 = 0
            var hevc = 0
            var jpeg = 0
            for c in connections.values where c.isAuthorized {
                switch c.wsMode {
                case .h264: h264 += 1
                case .hevc: hevc += 1
                case .jpeg: jpeg += 1
                case nil: break
                }
            }
            return ServerClientSummary(h264Count: h264, hevcCount: hevc, jpegCount: jpeg)
        }
        onClientsChanged?(summary)
    }
}

// MARK: - Per-Client Connection Handler

private final class ClientConnection: @unchecked Sendable {
    let id = UUID()
    private let nwConnection: NWConnection
    private let isTLS: Bool
    private let queue: DispatchQueue
    private weak var server: StreamingServer?

    private let lock = NSLock()
    private var readBuffer = Data()
    private var _wsMode: ClientStreamMode?
    private var _isAuthorized: Bool = false
    private var inFlightSends: Int = 0
    private var isClosed: Bool = false

    var wsMode: ClientStreamMode? {
        lock.withLock { _wsMode }
    }

    var isAuthorized: Bool {
        lock.withLock { _isAuthorized }
    }

    func setAuthorized(_ value: Bool) {
        lock.withLock { _isAuthorized = value }
    }

    var remoteAddress: String {
        switch nwConnection.endpoint {
        case .hostPort(let host, _):
            return "\(host)"
        default:
            return "iPad"
        }
    }

    init(nwConnection: NWConnection, isTLS: Bool, queue: DispatchQueue, server: StreamingServer) {
        self.nwConnection = nwConnection
        self.isTLS = isTLS
        self.queue = queue
        self.server = server
    }

    func start() {
        nwConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        nwConnection.start(queue: queue)
        receiveLoop()
    }

    func close() {
        let shouldNotify = lock.withLock { () -> Bool in
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        guard shouldNotify else { return }
        nwConnection.cancel()
        server?.removeClient(id)
    }

    func sendControlFrame(_ frameData: Data) {
        let ok = lock.withLock { !isClosed && _wsMode != nil }
        guard ok else { return }
        sendRaw(frameData)
    }

    func sendWebSocketFrame(_ frameData: Data, isCritical: Bool) {
        let allowed = lock.withLock { () -> Bool in
            guard !isClosed, _wsMode != nil else { return false }
            let isVideoStream = (_wsMode == .h264 || _wsMode == .hevc)
            let limit = isVideoStream ? (isCritical ? 16 : 4) : 2
            if inFlightSends >= limit {
                return false
            }
            inFlightSends += 1
            return true
        }
        guard allowed else {
            server?.recordDroppedFrame()
            return
        }

        server?.recordSentBytes(frameData.count)
        nwConnection.send(content: frameData, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.withLock { self.inFlightSends = max(0, self.inFlightSends - 1) }
            if error != nil {
                self.close()
            }
        })
    }

    private func receiveLoop() {
        nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.processIncoming(data)
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.receiveLoop()
        }
    }

    private func processIncoming(_ chunk: Data) {
        let isWS = lock.withLock { () -> Bool in
            readBuffer.append(chunk)
            return _wsMode != nil
        }

        if isWS {
            let frames = lock.withLock { WebSocketCodec.parseFrames(from: &readBuffer) }
            for frame in frames {
                switch frame.opcode {
                case .text:
                    if let text = String(data: frame.payload, encoding: .utf8) {
                        server?.handleWebSocketText(text, from: self)
                    }
                case .ping:
                    let pong = WebSocketCodec.encodeServerFrame(opcode: .pong, payload: frame.payload)
                    sendRaw(pong)
                case .close:
                    close()
                    return
                default:
                    break
                }
            }
        } else {
            tryHandleHTTPRequest()
        }
    }

    private func tryHandleHTTPRequest() {
        let delimiter = Data("\r\n\r\n".utf8)
        let headerData: Data? = lock.withLock {
            guard let range = readBuffer.range(of: delimiter) else { return nil }
            let req = readBuffer.subdata(in: readBuffer.startIndex..<range.lowerBound)
            readBuffer.removeSubrange(readBuffer.startIndex..<range.upperBound)
            return req
        }
        guard let headerData, let headerText = String(data: headerData, encoding: .utf8) else { return }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            close()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            close()
            return
        }
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }

        // Check for WebSocket upgrade
        if headers["upgrade"]?.lowercased() == "websocket",
           let clientKey = headers["sec-websocket-key"] {
            let mode: ClientStreamMode
            if path.contains("mode=hevc") {
                mode = .hevc
            } else if path.contains("mode=h264") {
                mode = .h264
            } else if path.contains("mode=jpeg") {
                mode = .jpeg
            } else {
                mode = isTLS ? .h264 : .jpeg
            }

            let accept = WebSocketCodec.acceptKey(for: clientKey)
            let handshake = """
            HTTP/1.1 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Accept: \(accept)\r
            \r\n
            """
            lock.withLock { _wsMode = mode }
            sendRaw(Data(handshake.utf8))
            server?.clientUpgradedToWebSocket(self, mode: mode)
            return
        }

        // Standard HTTP response
        guard let response = server?.serveHTTPRequest(path: path) else {
            close()
            return
        }

        var headerLines = [
            "HTTP/1.1 \(response.status)",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            "Connection: close"
        ]
        headerLines.append(contentsOf: response.extraHeaders)
        var raw = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        raw.append(response.body)

        nwConnection.send(content: raw, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func sendRaw(_ data: Data) {
        nwConnection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.close()
            }
        })
    }
}
