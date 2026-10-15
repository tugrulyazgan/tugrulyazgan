import Foundation

/// User preferences for the translated line shown under each lyric
/// (e.g. a German song with its Turkish translation underneath).
enum TranslationSettings {
    enum Keys {
        static let enabled = "translationEnabled"
        static let language = "translationLanguage"
        static let colorHex = "translationColorHex"
    }

    static let defaultLanguage = "tr"
    static let defaultColorHex = "#FFD60A"

    struct Language: Identifiable {
        let code: String
        /// Name in the language itself.
        let name: String

        var id: String {
            code
        }
    }

    /// Target languages offered in Settings.
    static let languages: [Language] = [
        Language(code: "tr", name: "Türkçe"),
        Language(code: "en", name: "English"),
        Language(code: "de", name: "Deutsch"),
        Language(code: "fr", name: "Français"),
        Language(code: "es", name: "Español"),
        Language(code: "it", name: "Italiano"),
        Language(code: "ru", name: "Русский"),
        Language(code: "ar", name: "العربية"),
        Language(code: "ja", name: "日本語"),
        Language(code: "ko", name: "한국어"),
        Language(code: "zh-CN", name: "简体中文"),
    ]

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
    }

    static var targetLanguage: String {
        UserDefaults.standard.string(forKey: Keys.language) ?? defaultLanguage
    }

    static var colorHex: String {
        UserDefaults.standard.string(forKey: Keys.colorHex) ?? defaultColorHex
    }
}
