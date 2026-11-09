import Foundation
import UIKit
import ACPModel

// MARK: - Models

struct FileEntry: Decodable, Identifiable, Equatable {
    let name: String
    let kind: String   // "file" or "dir"
    let size: Int
    let isImage: Bool

    var id: String { name }
    var isDirectory: Bool { kind == "dir" }
}

struct FileListResult {
    let path: String
    let entries: [FileEntry]
}

enum FileContentResult {
    case text(String, mimeType: String)
    case image(Data, mimeType: String)
    case error(String)
}

// MARK: - Service

/// Sends `bridge/files/*` requests over the existing authenticated WebSocket and
/// routes the bridge responses back to callers via async/await continuations.
@MainActor
class ComputerFileService: ObservableObject {
    weak var client: ACPClientWrapper?

    // Pending continuations keyed by normalised path.
    // Only one outstanding request per path at a time is supported.
    private var pendingList: [String: CheckedContinuation<FileListResult, Error>] = [:]
    private var pendingContent: [String: CheckedContinuation<FileContentResult, Never>] = [:]

    // MARK: - Public API

    /// List the directory at `path` relative to the aptove working directory.
    /// Pass `""` or `"/"` for the root working directory.
    func listFiles(path: String) async throws -> FileListResult {
        guard let client = client else {
            throw FileServiceError.notConnected
        }
        let key = path
        return try await withCheckedThrowingContinuation { cont in
            pendingList[key] = cont
            Task {
                let params: JsonValue = .object(["path": .string(path)])
                await client.sendBridgeMessage(method: "bridge/files/list", params: params)
            }
        }
    }

    /// Fetch the content of the file at `path` relative to the aptove working directory.
    func fetchContent(path: String) async -> FileContentResult {
        guard let client = client else {
            return .error("not_connected")
        }
        let key = path
        return await withCheckedContinuation { cont in
            pendingContent[key] = cont
            Task {
                let params: JsonValue = .object(["path": .string(path)])
                await client.sendBridgeMessage(method: "bridge/files/content", params: params)
            }
        }
    }

    // MARK: - Response Dispatch (called by ACPClientWrapper)

    /// Route `bridge/files/listResponse` and `bridge/files/contentResponse` received
    /// from the bridge to their waiting continuations.
    func handleNotification(_ notif: JsonRpcNotification) {
        guard case .object(let p) = notif.params else { return }

        if notif.method == "bridge/files/listResponse" {
            guard case .string(let path) = p["path"] else { return }
            guard let cont = pendingList.removeValue(forKey: path) else { return }

            if case .string(let err) = p["error"] {
                cont.resume(throwing: FileServiceError.bridgeError(err))
                return
            }

            var entries: [FileEntry] = []
            if case .array(let arr) = p["entries"] {
                entries = arr.compactMap { item -> FileEntry? in
                    guard case .object(let obj) = item,
                          case .string(let name) = obj["name"],
                          case .string(let kind) = obj["kind"] else { return nil }
                    let size: Int
                    if case .int(let n) = obj["size"] { size = n }
                    else if case .double(let d) = obj["size"] { size = Int(d) }
                    else { size = 0 }
                    let isImage: Bool
                    if case .bool(let b) = obj["isImage"] { isImage = b }
                    else { isImage = false }
                    return FileEntry(name: name, kind: kind, size: size, isImage: isImage)
                }
            }
            cont.resume(returning: FileListResult(path: path, entries: entries))

        } else if notif.method == "bridge/files/contentResponse" {
            guard case .string(let path) = p["path"] else { return }
            guard let cont = pendingContent.removeValue(forKey: path) else { return }

            if case .string(let err) = p["error"] {
                cont.resume(returning: .error(err))
                return
            }

            guard case .string(let encoding) = p["encoding"],
                  case .string(let data) = p["data"],
                  case .string(let mime) = p["mimeType"] else {
                cont.resume(returning: .error("invalid_response"))
                return
            }

            if encoding == "text" {
                cont.resume(returning: .text(data, mimeType: mime))
            } else {
                guard let decoded = Data(base64Encoded: data) else {
                    cont.resume(returning: .error("decode_failed"))
                    return
                }
                cont.resume(returning: .image(decoded, mimeType: mime))
            }
        }
    }
}

enum FileServiceError: LocalizedError {
    case notConnected
    case bridgeError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Aptove"
        case .bridgeError(let msg): return "Bridge error: \(msg)"
        }
    }
}
