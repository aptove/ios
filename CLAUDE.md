# iOS App Development Guidelines

## OSS / Enterprise Split

The repo is the OSS Aptove iOS app. It is also consumed as an SPM library by `ios-ent` (separate private repo), which adds enterprise transports (e.g. Cloudflare Zero Trust) without forking.

### How it works

| Component | File | Role |
|-----------|------|------|
| `TransportProvider` protocol | `Aptove/Services/TransportProvider.swift` | Interface every enterprise transport implements |
| `FeatureRegistry` singleton | `Aptove/Services/FeatureRegistry.swift` | Runtime registry; enterprise entry point registers providers before first render |
| `PairingType.plugin(String)` | `Aptove/Services/PairingService.swift` | Catch-all case that dispatches unknown transport names to `FeatureRegistry` |
| `Package.swift` | root | Exposes app code as `AptoveCore` SPM library so `ios-ent` can import it |

### Registration (enterprise entry point)

`ios-ent`'s app entry point calls this before the first SwiftUI render:

```swift
FeatureRegistry.shared.transportProviders = [
    CFZeroTrustTransportProvider(),
    // other enterprise providers...
]
```

The OSS `AptoveApp.swift` leaves `transportProviders` empty — built-in Local and Tailscale are handled directly in `PairingService`.

---

## Rules — keep OSS code enterprise-reusable

### 1. No hardcoded enterprise transport names in OSS

Never branch on `"cloudflare"` or any other enterprise transport name in `PairingService`, `AgentManager`, `QRScannerViewModel`, or any view. Use `FeatureRegistry` lookups instead.

**Wrong:**
```swift
case "cloudflare": priority = 2
```

**Right:**
```swift
priority = FeatureRegistry.shared.provider(forTransport: transport) != nil ? 2 : 3
```

### 2. PairingType switch statements must handle `.plugin`

Every `switch pairingURL.pairingType` in the codebase must include the `.plugin(let name)` case. Never add a new named case for an enterprise transport — use `.plugin`.

```swift
case .plugin(let name):
    let label = FeatureRegistry.shared.provider(forTransport: name)?.displayName ?? name
    pairingStatus = "Connecting via \(label)..."
```

### 3. PairingService dispatches plugins generically

The `pair(with:)` method must dispatch `.plugin` cases through the registry:

```swift
case .plugin(let name):
    guard let provider = FeatureRegistry.shared.provider(forTransport: name) else {
        throw PairingError.unsupportedPairingType(name)
    }
    return try await provider.pair(pairingURL: pairingURL)
```

Never add a named `pairCloudflare()` or similar private method in `PairingService` — that logic belongs in the enterprise `TransportProvider` implementation.

### 4. ManualPairingView enterprise options

`ManualPairingView.PairingTypeOption` lists built-in types only (`local`, `tailscale`). The static `allCasesWithEnterprise` computed property is the extension point — `ios-ent` overrides or supplements it to inject enterprise UI options into the picker. Do not add enterprise cases to the `enum` itself.

### 5. Package.swift exclusions

`Package.swift` excludes app-level files that are not part of the reusable library (`AptoveApp.swift`, assets, entitlements, localization). When adding new files that are app-entry-point-only (e.g. a new `@main` struct), add them to the `exclude` list. All `Services/`, `ViewModels/`, `Models/`, and `Views/` files are included in `AptoveCore` by default.

### 6. No direct CF SDK imports in OSS targets

The OSS app and `AptoveCore` must build with zero Cloudflare dependencies. Any CF SDK import belongs exclusively in `ios-ent`.

---

## TransportProvider Protocol

```swift
public protocol TransportProvider {
    var transportName: String { get }    // matches bridge transport key, e.g. "cloudflare"
    var displayName: String { get }      // shown in UI, e.g. "Cloudflare Tunnel"
    var pairingPath: String { get }      // e.g. "/pair/cloudflare"
    var usesExternalTLS: Bool { get }    // true = no cert pinning
    func pair(pairingURL: PairingURL) async throws -> PairingResult
}
```

Implement this in `ios-ent` and register via `FeatureRegistry.shared.transportProviders`.

---

## Transport Priority (AgentManager)

When a new `TransportEndpoint` is stored, priority determines which endpoint is preferred for auto-connect:

| Priority | Transport |
|----------|-----------|
| 0 | `tailscale-serve` |
| 1 | `tailscale-ip` |
| 2 | Enterprise plugins (anything in `FeatureRegistry`) |
| 3 | `local` (fallback) |

This is computed dynamically — do not add new hardcoded cases.
