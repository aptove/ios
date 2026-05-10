import MarkdownUI
import Splash
import SwiftUI

// MARK: - Syntax Highlighter

struct SplashHighlighter: CodeSyntaxHighlighter {
    private let syntaxHighlighter: SyntaxHighlighter<TextOutputFormat>

    init(theme: Splash.Theme) {
        self.syntaxHighlighter = SyntaxHighlighter(format: TextOutputFormat(theme: theme))
    }

    func highlightCode(_ content: String, language: String?) -> Text {
        guard language != nil else { return Text(content) }
        return Text(syntaxHighlighter.highlight(content))
    }
}

extension CodeSyntaxHighlighter where Self == SplashHighlighter {
    static func splash(theme: Splash.Theme) -> Self {
        SplashHighlighter(theme: theme)
    }

    static func splashAdapting(to colorScheme: ColorScheme) -> SplashHighlighter {
        SplashHighlighter(theme: colorScheme == .dark
            ? .wwdc17(withFont: .init(size: 16))
            : .sunset(withFont: .init(size: 16)))
    }
}

// MARK: - Text Output Format
// Builds an AttributedString (O(N) appends) instead of chaining Text+Text (O(N²)).

struct TextOutputFormat: OutputFormat {
    private let theme: Splash.Theme

    init(theme: Splash.Theme) {
        self.theme = theme
    }

    func makeBuilder() -> Builder {
        Builder(theme: theme)
    }
}

extension TextOutputFormat {
    struct Builder: OutputBuilder {
        private let theme: Splash.Theme
        private var attributed = AttributedString()

        fileprivate init(theme: Splash.Theme) {
            self.theme = theme
        }

        mutating func addToken(_ token: String, ofType type: TokenType) {
            let uiColor = theme.tokenColors[type] ?? theme.plainTextColor
            var part = AttributedString(token)
            part.foregroundColor = SwiftUI.Color(uiColor)
            attributed.append(part)
        }

        mutating func addPlainText(_ text: String) {
            var part = AttributedString(text)
            part.foregroundColor = SwiftUI.Color(theme.plainTextColor)
            attributed.append(part)
        }

        mutating func addWhitespace(_ whitespace: String) {
            attributed.append(AttributedString(whitespace))
        }

        func build() -> AttributedString {
            attributed
        }
    }
}

// MARK: - Code Block View
// Runs Splash off the main thread and caches by colorScheme to avoid re-highlighting on re-renders.

struct CodeBlockView: View {
    let config: CodeBlockConfiguration
    @Environment(\.colorScheme) private var colorScheme
    @State private var highlighted: AttributedString?

    private var theme: Splash.Theme {
        colorScheme == .dark
            ? .wwdc17(withFont: .init(size: 16))
            : .sunset(withFont: .init(size: 16))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(config.language ?? "code")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundColor(SwiftUI.Color(theme.plainTextColor))
                Spacer()
                Button {
                    UIPasteboard.general.string = config.content
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundColor(SwiftUI.Color(theme.plainTextColor).opacity(0.7))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(SwiftUI.Color(theme.backgroundColor))

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted ?? AttributedString(config.content))
                    .relativeLineSpacing(.em(0.25))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(12)
                    .foregroundColor(SwiftUI.Color(theme.plainTextColor))
            }
            .background(SwiftUI.Color(theme.backgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SwiftUI.Color(theme.plainTextColor).opacity(0.15), lineWidth: 1)
        )
        .padding(.vertical, 4)
        .task(id: colorScheme) {
            await computeHighlight()
        }
    }

    private func computeHighlight() async {
        let content = config.content
        let language = config.language
        let isDark = colorScheme == .dark

        let result: AttributedString = await Task.detached(priority: .userInitiated) {
            guard language != nil else { return AttributedString(content) }
            let theme: Splash.Theme = isDark
                ? .wwdc17(withFont: .init(size: 16))
                : .sunset(withFont: .init(size: 16))
            return SyntaxHighlighter(format: TextOutputFormat(theme: theme)).highlight(content)
        }.value

        highlighted = result
    }
}
