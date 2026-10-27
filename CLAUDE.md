# iOS App Development Guidelines

## OSS / Enterprise Architecture

This repo is the OSS Aptove iOS app. The app code is also exposed as an SPM library (`AptoveCore` via `Package.swift`) so that `ios-ent` (separate private repo) can depend on it and add enterprise-only features without forking.

| Component | Role |
|-----------|------|
| `Aptove/` (all files except `AptoveApp.swift`) | `AptoveCore` SPM library — shared with `ios-ent` |
| `AptoveApp.swift` | OSS app entry point — excluded from the library |
| `FeatureRegistry` | Runtime registry where enterprise builds inject extensions before first render |

`ios-ent` provides its own `@main` app entry point, imports `AptoveCore`, and registers enterprise providers into `FeatureRegistry` before the first SwiftUI render.

---

## CRITICAL: Changes to `AptoveCore` May Break `ios-ent`

Because `ios-ent` imports `AptoveCore` as an SPM dependency, any change to the shared code is effectively a change to a public API. **Before making any of the following changes, stop and ask the developer for approval:**

- Removing or narrowing `public` or `internal` visibility on any type, protocol, or member that `ios-ent` could be using
- Changing the signature of a `public protocol` in a breaking way (adding a required method, renaming a property, changing a type)
- Removing or restricting an extension point — a `FeatureRegistry` property, a protocol, a hook — that `ios-ent` injects into
- Adding a new required method to a protocol that `ios-ent` likely conforms to
- Adding a Swift Package dependency to `Package.swift` that could conflict with `ios-ent`'s dependency graph
- Moving `ios-ent`-only logic into `AptoveCore` where it would leak into the OSS build
- Removing a file from `Aptove/` that is currently included in `AptoveCore` (check `Package.swift` exclusions first)
- Hardcoding behavior that was previously delegated to `FeatureRegistry` or an injected extension

**When in doubt, flag it.** Say: "This change to `AptoveCore` may affect `ios-ent` — please confirm before I proceed."

---

## General Rules for AptoveCore

1. **No enterprise-specific code.** `AptoveCore` must compile cleanly without any knowledge of what `ios-ent` adds. Enterprise logic belongs in `ios-ent`.

2. **No hardcoded assumptions about registered features.** Code in `AptoveCore` must behave correctly whether `FeatureRegistry` is empty (OSS) or populated (enterprise).

3. **Extension points must remain open.** Do not remove or narrow `FeatureRegistry` properties or any protocol without developer approval.

4. **Prefer optional / default protocol requirements.** When adding a method to a protocol in `AptoveCore`, provide a default implementation where possible so existing conformances in `ios-ent` are not broken.

---

## Plugin/Extension Pattern (Transport System as Example)

The transport provider system illustrates the general extensibility pattern used in `AptoveCore`:

- `TransportProvider` protocol (`Aptove/Services/TransportProvider.swift`) — defines the interface
- `FeatureRegistry.shared.transportProviders` — the injection point
- `PairingType.plugin(String)` — catch-all in `PairingService` that dispatches to `FeatureRegistry`
- Built-in transports (Local, Tailscale) are handled directly in `PairingService`; enterprise transports go through the registry

This same pattern should be followed for any future extension point: define the protocol and registry property in `AptoveCore`, inject from `ios-ent`'s entry point.

### FeatureRegistry registration (ios-ent entry point)

```swift
// Called before the first SwiftUI render in ios-ent's @main
FeatureRegistry.shared.someProviders = [
    MyEnterpriseProvider(),
]
```

### TransportProvider protocol (reference)

```swift
public protocol TransportProvider {
    var transportName: String { get }    // matches bridge transport key
    var displayName: String { get }      // shown in UI
    var pairingPath: String { get }      // e.g. "/pair/mytransport"
    var usesExternalTLS: Bool { get }    // true = no cert pinning
    func pair(pairingURL: PairingURL) async throws -> PairingResult
}
```

---

## Coding Rules

### No hardcoded enterprise identifiers

Never branch on a specific enterprise feature name in `AptoveCore`. Use registry lookups instead.

**Wrong:**
```swift
case "some-enterprise-transport": priority = 2
```

**Right:**
```swift
priority = FeatureRegistry.shared.provider(forTransport: transport) != nil ? 2 : 3
```

### PairingType switch statements must handle `.plugin`

Every `switch pairingURL.pairingType` must include `.plugin`. Never add a named case for an enterprise transport.

```swift
case .plugin(let name):
    let label = FeatureRegistry.shared.provider(forTransport: name)?.displayName ?? name
    pairingStatus = "Connecting via \(label)..."
```

### No enterprise-specific private methods in PairingService

Dispatch through the registry generically — never add methods like `pairCloudflare()` or `pairVPN()` to `PairingService`.

```swift
case .plugin(let name):
    guard let provider = FeatureRegistry.shared.provider(forTransport: name) else {
        throw PairingError.unsupportedPairingType(name)
    }
    return try await provider.pair(pairingURL: pairingURL)
```

### Package.swift exclusions

Only app-entry-point files belong in `exclude` (`AptoveApp.swift`, assets, entitlements, localization). All `Services/`, `ViewModels/`, `Models/`, and `Views/` files are included in `AptoveCore` by default. When adding a new file that is OSS-app-only, add it to `exclude`.

---

## Transport Priority (AgentManager)

Priority determines which endpoint is preferred for auto-connect. Computed dynamically — never add hardcoded transport names:

| Priority | Transport |
|----------|-----------|
| 0 | `tailscale-serve` |
| 1 | `tailscale-ip` |
| 2 | Enterprise plugins (anything registered in `FeatureRegistry`) |
| 3 | `local` (fallback) |
