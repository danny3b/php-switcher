import AppKit
import Combine
import UniformTypeIdentifiers

struct DatabaseProgress: Decodable {
    let status: String
    let messageKey: String
    let messageArguments: [String]?
    let fraction: Double
    let databases: [String]?
    let serverID: String?
    let changed: Bool?
    let backupPath: String?
}

@MainActor final class DatabaseStore: ObservableObject {
    static let shared = DatabaseStore()
    private let defaults: UserDefaults
    private let passwordStore: DatabasePasswordStoring
    @Published var port: String { didSet { accountChanged(); defaults.set(port, forKey: "mysqlPort") } }
    @Published var user: String { didSet { accountChanged(); defaults.set(user, forKey: "mysqlUser") } }
    @Published var password = "" { didSet { connectionChanged(); verifiedCredential = nil } }
    @Published var clientPath: String { didSet { connectionChanged(); defaults.set(clientPath, forKey: "mysqlClientPath") } }
    @Published private(set) var rememberPassword: Bool
    @Published private(set) var credentialError: String?
    @Published private(set) var passwordReadFailed = false
    @Published private(set) var storedCredential: DatabaseCredential?
    @Published var createBackup = true
    @Published var selectedDatabase = ""
    @Published private(set) var sqlFile: URL?
    @Published private(set) var databases: [String] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isReplacing = false
    @Published private(set) var cancelling = false
    @Published private(set) var state: DatabaseProgress?
    @Published private(set) var error: String?
    @Published private(set) var backupURL: URL?
    @Published private(set) var databaseMayBePartial = false
    private var serverID: String?
    private var process: Process?
    private var timer: Timer?
    private var directory: URL?
    private var stateURL: URL?
    private var errorHandle: FileHandle?
    private var credentialsLoaded = false
    private var passwordAccount: DatabaseCredentialAccount?
    private var verifiedCredential: DatabaseCredential?
    private var activeCredential: DatabaseCredential?

    init(defaults: UserDefaults = .standard, passwordStore: DatabasePasswordStoring = DatabaseKeychain()) {
        self.defaults = defaults
        self.passwordStore = passwordStore
        let detected = Self.detectClient()
        clientPath = defaults.string(forKey: "mysqlClientPath") ?? detected ?? ""
        port = defaults.string(forKey: "mysqlPort") ?? (detected?.hasPrefix("/Applications/MAMP/") == true ? "8889" : "3306")
        user = defaults.string(forKey: "mysqlUser") ?? "root"
        rememberPassword = defaults.object(forKey: "rememberMySQLPassword") as? Bool ?? true
    }

    var credentialAccount: DatabaseCredentialAccount? { DatabaseCredentialAccount(port: port, user: user) }
    var passwordIsSaved: Bool {
        rememberPassword && storedCredential?.account == credentialAccount && storedCredential?.password == password
    }

    private func accountChanged() {
        connectionChanged()
        guard credentialAccount != passwordAccount else { return }
        verifiedCredential = nil
        if credentialsLoaded { restorePassword(force: true) }
        else { password = "" }
    }

    /// Load only when the Databases tab is used, not during unrelated PHP work.
    func restorePassword(force: Bool = false) {
        guard !isBusy, force || !credentialsLoaded || passwordAccount != credentialAccount else { return }
        credentialsLoaded = true
        passwordAccount = credentialAccount
        storedCredential = nil; credentialError = nil; passwordReadFailed = false
        password = ""
        guard rememberPassword, let account = credentialAccount else { return }
        do {
            if let saved = try passwordStore.password(for: account) {
                password = saved
                storedCredential = DatabaseCredential(account: account, password: saved)
            }
        } catch {
            passwordReadFailed = true
            credentialError = L("Nie udało się odczytać hasła z Pęku kluczy: {0}", error.localizedDescription)
        }
    }

    func setRememberPassword(_ enabled: Bool) {
        guard !isBusy, enabled != rememberPassword else { return }
        credentialError = nil; passwordReadFailed = false
        if !enabled, let account = credentialAccount {
            do { try passwordStore.removePassword(for: account) }
            catch {
                credentialError = L("Nie udało się usunąć hasła z Pęku kluczy: {0}", error.localizedDescription)
                return
            }
            storedCredential = nil
        }
        rememberPassword = enabled
        defaults.set(enabled, forKey: "rememberMySQLPassword")
        if enabled {
            if let verifiedCredential { recordSuccessfulConnection(verifiedCredential) }
            else if password.isEmpty { restorePassword(force: true) }
        }
    }

    // Called only for a successful connection, using the credentials actually
    // sent to the helper. A stale result must not save newly edited input.
    func recordSuccessfulConnection(_ credential: DatabaseCredential) {
        guard credential.account == credentialAccount, credential.password == password else { return }
        verifiedCredential = credential
        guard rememberPassword else { return }
        credentialError = nil; passwordReadFailed = false
        guard storedCredential != credential else { return }
        do {
            try passwordStore.save(credential)
            storedCredential = credential
        } catch {
            credentialError = L("Połączenie działa, ale nie udało się zapisać hasła w Pęku kluczy: {0}", error.localizedDescription)
        }
    }

    static func detectClient() -> String? {
        ["/Applications/MAMP/Library/bin/mysql80/bin/mysql", "/Applications/MAMP/Library/bin/mysql57/bin/mysql",
         "/Applications/MAMP/Library/bin/mysql", "/opt/homebrew/opt/mysql-client/bin/mysql",
         "/opt/homebrew/opt/mysql/bin/mysql", "/opt/homebrew/bin/mysql", "/usr/local/opt/mysql-client/bin/mysql",
         "/usr/local/opt/mysql/bin/mysql", "/usr/local/bin/mysql"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var connected: Bool { serverID != nil }
    var canConnect: Bool {
        !isBusy && Int(port).map { (1...65535).contains($0) } == true && !user.trimmingCharacters(in: .whitespaces).isEmpty && !clientPath.isEmpty
    }
    var canReplace: Bool { canConnect && connected && databases.contains(selectedDatabase) && sqlFile != nil }
    var message: String {
        guard let state else { return "" }
        return Localization.text(state.messageKey, arguments: state.messageArguments ?? [])
    }
    var backupDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PHP Switcher/database-backups")
    }

    private func connectionChanged() {
        serverID = nil; databases = []; selectedDatabase = ""
        if !isBusy { state = nil; error = nil }
    }

    func chooseClient() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = L("Wybierz program mysql")
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if !clientPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: clientPath).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            error = L("Wskaż wykonywalny program mysql."); return
        }
        clientPath = url.path
    }

    func chooseSQLFile() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = L("Wybierz plik SQL")
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "sql" else { error = L("Wybierz istniejący plik .sql."); return }
        sqlFile = url; error = nil
    }

    func connect() {
        guard canConnect, !SwitcherStore.shared.busy else { return }
        serverID = nil; databases = []; selectedDatabase = ""
        start(operation: "list")
    }

    func replace(confirmedName: String) {
        guard canReplace, confirmedName == selectedDatabase, !SwitcherStore.shared.busy else { return }
        start(operation: "replace")
    }

    private func start(operation: String) {
        guard let portNumber = Int(port), let script = Bundle.main.url(forResource: "import_database", withExtension: "py") else {
            error = L("Nie udało się uruchomić obsługi MySQL."); return
        }
        do {
            let job = FileManager.default.temporaryDirectory.appendingPathComponent("devzbik-database-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            directory = job
            stateURL = job.appendingPathComponent("state.json")
            let errorURL = job.appendingPathComponent("error.log")
            FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            errorHandle = try FileHandle(forWritingTo: errorURL)
            var request: [String: Any] = ["operation": operation, "port": portNumber, "user": user, "password": password, "client": clientPath]
            if operation == "replace" {
                request["database"] = selectedDatabase
                request["sqlFile"] = sqlFile?.path
                request["serverID"] = serverID
                request["backup"] = createBackup
                request["backupDirectory"] = backupDirectory.path
                request["lockDirectory"] = backupDirectory.deletingLastPathComponent().appendingPathComponent("database-locks").path
                backupURL = nil
            }
            let input = Pipe()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            task.arguments = [script.path, "--state", stateURL!.path]
            task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONDONTWRITEBYTECODE": "1", "LANG": "en_US.UTF-8"]
            task.standardInput = input
            task.standardOutput = FileHandle.nullDevice
            task.standardError = errorHandle
            task.terminationHandler = { _ in DispatchQueue.main.async { self.finish() } }
            activeCredential = credentialAccount.map { DatabaseCredential(account: $0, password: password) }
            error = nil; state = nil; databaseMayBePartial = false; cancelling = false
            isReplacing = operation == "replace"; isBusy = true; process = task
            try task.run()
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
            try input.fileHandleForWriting.close()
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                MainActor.assumeIsolated { self.readProgress() }
            }
        } catch {
            self.error = L("Nie udało się uruchomić obsługi MySQL.") + " " + error.localizedDescription
            if let process, process.isRunning { process.terminate() }
            else { cleanup() }
        }
    }

    private func readProgress() {
        guard let stateURL, let data = try? Data(contentsOf: stateURL),
              let result = try? JSONDecoder().decode(DatabaseProgress.self, from: data) else { return }
        state = result
        if let path = result.backupPath { backupURL = URL(fileURLWithPath: path) }
        databaseMayBePartial = result.changed == true && result.status != "complete"
    }

    private func finish() {
        readProgress()
        if process?.terminationStatus == 0 && state?.status == "complete" {
            if !isReplacing {
                databases = state?.databases ?? []
                serverID = state?.serverID
                selectedDatabase = ""
                if let activeCredential { recordSuccessfulConnection(activeCredential) }
            }
        } else if state?.status != "cancelled" {
            error = state?.status == "failed" ? message : L("Operacja MySQL została przerwana. Sprawdź stan wybranej bazy przed ponowną próbą.")
            if isReplacing && state == nil { databaseMayBePartial = true }
        }
        cleanup()
    }

    private func cleanup() {
        timer?.invalidate(); timer = nil
        try? errorHandle?.close(); errorHandle = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; stateURL = nil; process = nil
        activeCredential = nil
        isBusy = false; isReplacing = false; cancelling = false
    }

    func cancel() {
        guard isBusy, !cancelling else { return }
        if isReplacing {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("Anulować zastępowanie bazy?")
            alert.informativeText = L("Jeśli czyszczenie już się rozpoczęło, baza może pozostać pusta lub częściowo zaimportowana. Gotowa kopia zapasowa zostanie zachowana.")
            alert.addButton(withTitle: L("Kontynuuj"))
            alert.addButton(withTitle: L("Anuluj operację")).hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        cancelling = true
        process?.terminate()
    }
}
