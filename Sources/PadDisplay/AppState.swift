import Foundation
import SwiftUI
import CoreGraphics
import CGVirtualDisplayBridge
import PadDisplayCore

public enum ConnectionTab: String, CaseIterable, Identifiable {
    case wifi = "Wi-Fi"
    case usb = "USB Cable"

    public var id: String { rawValue }
}

public enum ProtocolTab: String, CaseIterable, Identifiable {
    case http = "Instant HTTP"
    case https = "60fps H.264"

    public var id: String { rawValue }
}

@MainActor
@Observable
public final class AppState {
    // User settings
    public var selectedPreset: DisplayPreset = .default
    public var orientation: DisplayOrientation = .landscape
    public var hiDPI: Bool = false
    public var autoMatchIPad: Bool = true
    public private(set) var matchedResolutionLabel: String?
    public var preferredCodec: VideoCodec = .hevc {
        didSet { server.updatePreferredCodec(preferredCodec) }
    }
    public var performanceProfile: PerformanceProfile = .auto {
        didSet {
            autoCongested = false
            cleanTelemetryTicks = 0
            applyPerformanceProfile()
        }
    }
    public var touchInputEnabled: Bool = true {
        didSet { inputInjector.isEnabled = touchInputEnabled }
    }
    public var connectionTab: ConnectionTab = .wifi
    public var protocolTab: ProtocolTab = .http
    public var preferLocalHostname: Bool = true
    public var requireAuth: Bool = true {
        didSet { server.updateSecurity(requireAuth: requireAuth, pinCode: pinCode) }
    }
    public private(set) var pinCode: String = StreamingServer.generatePIN()
    public private(set) var pendingApprovals: [PendingClientRequest] = []
    public var copiedFeedback: Bool = false

    // Live runtime state
    public private(set) var isRunning: Bool = false
    public private(set) var isStarting: Bool = false
    public private(set) var statusMessage: String = "Stopped"
    public private(set) var errorMessage: String?
    public private(set) var liveFPS: Double = 0
    public private(set) var telemetry: StreamTelemetry = StreamTelemetry()
    public private(set) var clients: ServerClientSummary = ServerClientSummary()
    public private(set) var network: NetworkSnapshot = NetworkDiscovery.currentSnapshot()
    public private(set) var accessibilityTrusted: Bool = InputInjector.isAccessibilityTrusted()
    public private(set) var httpsReady: Bool = false

    // Engine instances
    private var virtualDisplay: PDVirtualDisplay?
    private var lastAppliedMetrics: ClientDisplayMetrics?
    private var autoCongested: Bool = false
    private var lastObservedDroppedFrames: Int = 0
    private var cleanTelemetryTicks: Int = 0
    private let server = StreamingServer(httpPort: 8080, httpsPort: 8443)
    private let networkDiscovery = NetworkDiscovery()
    private let inputInjector = InputInjector()
    private var captureEngine: DisplayCaptureEngine?

    public init() {
        server.updateSecurity(requireAuth: requireAuth, pinCode: pinCode)
        setupCallbacks()
        networkDiscovery.start { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                let hadUSB = self.network.usbEndpoint != nil
                self.network = snapshot
                if !hadUSB && snapshot.usbEndpoint != nil {
                    self.connectionTab = .usb
                }
                self.applyPerformanceProfile()
            }
        }
    }

    public var activeURLString: String? {
        switch connectionTab {
        case .usb:
            guard let endpoint = network.usbEndpoint else { return nil }
            return protocolTab == .http
                ? endpoint.httpURL(port: server.httpPort)
                : endpoint.httpsURL(port: server.httpsPort)
        case .wifi:
            guard let endpoint = network.wifiEndpoint else { return nil }
            if preferLocalHostname {
                return protocolTab == .http
                    ? network.localHTTPURL(port: server.httpPort)
                    : network.localHTTPSURL(port: server.httpsPort)
            }
            return protocolTab == .http
                ? endpoint.httpURL(port: server.httpPort)
                : endpoint.httpsURL(port: server.httpsPort)
        }
    }

    public var secondaryWiFiIPString: String? {
        guard connectionTab == .wifi, preferLocalHostname, let ip = network.wifiEndpoint?.ipAddress else {
            return nil
        }
        return "IP: \(ip)"
    }

    public func refreshPermissions() {
        accessibilityTrusted = InputInjector.isAccessibilityTrusted()
    }

    public func regeneratePIN() {
        pinCode = StreamingServer.generatePIN()
        server.updateSecurity(requireAuth: requireAuth, pinCode: pinCode)
    }

    public func approveClient(_ id: UUID) {
        server.approveClient(id)
    }

    public func denyClient(_ id: UUID) {
        server.denyClient(id)
    }

    public func toggleRunning() {
        if isRunning {
            Task { await stop() }
        } else {
            Task { await start() }
        }
    }

    public func start() async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        errorMessage = nil
        statusMessage = "Creating virtual display…"

        let logical = selectedPreset.logicalSize(orientation: orientation)
        let pixels = selectedPreset.pixelSize(orientation: orientation, hiDPI: hiDPI)

        guard let display = PDVirtualDisplay(
            name: "PadDisplay",
            logicalWidth: UInt(logical.width),
            logicalHeight: UInt(logical.height),
            ppi: UInt(selectedPreset.ppi),
            hiDPI: hiDPI,
            refreshRate: 60.0
        ) else {
            isStarting = false
            errorMessage = "Could not create virtual display via CGVirtualDisplay."
            statusMessage = "Error"
            return
        }

        self.virtualDisplay = display
        inputInjector.setVirtualDisplayID(display.displayID)
        server.updateDisplaySize(width: pixels.width, height: pixels.height)

        do {
            statusMessage = "Starting streaming server…"
            let snap = NetworkDiscovery.currentSnapshot()
            self.network = snap
            try server.start(ips: snap.allIPs, hostname: snap.localHostname)
            self.httpsReady = server.isHTTPSRunning

            statusMessage = "Starting ScreenCaptureKit…"
            if captureEngine == nil {
                captureEngine = makeCaptureEngine()
            }
            applyPerformanceProfile()
            try await captureEngine?.start(
                displayID: display.displayID,
                pixelWidth: pixels.width,
                pixelHeight: pixels.height,
                fps: 60
            )

            isRunning = true
            isStarting = false
            statusMessage = "Ready — scan QR on iPad Safari"
            refreshPermissions()
        } catch {
            await stop()
            isStarting = false
            errorMessage = error.localizedDescription
            statusMessage = "Failed to start"
        }
    }

    public func stop() async {
        await captureEngine?.stop()
        server.stop()
        virtualDisplay?.teardown()
        virtualDisplay = nil
        inputInjector.setVirtualDisplayID(kCGNullDirectDisplay)
        isRunning = false
        liveFPS = 0
        telemetry = StreamTelemetry()
        clients = ServerClientSummary()
        matchedResolutionLabel = nil
        lastAppliedMetrics = nil
        autoCongested = false
        lastObservedDroppedFrames = 0
        cleanTelemetryTicks = 0
        statusMessage = "Stopped"
    }

    public func applyClientMetricsIfEnabled(_ metrics: ClientDisplayMetrics) {
        guard autoMatchIPad, isRunning, let display = virtualDisplay else { return }
        if lastAppliedMetrics == metrics { return }
        lastAppliedMetrics = metrics

        let geo = metrics.resolvedGeometry(hiDPI: hiDPI)
        orientation = metrics.orientation
        matchedResolutionLabel = "\(geo.logicalWidth)×\(geo.logicalHeight)"

        Task {
            _ = display.applyLogicalWidth(
                UInt(geo.logicalWidth),
                logicalHeight: UInt(geo.logicalHeight),
                hiDPI: hiDPI,
                refreshRate: 60.0
            )
            inputInjector.refreshDisplayBounds()
            server.updateDisplaySize(width: geo.pixelWidth, height: geo.pixelHeight)
            do {
                try await captureEngine?.start(
                    displayID: display.displayID,
                    pixelWidth: geo.pixelWidth,
                    pixelHeight: geo.pixelHeight,
                    fps: 60
                )
            } catch {
                errorMessage = "Auto-match resize error: \(error.localizedDescription)"
            }
        }
    }

    public func applyDisplaySettingsIfRunning() {
        guard isRunning, let display = virtualDisplay else { return }
        Task {
            let logical = selectedPreset.logicalSize(orientation: orientation)
            let pixels = selectedPreset.pixelSize(orientation: orientation, hiDPI: hiDPI)
            _ = display.applyLogicalWidth(
                UInt(logical.width),
                logicalHeight: UInt(logical.height),
                hiDPI: hiDPI,
                refreshRate: 60.0
            )
            inputInjector.refreshDisplayBounds()
            server.updateDisplaySize(width: pixels.width, height: pixels.height)
            do {
                try await captureEngine?.start(
                    displayID: display.displayID,
                    pixelWidth: pixels.width,
                    pixelHeight: pixels.height,
                    fps: 60
                )
            } catch {
                errorMessage = "Resize capture error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Private Wiring

    private func setupCallbacks() {
        server.onClientsChanged = { [weak self] summary in
            Task { @MainActor in
                guard let self else { return }
                self.clients = summary
                self.captureEngine?.updateDemand(CaptureDemand(
                    needsH264: summary.h264Count > 0,
                    needsHEVC: summary.hevcCount > 0,
                    needsJPEG: summary.jpegCount > 0
                ))
            }
        }

        server.onRequestKeyframe = { [weak self] in
            Task { @MainActor in
                self?.captureEngine?.h264Encoder.requestKeyframe()
                self?.captureEngine?.hevcEncoder.requestKeyframe()
            }
        }

        server.onPointerEvent = { [weak self] event in
            self?.inputInjector.handle(event)
        }

        server.onClientDisplayMetrics = { [weak self] metrics in
            Task { @MainActor in
                self?.applyClientMetricsIfEnabled(metrics)
            }
        }

        server.onTelemetryUpdate = { [weak self] stats in
            Task { @MainActor in
                guard let self else { return }
                self.telemetry = stats
                self.evaluateAutoPerformance(stats)
            }
        }

        server.onPendingApprovalsChanged = { [weak self] pending in
            Task { @MainActor in
                self?.pendingApprovals = pending
            }
        }

        server.onLog = { [weak self] msg in
            Task { @MainActor in
                self?.errorMessage = msg
            }
        }
    }

    public func applyPerformanceProfile() {
        let isUSB = (connectionTab == .usb && network.usbEndpoint != nil)
        let tuning = performanceProfile.resolvedTuning(isUSB: isUSB, congested: autoCongested)
        captureEngine?.applyPerformanceTuning(tuning)
    }

    private func evaluateAutoPerformance(_ stats: StreamTelemetry) {
        guard performanceProfile == .auto, isRunning, clients.totalCount > 0 else {
            lastObservedDroppedFrames = stats.droppedFrames
            return
        }
        let deltaDrops = max(0, stats.droppedFrames - lastObservedDroppedFrames)
        lastObservedDroppedFrames = stats.droppedFrames

        let isCongestedNow = deltaDrops >= 3 || stats.latencyMs > 35.0
        if isCongestedNow {
            cleanTelemetryTicks = 0
            if !autoCongested {
                autoCongested = true
                applyPerformanceProfile()
            }
        } else if autoCongested {
            cleanTelemetryTicks += 1
            if cleanTelemetryTicks >= 8 {
                autoCongested = false
                cleanTelemetryTicks = 0
                applyPerformanceProfile()
            }
        }
    }

    private func makeCaptureEngine() -> DisplayCaptureEngine {
        let srv = self.server
        let engine = DisplayCaptureEngine(
            onH264Packet: { packet in
                srv.broadcastH264(packet)
            },
            onHEVCPacket: { packet in
                srv.broadcastHEVC(packet)
            },
            onJPEGPacket: { packet in
                srv.broadcastJPEG(packet)
            }
        )
        engine.onEncodeLatencyUpdate = { ms in
            srv.updateEncodeLatency(ms)
        }
        engine.onFPSUpdate = { [weak self] fps in
            Task { @MainActor in
                self?.liveFPS = fps
            }
        }
        engine.onError = { [weak self] msg in
            Task { @MainActor in
                self?.errorMessage = msg
            }
        }
        return engine
    }
}
