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
    public var touchInputEnabled: Bool = true {
        didSet { inputInjector.isEnabled = touchInputEnabled }
    }
    public var connectionTab: ConnectionTab = .wifi
    public var protocolTab: ProtocolTab = .http
    public var copiedFeedback: Bool = false

    // Live runtime state
    public private(set) var isRunning: Bool = false
    public private(set) var isStarting: Bool = false
    public private(set) var statusMessage: String = "Stopped"
    public private(set) var errorMessage: String?
    public private(set) var liveFPS: Double = 0
    public private(set) var clients: ServerClientSummary = ServerClientSummary()
    public private(set) var network: NetworkSnapshot = NetworkDiscovery.currentSnapshot()
    public private(set) var accessibilityTrusted: Bool = InputInjector.isAccessibilityTrusted()
    public private(set) var httpsReady: Bool = false

    // Engine instances
    private var virtualDisplay: PDVirtualDisplay?
    private let server = StreamingServer(httpPort: 8080, httpsPort: 8443)
    private let networkDiscovery = NetworkDiscovery()
    private let inputInjector = InputInjector()
    private var captureEngine: DisplayCaptureEngine?

    public init() {
        setupCallbacks()
        networkDiscovery.start { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                let hadUSB = self.network.usbEndpoint != nil
                self.network = snapshot
                if !hadUSB && snapshot.usbEndpoint != nil {
                    self.connectionTab = .usb
                }
            }
        }
    }

    public var activeURLString: String? {
        let endpoint: NetworkEndpoint?
        switch connectionTab {
        case .usb:
            endpoint = network.usbEndpoint
        case .wifi:
            endpoint = network.wifiEndpoint
        }
        guard let endpoint else { return nil }
        switch protocolTab {
        case .http:
            return endpoint.httpURL(port: server.httpPort)
        case .https:
            return endpoint.httpsURL(port: server.httpsPort)
        }
    }

    public func refreshPermissions() {
        accessibilityTrusted = InputInjector.isAccessibilityTrusted()
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
        clients = ServerClientSummary()
        statusMessage = "Stopped"
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
                    needsJPEG: summary.jpegCount > 0
                ))
            }
        }

        server.onRequestKeyframe = { [weak self] in
            Task { @MainActor in
                self?.captureEngine?.h264Encoder.requestKeyframe()
            }
        }

        server.onPointerEvent = { [weak self] event in
            self?.inputInjector.handle(event)
        }

        server.onLog = { [weak self] msg in
            Task { @MainActor in
                self?.errorMessage = msg
            }
        }
    }

    private func makeCaptureEngine() -> DisplayCaptureEngine {
        let srv = self.server
        let engine = DisplayCaptureEngine(
            onH264Packet: { packet in
                srv.broadcastH264(packet)
            },
            onJPEGPacket: { packet in
                srv.broadcastJPEG(packet)
            }
        )
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
