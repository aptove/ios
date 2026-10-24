import Foundation

/// Central registry for enterprise-extensible features.
///
/// The OSS app entry point (`AptoveApp.swift`) leaves `transportProviders`
/// empty — built-in Local and Tailscale transports are handled directly in
/// `PairingService`.
///
/// Enterprise entry points register additional providers (e.g.
/// `CFZeroTrustTransportProvider`) before the app's first render, making
/// them available throughout the app.
class FeatureRegistry {
    static let shared = FeatureRegistry()
    private init() {}

    /// Additional transport providers registered by enterprise builds.
    /// Built-in transports (local, tailscale) are NOT in this list.
    var transportProviders: [TransportProvider] = []

    /// Find a registered provider for the given transport name.
    func provider(forTransport name: String) -> TransportProvider? {
        transportProviders.first { $0.transportName == name }
    }

    /// All registered transport names (enterprise transports only).
    var registeredTransportNames: [String] {
        transportProviders.map { $0.transportName }
    }
}
