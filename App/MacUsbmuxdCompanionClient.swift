import CryptoKit
import Foundation
import Security

struct MacUsbmuxdDevice: Codable, Identifiable, Hashable {
    let udid: String
    let transport: String
    var id: String { udid }
}

struct MacUsbmuxdCompanionResponse: Decodable {
    let ok: Bool
    let message: String
    let devices: [MacUsbmuxdDevice]?
    let pairingFileBase64: String?
    let pairingFileName: String?
    let verified: Bool

    enum CodingKeys: String, CodingKey {
        case ok, message, devices, verified
        case pairingFileBase64 = "pairing_file_base64"
        case pairingFileName = "pairing_file_name"
    }
}

struct MacUsbmuxdCompanionRequest: Encodable {
    let action: String
    let token: String
    var udid: String?
    var lockdownPairingPlistBase64: String?
    var rpPairingPlistBase64: String?
    var hostLabel: String?

    enum CodingKeys: String, CodingKey {
        case action, token, udid
        case lockdownPairingPlistBase64 = "lockdown_pairing_plist_base64"
        case rpPairingPlistBase64 = "rp_pairing_plist_base64"
        case hostLabel = "host_label"
    }
}

enum MacUsbmuxdCompanionError: LocalizedError {
    case invalidHost
    case invalidPort
    case invalidFingerprint
    case invalidToken
    case tlsPinMismatch(expected: String, received: String)
    case tlsTrust(String)
    case httpStatus(Int)
    case invalidResponse
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "Enter the Mac companion's specific LocalDevVPN/LAN IP address, not a URL or CIDR route."
        case .invalidPort:
            return "Enter a valid TCP port between 1 and 65535."
        case .invalidFingerprint:
            return "Enter the 64-character SHA-256 certificate fingerprint printed by the Mac companion. Colons and spaces are optional."
        case .invalidToken:
            return "Enter the companion access token printed at first launch or stored in its access-token.txt file."
        case .tlsPinMismatch(let expected, let received):
            return "TLS certificate pin mismatch. Expected SHA-256 \(expected), received \(received). Connection was rejected."
        case .tlsTrust(let message):
            return "The pinned companion certificate could not be trusted: \(message)"
        case .httpStatus(let status):
            return "Mac companion returned HTTP status \(status)."
        case .invalidResponse:
            return "The Mac companion response was not valid JSON or did not contain the expected fields."
        case .remote(let message):
            return message
        }
    }
}

/// An ephemeral HTTPS client with explicit leaf-certificate SHA-256 pinning.
/// The access token and pairing files are sent only inside this pinned TLS session.
final class MacUsbmuxdCompanionClient {
    let host: String
    let port: UInt16
    let fingerprint: String
    let token: String

    init(host: String, port: String, fingerprint: String, token: String) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !normalizedHost.isEmpty,
              !normalizedHost.contains("/"),
              !normalizedHost.contains("://"),
              !normalizedHost.contains(where: { $0.isWhitespace }) else {
            throw MacUsbmuxdCompanionError.invalidHost
        }
        guard let parsedPort = UInt16(port), parsedPort > 0 else {
            throw MacUsbmuxdCompanionError.invalidPort
        }
        let fingerprintInput = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fingerprintInput.allSatisfy({ $0.isHexDigit || $0 == ":" || $0.isWhitespace }) else {
            throw MacUsbmuxdCompanionError.invalidFingerprint
        }
        let normalizedFingerprint = fingerprintInput.filter { $0.isHexDigit }.lowercased()
        guard normalizedFingerprint.count == 64 else {
            throw MacUsbmuxdCompanionError.invalidFingerprint
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 48 else { throw MacUsbmuxdCompanionError.invalidToken }

        self.host = normalizedHost
        self.port = parsedPort
        self.fingerprint = normalizedFingerprint
        self.token = token
    }

    func listDevices() async throws -> [MacUsbmuxdDevice] {
        let response = try await send(.init(action: "list_devices", token: token))
        return response.devices ?? []
    }

    func createRPPairing(lockdownFile: Data, udid: String) async throws -> MacUsbmuxdCompanionResponse {
        guard !udid.isEmpty else { throw MacUsbmuxdCompanionError.remote("Select a target UDID first.") }
        return try await send(.init(
            action: "create_rppairing",
            token: token,
            udid: udid,
            lockdownPairingPlistBase64: lockdownFile.base64EncodedString(),
            hostLabel: "GassPair"
        ), timeout: 360)
    }

    func verifyRPPairing(lockdownFile: Data, rpFile: Data, udid: String) async throws -> MacUsbmuxdCompanionResponse {
        guard !udid.isEmpty else { throw MacUsbmuxdCompanionError.remote("Select a target UDID first.") }
        return try await send(.init(
            action: "verify_rppairing",
            token: token,
            udid: udid,
            lockdownPairingPlistBase64: lockdownFile.base64EncodedString(),
            rpPairingPlistBase64: rpFile.base64EncodedString(),
            hostLabel: "GassPair"
        ), timeout: 60)
    }

    private func send(_ payload: MacUsbmuxdCompanionRequest, timeout: TimeInterval = 20) async throws -> MacUsbmuxdCompanionResponse {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = Int(port)
        components.path = "/api/v1"
        guard let url = components.url else { throw MacUsbmuxdCompanionError.invalidHost }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(payload)

        let delegate = PinnedCompanionTLSDelegate(expectedFingerprint: fingerprint, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MacUsbmuxdCompanionError.invalidResponse }
            let decoded: MacUsbmuxdCompanionResponse
            do {
                decoded = try JSONDecoder().decode(MacUsbmuxdCompanionResponse.self, from: data)
            } catch {
                if !(200..<300).contains(http.statusCode) { throw MacUsbmuxdCompanionError.httpStatus(http.statusCode) }
                throw MacUsbmuxdCompanionError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw MacUsbmuxdCompanionError.remote(decoded.message)
            }
            guard decoded.ok else { throw MacUsbmuxdCompanionError.remote(decoded.message) }
            return decoded
        } catch let error as MacUsbmuxdCompanionError {
            throw error
        } catch {
            throw MacUsbmuxdCompanionError.remote("Could not reach the pinned Mac companion at \(host):\(port): \(error.localizedDescription)")
        }
    }
}

private final class PinnedCompanionTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expectedFingerprint: String
    private let host: String

    init(expectedFingerprint: String, host: String) {
        self.expectedFingerprint = expectedFingerprint
        self.host = host
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let certificateDER = SecCertificateCopyData(certificate) as Data
        let received = SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
        guard constantTimeEqual(received, expectedFingerprint) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // The certificate is self-signed. Trust this certificate as the only anchor
        // only after the SHA-256 pin matches, and still enforce the configured host/IP.
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
