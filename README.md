# Aptove - iOS

A mobile chat application for iOS that enables users to connect with AI agents using the Agent Client Protocol (ACP).

## Features

- **QR Code Agent Connection** - Scan QR codes to instantly connect to AI agents
- **Manual URL Entry** - Enter agent URLs manually for flexible connection options
- **Agent Management** - Manage multiple agent connections with easy switching
- **Real-time Chat** - Send and receive messages with AI agents
- **Message Streaming** - Display agent responses as they stream in real-time
- **Secure Credentials** - iOS Keychain encryption for connection credentials
- **Native SwiftUI** - Modern, fluid iOS interface with native look and feel
- **Full ACP Protocol** - Integrated with (soon to be) official ACP Swift SDK

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
│   └── ClientCache.swift     # Thread-safe client caching
├── ViewModels/
│   ├── AgentListViewModel.swift
│   └── ChatViewModel.swift
├── Views/
│   ├── ContentView.swift     # Main navigation
│   ├── AgentListView.swift   # Agent list screen
│   ├── ChatView.swift        # Chat interface
│   ├── QRScannerView.swift   # QR code scanner
│   └── ManualConnectionView.swift # Manual URL entry
└── AptoveApp.swift           # App entry point
```

## Technology Stack

- **UI**: SwiftUI
- **Architecture**: MVVM
- **Networking**: ACP Swift SDK with WebSocket transport
- **Security**: iOS Keychain
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

The app connects to ACP agents using QR codes or manual entry with the following format:

```json
{
  "url": "ws://192.168.1.100:8080",
  "protocol": "acp",
  "version": "1.0"
}
```

For Cloudflare Zero Trust connections:

```json
{
  "url": "wss://agent.yourdomain.com",
  "clientId": "xxxxx.access",
  "clientSecret": "xxxxxxxxxxxxxx",
  "protocol": "acp",
  "version": "1.0"
}
```

## Security

- **Credential Storage**: Uses iOS Keychain for secure credential storage
- **Network Security**: Supports both ws:// (local) and wss:// (secure) connections
- **Actor Isolation**: Thread-safe client management using Swift actors

## Known Limitations

1. **Background Sync**: Messages are not synced in background. App must be active for real-time communication.

2. **Single Active Chat**: Currently displays one active chat at a time.

## Future Enhancements

- [ ] Push notifications for messages
- [ ] File attachments support
- [ ] Voice input with Speech framework
- [ ] Session management (fork, resume)
- [ ] iCloud sync for settings
- [ ] Widget support
- [ ] Multiple concurrent agent connections

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
