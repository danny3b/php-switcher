import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case polish = "pl"
    case english = "en"

    static let defaultsKey = "appLanguage"
    var id: String { rawValue }
    var name: String { self == .polish ? "Polski" : "English" }
    var locale: Locale { Locale(identifier: rawValue) }
    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .polish
    }
}

enum Localization {
    static let englishBundle = Bundle.main.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:))

    /// Numbered placeholders allow translations to reorder arguments. Substituted
    /// values are never interpreted as format strings or as further placeholders.
    static func text(_ key: String, arguments: [String] = [], language: AppLanguage = .current,
                     bundle: Bundle? = englishBundle) -> String {
        let template = language == .english ? (bundle?.localizedString(forKey: key, value: key, table: nil) ?? key) : key
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
