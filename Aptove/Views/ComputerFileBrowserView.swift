import SwiftUI
import UIKit

/// Sheet that lets the user navigate the Aptove working-directory tree,
/// open files in a full-screen viewer, and add images or text files to a chat message.
struct ComputerFileBrowserView: View {
    @ObservedObject var fileService: ComputerFileService
    var onAddImage: (UIImage) -> Void
    var onAddFile: (FileAttachment) -> Void
    var onRemoveImage: (UIImage) -> Void
    var onRemoveFile: (FileAttachment) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var appLanguage: String = ""

    // Navigation stack paths — each element is the relative path from root
    @State private var navigationPath: [String] = []
    @State private var entries: [String: [FileEntry]] = [:] // path → entries
    @State private var loadingPaths: Set<String> = []
    @State private var errorPaths: Set<String> = []

    // Thumbnail cache: relative path → UIImage
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var loadingThumbnails: Set<String> = []

    // Track added items so rows show a badge and viewer shows Remove button
    @State private var addedImages: [String: UIImage] = [:]       // path → UIImage
    @State private var addedFiles: [String: FileAttachment] = [:] // path → FileAttachment

    // File viewer
    @State private var viewerEntry: (path: String, result: FileContentResult)? = nil
    @State private var loadingViewerPath: String? = nil

    var body: some View {
        NavigationStack(path: $navigationPath) {
            directoryView(path: "")
                .navigationDestination(for: String.self) { path in
                    directoryView(path: path)
                }
        }
    }

    @ViewBuilder
    private func directoryView(path: String) -> some View {
        let pathEntries = entries[path] ?? []
        let isLoading = loadingPaths.contains(path)
        let hasError = errorPaths.contains(path)
        let title = path.isEmpty ? Bundle.localized("computer_files_title", language: appLanguage)
                                 : URL(fileURLWithPath: path).lastPathComponent

        Group {
            if isLoading && pathEntries.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundColor(.orange)
                    Text("computer_files_error")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pathEntries.isEmpty && !isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.largeTitle).foregroundColor(.secondary)
                    Text("computer_files_empty")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(pathEntries) { entry in
                    fileRow(entry: entry, dirPath: path)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if navigationPath.isEmpty {
                    Button("close_button") { dismiss() }
                }
            }
        }
        .task(id: path) {
            await loadDirectory(path: path)
        }
        .sheet(item: Binding(
            get: { viewerEntry.map { VE(path: $0.path, result: $0.result) } },
            set: { if $0 == nil { viewerEntry = nil } }
        )) { ve in
            let alreadyAdded = addedImages[ve.path] != nil || addedFiles[ve.path] != nil
            FileViewerView(
                fileName: URL(fileURLWithPath: ve.path).lastPathComponent,
                result: ve.result,
                onAddImage: { image in
                    addedImages[ve.path] = image
                    onAddImage(image)
                },
                onAddFile: { file in
                    addedFiles[ve.path] = file
                    onAddFile(file)
                },
                isAdded: alreadyAdded,
                onRemove: {
                    if let image = addedImages.removeValue(forKey: ve.path) {
                        onRemoveImage(image)
                    } else if let file = addedFiles.removeValue(forKey: ve.path) {
                        onRemoveFile(file)
                    }
                }
            )
        }
    }

    @ViewBuilder
    private func fileRow(entry: FileEntry, dirPath: String) -> some View {
        let entryPath = dirPath.isEmpty ? entry.name : "\(dirPath)/\(entry.name)"
        let isLoadingViewer = loadingViewerPath == entryPath
        let isAdded = addedImages[entryPath] != nil || addedFiles[entryPath] != nil

        Button {
            if entry.isDirectory {
                navigationPath.append(entryPath)
            } else {
                Task { await openFile(path: entryPath) }
            }
        } label: {
            HStack(spacing: 12) {
                // Icon / thumbnail area
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray6))
                        .frame(width: 48, height: 48)

                    if entry.isDirectory {
                        Image(systemName: "folder.fill")
                            .font(.title2)
                            .foregroundColor(.yellow)
                    } else if entry.isImage {
                        if let thumb = thumbnails[entryPath] {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundColor(.blue)
                        }
                    } else {
                        Image(systemName: fileIcon(for: entry.name))
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }

                    // Added badge — green checkmark in top-right corner
                    if isAdded {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                            .background(Circle().fill(Color(.systemBackground)).padding(-2))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(2)
                    }
                }
                .task(id: entryPath) {
                    if entry.isImage && !thumbnails.keys.contains(entryPath) {
                        await loadThumbnail(path: entryPath)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if !entry.isDirectory {
                        Text(formattedSize(entry.size))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if isLoadingViewer {
                    ProgressView().scaleEffect(0.8)
                } else if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data Loading

    private func loadDirectory(path: String) async {
        guard entries[path] == nil else { return }
        loadingPaths.insert(path)
        errorPaths.remove(path)
        do {
            let result = try await fileService.listFiles(path: path)
            entries[path] = result.entries
        } catch {
            errorPaths.insert(path)
        }
        loadingPaths.remove(path)
    }

    private func loadThumbnail(path: String) async {
        guard !loadingThumbnails.contains(path), thumbnails[path] == nil else { return }
        loadingThumbnails.insert(path)
        let result = await fileService.fetchContent(path: path)
        if case .image(let data, _) = result, let img = UIImage(data: data) {
            thumbnails[path] = img
        }
        loadingThumbnails.remove(path)
    }

    private func openFile(path: String) async {
        loadingViewerPath = path
        let result = await fileService.fetchContent(path: path)
        loadingViewerPath = nil
        viewerEntry = (path: path, result: result)
    }

    // MARK: - Helpers

    private func fileIcon(for name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        switch ext {
        case "rs": return "swift"
        case "swift": return "swift"
        case "py": return "doc.text.fill"
        case "js", "ts", "jsx", "tsx": return "doc.text.fill"
        case "html", "htm": return "globe"
        case "css": return "paintbrush.fill"
        case "json": return "curlybraces"
        case "md", "markdown": return "doc.richtext"
        case "sh", "bash", "zsh": return "terminal.fill"
        case "pdf": return "doc.fill"
        case "txt": return "doc.text"
        case "toml", "yaml", "yml": return "gearshape"
        default: return "doc"
        }
    }

    private func formattedSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

// Helper Identifiable wrapper for the viewer sheet
private struct VE: Identifiable {
    let path: String
    let result: FileContentResult
    var id: String { path }
}
