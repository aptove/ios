import Foundation

/// A registered transport implementation.
///
/// OSS builds register `LocalTransportProvider` and `TailscaleTransportProvider`.
/// Enterprise builds additionally register `CFZeroTrustTransportProvider`.
public protocol TransportProvider {
    /// Internal name matching the bridge transport key (e.g. "cloudflare").
    var transportName: String { get }
    /// Human-readable label shown in UI.
    var displayName: String { get }
    /// The pairing endpoint path (e.g. "/pair/cloudflare").
    var pairingPath: String { get }
    /// Whether this transport uses TLS provided externally (no cert pinning).
    var usesExternalTLS: Bool { get }
    /// Perform the pairing request and return a `PairingResult`.
    func pair(pairingURL: PairingURL) async throws -> PairingResult
}
