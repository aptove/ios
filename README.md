# Aptove - iOS

A native iOS chat app for interacting with AI agents over the [Agent Client Protocol (ACP)](https://github.com/agent-client-protocol).

## Features

- **Secure QR Pairing** - Scan QR codes to securely pair with Aptove Router
- **Certificate Pinning** - TLS certificate validation prevents MITM attacks
- **Manual Pairing** - Enter pairing code manually if QR scanning is unavailable
- **Agent Management** - Manage multiple agent connections with easy switching
- **Real-time Chat** - Send and receive messages with AI agents
- **Message Streaming** - Display agent responses as they stream in real-time
- **Secure Credentials** - iOS Keychain encryption for connection credentials
- **Native SwiftUI** - Modern, fluid iOS interface with native look and feel
- **Full ACP Protocol** - Integrated with ACP Swift SDK

## Requirements

- iOS 17.0 or later
- Xcode 16.0+ (for development)

## Documentation

User guides are in the [Aptove docs](https://docs.aptove.com/mobile-app/overview).

For AI coding guidelines and CoreData schema reference, see [CLAUDE.md](CLAUDE.md).

## Building

1. Install Xcode 16.0 or later
2. Clone the repository
3. Open `Aptove.xcodeproj` in Xcode

The app uses the ACP Swift SDK via Swift Package Manager:

```swift
.package(url: "https://github.com/aptove/swift-sdk.git", from: "0.2.0")
```

```bash
# Build for simulator
xcodebuild -project Aptove.xcodeproj -scheme Aptove \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

# Build for device (requires signing)
xcodebuild -project Aptove.xcodeproj -scheme Aptove \
  -destination 'generic/platform=iOS' build
```

---

## ⚖️ License & Trademarks

### Software License
This project is licensed under the **Apache License 2.0**.
- You are free to use, modify, and distribute the code.
- You must include the original copyright notice and license in any copies.
- For full details, see the [LICENSE](LICENSE) file.

### Trademark Policy
The name **Aptove**, the logo, and all related branding are **not** part of the Apache 2.0 license.
- **Redistribution:** If you distribute a modified version of this app, you **must** remove all original branding and use a different name/icon.
- For full details on what is and isn't allowed, please read our [TRADEMARKS.md](TRADEMARKS.md) policy.

---
*Maintained by Saltuk Alakus. For commercial inquiries or licensing questions, please open an issue or contact saltukalakus@gmail.com*
