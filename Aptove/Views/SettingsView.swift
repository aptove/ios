import SwiftUI
import Speech

struct SettingsView: View {
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @AppStorage("voiceLanguage") private var voiceLanguage: String = "en-US"
    @AppStorage("isVerboseMode") private var isVerboseMode: Bool = true
    @Environment(\.tabBarHeight) private var tabBarHeight

    private var themeSubtitle: LocalizedStringKey {
        isDarkMode ? "settings_dark_theme_active" : "settings_light_theme_active"
    }

    private var verboseModeSubtitle: LocalizedStringKey {
        isVerboseMode ? "settings_verbose_messages_on" : "settings_verbose_messages_off"
    }

    private var currentLanguageName: String {
        let code = appLanguage.isEmpty
            ? (Locale.current.language.languageCode?.identifier ?? "en")
            : appLanguage
        return code == "tr" ? "Türkçe" : "English"
    }

    private var currentVoiceLanguageName: String {
        Locale.current.localizedString(forIdentifier: voiceLanguage) ?? voiceLanguage
    }

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Appearance")) {
                    HStack(spacing: 14) {
                        Image(systemName: isDarkMode ? "moon.fill" : "sun.max.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(isDarkMode ? Color.blue : Color.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dark Mode")
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Text(themeSubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: $isDarkMode)
                            .labelsHidden()
                    }
                    .padding(.vertical, 4)

                    HStack(spacing: 14) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.purple)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Verbose Messages")
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Text(verboseModeSubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: $isVerboseMode)
                            .labelsHidden()
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("Language")) {
                    NavigationLink(destination: LanguagePickerView(appLanguage: $appLanguage)) {
                        HStack(spacing: 14) {
                            Image(systemName: "globe")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Language")
                                Text(currentLanguageName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    NavigationLink(destination: VoiceLanguagePickerView(voiceLanguage: $voiceLanguage)) {
                        HStack(spacing: 14) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Voice Language")
                                Text(currentVoiceLanguageName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section(header: Text("About")) {
                    Link(destination: URL(string: "https://aptove.com/terms")!) {
                        HStack {
                            Text("Terms of Service")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                            .foregroundColor(.secondary)
                    }
                }

                // Spacer row so content scrolls above the floating tab bar.
                // safeAreaInset on the parent ZStack does not propagate through
                // this view's nested NavigationStack (UIKit limitation).
                Color.clear
                    .frame(height: tabBarHeight)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            .navigationTitle(Bundle.localized("Settings", language: appLanguage))
        }
    }
}

struct LanguagePickerView: View {
    @Binding var appLanguage: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tabBarHeight) private var tabBarHeight

    private let languages: [(code: String, name: String)] = [
        ("en", "English"),
        ("tr", "Türkçe")
    ]

    private var selectedCode: String {
        appLanguage.isEmpty
            ? (Locale.current.language.languageCode?.identifier ?? "en")
            : appLanguage
    }

    var body: some View {
        List {
            ForEach(languages, id: \.code) { lang in
                HStack {
                    Text(lang.name)
                    Spacer()
                    if selectedCode == lang.code {
                        Image(systemName: "checkmark")
                            .foregroundColor(.blue)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    appLanguage = lang.code
                    dismiss()
                }
            }
            Color.clear
                .frame(height: tabBarHeight)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
        }
        .navigationTitle(Bundle.localized("Language", language: appLanguage))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct VoiceLanguagePickerView: View {
    @Binding var voiceLanguage: String
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tabBarHeight) private var tabBarHeight

    private static let languages: [(code: String, name: String)] = {
        SFSpeechRecognizer.supportedLocales()
            .compactMap { locale -> (code: String, name: String)? in
                let code = locale.identifier
                guard let name = Locale.current.localizedString(forIdentifier: code) else { return nil }
                return (code: code, name: name)
            }
            .sorted { $0.name < $1.name }
    }()

    var body: some View {
        List {
            ForEach(Self.languages, id: \.code) { lang in
                HStack {
                    Text(lang.name)
                    Spacer()
                    if voiceLanguage == lang.code {
                        Image(systemName: "checkmark")
                            .foregroundColor(.blue)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    voiceLanguage = lang.code
                    dismiss()
                }
            }
            Color.clear
                .frame(height: tabBarHeight)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
        }
        .navigationTitle(Bundle.localized("Voice Language", language: appLanguage))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    SettingsView()
}
