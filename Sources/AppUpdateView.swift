import SwiftUI

struct AppUpdateView: View {
    @ObservedObject private var updates = AppUpdates.shared
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var store = SwitcherStore.shared

    private var status: String {
        switch updates.phase {
        case .idle: return L("Zainstalowana wersja: {0}", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
        case .checking: return L("Sprawdzanie aktualizacji aplikacji…")
        case .available: return L("Dostępna wersja {0}", updates.version ?? "")
        case .downloading: return L("Pobieranie wersji {0}…", updates.version ?? "")
        case .extracting: return L("Weryfikowanie i przygotowywanie aktualizacji…")
        case .ready: return L("Wersja {0} jest gotowa do instalacji.", updates.version ?? "")
        case .installing: return L("Instalowanie aktualizacji aplikacji…")
        case .upToDate: return L("DevŻbik jest aktualny.")
        case .failed: return L("Nie udało się sprawdzić lub pobrać aktualizacji.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L("Aktualizacje aplikacji"), systemImage: "arrow.down.app")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(L("Sprawdź aktualizacje")) { updates.check() }
                    .disabled(!updates.canCheck || updates.isBusy)
            }
            Toggle(L("Sprawdzaj przy uruchomieniu i co 6 godzin"), isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                .toggleStyle(.checkbox)
            Toggle(L("Automatycznie pobieraj nowe wersje"), isOn: $updates.automaticDownloads)
                .toggleStyle(.checkbox)
            HStack(spacing: 10) {
                if updates.isBusy { ProgressView().controlSize(.small) }
                Text(status).font(.system(size: 12)).foregroundStyle(updates.phase == .ready ? Color.green : Color.secondary)
            }
            if let progress = updates.progress { ProgressView(value: progress) }
            if let lastChecked = updates.lastChecked {
                Text(L("Ostatnie sprawdzenie: {0}", lastChecked.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(preferences.language.locale))))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error = updates.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            }
            if updates.phase == .available {
                Button(L("Pobierz aktualizację")) { updates.download() }
            } else if updates.phase == .ready || updates.phase == .installing {
                Button(L("Zainstaluj i uruchom ponownie")) { updates.installAndRestart() }
                    .buttonStyle(.borderedProminent).disabled(!store.canRestartForUpdate)
                if !store.canRestartForUpdate {
                    Text(L("Zakończ bieżącą operację i zapisz lub zamknij edytor ustawień przed aktualizacją."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack {
                if [.checking, .downloading, .ready].contains(updates.phase) {
                    Button(L("Anuluj")) { updates.cancel() }.buttonStyle(.link)
                }
                Spacer()
                Link(L("Wydania na GitHubie"), destination: URL(string: "https://github.com/danny3b/php-switcher/releases")!)
                    .font(.system(size: 11))
            }
        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
