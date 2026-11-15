import Foundation
import os

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.aptove.app"

    /// Pairing, certificate validation, QR scanning
    static let pairing = Logger(subsystem: subsystem, category: "pairing")

    /// Agent connections, transport fallback, reconnect
    static let connection = Logger(subsystem: subsystem, category: "connection")

    /// CoreData, migrations, repositories
    static let data = Logger(subsystem: subsystem, category: "data")

    /// Push notifications, APNs tokens
    static let push = Logger(subsystem: subsystem, category: "push")

    /// Chat, messaging, streaming
    static let chat = Logger(subsystem: subsystem, category: "chat")

    /// QR camera scanner (native + software fallback)
    static let scanner = Logger(subsystem: subsystem, category: "scanner")

    /// App lifecycle
    static let app = Logger(subsystem: subsystem, category: "app")
}
