import SwiftUI

struct LanguageSelectionView: View {
    @ObservedObject var preferences: AppPreferences
    @State private var selection: AppLanguage

    init(preferences: AppPreferences) {
        self.preferences = preferences
        _selection = State(initialValue: preferences.language)
    }

    private func text(_ key: String) -> String { Localization.text(key, language: selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(text("Wybierz język aplikacji"), systemImage: "globe")
                .font(.title2.bold())
            Picker(text("Język programu"), selection: $selection) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.name).tag(language)
                }
            }.pickerStyle(.radioGroup).labelsHidden()
            Text(text("Możesz zmienić język później w Ustawieniach."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(text("Kontynuuj")) { preferences.completeLanguageSelection(selection) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 440, alignment: .leading)
        .environment(\.locale, selection.locale)
        .interactiveDismissDisabled()
    }
}
