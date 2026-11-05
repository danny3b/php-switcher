import SwiftUI
import ServiceManagement

enum AppTab: String, CaseIterable, Identifiable {
    case versions, databases, settings, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .versions: return L("Wersje PHP")
        case .databases: return L("Bazy danych")
        case .settings: return L("Ustawienia")
        case .about: return L("O programie")
        }
    }
}

struct MainView: View {
    @ObservedObject private var store = SwitcherStore.shared
    @ObservedObject private var preferences = AppPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("Zakładka"), selection: Binding(get: { store.selectedTab }, set: { store.selectTab($0) })) {
                ForEach(AppTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .id(preferences.language)
            .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 8)
            switch store.selectedTab {
            case .versions: SwitcherView()
            case .databases: DatabasesView()
            case .settings: AppSettingsView(preferences: preferences)
            case .about: AboutView()
            }
        }
        .frame(minWidth: 720, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, preferences.language.locale)
        .sheet(isPresented: Binding(get: { preferences.needsLanguageSelection }, set: { _ in })) {
            LanguageSelectionView(preferences: preferences)
        }
    }
}

struct AppSettingsView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            Label(L("Ustawienia programu"), systemImage: "gearshape")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text(L("Dostosuj DevŻbik do siebie."))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(L("Język programu"), systemImage: "globe")
                    Spacer()
                    Picker(L("Język programu"), selection: $preferences.language) {
                        ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                    }.labelsHidden().frame(width: 180)
                }
                Text(L("Zmiana języka jest zapisywana automatycznie i działa od razu."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: Binding(get: { preferences.launchAtLogin }, set: { preferences.setLaunchAtLogin($0) })) {
                    Label(L("Uruchamiaj przy starcie systemu"), systemImage: "power")
                }.toggleStyle(.switch)
                Text(L("Otwieraj DevŻbik automatycznie po zalogowaniu do macOS."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if preferences.loginStatus == .requiresApproval {
                    Label(L("Autostart czeka na zgodę w Ustawieniach systemowych macOS."), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                    HStack {
                        Button(L("Otwórz ustawienia logowania")) { SMAppService.openSystemSettingsLoginItems() }
                        Button(L("Anuluj autostart")) { preferences.setLaunchAtLogin(false) }.buttonStyle(.link)
                    }
                } else if preferences.loginStatus == .notFound && preferences.loginError != nil {
                    Text(L("macOS nie znalazł aplikacji do autostartu. Uruchom ją z docelowego folderu Aplikacje i spróbuj ponownie."))
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
                if let error = preferences.loginError {
                    Text(L("Nie udało się zmienić autostartu: {0}", error))
                        .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                }
            }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            AppUpdateView()
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
            .onAppear { preferences.refreshLoginStatus() }
    }
}

struct AboutView: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 100, height: 100)
            VStack(spacing: 7) {
                Text("DevŻbik").font(.system(size: 30, weight: .bold, design: .rounded))
                Text(L("Wersja {0} ({1})", version, build)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(L("Natywna aplikacja macOS do zarządzania PHP i odświeżania lokalnych baz MySQL."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            VStack(spacing: 8) {
                Text(L("Twórca programu")).font(.system(size: 12)).foregroundStyle(.secondary)
                Text("danny3b").font(.system(size: 21, weight: .semibold, design: .rounded)).textSelection(.enabled)
            }.frame(maxWidth: 460).padding(.vertical, 24)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 0)
        }.padding(.top, 45).padding(.horizontal, 28).padding(.bottom, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
