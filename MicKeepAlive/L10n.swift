import Foundation

enum L10n {
    static var isChinese: Bool {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return !preferred.hasPrefix("en")
    }

    static func pick(_ zh: String, _ en: String) -> String {
        return isChinese ? zh : en
    }
}
