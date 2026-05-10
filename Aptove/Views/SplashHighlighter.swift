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
        guard language != nil else {
            return Text(content)
        }
        return syntaxHighlighter.highlight(content)
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
        private var accumulatedText: [Text]

        fileprivate init(theme: Splash.Theme) {
            self.theme = theme
            accumulatedText = []
        }

        mutating func addToken(_ token: String, ofType type: TokenType) {
            let color = theme.tokenColors[type] ?? theme.plainTextColor
            accumulatedText.append(Text(token).foregroundColor(SwiftUI.Color(color)))
        }

        mutating func addPlainText(_ text: String) {
            accumulatedText.append(
                Text(text).foregroundColor(SwiftUI.Color(theme.plainTextColor))
            )
        }

        mutating func addWhitespace(_ whitespace: String) {
            accumulatedText.append(Text(whitespace))
        }

        func build() -> Text {
            accumulatedText.reduce(Text(""), +)
        }
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let config: CodeBlockConfiguration
    @Environment(\.colorScheme) private var colorScheme

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
                config.label
                    .relativeLineSpacing(.em(0.25))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(12)
            }
            .background(SwiftUI.Color(theme.backgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SwiftUI.Color(theme.plainTextColor).opacity(0.15), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }
}
