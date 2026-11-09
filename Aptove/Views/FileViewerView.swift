import SwiftUI
import WebKit
import UIKit

/// Full-screen viewer for files fetched from the Aptove computer file browser.
/// • Text / source-code files: rendered in a WKWebView with highlight.js syntax
///   colouring (CDN). Falls back gracefully to plain monospace text if offline.
/// • Images: displayed with pinch-to-zoom.
/// Both types show an "Add" toolbar button when the respective callback is provided.
struct FileViewerView: View {
    let fileName: String
    let result: FileContentResult
    var onAddImage: ((UIImage) -> Void)?
    var onAddFile: ((FileAttachment) -> Void)?
    var isAdded: Bool = false
    var onRemove: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            fileContent
                .navigationTitle(fileName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("close_button") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        actionButton
                    }
                }
        }
    }

    @ViewBuilder
    private var fileContent: some View {
        switch result {
        case .text(let code, let mimeType):
            CodeWebView(code: code, mimeType: mimeType)
                .ignoresSafeArea(edges: .bottom)
        case .image(let data, _):
            if let image = UIImage(data: data) {
                ImageScrollView(image: image)
            } else {
                Text("file_viewer_cannot_load_image")
                    .foregroundColor(.secondary)
            }
        case .error(let msg):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text("file_viewer_error_prefix")
                    .foregroundColor(.secondary)
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isAdded {
            Button("file_viewer_remove") {
                onRemove?()
                dismiss()
            }
            .fontWeight(.semibold)
            .tint(.red)
        } else {
            switch result {
            case .text(let code, let mimeType):
                if let onAddFile {
                    Button("file_viewer_add") {
                        let data = code.data(using: .utf8) ?? Data()
                        onAddFile(FileAttachment(name: fileName, data: data, mimeType: mimeType))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            case .image(let data, _):
                if let onAddImage, let image = UIImage(data: data) {
                    Button("file_viewer_add") {
                        onAddImage(image)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            case .error:
                EmptyView()
            }
        }
    }
}

// MARK: - Code WebView

private struct CodeWebView: UIViewRepresentable {
    let code: String
    let mimeType: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.backgroundColor = UIColor(red: 0.051, green: 0.067, blue: 0.090, alpha: 1)
        webView.isOpaque = false
        webView.scrollView.indicatorStyle = .white
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let lang = languageClass(for: mimeType)
        let escaped = escapeForHTML(code)
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=4">
        <link rel="stylesheet"
              href="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/styles/github-dark.min.css">
        <script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/highlight.min.js"></script>
        <style>
          html, body { margin:0; padding:0; background:#0d1117; }
          body { padding:16px; }
          pre { margin:0; }
          code { font-family: 'JetBrains Mono', 'Courier New', monospace;
                 font-size: 13px; line-height: 1.5;
                 white-space: pre-wrap; word-break: break-all; }
          /* Fallback: plain monospace if JS/CSS unavailable */
          code:not(.hljs) { color: #e6edf3; background: transparent; }
        </style>
        </head>
        <body>
        <pre><code class="language-\(lang)">\(escaped)</code></pre>
        <script>
        if (typeof hljs !== 'undefined') { hljs.highlightAll(); }
        </script>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func languageClass(for mime: String) -> String {
        switch mime {
        case "text/x-rust": return "rust"
        case "text/x-swift": return "swift"
        case "text/x-python": return "python"
        case "text/x-ruby": return "ruby"
        case "text/x-go": return "go"
        case "text/x-java": return "java"
        case "text/x-kotlin": return "kotlin"
        case "text/x-c", "text/x-cpp": return "cpp"
        case "text/x-csharp": return "csharp"
        case "text/x-shellscript": return "bash"
        case "text/javascript", "text/typescript": return "javascript"
        case "text/html": return "html"
        case "text/css": return "css"
        case "application/json": return "json"
        case "application/xml": return "xml"
        case "text/markdown": return "markdown"
        default: return "plaintext"
        }
    }

    private func escapeForHTML(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Image Scroll View (pinch-to-zoom)

private struct ImageScrollView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .black
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
            imageView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
