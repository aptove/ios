import Foundation
import CommonCrypto

/// Represents different pairing endpoint types based on URL path
enum PairingType {
    case local      // /pair/local - Self-signed TLS, returns WebSocket URL + authToken
    case cloudflare // /pair/cloudflare - Cloudflare Access, returns clientId + clientSecret
    case tailscale  // /pair/tailscale - Tailscale transport; standard TLS (serve) or cert pinning (ip)
    case unknown(String)

    init(from path: String) {
        switch path {
        case "/pair/local":
            self = .local
        case "/pair/cloudflare":
            self = .cloudflare
        case "/pair/tailscale":
            self = .tailscale
        default:
            self = .unknown(path)
        }
    }

    var description: String {
        switch self {
        case .local: return "Local Bridge"
        case .cloudflare: return "Cloudflare Tunnel"
        case .tailscale: return "Tailscale"
        case .unknown(let path): return "Unknown (\(path))"
        }
    }
}

/// Parsed pairing URL from QR code
struct PairingURL {
    let baseURL: URL          // https://192.168.1.100:8080
    let pairingType: PairingType
    let code: String          // 6-digit pairing code
    let fingerprint: String?  // TLS cert fingerprint (for local)
    let fullURL: URL          // Complete pairing URL
    
    /// Parse a pairing URL from QR code content
    /// Expected format: https://IP:PORT/pair/local?code=XXXXXX&fp=SHA256:...
    static func parse(_ urlString: String) throws -> PairingURL {
        guard let url = URL(string: urlString) else {
            throw PairingError.invalidURL("Could not parse URL")
        }
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PairingError.invalidURL("Could not parse URL components")
        }
        
        // Validate scheme
        guard components.scheme == "https" || components.scheme == "http" else {
            throw PairingError.invalidURL("Pairing URL must use https:// or http://")
        }
        
        // Extract pairing type from path
        let path = components.path
        guard path.hasPrefix("/pair/") else {
            throw PairingError.invalidURL("Not a pairing URL (expected /pair/...)")
        }
        let pairingType = PairingType(from: path)
        
        // Extract query parameters
        let queryItems = components.queryItems ?? []
        let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        
        // Code is required
        guard let code = params["code"], !code.isEmpty else {
            throw PairingError.missingCode
        }
        
        // Fingerprint is optional (required for local, not for cloudflare)
        let fingerprint = params["fp"]
        
        // Build base URL (without path and query)
        var baseComponents = components
        baseComponents.path = ""
        baseComponents.queryItems = nil
        guard let baseURL = baseComponents.url else {
            throw PairingError.invalidURL("Could not construct base URL")
        }
        
        return PairingURL(
            baseURL: baseURL,
            pairingType: pairingType,
            code: code,
            fingerprint: fingerprint,
            fullURL: url
        )
    }
    
    /// The WebSocket URL for this connection (derived from base URL)
    var websocketURL: String {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        return components.url?.absoluteString ?? baseURL.absoluteString
    }
}

/// Response from /pair/local endpoint
struct LocalPairingResponse: Codable {
    let url: String
    let `protocol`: String
    let version: String
    let authToken: String
    let certFingerprint: String?
}

/// Response from /pair/cloudflare endpoint (future)
struct CloudflarePairingResponse: Codable {
    let url: String
    let `protocol`: String
    let version: String
    let authToken: String
    let clientId: String
    let clientSecret: String
}

/// Generic pairing response that can hold either type
enum PairingResponse {
    case local(LocalPairingResponse)
    case cloudflare(CloudflarePairingResponse)
    
    /// Convert to ConnectionConfig for use with ACPClientWrapper
    func toConnectionConfig() -> ConnectionConfig {
        switch self {
        case .local(let response):
            return ConnectionConfig(
                url: response.url,
                clientId: nil,
                clientSecret: nil,
                authToken: response.authToken,
                certFingerprint: response.certFingerprint,
                protocolVersion: response.protocol,
                version: response.version
            )
        case .cloudflare(let response):
            return ConnectionConfig(
                url: response.url,
                clientId: response.clientId,
                clientSecret: response.clientSecret,
                authToken: response.authToken,
                certFingerprint: nil,
                protocolVersion: response.protocol,
                version: response.version
            )
        }
    }
}

/// Error types for pairing operations
enum PairingError: LocalizedError {
    case invalidURL(String)
    case missingCode
    case missingFingerprint
    case invalidCode
    case rateLimited
    case fingerprintMismatch(expected: String, actual: String)
    case networkError(Error)
    case invalidResponse(String)
    case unsupportedPairingType(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL(let reason):
            return "Invalid pairing URL: \(reason)"
        case .missingCode:
            return "Pairing code not found in URL"
        case .missingFingerprint:
            return "Certificate fingerprint required for local pairing"
        case .invalidCode:
            return "Invalid or expired pairing code"
        case .rateLimited:
            return "Too many attempts. Please restart the bridge for a new code."
        case .fingerprintMismatch(let expected, let actual):
            return "Security warning: Certificate mismatch!\nExpected: \(expected)\nReceived: \(actual)\nThis may indicate a man-in-the-middle attack."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse(let reason):
            return "Invalid response from bridge: \(reason)"
        case .unsupportedPairingType(let type):
            return "Unsupported pairing type: \(type)"
        }
    }
}

/// Service for handling pairing with the bridge
actor PairingService {
    
    /// Complete the pairing flow by calling the pairing endpoint
    /// - Parameter pairingURL: Parsed pairing URL from QR code
    /// - Returns: ConnectionConfig ready for use with ACPClientWrapper
    func pair(with pairingURL: PairingURL) async throws -> ConnectionConfig {
        switch pairingURL.pairingType {
        case .local:
            return try await pairLocal(pairingURL: pairingURL)
        case .cloudflare:
            return try await pairCloudflare(pairingURL: pairingURL)
        case .tailscale:
            return try await pairTailscale(pairingURL: pairingURL)
        case .unknown(let path):
            throw PairingError.unsupportedPairingType(path)
        }
    }
    
    // MARK: - Local Pairing
    
    /// Pair with a local bridge using certificate pinning
    private func pairLocal(pairingURL: PairingURL) async throws -> ConnectionConfig {
        // For local pairing, fingerprint is required for security
        guard let expectedFingerprint = pairingURL.fingerprint else {
            throw PairingError.missingFingerprint
        }
        
        print("🔐 PairingService: Starting local pairing")
        print("🔐 PairingService: URL: \(pairingURL.fullURL)")
        print("🔐 PairingService: Expected fingerprint: \(expectedFingerprint)")
        
        // Create delegate for certificate pinning
        let delegate = PairingCertificateDelegate(expectedFingerprint: expectedFingerprint)
        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
        
        defer {
            session.invalidateAndCancel()
        }
        
        // Make the pairing request
        var request = URLRequest(url: pairingURL.fullURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Check if it was a fingerprint mismatch
            if let actualFingerprint = delegate.receivedFingerprint,
               actualFingerprint.lowercased() != expectedFingerprint.lowercased() {
                throw PairingError.fingerprintMismatch(
                    expected: expectedFingerprint,
                    actual: actualFingerprint
                )
            }
            throw PairingError.networkError(error)
        }
        
        // Check HTTP status
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PairingError.invalidResponse("Not an HTTP response")
        }
        
        print("🔐 PairingService: HTTP status: \(httpResponse.statusCode)")
        
        switch httpResponse.statusCode {
        case 200:
            // Success - parse response
            let decoder = JSONDecoder()
            do {
                let pairingResponse = try decoder.decode(LocalPairingResponse.self, from: data)
                print("✅ PairingService: Pairing successful!")
                print("✅ PairingService: WebSocket URL: \(pairingResponse.url)")
                return PairingResponse.local(pairingResponse).toConnectionConfig()
            } catch {
                throw PairingError.invalidResponse("Could not parse response: \(error)")
            }
            
        case 401:
            // Invalid code
            throw PairingError.invalidCode
            
        case 429:
            // Rate limited
            throw PairingError.rateLimited
            
        default:
            // Try to parse error response
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = errorJson["message"] as? String {
                throw PairingError.invalidResponse("Server error: \(message)")
            }
            throw PairingError.invalidResponse("HTTP \(httpResponse.statusCode)")
        }
    }
    
    // MARK: - Tailscale Pairing

    /// Pair with a Tailscale-transported bridge.
    /// - `serve` mode (no fingerprint): Tailscale provides a valid Let's Encrypt cert → standard TLS.
    /// - `ip` mode (fingerprint present): self-signed cert → cert pinning, same as local pairing.
    private func pairTailscale(pairingURL: PairingURL) async throws -> ConnectionConfig {
        print("🔐 PairingService: Starting Tailscale pairing")
        print("🔐 PairingService: URL: \(pairingURL.fullURL)")

        if pairingURL.fingerprint != nil {
            // ip mode: fingerprint is present — reuse cert-pinning logic from pairLocal
            print("🔐 PairingService: Tailscale ip mode — using cert pinning")
            return try await pairLocal(pairingURL: pairingURL)
        }

        // serve mode: Tailscale CA cert is trusted by iOS — use standard TLS
        print("🔐 PairingService: Tailscale serve mode — using standard TLS")
        let session = URLSession.shared

        var request = URLRequest(url: pairingURL.fullURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PairingError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PairingError.invalidResponse("Not an HTTP response")
        }

        print("🔐 PairingService: HTTP status: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            do {
                let pairingResponse = try decoder.decode(LocalPairingResponse.self, from: data)
                print("✅ PairingService: Tailscale pairing successful!")
                return PairingResponse.local(pairingResponse).toConnectionConfig()
            } catch {
                throw PairingError.invalidResponse("Could not parse response: \(error)")
            }
        case 401:
            throw PairingError.invalidCode
        case 429:
            throw PairingError.rateLimited
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = errorJson["message"] as? String {
                throw PairingError.invalidResponse("Server error: \(message)")
            }
            throw PairingError.invalidResponse("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Cloudflare Pairing (Future)

    /// Pair with a Cloudflare-tunneled bridge
    private func pairCloudflare(pairingURL: PairingURL) async throws -> ConnectionConfig {
        print("🔐 PairingService: Starting Cloudflare pairing")
        print("🔐 PairingService: URL: \(pairingURL.fullURL)")
        
        // Cloudflare uses trusted CA certificates, no pinning needed
        let session = URLSession.shared
        
        var request = URLRequest(url: pairingURL.fullURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PairingError.networkError(error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PairingError.invalidResponse("Not an HTTP response")
        }
        
        print("🔐 PairingService: HTTP status: \(httpResponse.statusCode)")
        
        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            do {
                let pairingResponse = try decoder.decode(CloudflarePairingResponse.self, from: data)
                print("✅ PairingService: Cloudflare pairing successful!")
                return PairingResponse.cloudflare(pairingResponse).toConnectionConfig()
            } catch {
                throw PairingError.invalidResponse("Could not parse response: \(error)")
            }
            
        case 401:
            throw PairingError.invalidCode
            
        case 429:
            throw PairingError.rateLimited
            
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = errorJson["message"] as? String {
                throw PairingError.invalidResponse("Server error: \(message)")
            }
            throw PairingError.invalidResponse("HTTP \(httpResponse.statusCode)")
        }
    }
}

/// URLSession delegate for certificate pinning during pairing
private class PairingCertificateDelegate: NSObject, URLSessionDelegate {
    let expectedFingerprint: String
    var receivedFingerprint: String?
    
    init(expectedFingerprint: String) {
        self.expectedFingerprint = expectedFingerprint
        super.init()
    }
    
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // Get the server certificate
        if #available(iOS 15.0, *) {
            guard let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
                  let serverCert = certificates.first else {
                print("🔐 PairingCertificateDelegate: Failed to get server certificate")
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            
            // Calculate SHA256 fingerprint
            let certData = SecCertificateCopyData(serverCert) as Data
            let fingerprint = sha256Fingerprint(of: certData)
            receivedFingerprint = fingerprint
            
            print("🔐 PairingCertificateDelegate: Server fingerprint: \(fingerprint)")
            print("🔐 PairingCertificateDelegate: Expected fingerprint: \(expectedFingerprint)")
            
            // Normalize fingerprints for comparison
            // Bridge may send "SHA256:XX:XX:XX" or just "XX:XX:XX"
            let normalizedExpected = normalizeFingerprint(expectedFingerprint)
            let normalizedReceived = normalizeFingerprint(fingerprint)
            
            if normalizedReceived.lowercased() == normalizedExpected.lowercased() {
                print("🔐 PairingCertificateDelegate: ✅ Fingerprint matches!")
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
            } else {
                print("🔐 PairingCertificateDelegate: ❌ Fingerprint MISMATCH!")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            // iOS 14 fallback
            print("🔐 PairingCertificateDelegate: iOS 14 - trusting with fingerprint")
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        }
    }
    
    /// Calculate SHA256 fingerprint of certificate data
    private func sha256Fingerprint(of data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return "SHA256:" + hash.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    
    /// Normalize fingerprint by removing "SHA256:" prefix if present
    private func normalizeFingerprint(_ fingerprint: String) -> String {
        if fingerprint.uppercased().hasPrefix("SHA256:") {
            return String(fingerprint.dropFirst(7))
        }
        return fingerprint
    }
}
