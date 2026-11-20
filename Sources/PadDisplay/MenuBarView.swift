import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import PadDisplayCore

struct MenuBarView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            Divider()
            connectionSection
            Divider()
            displaySettingsSection
            Divider()
            permissionsAndFooterSection
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            state.refreshPermissions()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.isRunning ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text("PadDisplay")
                        .font(.headline)
                }
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: { state.toggleRunning() }) {
                Text(state.isStarting ? "Starting…" : (state.isRunning ? "Stop" : "Start"))
                    .frame(minWidth: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(state.isRunning ? .red : .accentColor)
            .disabled(state.isStarting)
        }
    }

    private var statusSubtitle: String {
        if !state.isRunning { return state.statusMessage }
        if state.clients.totalCount > 0 {
            let mode: String
            if state.clients.hevcCount > 0 {
                mode = "HEVC"
            } else if state.clients.h264Count > 0 {
                mode = "H.264"
            } else {
                mode = "HTTP"
            }
            return "\(state.clients.totalCount) iPad connected (\(mode) • \(Int(state.liveFPS.rounded())) FPS)"
        }
        return state.statusMessage
    }

    // MARK: - Connection & QR

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Connection", selection: $state.connectionTab) {
                ForEach(ConnectionTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            Picker("Mode", selection: $state.protocolTab) {
                ForEach(ProtocolTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            if let urlString = state.activeURLString {
                HStack(spacing: 12) {
                    if let qr = generateQRCode(from: urlString) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 104, height: 104)
                            .padding(6)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.connectionTab == .usb ? "USB Wired Link" : "Wi-Fi Link")
                            .font(.subheadline.weight(.semibold))

                        Text(urlString)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)

                        if let ipHint = state.secondaryWiFiIPString {
                            Text(ipHint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Button(state.copiedFeedback ? "Copied!" : "Copy URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(urlString, forType: .string)
                            state.copiedFeedback = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                state.copiedFeedback = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if state.protocolTab == .https {
                            Text("Requires 1-time CA trust from HTTP mode.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if state.connectionTab == .wifi {
                    Toggle("Use stable .local URL (recommended for Home Screen)", isOn: $state.preferLocalHostname)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            } else if state.connectionTab == .usb {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No USB network interface detected")
                        .font(.subheadline.weight(.medium))
                    Text("Plug in your iPad via USB and enable:\nSystem Settings → General → Sharing → Internet Sharing → iPad USB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text("No active Wi-Fi IPv4 address found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = state.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Display Settings

    private var displaySettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Virtual Display")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Preset", selection: $state.selectedPreset) {
                ForEach(DisplayPreset.allPresets) { preset in
                    Text(preset.name).tag(preset)
                }
            }
            .onChange(of: state.selectedPreset) { _, _ in
                state.applyDisplaySettingsIfRunning()
            }

            HStack {
                Picker("Orientation", selection: $state.orientation) {
                    ForEach(DisplayOrientation.allCases) { o in
                        Text(o.rawValue).tag(o)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: state.orientation) { _, _ in
                    state.applyDisplaySettingsIfRunning()
                }
            }

            Picker("Codec", selection: $state.preferredCodec) {
                ForEach(VideoCodec.allCases) { codec in
                    Text(codec.rawValue).tag(codec)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Toggle("HiDPI (Retina 2×)", isOn: $state.hiDPI)
                    .onChange(of: state.hiDPI) { _, _ in
                        state.applyDisplaySettingsIfRunning()
                    }
                Spacer()
                Toggle("Touch / Pencil", isOn: $state.touchInputEnabled)
            }
            .toggleStyle(.checkbox)
            .font(.caption)
        }
    }

    // MARK: - Permissions & Footer

    private var permissionsAndFooterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.accessibilityTrusted {
                HStack {
                    Image(systemName: "hand.tap")
                        .foregroundStyle(.orange)
                    Text("Accessibility needed for Touch/Pencil")
                        .font(.caption)
                    Spacer()
                    Button("Grant") {
                        _ = InputInjector.isAccessibilityTrusted(prompt: true)
                        InputInjector.openAccessibilitySettings()
                    }
                    .controlSize(.small)
                }
            }

            HStack {
                Button("Screen Recording…") {
                    InputInjector.openScreenRecordingSettings()
                }
                .buttonStyle(.link)
                .font(.caption)

                Spacer()

                Button("Quit PadDisplay") {
                    Task {
                        await state.stop()
                        NSApplication.shared.terminate(nil)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - QR Generator

    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 104, height: 104))
    }
}
