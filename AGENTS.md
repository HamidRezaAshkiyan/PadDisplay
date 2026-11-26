# AGENTS.md — PadDisplay

## Overview
**PadDisplay** is a native macOS menu bar app that turns an iPad into an extended second monitor over Wi-Fi or wired USB cable with **no iOS app required**. It creates a real macOS virtual display via private `CGVirtualDisplay` APIs, captures it with `ScreenCaptureKit`, encodes frames with `VideoToolbox` (H.264) or JPEG, streams over WebSocket (HTTP `:8080` or HTTPS `:8443`) to a Safari PWA client (`WebCodecs` `VideoDecoder`), and injects iPad touch/Apple Pencil events back into macOS via `CGEvent`.

## Tech Stack & Requirements
- **Platform:** macOS 14.0+ (Apple Silicon recommended; `LSUIElement=true` menu bar agent).
- **Languages & Toolchain:** Swift 6.0 (`swift-tools-version: 6.0`) + Objective-C bridge (`CGVirtualDisplayBridge`), vanilla HTML/CSS/JS PWA client. No Xcode IDE required—builds purely with SwiftPM (`swift`).
- **Apple Frameworks:** `SwiftUI`, `AppKit`, `CoreGraphics`, `ScreenCaptureKit`, `VideoToolbox`, `CoreMedia`, `CoreVideo`, `CoreImage`, `Network`, `Security`, `ApplicationServices`.
- **Zero External Swift Dependencies:** Pure Apple SDKs + SwiftPM.

## Repository Structure
```text
PadDisplay/
├── Package.swift                           # SwiftPM manifest (4 targets)
├── Assets/                                 # AppIcon-1024.png, AppIcon.icns
├── scripts/build-app.sh                    # Builds, assembles, and ad-hoc signs build/PadDisplay.app
├── Sources/
│   ├── CGVirtualDisplayBridge/             # Obj-C wrapper over private CGVirtualDisplay APIs
│   │   ├── include/PDVirtualDisplay.h
│   │   └── PDVirtualDisplay.m
│   ├── PadDisplayCore/                     # Core library (virtual display, capture, encoding, server, input)
│   │   ├── Capture/
│   │   │   ├── DisplayCaptureEngine.swift  # ScreenCaptureKit capture pipeline
│   │   │   ├── DisplayPresets.swift        # iPad resolution/HiDPI presets (Landscape/Portrait)
│   │   │   ├── FrameProtocol.swift         # Binary WebSocket frame header/protocol
│   │   │   ├── H264Encoder.swift           # VideoToolbox hardware H.264 encoder
│   │   │   └── JPEGEncoder.swift           # Hardware JPEG fallback encoder
│   │   ├── Input/InputInjector.swift       # CGEvent mouse/touch/scroll injector
│   │   ├── Server/
│   │   │   ├── StreamingServer.swift       # Network.framework HTTP (:8080) & HTTPS (:8443) + WS server
│   │   │   ├── WebSocketCodec.swift        # RFC 6455 WebSocket framing
│   │   │   ├── CertManager.swift           # Local Root CA & leaf TLS cert + .mobileconfig generator
│   │   │   └── NetworkDiscovery.swift      # Wi-Fi & iPad USB interface detection
│   │   └── Resources/WebClient/            # Bundled Safari PWA (index.html, app.js, styles.css, manifest.json)
│   ├── PadDisplay/                         # Menu bar SwiftUI executable
│   │   ├── PadDisplayApp.swift             # @main MenuBarExtra entry point
│   │   ├── AppState.swift                  # Observable app lifecycle & streaming coordinator
│   │   └── MenuBarView.swift               # Menu bar popover UI (QR code, presets, Wi-Fi/USB tabs)
│   └── PadDisplaySelfTest/main.swift       # Automated self-test executable
└── .github/workflows/                      # ci.yml (macos-15) & release.yml
```

## Architecture & Key Flows
- **Entry Point:** `Sources/PadDisplay/PadDisplayApp.swift` mounts a SwiftUI `MenuBarExtra(.window)` backed by `AppState`.
- **Virtual Display & Capture:** `PDVirtualDisplay` (`CGVirtualDisplayBridge`) creates a virtual display using `DisplayPresets`. `DisplayCaptureEngine` captures frames via `ScreenCaptureKit` and routes them to `H264Encoder` (for HTTPS/WebCodecs `:8443`) or `JPEGEncoder` (for instant HTTP `:8080`).
- **Transport & PWA Client:** `StreamingServer` serves `Resources/WebClient/` and upgrades `/ws` connections via `WebSocketCodec`. Frames are sent using `FrameProtocol`. `CertManager` generates a local Root CA and serves a `.mobileconfig` profile so iPad Safari trusts `:8443` (unlocking `WebCodecs` `VideoDecoder` in secure context).
- **Input Loop:** Touch and Apple Pencil gestures in `WebClient/app.js` send normalized coordinates back over WebSocket to `InputInjector`, which maps them onto the virtual display's `CGEvent` coordinate space.

## Development & Commands
```bash
# Build debug
swift build

# Run automated self-test suite
swift run PadDisplaySelfTest

# Build, bundle, and ad-hoc codesign build/PadDisplay.app (debug or release)
./scripts/build-app.sh release
open build/PadDisplay.app
```

## Configuration & Environment
- No `.env` files or external secrets.
- **Ports:** HTTP `:8080` (instant JPEG over WebSocket), HTTPS `:8443` (60fps H.264 WebCodecs).
- **macOS Permissions:** Requires **Screen Recording** (capture) and **Accessibility** (touch/Apple Pencil input injection).
- **Bundle Metadata:** `CFBundleIdentifier` (`com.paddisplay.app`), `CFBundleShortVersionString`, and `CFBundleVersion` are generated inline inside `scripts/build-app.sh`.

## Conventions & Gotchas
- **Private CoreGraphics API:** `CGVirtualDisplayBridge` dynamically/privately bridges `CGVirtualDisplay`; keep Obj-C bridging isolated in `Sources/CGVirtualDisplayBridge`.
- **SwiftPM Resource Bundle:** `PadDisplayCore` copies `Resources/WebClient` as a bundle resource (`PadDisplay_PadDisplayCore.bundle`). `scripts/build-app.sh` copies this bundle into `PadDisplay.app/Contents/Resources/` — changes to `WebClient/` require rebuilding/re-bundling.
- **Ad-hoc Signing & TCC:** `scripts/build-app.sh` ad-hoc signs with `--identifier "com.paddisplay.app"`. Re-signing locally can occasionally require toggling Screen Recording / Accessibility permissions in System Settings.
- **No XCTest target:** Automated verification runs via the executable target `swift run PadDisplaySelfTest` (used in `.github/workflows/ci.yml`).
