import SwiftUI
import AppKit
import Combine

struct InstallProgress: Decodable {
    let fraction: Double
    let message: String
    let messageKey: String?
    let messageArguments: [String]?
    let status: String
    let log: String
}

@MainActor final class SwitcherStore: ObservableObject {
    static let shared = SwitcherStore()
    let manager = PHPManager()
    @Published var selectedTab: AppTab = .versions
    @Published var installations: [PHPInstallation] = [] {
        didSet { if oldValue != installations { refreshSecurityAssessments() } }
    }
    @Published var activeRoot: String? {
        didSet { if oldValue != activeRoot { refreshSecurityAssessments() } }
    }
    @Published var loading = false
    @Published var working = false
    @Published var installing: String?
    @Published var progress: Double = 0
    @Published var progressText = ""
    @Published var notice = ""
    @Published var error: String?
    @Published var unavailable: [String] = []
    @Published var showOther = false
    @Published var customVersion = ""
    @Published var showOlder = false
    @Published var logPath: String?
    @Published var configuration: PHPIniEditor?
    @Published var removalStatus: String?
    @Published var securitySnapshot: PHPSecuritySnapshot? {
        didSet {
            assessmentCache.snapshot = securitySnapshot
            refreshSecurityAssessments()
        }
    }
    @Published private(set) var securityAssessments: [PHPSecurityAssessment] = []
    private let assessmentCache: PHPSecurityAssessmentCache
    init(assessmentCache: PHPSecurityAssessmentCache? = nil) {
        self.assessmentCache = assessmentCache ?? PHPSecurityAssessmentCache()
    }
    @Published var securityChecking = false
    @Published var securityError: String?
    @Published var securityDetails = false
    @Published var autoSecurity = UserDefaults.standard.object(forKey: "autoSecurity") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoSecurity, forKey: "autoSecurity")
            if autoSecurity { checkSecurity() }
        }
    }
    var securityTimer: Timer?
    var lastSecurityAttempt: Date?
    var securityCacheURL: URL { manager.home.appendingPathComponent("Library/Caches/PHP Switcher/security.json") }
    var suggested: [String] {
        ["8.5", "8.4", "8.3"].enumerated().map { index, branch in
            securitySnapshot?.releases[branch]?.version ?? ["8.5.12", "8.4.27", "8.3.36"][index]
        }
    }
    var monitored: [PHPInstallation] {
        installations.filter { $0.source == "PHP Switcher" || $0.source == "Dodane ręcznie" || $0.root == activeRoot }
    }
    private func refreshSecurityAssessments() {
        securityAssessments = assessmentCache.assessments(for: monitored)
    }
    var criticalSecurity: Bool { securityAssessments.contains { $0.critical } }
    var securityAttention: Bool { securityAssessments.contains { $0.needsAttention } }
    var securityFresh: Bool { securitySnapshot?.isFresh() == true && securityError == nil }
    var securityTitle: String {
        if securityChecking { return L("Sprawdzanie poprawek PHP…") }
        if securitySnapshot == nil { return securityError == nil ? L("Sprawdź poprawki bezpieczeństwa") : L("Nie udało się sprawdzić poprawek") }
        if criticalSecurity { return L("Dostępne krytyczne poprawki PHP") }
        if !securityFresh { return L("Wynik wymaga ponownego sprawdzenia") }
        if monitored.isEmpty { return L("Brak wersji PHP w zakresie sprawdzania") }
        if securityAttention { return L("Wersje PHP wymagają uwagi") }
        return L("Brak nowszych poprawek bezpieczeństwa")
    }

    func startSecurityChecks() {
        securitySnapshot = PHPSecurityCache.load(securityCacheURL)
        securityTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { self.objectWillChange.send(); self.checkSecurity() }
        }
    }

    func checkSecurity(force: Bool = false) {
        guard !securityChecking, !loading, force || autoSecurity else { return }
        if !force, let lastSecurityAttempt, Date().timeIntervalSince(lastSecurityAttempt) < 15 * 60 { return }
        if !force, securityError == nil, let snapshot = securitySnapshot, snapshot.isFresh(),
           monitored.allSatisfy({ item in
               guard let version = PHPVersion(item.version) else { return true }
               return !snapshot.supportedBranches.contains(version.branch) || snapshot.releases[version.branch] != nil
           }) { return }
        securityChecking = true
        lastSecurityAttempt = Date()
        let branches = monitored.compactMap { PHPVersion($0.version)?.branch }
        Task {
            do {
                let snapshot = try await PHPSecurityClient().fetch(branches: branches)
                securitySnapshot = snapshot
                securityError = nil
                try? PHPSecurityCache.save(snapshot, to: securityCacheURL)
            } catch {
                securityError = L("Nie można potwierdzić aktualnego stanu. ") + error.localizedDescription
            }
            securityChecking = false
        }
    }
    var process: Process?
    var timer: Timer?
    var stateURL: URL?
    var launcherLog: URL?
    var logHandle: FileHandle?
    var jobStatus = ""
    var hasInstallerProgress = false
    var canRestartForUpdate: Bool { !AppPreferences.shared.needsLanguageSelection && !loading && !working && installing == nil && configuration == nil }
    var busy: Bool { !canRestartForUpdate || AppUpdates.shared.phase == .installing }
    var active: PHPInstallation? { installations.first { $0.root == activeRoot } }
    var missing: [String] { suggested.filter { version in !installations.contains { $0.version == version } } }

    @discardableResult func selectTab(_ tab: AppTab) -> Bool {
        guard tab != selectedTab else { return true }
        if let editor = configuration, !editor.canClose() { return false }
        if configuration != nil { configuration = nil }
        if showOther { showOther = false }
        selectedTab = tab
        return true
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        let manager = manager
        DispatchQueue.global(qos: .userInitiated).async {
            let result = manager.discover()
            let active = manager.activeRoot()
            DispatchQueue.main.async {
                self.installations = result.installations
                self.unavailable = result.unavailable
                self.activeRoot = active
                self.loading = false
                self.checkSecurity()
            }
        }
    }

    func activate(_ installation: PHPInstallation) {
        guard !busy else { return }
        working = true; error = nil
        let manager = manager
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try manager.activate(installation)
                DispatchQueue.main.async {
                    self.activeRoot = installation.root
                    self.notice = L("PHP {0} jest teraz aktywne w terminalu.", String(describing: installation.version))
                    self.working = false
                    self.checkSecurity()
                }
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription; self.working = false }
            }
        }
    }

    func addInstallation() {
        let panel = NSOpenPanel()
        panel.title = L("Dodaj instalację PHP")
        panel.message = L("Wskaż folder wersji PHP albo plik bin/php.")
        panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        let manager = manager
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try manager.add(url)
                DispatchQueue.main.async { self.working = false; self.refresh() }
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription; self.working = false }
            }
        }
    }

    func removalHelp(_ installation: PHPInstallation) -> String {
        if installation.root == activeRoot { return L("Najpierw wybierz inną wersję PHP, aby usunąć tę instalację.") }
        switch installation.source {
        case "PHP Switcher": return L("Przenieś PHP {0} wraz z konfiguracją do Kosza", String(describing: installation.version))
        case "Dodane ręcznie": return L("Usuń PHP {0} z listy; pliki pozostaną na dysku", String(describing: installation.version))
        case "Homebrew": return L("Odinstaluj PHP {0} przez Homebrew", String(describing: installation.version))
        default: return L("Tą instalacją zarządza {0}. Usuń ją w tym narzędziu.", String(describing: installation.source))
        }
    }

    func requestRemoval(_ installation: PHPInstallation, preserveNotice: Bool = false) {
        guard !busy else { return }
        working = true; error = nil; logPath = nil
        if !preserveNotice { notice = "" }
        removalStatus = L("Sprawdzanie możliwości usunięcia PHP {0}…", String(describing: installation.version))
        let manager = manager
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let plan = try manager.prepareRemoval(installation, allowingServiceStop: true)
                DispatchQueue.main.async {
                    if plan.service != nil { self.confirmServiceStop(plan, continueRemoval: true) }
                    else { self.confirmRemoval(plan) }
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription
                    self.removalStatus = nil
                    self.working = false
                }
            }
        }
    }

    func requestServiceStop(_ installation: PHPInstallation) {
        guard !busy else { return }
        working = true; error = nil; logPath = nil; notice = ""
        removalStatus = L("Sprawdzanie usługi PHP {0}…", String(describing: installation.version))
        let manager = manager
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let plan = try manager.prepareServiceStop(installation)
                DispatchQueue.main.async { self.confirmServiceStop(plan, continueRemoval: false) }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription; self.removalStatus = nil; self.working = false
                }
            }
        }
    }

    private func confirmServiceStop(_ plan: PHPRemovalPlan, continueRemoval: Bool) {
        guard let service = plan.service else { removalStatus = nil; working = false; return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Zatrzymać usługę PHP {0}?", String(describing: plan.installation.version))
        alert.informativeText = L("Usługa: {0}\n\nPHP-FPM zostanie zatrzymane, a uruchamianie przy logowaniu wyłączone. Strony korzystające z tej usługi przestaną odpowiadać. Plik autostartu zostanie zachowany w kopii zapasowej.\n\n", String(describing: service.label)) +
            (continueRemoval ? L("Następnie pojawi się osobne potwierdzenie odinstalowania PHP.") : L("PHP pozostanie zainstalowane. Potem możesz je usunąć przyciskiem Kosza."))
        alert.addButton(withTitle: L("Anuluj"))
        alert.addButton(withTitle: L("Zatrzymaj usługę")).hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { removalStatus = nil; working = false; return }
        removalStatus = L("Zatrzymywanie usługi PHP {0}…", String(describing: plan.installation.version))
        let manager = manager
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try manager.stopService(plan)
                DispatchQueue.main.async {
                    self.notice = L("Usługa PHP {0} i jej autostart są wyłączone.", String(describing: plan.installation.version))
                    self.removalStatus = nil; self.working = false
                    if continueRemoval { self.requestRemoval(plan.installation, preserveNotice: true) }
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription; self.removalStatus = nil; self.working = false
                }
            }
        }
    }

    private func confirmRemoval(_ plan: PHPRemovalPlan) {
        let item = plan.installation
        let alert = NSAlert()
        alert.alertStyle = .warning
        let action: String
        let status: String
        let success: String
        switch plan.kind {
        case .trash:
            alert.messageText = L("Przenieść PHP {0} do Kosza?", String(describing: item.version))
            alert.informativeText = L("Do Kosza trafi cała instalacja wraz z jej php.ini i rozszerzeniami:\n\n{0}\n\nMożesz ją odzyskać, przenosząc folder z Kosza z powrotem w to miejsce.", String(describing: item.root))
            action = L("Przenieś do Kosza")
            status = L("Przenoszenie PHP {0} do Kosza…", String(describing: item.version))
            success = L("PHP {0} przeniesiono do Kosza.", String(describing: item.version))
        case .forget:
            alert.messageText = L("Usunąć PHP {0} z listy?", String(describing: item.version))
            alert.informativeText = L("Pliki pozostaną na dysku:\n\n{0}\n\nMożesz ponownie dodać tę instalację przyciskiem Dodaj z dysku.", String(describing: item.root))
            action = L("Usuń z listy")
            status = L("Usuwanie PHP {0} z listy…", String(describing: item.version))
            success = L("PHP {0} usunięto z listy. Pliki pozostały na dysku.", String(describing: item.version))
        case .homebrew:
            guard let brew = plan.homebrew else { removalStatus = nil; working = false; return }
            alert.messageText = L("Odinstalować PHP {0} przez Homebrew?", String(describing: item.version))
            alert.informativeText = L("Pakiet: {0}\n{1}\n\nHomebrew trwale usunie tę instalację i jej dowiązania. Pliki nie trafią do Kosza; odzyskanie wymaga ponownej instalacji.\n\nBiblioteki zależne oraz konfiguracja w {2}/etc/php nie będą automatycznie czyszczone. Homebrew przerwie operację, jeśli inne pakiety wymagają tego PHP.", String(describing: brew.formula), String(describing: item.root), String(describing: brew.prefix.path))
            action = L("Odinstaluj przez Homebrew")
            status = L("Odinstalowywanie PHP {0} przez Homebrew…", String(describing: item.version))
            success = L("PHP {0} odinstalowano przez Homebrew.", String(describing: item.version))
        }
        alert.addButton(withTitle: L("Anuluj"))
        alert.addButton(withTitle: action).hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else {
            removalStatus = nil; working = false; return
        }
        removalStatus = status
        let manager = manager
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try manager.remove(plan)
                DispatchQueue.main.async {
                    self.notice = success
                    self.removalStatus = nil
                    self.working = false
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription
                    self.removalStatus = nil
                    self.working = false
                    self.refresh()
                }
            }
        }
    }

    func install(_ version: String) {
        guard !busy else { return }
        guard PHPManager.isValidVersion(version) else {
            error = L("Podaj pełną wersję PHP 8.3, 8.4 lub 8.5, np. 8.4.27."); return
        }
        guard let script = Bundle.main.url(forResource: "install_php", withExtension: "py") else {
            error = L("Brakuje instalatora w pakiecie aplikacji."); return
        }
        do {
            let job = manager.home.appendingPathComponent("Library/Application Support/PHP Switcher/jobs/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
            stateURL = job.appendingPathComponent("state.json")
            launcherLog = job.appendingPathComponent("launcher.log")
            FileManager.default.createFile(atPath: launcherLog!.path, contents: nil)
            logHandle = try FileHandle(forWritingTo: launcherLog!)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            task.arguments = [script.path, "--version", version, "--state", stateURL!.path]
            task.standardOutput = logHandle
            task.standardError = logHandle
            task.terminationHandler = { _ in DispatchQueue.main.async { self.finishInstallation() } }
            error = nil; notice = ""; logPath = launcherLog?.path
            progress = 0; progressText = L("Uruchamianie instalatora…"); jobStatus = "running"; hasInstallerProgress = false
            installing = version; process = task
            try task.run()
            timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
                MainActor.assumeIsolated { self.readProgress() }
            }
        } catch {
            self.error = error.localizedDescription; installing = nil; process = nil
            try? logHandle?.close(); logHandle = nil
        }
    }

    func readProgress() {
        guard let url = stateURL, let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(InstallProgress.self, from: data) else { return }
        hasInstallerProgress = true
        progress = state.fraction
        progressText = Localization.text(state.messageKey ?? state.message, arguments: state.messageArguments ?? [])
        logPath = state.log; jobStatus = state.status
    }

    func finishInstallation() {
        timer?.invalidate(); timer = nil
        readProgress()
        let succeeded = process?.terminationStatus == 0
        if succeeded { notice = progressText }
        else if jobStatus == "cancelled" { notice = L("Instalacja anulowana. Aktywna wersja PHP pozostała bez zmian.") }
        else {
            let details = launcherLog.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            error = !hasInstallerProgress ? String(details.suffix(700)) : progressText
        }
        installing = nil; process = nil
        try? logHandle?.close(); logHandle = nil
        refresh()
    }

    func cancelInstall() { progressText = L("Anulowanie instalacji…"); process?.terminate() }

    func showConfiguration(_ installation: PHPInstallation) {
        guard !busy else { return }
        working = true; error = nil; logPath = nil
        let service = PHPIniService(manager: manager)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let snapshot = try service.read(installation)
                DispatchQueue.main.async {
                    self.configuration = PHPIniEditor(snapshot: snapshot, service: service)
                    self.working = false
                }
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription; self.working = false }
            }
        }
    }

    func showLog() { if let path = logPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
}

struct SwitcherView: View {
    @ObservedObject var store = SwitcherStore.shared
    @ObservedObject private var preferences = AppPreferences.shared
    private let accent = Color(red: 0.38, green: 0.34, blue: 0.87)
    var displayed: [PHPInstallation] {
        store.installations.filter { store.showOlder || $0.source == "PHP Switcher" || $0.source == "Dodane ręcznie" || $0.root == store.activeRoot }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 27, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(LinearGradient(colors: [accent, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
                Text("PHP Switcher").font(.system(size: 26, weight: .bold, design: .rounded))
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("Odśwież zainstalowane wersje")).disabled(store.busy)
            }.padding(28)

            HStack(spacing: 14) {
                Image(systemName: "terminal.fill").font(.system(size: 23)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("AKTYWNE W TERMINALU")).font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(.secondary)
                    Text(store.active.map { "PHP " + $0.version } ?? (store.loading ? L("Wczytywanie…") : L("Wybierz wersję PHP")))
                        .font(.system(size: 25, weight: .semibold, design: .monospaced))
                }
                Spacer()
                if store.active != nil {
                    Label(L("Aktywne"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
                }
            }.padding(20).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 15)).padding(.horizontal, 28)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SecurityView(store: store).padding(.top, 20)
                    HStack {
                        Text(L("Zainstalowane")).font(.system(size: 15, weight: .semibold))
                        Text("\(displayed.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Dodaj z dysku…")) { store.addInstallation() }.buttonStyle(.link).disabled(store.busy)
                    }.padding(.top, 23)
                    if displayed.isEmpty && !store.loading {
                        Text(L("Nie znaleziono PHP. Zainstaluj wersję poniżej albo wskaż istniejącą instalację."))
                            .foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    ForEach(displayed) { item in
                        HStack(spacing: 13) {
                            Text(String(item.version.split(separator: ".").prefix(2).joined(separator: ".")))
                                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                                .foregroundStyle(item.root == store.activeRoot ? accent : Color.secondary)
                                .frame(width: 52, height: 43)
                                .background(accent.opacity(item.root == store.activeRoot ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("PHP " + item.version).font(.system(size: 14, weight: .semibold))
                                Text(L(item.source)).font(.system(size: 11)).foregroundStyle(.secondary)
                            }.help(item.root)
                            Spacer()
                            Button { store.showConfiguration(item) } label: { Image(systemName: "slider.horizontal.3") }
                                .buttonStyle(.borderless).accessibilityLabel(L("Ustawienia PHP ") + item.version)
                                .help(L("Edytuj popularne ustawienia php.ini")).disabled(store.busy)
                            if item.root == store.activeRoot {
                                Text(L("Wybrane")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 78)
                            } else {
                                Button(L("Użyj")) { store.activate(item) }.buttonStyle(.borderedProminent).tint(accent).frame(width: 78).disabled(store.busy)
                            }
                            if item.source == "Homebrew" {
                                Button { store.requestServiceStop(item) } label: { Image(systemName: "stop.circle") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(L("Zatrzymaj usługę PHP {0}", String(describing: item.version)))
                                    .help(L("Zatrzymaj PHP-FPM i wyłącz uruchamianie przy logowaniu"))
                                    .disabled(store.busy)
                            }
                            Button { store.requestRemoval(item) } label: {
                                Image(systemName: item.source == "Dodane ręcznie" ? "minus.circle" : "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(item.source == "Dodane ręcznie" ? L("Usuń PHP {0} z listy", String(describing: item.version)) : L("Usuń PHP {0}", String(describing: item.version)))
                            .help(store.removalHelp(item))
                            .disabled(store.busy)
                        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                         .overlay(RoundedRectangle(cornerRadius: 11).stroke(item.root == store.activeRoot ? accent.opacity(0.35) : Color.primary.opacity(0.07), lineWidth: 1))
                    }
                    if store.installations.count > displayed.count || store.showOlder {
                        Toggle(L("Pokaż pozostałe instalacje (MAMP, Homebrew)"), isOn: $store.showOlder).toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(L("Instalowanie")).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button(L("Inna wersja…")) { store.showOther = true }.buttonStyle(.link).disabled(store.busy)
                    }.padding(.top, 14)
                    if !store.missing.isEmpty && store.installing == nil {
                        HStack(spacing: 10) {
                            ForEach(store.missing, id: \.self) { version in
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("PHP " + version).font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    Text(L("Oficjalne źródła PHP")).font(.system(size: 11)).foregroundStyle(.secondary)
                                    Button { store.install(version) } label: { Label(L("Zainstaluj"), systemImage: "arrow.down.circle") }
                                        .disabled(store.busy)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
                                 .background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
                            }
                        }
                    } else if store.installing == nil {
                        Text(L("Proponowane wersje są już zainstalowane. Kolejną dodasz przez „Inna wersja…”."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if let version = store.installing {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(L("Instalowanie PHP ") + version).fontWeight(.semibold)
                                Spacer()
                                Button(L("Anuluj")) { store.cancelInstall() }
                            }
                            ProgressView(value: store.progress).tint(accent)
                            Text(store.progressText).font(.system(size: 12)).foregroundStyle(.secondary)
                            Button(L("Pokaż dziennik")) { store.showLog() }.buttonStyle(.link).font(.system(size: 11))
                        }.padding(16).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
                    }
                    if !store.unavailable.isEmpty {
                        DisclosureGroup(L("Nie można uruchomić {0} starszych instalacji", String(describing: store.unavailable.count))) {
                            ForEach(store.unavailable, id: \.self) { Text($0).font(.system(size: 11)).textSelection(.enabled) }
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 28).padding(.bottom, 22)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let status = store.removalStatus {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.system(size: 12))
                    }
                }
                if !store.notice.isEmpty { Label(store.notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12)) }
                HStack(alignment: .top) {
                    Text(L("Dotyczy PHP w terminalu. Przy pierwszym użyciu otwórz nowe okno Terminala."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { NSWorkspace.shared.open(store.manager.root) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help(L("Folder instalacji PHP"))
                }
            }.padding(.horizontal, 28).padding(.vertical, 15)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 660, idealHeight: 770)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(L("Nie udało się wykonać operacji"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            if store.logPath != nil { Button(L("Dziennik")) { store.showLog() } }
            Button("OK", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .sheet(item: $store.configuration) { editor in
            PHPConfigurationView(editor: editor) { store.configuration = nil }
        }
        .sheet(isPresented: $store.showOther) {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("Zainstaluj PHP")).font(.title2.bold())
                Text(L("Podaj dokładną wersję z serii 8.3, 8.4 lub 8.5. Instalator sprawdzi ją na php.net.")).foregroundStyle(.secondary)
                TextField(L("np. 8.5.12"), text: $store.customVersion).textFieldStyle(.roundedBorder).onSubmit { installCustom() }
                HStack { Spacer(); Button(L("Anuluj")) { store.showOther = false }; Button(L("Zainstaluj")) { installCustom() }.keyboardShortcut(.defaultAction).disabled(!PHPManager.isValidVersion(store.customVersion.trimmingCharacters(in: .whitespaces))) }
            }.padding(26).frame(width: 410)
        }
    }
    func installCustom() {
        let version = store.customVersion.trimmingCharacters(in: .whitespaces)
        guard PHPManager.isValidVersion(version) else { return }
        store.showOther = false; store.install(version)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct MenuState: Equatable {
        let installations: [PHPInstallation]
        let activeRoot: String?
        let activeVersion: String?
        let securityTitle: String
        let critical: Bool
        let busy: Bool
        let checking: Bool
        let loading: Bool
        let updateReady: Bool
        let language: AppLanguage
    }
    private var lastMenuState: MenuState?
    private var menuUpdateScheduled = false
    var statusItem: NSStatusItem?
    var subscription: AnyCancellable?
    var preferencesSubscription: AnyCancellable?
    var updateSubscription: AnyCancellable?
    var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        item.button?.toolTip = L("PHP Switcher — aktywna wersja w terminalu")
        subscription = SwitcherStore.shared.objectWillChange.sink { [weak self] _ in
            self?.scheduleMenuUpdate()
        }
        preferencesSubscription = AppPreferences.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateMenu(); SwitcherStore.shared.objectWillChange.send() }
        }
        updateSubscription = AppUpdates.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateMenu(); SwitcherStore.shared.objectWillChange.send() }
        }
        AppUpdates.shared.canInstall = { SwitcherStore.shared.canRestartForUpdate }
        AppUpdates.shared.revealSettings = { [weak self] in self?.showSettings() }
        AppUpdates.shared.start()
        updateMenu()
        SwitcherStore.shared.startSecurityChecks()
        SwitcherStore.shared.refresh()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SwitcherStore.shared.checkSecurity() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func scheduleMenuUpdate() {
        guard !menuUpdateScheduled else { return }
        menuUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.menuUpdateScheduled = false
            self?.updateMenu()
        }
    }

    func updateMenu() {
        let store = SwitcherStore.shared
        let state = MenuState(installations: store.installations, activeRoot: store.activeRoot,
                              activeVersion: store.active?.version, securityTitle: store.securityTitle,
                              critical: store.criticalSecurity, busy: store.busy,
                              checking: store.securityChecking, loading: store.loading,
                              updateReady: AppUpdates.shared.phase == .ready, language: AppPreferences.shared.language)
        guard state != lastMenuState else { return }
        lastMenuState = state
        statusItem?.button?.title = (store.criticalSecurity ? "⚠︎ " : "") + "PHP " + (store.active?.version ?? "–")
        statusItem?.button?.toolTip = "PHP Switcher — " + store.securityTitle
        let menu = NSMenu()
        let title = NSMenuItem(title: L("PHP w terminalu"), action: nil, keyEquivalent: "")
        menu.addItem(title)
        for installation in store.installations where installation.version.compare("8.3.0", options: .numeric) != .orderedAscending {
            let entry = NSMenuItem(title: "\(installation.version) · \(L(installation.source))", action: #selector(choose(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = installation.root
            entry.state = installation.root == store.activeRoot ? .on : .off
            entry.isEnabled = !store.busy
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let security = NSMenuItem(title: store.securityTitle, action: #selector(showSecurity), keyEquivalent: "")
        security.target = self; menu.addItem(security)
        let check = NSMenuItem(title: store.securityChecking ? L("Sprawdzanie…") : L("Sprawdź poprawki teraz"), action: #selector(checkSecurity), keyEquivalent: "")
        check.target = self; check.isEnabled = !store.securityChecking && !store.loading; menu.addItem(check)
        menu.addItem(.separator())
        let show = NSMenuItem(title: L("Otwórz PHP Switcher…"), action: #selector(showWindow), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        let settings = NSMenuItem(title: L("Ustawienia programu…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let about = NSMenuItem(title: L("O PHP Switcher"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        let update = NSMenuItem(title: AppUpdates.shared.phase == .ready ? L("Aktualizacja gotowa do instalacji…") : L("Sprawdź aktualizacje aplikacji…"), action: #selector(showUpdates), keyEquivalent: "")
        update.target = self; menu.addItem(update)
        let quit = NSMenuItem(title: L("Zakończ"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem?.menu = menu
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let root = sender.representedObject as? String,
              let item = SwitcherStore.shared.installations.first(where: { $0.root == root }) else { return }
        SwitcherStore.shared.activate(item)
    }
    @objc func showWindow() { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
    @objc func showSecurity() { SwitcherStore.shared.selectTab(.versions); SwitcherStore.shared.securityDetails = true; showWindow() }
    @objc func showSettings() { SwitcherStore.shared.selectTab(.settings); showWindow() }
    @objc func showAbout() { SwitcherStore.shared.selectTab(.about); showWindow() }
    @objc func showUpdates() { showSettings(); AppUpdates.shared.check() }
    @objc func checkSecurity() { SwitcherStore.shared.checkSecurity(force: true) }
    func applicationDidBecomeActive(_ notification: Notification) {
        AppPreferences.shared.refreshLoginStatus()
        SwitcherStore.shared.objectWillChange.send()
        SwitcherStore.shared.checkSecurity()
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if SwitcherStore.shared.working { return .terminateCancel }
        if let editor = SwitcherStore.shared.configuration, !editor.canClose() { return .terminateCancel }
        if SwitcherStore.shared.installing != nil {
            let alert = NSAlert()
            alert.messageText = L("Trwa instalowanie PHP")
            alert.informativeText = L("Zamknięcie aplikacji anuluje instalację. Aktywna wersja PHP pozostanie bez zmian.")
            alert.addButton(withTitle: L("Pozostań")); alert.addButton(withTitle: L("Anuluj instalację i zamknij"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            SwitcherStore.shared.cancelInstall()
        }
        if AppUpdates.shared.prepareForTermination(completion: {
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }) { return .terminateLater }
        return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}

#if !TESTING
@main
#endif
struct PHPSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var preferences = AppPreferences.shared
    var body: some Scene {
        Window("PHP Switcher", id: "main") { MainView() }
            .defaultSize(width: 740, height: 820)
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(L("Ustawienia programu…")) { delegate.showSettings() }.keyboardShortcut(",")
                }
                CommandGroup(replacing: .appInfo) {
                    Button(L("O PHP Switcher")) { delegate.showAbout() }
                }
                CommandGroup(after: .appInfo) {
                    Button(L("Sprawdź aktualizacje aplikacji…")) { delegate.showUpdates() }
                }
            }
    }
}
