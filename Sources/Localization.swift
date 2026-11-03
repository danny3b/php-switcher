import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case polish = "pl"
    case english = "en"
    case german = "de"
    case french = "fr"
    case italian = "it"

    static let defaultsKey = "appLanguage"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .polish: return "Polski"
        case .english: return "English"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .italian: return "Italiano"
        }
    }
    var locale: Locale { Locale(identifier: rawValue) }
    static func preferred(from identifiers: [String] = Locale.preferredLanguages) -> Self {
        for identifier in identifiers {
            if let code = Locale(identifier: identifier).language.languageCode?.identifier,
               let language = Self(rawValue: code) { return language }
        }
        return .english
    }
    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? preferred()
    }
}

enum Localization {
    private static let bundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues:
        AppLanguage.allCases.compactMap { language in
            Bundle.main.url(forResource: language.rawValue, withExtension: "lproj")
                .flatMap(Bundle.init(url:)).map { (language, $0) }
        })

    /// Numbered placeholders allow translations to reorder arguments. Substituted
    /// values are never interpreted as format strings or as further placeholders.
    static func text(_ key: String, arguments: [String] = [], language: AppLanguage = .current,
                     bundle: Bundle? = nil) -> String {
        let template = language == .polish ? key : ((bundle ?? bundles[language])?.localizedString(forKey: key, value: key, table: nil) ?? key)
        let pattern = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        var result = "", cursor = template.startIndex
        for match in pattern.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let range = Range(match.range, in: template), let number = Range(match.range(at: 1), in: template),
                  let index = Int(template[number]), arguments.indices.contains(index) else { continue }
            result += template[cursor..<range.lowerBound] + arguments[index]
            cursor = range.upperBound
        }
        return result + template[cursor...]
    }
}

func L(_ key: String, _ arguments: String...) -> String {
    Localization.text(key, arguments: arguments)
}
