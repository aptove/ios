import UIKit

/// Persists per-agent avatar images in the app's Documents directory.
/// Files are stored as `{agentId}_avatar.jpg`.
enum AvatarStore {
    private static func url(for agentId: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(agentId)_avatar.jpg")
    }

    static func save(_ image: UIImage, for agentId: String) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: url(for: agentId), options: .atomic)
    }

    static func load(for agentId: String) -> UIImage? {
        guard let data = try? Data(contentsOf: url(for: agentId)) else { return nil }
        return UIImage(data: data)
    }

    static func delete(for agentId: String) {
        try? FileManager.default.removeItem(at: url(for: agentId))
    }
}
