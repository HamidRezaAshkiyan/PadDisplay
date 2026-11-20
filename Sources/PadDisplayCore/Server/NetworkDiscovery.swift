import Foundation
import Network
import Darwin

public struct NetworkEndpoint: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case usb = "USB Cable"
        case wifi = "Wi-Fi"
    }

    public let id: String
    public let kind: Kind
    public let interfaceName: String
    public let ipAddress: String

    public init(kind: Kind, interfaceName: String, ipAddress: String) {
        self.id = "\(kind.rawValue)-\(interfaceName)-\(ipAddress)"
        self.kind = kind
        self.interfaceName = interfaceName
        self.ipAddress = ipAddress
    }

    public func httpURL(port: UInt16 = 8080) -> String {
        "http://\(ipAddress):\(port)"
    }

    public func httpsURL(port: UInt16 = 8443) -> String {
        "https://\(ipAddress):\(port)"
    }
}

public struct NetworkSnapshot: Equatable, Sendable {
    public let usbEndpoint: NetworkEndpoint?
    public let wifiEndpoint: NetworkEndpoint?
    public let localHostname: String

    public init(usbEndpoint: NetworkEndpoint?, wifiEndpoint: NetworkEndpoint?, localHostname: String) {
        self.usbEndpoint = usbEndpoint
        self.wifiEndpoint = wifiEndpoint
        self.localHostname = localHostname
    }

    public var allIPs: [String] {
        var ips: [String] = []
        if let usb = usbEndpoint?.ipAddress { ips.append(usb) }
        if let wifi = wifiEndpoint?.ipAddress { ips.append(wifi) }
        if !ips.contains("192.168.2.1") { ips.append("192.168.2.1") }
        return ips
    }

    public func localHTTPURL(port: UInt16 = 8080) -> String {
        "http://\(localHostname):\(port)"
    }

    public func localHTTPSURL(port: UInt16 = 8443) -> String {
        "https://\(localHostname):\(port)"
    }

    public static func normalizeLocalHostname(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "localhost" }
        if trimmed.lowercased().hasSuffix(".local") {
            return trimmed
        }
        return "\(trimmed).local"
    }
}

/// Discovers active USB-over-IP (Internet Sharing / USB Ethernet) and Wi-Fi IPv4 interfaces on macOS.
public final class NetworkDiscovery: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.paddisplay.net-discovery")
    private let lock = NSLock()
    private var onChange: (@Sendable (NetworkSnapshot) -> Void)?

    public init() {}

    public func start(onChange: @escaping @Sendable (NetworkSnapshot) -> Void) {
        lock.withLock { self.onChange = onChange }
        onChange(Self.currentSnapshot())

        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            let snapshot = Self.currentSnapshot()
            let callback = self.lock.withLock { self.onChange }
            callback?(snapshot)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
        lock.withLock { onChange = nil }
    }

    public static func currentSnapshot() -> NetworkSnapshot {
        let hostname = cleanLocalHostname()
        var usbCandidate: NetworkEndpoint?
        var wifiCandidate: NetworkEndpoint?

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return NetworkSnapshot(usbEndpoint: nil, wifiEndpoint: nil, localHostname: hostname)
        }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp && isRunning && !isLoopback else { continue }

            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: current.pointee.ifa_name)
            var ipBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &ipBuffer,
                socklen_t(ipBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ipBytes = ipBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let ip = String(decoding: ipBytes, as: UTF8.self)

            // Classify USB-over-IP vs Wi-Fi / LAN
            // macOS Internet Sharing to iPad USB creates `bridge100` (usually 192.168.2.1).
            // iPad USB Hotspot or Apple USB Ethernet creates an `en*` (non-en0) with 172.20.10.x or 169.254.x.x.
            if name.hasPrefix("bridge") || ip.hasPrefix("192.168.2.") {
                if usbCandidate == nil || name == "bridge100" {
                    usbCandidate = NetworkEndpoint(kind: .usb, interfaceName: name, ipAddress: ip)
                }
            } else if name == "en0" {
                wifiCandidate = NetworkEndpoint(kind: .wifi, interfaceName: name, ipAddress: ip)
            } else if name.hasPrefix("en") {
                if ip.hasPrefix("172.20.10.") || ip.hasPrefix("169.254.") {
                    if usbCandidate == nil {
                        usbCandidate = NetworkEndpoint(kind: .usb, interfaceName: name, ipAddress: ip)
                    }
                } else if wifiCandidate == nil {
                    wifiCandidate = NetworkEndpoint(kind: .wifi, interfaceName: name, ipAddress: ip)
                }
            }
        }

        return NetworkSnapshot(usbEndpoint: usbCandidate, wifiEndpoint: wifiCandidate, localHostname: hostname)
    }

    private static func cleanLocalHostname() -> String {
        NetworkSnapshot.normalizeLocalHostname(ProcessInfo.processInfo.hostName)
    }
}
