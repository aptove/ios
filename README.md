# Aptove - iOS

A mobile chat application for iOS that enables users to connect with AI agents using the Agent Client Protocol (ACP).

## Features

- **Secure QR Pairing** - Scan QR codes to securely pair with local bridge
- **Certificate Pinning** - TLS certificate validation prevents MITM attacks
- **Manual Pairing** - Enter pairing code manually if QR scanning unavailable
- **Agent Management** - Manage multiple agent connections with easy switching
- **Real-time Chat** - Send and receive messages with AI agents
- **Message Streaming** - Display agent responses as they stream in real-time
- **Secure Credentials** - iOS Keychain encryption for connection credentials
- **Native SwiftUI** - Modern, fluid iOS interface with native look and feel
- **Full ACP Protocol** - Integrated with ACP Swift SDK

## Requirements

- iOS 15.0 or later
- Swift 6.0+
- Xcode 16.0+ (for development)

## Architecture

The app follows MVVM pattern with SwiftUI:

```
Aptove/
├── Models/
│   ├── Agent.swift           # Agent data model
│   ├── Message.swift         # Chat message model
│   └── ConnectionConfig.swift # Connection configuration
├── Services/
│   ├── AgentManager.swift    # Agent connection management
│   ├── KeychainService.swift # Secure credential storage
│   ├── PairingService.swift  # Secure pairing with cert pinning
│   └── ClientCache.swift     # Thread-safe client caching
├── ViewModels/
│   ├── AgentListViewModel.swift
│   ├── ChatViewModel.swift
│   └── QRScannerViewModel.swift
├── Views/
│   ├── ContentView.swift     # Main navigation
│   ├── AgentListView.swift   # Agent list screen
│   ├── ChatView.swift        # Chat interface
│   ├── QRScannerView.swift   # QR code scanner
│   └── ManualPairingView.swift # Manual pairing entry
└── AptoveApp.swift           # App entry point
```

## Technology Stack

- **UI**: SwiftUI
- **Architecture**: MVVM
- **Networking**: ACP Swift SDK with WebSocket transport
- **Security**: iOS Keychain + Certificate Pinning
- **QR Scanning**: AVFoundation Camera
- **Concurrency**: Swift Concurrency (async/await, actors)

## Building

### Prerequisites

1. Install Xcode 16.0 or later
2. Clone the repository
3. Open `Aptove.xcodeproj` in Xcode

### ACP SDK Integration

The app uses the ACP Swift SDK via Swift Package Manager:

```swift
// Package dependency
.package(url: "https://github.com/aptove/swift-sdk.git", from: "0.1.13")
```

### Build Commands

```bash
# Build for simulator
xcodebuild -project Aptove.xcodeproj -scheme Aptove \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

# Build for device (requires signing)
xcodebuild -project Aptove.xcodeproj -scheme Aptove \
  -destination 'generic/platform=iOS' build
```

## Configuration

The app connects to ACP agents by scanning a pairing QR code from the bridge:

```
https://192.168.1.100:3001/pair/local?code=123456&fp=SHA256:XXXX...
```

The QR code contains:
- **Pairing URL** - Bridge's HTTPS endpoint
- **Pairing Code** - 6-digit one-time code (expires in 60 seconds)
- **Certificate Fingerprint** - For TLS certificate pinning

After successful pairing, the app receives WebSocket credentials securely.

## Security

- **Credential Storage**: Uses iOS Keychain for secure credential storage
- **Certificate Pinning**: Validates TLS certificate fingerprint from QR code
- **Secure Pairing**: One-time codes with 60-second expiry and rate limiting
- **Actor Isolation**: Thread-safe client management using Swift actors

## Known Limitations

1. **Background Sync**: Messages are not synced in background. App must be active for real-time communication.

2. **Local Network Only**: Secure pairing requires device to be on same network as bridge.

## Future Enhancements

- [ ] Cloudflare tunnel support for remote access
- [ ] Push notifications for messages
- [ ] File attachments support
- [ ] Voice input with Speech framework
- [ ] Session management (fork, resume)
- [ ] Widget support

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
