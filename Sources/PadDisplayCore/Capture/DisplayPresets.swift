import Foundation

public enum DisplayOrientation: String, CaseIterable, Identifiable, Sendable {
    case landscape = "Landscape"
    case portrait = "Portrait"

    public var id: String { rawValue }
}

public struct DisplayPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let landscapeWidth: Int
    public let landscapeHeight: Int
    public let ppi: Int

    public init(id: String, name: String, landscapeWidth: Int, landscapeHeight: Int, ppi: Int) {
        self.id = id
        self.name = name
        self.landscapeWidth = landscapeWidth
        self.landscapeHeight = landscapeHeight
        self.ppi = ppi
    }

    public func logicalSize(orientation: DisplayOrientation) -> (width: Int, height: Int) {
        switch orientation {
        case .landscape:
            return (landscapeWidth, landscapeHeight)
        case .portrait:
            return (landscapeHeight, landscapeWidth)
        }
    }

    /// Returns even pixel dimensions suitable for H.264 4:2:0 encoding.
    public func pixelSize(orientation: DisplayOrientation, hiDPI: Bool) -> (width: Int, height: Int) {
        let logical = logicalSize(orientation: orientation)
        let scale = hiDPI ? 2 : 1
        let w = (logical.width * scale) & ~1
        let h = (logical.height * scale) & ~1
        return (max(w, 640), max(h, 480))
    }

    public static let allPresets: [DisplayPreset] = [
        DisplayPreset(id: "ipad-pro-13", name: "iPad Pro 13\" / 12.9\"", landscapeWidth: 1366, landscapeHeight: 1024, ppi: 264),
        DisplayPreset(id: "ipad-pro-11", name: "iPad Pro / Air 11\"", landscapeWidth: 1194, landscapeHeight: 834, ppi: 264),
        DisplayPreset(id: "ipad-10-9", name: "iPad 10.9\" / Air", landscapeWidth: 1180, landscapeHeight: 820, ppi: 264),
        DisplayPreset(id: "ipad-mini", name: "iPad mini 8.3\"", landscapeWidth: 1133, landscapeHeight: 744, ppi: 326),
        DisplayPreset(id: "fhd-1080p", name: "Standard 1080p (16:9)", landscapeWidth: 1920, landscapeHeight: 1080, ppi: 160),
    ]

    public static let `default` = allPresets[1] // iPad Pro / Air 11"
}
