import SwiftUI

struct SettingsView: View {
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @AppStorage("voiceLanguage") private var voiceLanguage: String = "en-US"

    private var themeSubtitle: LocalizedStringKey {
        isDarkMode ? "settings_dark_theme_active" : "settings_light_theme_active"
    }

    private var currentLanguageName: String {
        let code = appLanguage.isEmpty
            ? (Locale.current.language.languageCode?.identifier ?? "en")
            : appLanguage
        return code == "tr" ? "Türkçe" : "English"
    }

    private var currentVoiceLanguageName: String {
        voiceLanguage.hasPrefix("tr") ? "Türkçe" : "English"
    }

    var body: some View {
        NavigationView {
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
                            Text(themeSubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: $isDarkMode)
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
                    Link(destination: URL(string: "https://aptove.com/terms-of-service")!) {
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
            }
            .navigationTitle("Settings")
        }
    }
}

struct LanguagePickerView: View {
    @Binding var appLanguage: String
    @Environment(\.dismiss) private var dismiss

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
        }
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct VoiceLanguagePickerView: View {
    @Binding var voiceLanguage: String
    @Environment(\.dismiss) private var dismiss

    private let languages: [(code: String, name: String)] = [
        ("en-US", "English"),
        ("tr-TR", "Türkçe")
    ]

    var body: some View {
        List {
            ForEach(languages, id: \.code) { lang in
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
        }
        .navigationTitle("Voice Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    SettingsView()
}
