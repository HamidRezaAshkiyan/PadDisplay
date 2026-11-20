import Foundation
import Security

/// Manages a local Root CA and SAN leaf certificate for PadDisplay's HTTPS/WSS 60fps H.264 server.
/// Uses macOS bundled LibreSSL (`/usr/bin/openssl`) and generates a 1-tap `.mobileconfig` profile for iPadOS.
public final class CertManager: Sendable {
    public enum CertError: LocalizedError {
        case opensslFailed(String)
        case p12ImportFailed(OSStatus)
        case identityMissing

        public var errorDescription: String? {
            switch self {
            case .opensslFailed(let msg): return "Certificate generation failed: \(msg)"
            case .p12ImportFailed(let status): return "Failed to import PKCS#12 identity (OSStatus \(status))"
            case .identityMissing: return "PKCS#12 archive did not contain a valid TLS identity."
            }
        }
    }

    public let certsDirectory: URL
    private let p12Password = "paddisplay-local"

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.certsDirectory = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.certsDirectory = appSupport.appendingPathComponent("PadDisplay/certs", isDirectory: true)
        }
    }

    public var caCertURL: URL { certsDirectory.appendingPathComponent("ca.crt") }
    public var caKeyURL: URL { certsDirectory.appendingPathComponent("ca.key") }
    public var serverP12URL: URL { certsDirectory.appendingPathComponent("server.p12") }
    private var sanMarkerURL: URL { certsDirectory.appendingPathComponent("san-marker.txt") }

    /// Ensures Root CA + leaf cert covering `ips` and `hostname` exist, and returns a `sec_identity_t` for `NWProtocolTLS`.
    public func ensureTLSIdentity(ips: [String], hostname: String) throws -> sec_identity_t {
        try FileManager.default.createDirectory(at: certsDirectory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: caCertURL.path) ||
           !FileManager.default.fileExists(atPath: caKeyURL.path) {
            try generateRootCA()
        }

        let uniqueIPs = Array(Set(ips + ["127.0.0.1", "192.168.2.1"])).sorted()
        let sanMarker = (uniqueIPs + [hostname]).joined(separator: ",")
        let existingMarker = (try? String(contentsOf: sanMarkerURL, encoding: .utf8)) ?? ""

        if !FileManager.default.fileExists(atPath: serverP12URL.path) || existingMarker != sanMarker {
            try generateLeafCertificate(ips: uniqueIPs, hostname: hostname)
            try sanMarker.write(to: sanMarkerURL, atomically: true, encoding: .utf8)
        }

        return try loadSecIdentity()
    }

    /// Generates an Apple `.mobileconfig` configuration profile containing the PadDisplay Local Root CA.
    /// Installing this profile on iPadOS and enabling Full Trust unlocks 60fps H.264 WebCodecs over HTTPS/WSS.
    public func mobileConfigData() throws -> Data {
        if !FileManager.default.fileExists(atPath: caCertURL.path) {
            try FileManager.default.createDirectory(at: certsDirectory, withIntermediateDirectories: true)
            try generateRootCA()
        }

        // Convert PEM CA cert to DER for .mobileconfig PayloadContent
        let derURL = certsDirectory.appendingPathComponent("ca.der")
        try runOpenSSL(["x509", "-in", caCertURL.path, "-outform", "DER", "-out", derURL.path])
        let derData = try Data(contentsOf: derURL)
        let certBase64 = derData.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])

        let profileXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadContent</key>
            <array>
                <dict>
                    <key>PayloadCertificateFileName</key>
                    <string>PadDisplayLocalCA.cer</string>
                    <key>PayloadContent</key>
                    <data>
        \(certBase64)
                    </data>
                    <key>PayloadDescription</key>
                    <string>Enables trusted local HTTPS for PadDisplay 60fps H.264 streaming on your iPad.</string>
                    <key>PayloadDisplayName</key>
                    <string>PadDisplay Local CA</string>
                    <key>PayloadIdentifier</key>
                    <string>com.paddisplay.local-ca.cert</string>
                    <key>PayloadType</key>
                    <string>com.apple.security.root</string>
                    <key>PayloadUUID</key>
                    <string>A1B2C3D4-5E6F-47A8-9B0C-1D2E3F4A5B6C</string>
                    <key>PayloadVersion</key>
                    <integer>1</integer>
                </dict>
            </array>
            <key>PayloadDescription</key>
            <string>Installs the PadDisplay Local Root CA so Safari on your iPad trusts your Mac for 60fps H.264 WebCodecs display streaming.</string>
            <key>PayloadDisplayName</key>
            <string>PadDisplay Local HTTPS</string>
            <key>PayloadIdentifier</key>
            <string>com.paddisplay.local-ca.profile</string>
            <key>PayloadRemovalDisallowed</key>
            <false/>
            <key>PayloadType</key>
            <string>Configuration</string>
            <key>PayloadUUID</key>
            <string>F1E2D3C4-B5A6-4987-8123-456789ABCDEF</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
        </plist>
        """
        return Data(profileXML.utf8)
    }

    // MARK: - Private OpenSSL Helpers (LibreSSL 3.3.6 compatible)

    private func generateRootCA() throws {
        let caConfigURL = certsDirectory.appendingPathComponent("ca.cnf")
        let caConfig = """
        [req]
        distinguished_name = dn
        x509_extensions = v3_ca
        prompt = no

        [dn]
        CN = PadDisplay Local CA
        O = PadDisplay

        [v3_ca]
        basicConstraints = critical,CA:TRUE
        keyUsage = critical,digitalSignature,cRLSign,keyCertSign
        subjectKeyIdentifier = hash
        """
        try caConfig.write(to: caConfigURL, atomically: true, encoding: .utf8)

        try runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", caKeyURL.path,
            "-out", caCertURL.path,
            "-days", "3650",
            "-sha256",
            "-config", caConfigURL.path
        ])
    }

    private func generateLeafCertificate(ips: [String], hostname: String) throws {
        let serverKeyURL = certsDirectory.appendingPathComponent("server.key")
        let serverCSRURL = certsDirectory.appendingPathComponent("server.csr")
        let serverCertURL = certsDirectory.appendingPathComponent("server.crt")
        let leafConfigURL = certsDirectory.appendingPathComponent("leaf.cnf")

        var altLines: [String] = [
            "DNS.1 = localhost",
            "DNS.2 = \(hostname)"
        ]
        for (idx, ip) in ips.enumerated() {
            altLines.append("IP.\(idx + 1) = \(ip)")
        }

        let leafConfig = """
        [req]
        distinguished_name = dn
        req_extensions = v3_req
        prompt = no

        [dn]
        CN = \(hostname)
        O = PadDisplay

        [v3_req]
        basicConstraints = CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = @alt_names

        [alt_names]
        \(altLines.joined(separator: "\n"))
        """
        try leafConfig.write(to: leafConfigURL, atomically: true, encoding: .utf8)

        try runOpenSSL([
            "req", "-new", "-newkey", "rsa:2048", "-nodes",
            "-keyout", serverKeyURL.path,
            "-out", serverCSRURL.path,
            "-config", leafConfigURL.path
        ])

        try runOpenSSL([
            "x509", "-req",
            "-in", serverCSRURL.path,
            "-CA", caCertURL.path,
            "-CAkey", caKeyURL.path,
            "-CAcreateserial",
            "-out", serverCertURL.path,
            "-days", "820",
            "-sha256",
            "-extfile", leafConfigURL.path,
            "-extensions", "v3_req"
        ])

        try runOpenSSL([
            "pkcs12", "-export",
            "-inkey", serverKeyURL.path,
            "-in", serverCertURL.path,
            "-certfile", caCertURL.path,
            "-out", serverP12URL.path,
            "-passout", "pass:\(p12Password)"
        ])
    }

    private func loadSecIdentity() throws -> sec_identity_t {
        let p12Data = try Data(contentsOf: serverP12URL)
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: p12Password
        ]
        var rawItems: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess else {
            throw CertError.p12ImportFailed(status)
        }
        guard let items = rawItems as? [[String: Any]],
              let first = items.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw CertError.identityMissing
        }
        let secIdentity = identityRef as! SecIdentity
        guard let nwIdentity = sec_identity_create(secIdentity) else {
            throw CertError.identityMissing
        }
        return nwIdentity
    }

    private func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Exit code \(process.terminationStatus)"
            throw CertError.opensslFailed(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
