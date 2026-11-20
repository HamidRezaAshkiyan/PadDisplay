import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

public struct PointerEventMessage: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        case move
        case down
        case drag
        case up
        case rightClick
        case scroll
    }

    public let action: Action
    /// Normalized [0.0, 1.0] X coordinate across the virtual display.
    public let x: Double
    /// Normalized [0.0, 1.0] Y coordinate across the virtual display.
    public let y: Double
    /// Optional scroll delta X (pixels) for `.scroll`.
    public let dx: Double?
    /// Optional scroll delta Y (pixels) for `.scroll`.
    public let dy: Double?

    public init(action: Action, x: Double, y: Double, dx: Double? = nil, dy: Double? = nil) {
        self.action = action
        self.x = x
        self.y = y
        self.dx = dx
        self.dy = dy
    }
}

/// Maps normalized iPad touch/Apple Pencil events onto the macOS virtual display via CGEvent.
public final class InputInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var virtualDisplayID: CGDirectDisplayID = kCGNullDirectDisplay
    public var isEnabled: Bool {
        get { lock.withLock { _isEnabled } }
        set { lock.withLock { _isEnabled = newValue } }
    }
    private var _isEnabled: Bool = true

    public init() {}

    public func setVirtualDisplayID(_ id: CGDirectDisplayID) {
        lock.withLock { virtualDisplayID = id }
    }

    public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Pure coordinate mapping helper (unit-tested).
    public static func mapNormalizedPoint(x: Double, y: Double, into bounds: CGRect) -> CGPoint {
        let clampedX = min(max(x, 0.0), 1.0)
        let clampedY = min(max(y, 0.0), 1.0)
        return CGPoint(
            x: bounds.origin.x + clampedX * bounds.size.width,
            y: bounds.origin.y + clampedY * bounds.size.height
        )
    }

    public func handle(_ event: PointerEventMessage) {
        let (enabled, displayID) = lock.withLock { (_isEnabled, virtualDisplayID) }
        guard enabled, displayID != kCGNullDirectDisplay, Self.isAccessibilityTrusted() else { return }

        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let point = Self.mapNormalizedPoint(x: event.x, y: event.y, into: bounds)

        switch event.action {
        case .move:
            postMouse(type: .mouseMoved, at: point, button: .left)
        case .down:
            postMouse(type: .leftMouseDown, at: point, button: .left)
        case .drag:
            postMouse(type: .leftMouseDragged, at: point, button: .left)
        case .up:
            postMouse(type: .leftMouseUp, at: point, button: .left)
        case .rightClick:
            postMouse(type: .rightMouseDown, at: point, button: .right)
            postMouse(type: .rightMouseUp, at: point, button: .right)
        case .scroll:
            let dy = Int32((event.dy ?? 0).rounded())
            let dx = Int32((event.dx ?? 0).rounded())
            postMouse(type: .mouseMoved, at: point, button: .left)
            if let scrollEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: dy,
                wheel2: dx,
                wheel3: 0
            ) {
                scrollEvent.location = point
                scrollEvent.post(tap: .cghidEventTap)
            }
        }
    }

    private func postMouse(type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        if let cgEvent = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) {
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}
