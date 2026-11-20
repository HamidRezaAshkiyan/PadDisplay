import Foundation
import Network
import Security

public enum ClientStreamMode: String, Sendable {
    case h264
    case jpeg
}

public struct ServerClientSummary: Sendable, Equatable {
    public let h264Count: Int
    public let jpegCount: Int

    public var totalCount: Int { h264Count + jpegCount }

    public init(h264Count: Int = 0, jpegCount: Int = 0) {
        self.h264Count = h264Count
        self.jpegCount = jpegCount
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
    private var displaySize: (width: Int, height: Int) = (1194, 834)
    private var httpsActive: Bool = false

    public var onClientsChanged: (@Sendable (ServerClientSummary) -> Void)?
    public var onRequestKeyframe: (@Sendable () -> Void)?
    public var onPointerEvent: (@Sendable (PointerEventMessage) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    public init(httpPort: UInt16 = 8080, httpsPort: UInt16 = 8443, certManager: CertManager = CertManager()) {
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.certManager = certManager
    }

    public func updateDisplaySize(width: Int, height: Int) {
        lock.withLock { displaySize = (width, height) }
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
            return (h, hs, c)
        }
        http?.cancel()
        https?.cancel()
        for conn in activeConns {
            conn.close()
        }
        notifyClientsChanged()
    }

    public func broadcastH264(_ packet: EncodedFramePacket) {
        let wsFrame = WebSocketCodec.encodeServerFrame(opcode: .binary, payload: packet.serialize())
        if packet.type == .h264Config {
            lock.withLock { cachedH264Config = wsFrame }
        }

        let targets = lock.withLock {
            connections.values.filter { $0.wsMode == .h264 }
        }
        let isCritical = (packet.type == .h264Config || packet.type == .h264Keyframe)
        for client in targets {
            client.sendWebSocketFrame(wsFrame, isCritical: isCritical)
        }
    }

    public func broadcastJPEG(_ packet: EncodedFramePacket) {
        let wsFrame = WebSocketCodec.encodeServerFrame(opcode: .binary, payload: packet.serialize())
        let targets = lock.withLock {
            connections.values.filter { $0.wsMode == .jpeg }
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
        let removed = lock.withLock { connections.removeValue(forKey: id) }
        if removed?.wsMode != nil {
            notifyClientsChanged()
        }
    }

    fileprivate func clientUpgradedToWebSocket(_ client: ClientConnection, mode: ClientStreamMode) {
        notifyClientsChanged()
        if mode == .h264 {
            if let config = lock.withLock({ cachedH264Config }) {
                client.sendWebSocketFrame(config, isCritical: true)
            }
            onRequestKeyframe?()
        }
    }

    fileprivate func handleWebSocketText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let pointer = try? JSONDecoder().decode(PointerEventMessage.self, from: data) {
            onPointerEvent?(pointer)
            return
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cmd = obj["cmd"] as? String, cmd == "keyframe" {
            onRequestKeyframe?()
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
            let (size, httpsOK) = lock.withLock { (displaySize, httpsActive) }
            let json = """
            {"httpPort":\(httpPort),"httpsPort":\(httpsPort),"httpsAvailable":\(httpsOK ? "true" : "false"),"width":\(size.width),"height":\(size.height)}
            """
            return ("200 OK", "application/json", [], Data(json.utf8))
        default:
            return ("404 Not Found", "text/plain", [], Data("Not Found".utf8))
        }
    }

    private func loadWebAsset(_ filename: String, contentType: String) -> (String, String, [String], Data) {
        if let url = Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "WebClient"),
           let data = try? Data(contentsOf: url) {
            return ("200 OK", contentType, ["Cache-Control: no-cache"], data)
        }
        return ("404 Not Found", "text/plain", [], Data("Missing asset: \(filename)".utf8))
    }

    private func notifyClientsChanged() {
        let summary = lock.withLock { () -> ServerClientSummary in
            var h264 = 0
            var jpeg = 0
            for c in connections.values {
                switch c.wsMode {
                case .h264: h264 += 1
                case .jpeg: jpeg += 1
                case nil: break
                }
            }
            return ServerClientSummary(h264Count: h264, jpegCount: jpeg)
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
    private var inFlightSends: Int = 0
    private var isClosed: Bool = false

    var wsMode: ClientStreamMode? {
        lock.withLock { _wsMode }
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

    func sendWebSocketFrame(_ frameData: Data, isCritical: Bool) {
        let allowed = lock.withLock { () -> Bool in
            guard !isClosed, _wsMode != nil else { return false }
            let limit = (_wsMode == .h264) ? (isCritical ? 16 : 4) : 2
            if inFlightSends >= limit {
                return false
            }
            inFlightSends += 1
            return true
        }
        guard allowed else { return }

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
                        server?.handleWebSocketText(text)
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
            if path.contains("mode=h264") {
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
