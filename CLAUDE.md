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

## UI Performance Rules

### Never call blocking APIs on the main actor

`@MainActor` classes/functions run on the main thread. Any synchronous blocking call stalls the UI. Common offenders in this codebase:

| API | Risk | Fix |
|-----|------|-----|
| `AVAudioSession.setCategory/setActive` | Blocks 5–50ms | `nonisolated async` helper |
| `SecItemCopyMatching/SecItemAdd/SecItemDelete` (Keychain) | Blocks 50–500ms | `nonisolated async` helper |
| `NSManagedObjectContext.fetch()` in per-chunk/per-frame paths | Blocks 10–100ms | `fetchBatchSize`; move out of hot paths |
| `NSRegularExpression(pattern:)` per call | Allocs regex engine each time | `private static let` constant |
| `DateFormatter()` / `JSONEncoder()` / `JSONDecoder()` per call | Allocs + configures each time | `private static let` constant |

**Pattern: `nonisolated static async` helper for off-thread work**

A `nonisolated async` function awaited from `@MainActor` runs on the Swift cooperative thread pool, not the main thread. Use this to move blocking I/O (Keychain, AVAudioSession) off the main actor:

```swift
// ✅ Correct — runs off main thread
nonisolated static func retrieveAsync(for id: String) async throws -> Config {
    try retrieve(for: id)           // calls SecItemCopyMatching here, off main thread
}

// In @MainActor code:
let config = try await KeychainManager.retrieveAsync(for: agentId)
```

**Pattern: `Task.detached` for fire-and-forget blocking cleanup**

```swift
private func stopEngine() {
    // ... synchronous cleanup on main actor ...
    Task.detached {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
```

### Never call Keychain (`SecItem*`) synchronously on `@MainActor`

Both `KeychainManager` and `TransportCredentialManager` expose `*Async` variants. Always use them from `@MainActor` contexts (ViewModels, AgentManager):

```swift
// ❌ Wrong — blocks main thread for 50-500ms
try KeychainManager.save(config: config, for: agentId)

// ✅ Correct — Keychain write runs off main thread
try await KeychainManager.saveAsync(config: config, for: agentId)
```

### Throttle high-frequency `@Published` side-effects during streaming

Callbacks that fire on every streamed chunk must not trigger expensive side effects on each call. Pattern: throttle with a timestamp check.

```swift
// ❌ Wrong — called 50× per second during streaming
onChunk: { chunk in
    Task { @MainActor in
        self.messages[i].text += chunk   // fine — just a property set
        self.updateConversation()        // BAD: copies array + sorts agents every chunk
    }
}

// ✅ Correct — throttled; SwiftUI re-renders from @Published without the expensive call
onChunk: { chunk in
    Task { @MainActor in
        self.messages[i].text += chunk
        let now = Date()
        if now.timeIntervalSince(self.lastUpdateTime) >= 0.3 {
            self.updateConversation()
            self.lastUpdateTime = now
        }
    }
}
```

Always call the un-throttled version once at end-of-stream to flush final state.

### Use `static let` for expensive-to-construct objects

```swift
// ❌ Wrong — allocated on every call / view render
private var timeString: String {
    let formatter = DateFormatter()       // expensive!
    return formatter.string(from: timestamp)
}
private func extractJson(_ text: String) -> String? {
    let regex = try? NSRegularExpression(pattern: ...)  // expensive!
}

// ✅ Correct — allocated once
private static let timeFormatter: DateFormatter = {
    let f = DateFormatter(); f.timeStyle = .short; return f
}()
private static let codeFenceRegex = try? NSRegularExpression(pattern: ...)
private static let encoder = JSONEncoder()
private static let decoder = JSONDecoder()
```

### Avoid redundant CoreData refreshes after mutations

`AgentRepository` uses a `NSManagedObjectContextObjectsDidChange` observer that automatically calls `refreshAgents()` whenever context objects change. Do **not** call `refreshAgents()` explicitly after `saveContext()` — the observer fires before save and handles it. Duplicate calls cause two full fetches per mutation.

```swift
// ❌ Wrong — triggers two fetches per mutation
entity.name = newName
saveContext(context)
refreshAgents()   // redundant; observer already fired on entity.name = ...

// ✅ Correct — observer handles refresh automatically
entity.name = newName
saveContext(context)
```

### Set `fetchBatchSize` on NSFetchRequest for list queries

Avoid loading the full result set into memory at once:

```swift
let request = AgentEntity.fetchRequest()
request.fetchBatchSize = 20   // load in pages of 20
```

### Waveform / audio buffer updates must use `DispatchQueue.main.async`

Audio tap callbacks (`installTap`) run on a background audio thread. Always dispatch UI state mutations back to main:

```swift
inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
    // compute off audio thread ...
    DispatchQueue.main.async { self?.waveformSamples.append(level) }
}
```

### Move message filtering out of SwiftUI `body`

Inline `.filter { }` in `ForEach` re-allocates on every SwiftUI render pass. Use a computed property with an early-exit for the common (no-filter) case:

```swift
// ❌ Wrong — allocates filtered array on every render
ForEach(viewModel.messages.filter { $0.type != .thought }) { ... }

// ✅ Correct
private var displayedMessages: [Message] {
    guard !isVerboseMode else { return viewModel.messages }
    return viewModel.messages.filter { $0.type != .thought && $0.type != .toolStatus }
}
```

### Prefer `async`/`await` over `DispatchQueue.main.async` in new code

New ViewModels should use `Task { @MainActor in ... }` rather than `DispatchQueue.main.async` for clarity about actor isolation. The `DispatchQueue.main.async` pattern in existing audio tap callbacks is acceptable since those closures run on the audio thread outside Swift concurrency.

### Never mutate an observed property synchronously inside its own `onChange`

Setting the same property you're observing inside `.onChange(of:)` causes SwiftUI attribute graph cycles (`Cycle detected through attribute: XXXXXX` in logs). The change handler fires, mutates the attribute, and SwiftUI tries to re-evaluate it within the same rendering pass.

```swift
// ❌ Wrong — mutates the observed property synchronously, causing an attribute cycle
.onChange(of: viewModel.someValue) { _, value in
    // process value...
    viewModel.someValue = nil
}

// ✅ Correct — defer the clear to the next runloop turn
.onChange(of: viewModel.someValue) { _, value in
    // process value...
    Task { @MainActor in viewModel.someValue = nil }
}
```

This applies to any `@Published`, `@State`, or `@Binding` property observed by `onChange`.

---

## Localization

The app supports **English (`en`) and Turkish (`tr`)**. All user-visible strings must be localized. Never hardcode English text directly in views.

### Supported languages and catalog files

| Language | File |
|----------|------|
| English | `Aptove/en.lproj/Localizable.strings` |
| Turkish | `Aptove/tr.lproj/Localizable.strings` |

### Rules

1. **Every user-visible string needs a key in both catalog files.** When you add a new string, add it to `en.lproj/Localizable.strings` AND `tr.lproj/Localizable.strings` in the same commit.

2. **When a key's English text changes, update the Turkish translation too.** Do not leave the Turkish entry pointing at outdated text. If you don't know the correct Turkish translation, add a `// TODO: translate` comment in the `.strings` file and flag it.

3. **When a key is removed, remove it from both files.**

4. **Use `Text("key")` / `Button("key")` for in-body text.** SwiftUI treats string literals as `LocalizedStringKey` and resolves them via the `\.locale` environment set in `AptoveApp`. No extra wrapper needed.

5. **Use `Bundle.localized(key, language: appLanguage)` for `.navigationTitle()` only.** UIKit's navigation bar ignores SwiftUI's `\.locale` environment. Every view with a `.navigationTitle()` must read `@AppStorage("appLanguage") private var appLanguage: String = ""` and call `Bundle.localized`.

6. **Use named keys (not raw text) when the display string contains special characters or punctuation that may vary by locale** — e.g. use `"memory_correcting"` not `"Correcting…"` directly, so the key and display value are decoupled.

### Patterns

```swift
// ✅ In-body text — LocalizedStringKey resolved via \.locale
Text("Cancel")                        // looks up "Cancel" in strings file
Button("Delete") { ... }              // same
Section("Agent Information") { ... }  // same
.alert("Connection Error", ...)       // same

// ✅ Navigation title — must use Bundle.localized
@AppStorage("appLanguage") private var appLanguage: String = ""
...
.navigationTitle(Bundle.localized("Configuration", language: appLanguage))

// ❌ Wrong — hardcoded English, not translated
Text("Tap mic to dictate")            // missing from catalog → never translates
.navigationTitle("Configuration")     // UIKit ignores \.locale → always English
```

### Adding a new screen checklist

- [ ] Add all user-visible string keys to `en.lproj/Localizable.strings`
- [ ] Add Turkish translations to `tr.lproj/Localizable.strings`
- [ ] Add `@AppStorage("appLanguage") private var appLanguage: String = ""` to the view
- [ ] Use `Bundle.localized(key, language: appLanguage)` for `.navigationTitle()`
- [ ] Use plain `Text("key")` / `Button("key")` for everything else

---

## Transport Priority (AgentManager)

Priority determines which endpoint is preferred for auto-connect. Computed dynamically — never add hardcoded transport names:

| Priority | Transport |
|----------|-----------|
| 0 | `tailscale-serve` |
| 1 | `tailscale-ip` |
| 2 | Enterprise plugins (anything registered in `FeatureRegistry`) |
| 3 | `local` (fallback) |
