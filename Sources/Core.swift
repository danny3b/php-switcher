import Foundation
import Darwin

struct SwitcherError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CommandResult {
    let status: Int32
    let output: String
    let error: String
}

enum Command {
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 8,
                    environmentOverrides: [String: String] = [:]) throws -> CommandResult {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("php-switcher-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appendingPathComponent("out")
        let err = folder.appendingPathComponent("err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let output = try FileHandle(forWritingTo: out)
        let errors = try FileHandle(forWritingTo: err)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "PHPRC")
        environment.removeValue(forKey: "PHP_INI_SCAN_DIR")
        environment.merge(environmentOverrides) { _, new in new }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.04) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.15)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw SwitcherError(message: L("Polecenie nie zakończyło się w wyznaczonym czasie: {0}. Odśwież listę, aby sprawdzić stan instalacji.", String(describing: executable.path)))
        }
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus,
                             output: String(data: (try Data(contentsOf: out)).prefix(262144), encoding: .utf8) ?? "",
                             error: String(data: (try Data(contentsOf: err)).prefix(262144), encoding: .utf8) ?? "")
    }
}

struct PHPInstallation: Identifiable, Equatable, Codable, Sendable {
    var id: String { root }
    let root: String
    let version: String
    // Keep the source identifier stable for stored installations and removal checks.
    let source: String
    var sourceName: String { source == "PHP Switcher" ? "DevŻbik" : L(source) }
    var url: URL { URL(fileURLWithPath: root) }
    var binary: URL { url.appendingPathComponent("bin/php") }
}

struct Discovery: Sendable {
    let installations: [PHPInstallation]
    let unavailable: [String]
}

enum PHPRemovalKind: Sendable { case trash, forget, homebrew }

struct PHPHomebrewRemoval: Equatable, Sendable {
    let prefix: URL
    let formula: String
    let kegVersion: String
    var executable: URL { prefix.appendingPathComponent("bin/brew") }

    func run(_ arguments: [String]) throws -> CommandResult {
        let environment = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1",
                           "HOMEBREW_NO_AUTOREMOVE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1",
                           "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1"]
        #if arch(arm64)
        if prefix.path == "/usr/local" {
            return try Command.run(URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", executable.path] + arguments,
                                   timeout: 120, environmentOverrides: environment)
        }
        #endif
        return try Command.run(executable, arguments, timeout: 120, environmentOverrides: environment)
    }

    func checked(_ arguments: [String]) throws -> String {
        let result = try run(arguments)
        guard result.status == 0 else {
            throw SwitcherError(message: L("Homebrew nie wykonało operacji dla {0}.\n\n", String(describing: formula)) +
                                String((result.error + "\n" + result.output).trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000)))
        }
        return result.output
    }
}

struct PHPRemovalPlan: Sendable {
    let installation: PHPInstallation
    let kind: PHPRemovalKind
    let device: UInt64
    let inode: UInt64
    let homebrew: PHPHomebrewRemoval?
    let service: PHPUserService?
}

struct PHPUserService: Equatable, Sendable {
    let file: URL
    let label: String
    let binary: URL
    let contents: Data
    let device: UInt64
    let inode: UInt64
}

final class PHPManager: Sendable {
    let home: URL
    let mamp: URL
    let brews: [URL]
    var fm: FileManager { FileManager.default }
    var root: URL { home.appendingPathComponent(".local/php") }
    var current: URL { root.appendingPathComponent("current") }
    var settings: URL { home.appendingPathComponent("Library/Application Support/PHP Switcher/installations.json") }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         mamp: URL = URL(fileURLWithPath: "/Applications/MAMP/bin/php"),
         brews: [URL] = [URL(fileURLWithPath: "/usr/local/Cellar"), URL(fileURLWithPath: "/opt/homebrew/Cellar")]) {
        self.home = home; self.mamp = mamp; self.brews = brews
    }

    static func isValidVersion(_ value: String) -> Bool {
        value.range(of: #"^8\.(3|4|5)\.\d{1,3}$"#, options: .regularExpression) != nil
    }

    static func newestFirst(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedDescending
    }

    func children(_ parent: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    }

    func inspect(_ root: URL, source: String, configured: Bool = false) throws -> PHPInstallation {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let binary = resolved.appendingPathComponent("bin/php")
        guard fm.isExecutableFile(atPath: binary.path), !fm.fileExists(atPath: resolved.appendingPathComponent(".installing").path) else {
            throw SwitcherError(message: L("To nie jest gotowa instalacja PHP: {0}", String(describing: resolved.path)))
        }
        let result = try Command.run(binary, (configured ? [] : ["-n"]) + ["-r", "echo '\nPHP_SWITCHER_VERSION=',PHP_VERSION;"])
        guard result.status == 0,
              let marker = result.output.range(of: "PHP_SWITCHER_VERSION=", options: .backwards) else {
            throw SwitcherError(message: L("Nie można uruchomić PHP w {0}. {1}", String(describing: resolved.path), String(describing: result.error.prefix(300))))
        }
        let version = String(result.output[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.range(of: #"^\d+\.\d+\.\d+(?:[A-Za-z0-9.-]*)?$"#, options: .regularExpression) != nil else {
            throw SwitcherError(message: L("Nie rozpoznano wersji PHP."))
        }
        if configured && (result.error.contains("Failed loading") || result.error.contains("Unable to load dynamic library") || result.error.contains("Fatal error")) {
            throw SwitcherError(message: L("PHP ma błąd konfiguracji rozszerzeń. {0}", String(describing: result.error.prefix(400))))
        }
        return PHPInstallation(root: resolved.path, version: version, source: source)
    }

    func discover() -> Discovery {
        var candidates: [(URL, String)] = children(root).filter { $0.lastPathComponent != "current" }.map { ($0, "PHP Switcher") }
        candidates += children(mamp).filter { $0.lastPathComponent.hasPrefix("php") && $0.lastPathComponent != "php" }.map { ($0, "MAMP") }
        for brew in brews {
            for formula in children(brew) where formula.lastPathComponent == "php" || formula.lastPathComponent.hasPrefix("php@") {
                candidates += children(formula).map { ($0, "Homebrew") }
            }
        }
        candidates += customRoots().map { (URL(fileURLWithPath: $0), "Dodane ręcznie") }
        var seen = Set<String>(), found: [PHPInstallation] = [], errors: [String] = []
        for (url, source) in candidates {
            let resolved = url.resolvingSymlinksInPath().path
            guard seen.insert(resolved).inserted, fm.isExecutableFile(atPath: url.appendingPathComponent("bin/php").path),
                  !fm.fileExists(atPath: url.appendingPathComponent(".installing").path) else { continue }
            do { found.append(try inspect(url, source: source)) }
            catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        found.sort { $0.version == $1.version ? $0.source < $1.source : Self.newestFirst($0.version, $1.version) }
        return Discovery(installations: found, unavailable: errors)
    }

    func activeRoot() -> String? {
        guard (try? fm.destinationOfSymbolicLink(atPath: current.path)) != nil else { return nil }
        return current.resolvingSymlinksInPath().path
    }

    func customRoots() -> [String] {
        guard let data = try? Data(contentsOf: settings), let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return paths
    }

    func add(_ selected: URL) throws {
        var candidate = selected
        if selected.lastPathComponent == "php" && selected.deletingLastPathComponent().lastPathComponent == "bin" {
            candidate = selected.deletingLastPathComponent().deletingLastPathComponent()
        } else if selected.lastPathComponent == "bin" { candidate = selected.deletingLastPathComponent() }
        let installation = try inspect(candidate, source: "Dodane ręcznie")
        var roots = customRoots()
        if !roots.contains(installation.root) { roots.append(installation.root) }
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(roots).write(to: settings, options: .atomic)
    }

    func activate(_ installation: PHPInstallation) throws {
        try withInstallationLock { try activateLocked(installation) }
    }

    private func activateLocked(_ installation: PHPInstallation) throws {
        let checked = try inspect(installation.url, source: installation.source, configured: true)
        guard checked.version == installation.version else { throw SwitcherError(message: L("Wersja zmieniła się od ostatniego odświeżenia listy.")) }
        if let attrs = try? fm.attributesOfItem(atPath: current.path), attrs[.type] as? FileAttributeType != .typeSymbolicLink {
            throw SwitcherError(message: L("Ścieżka current jest zwykłym plikiem lub folderem. Nie została zastąpiona."))
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try ensureShellPath()
        let temporary = root.appendingPathComponent(".current-" + UUID().uuidString)
        try fm.createSymbolicLink(at: temporary, withDestinationURL: installation.url)
        defer { try? fm.removeItem(at: temporary) }
        guard rename(temporary.path, current.path) == 0 else { throw SwitcherError(message: L("Nie udało się przełączyć PHP: {0}", String(describing: String(cString: strerror(errno))))) }
    }

    /// Uses the same flock as install_php.py, so another app instance cannot remove
    /// the build template while an installation or activation is in progress.
    func withInstallationLock<T>(_ operation: () throws -> T) throws -> T {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent(".installer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SwitcherError(message: L("Nie można uzyskać blokady katalogu PHP.")) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw SwitcherError(message: L("Trwa instalowanie lub zmienianie PHP. Spróbuj po zakończeniu tej operacji."))
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    func prepareRemoval(_ installation: PHPInstallation, allowingServiceStop: Bool = false) throws -> PHPRemovalPlan {
        try preparePlan(installation, allowingServiceStop: allowingServiceStop, protectActive: true)
    }

    func prepareServiceStop(_ installation: PHPInstallation) throws -> PHPRemovalPlan {
        guard installation.source == "Homebrew" else { throw SwitcherError(message: L("Zatrzymywanie usług dotyczy PHP z Homebrew.")) }
        let plan = try preparePlan(installation, allowingServiceStop: true, protectActive: false)
        guard plan.service != nil else { throw SwitcherError(message: L("Ta wersja PHP nie ma zarejestrowanej usługi PHP-FPM. Możesz przejść do usuwania przyciskiem Kosza.")) }
        return plan
    }

    private func preparePlan(_ installation: PHPInstallation, allowingServiceStop: Bool, protectActive: Bool) throws -> PHPRemovalPlan {
        let candidate = installation.url.standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard !protectActive || activeRoot() != resolved.path else {
            throw SwitcherError(message: L("To jest aktywne PHP. Najpierw wybierz inną wersję przyciskiem Użyj."))
        }
        let attributes = try fm.attributesOfItem(atPath: candidate.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw SwitcherError(message: L("Można usunąć wyłącznie katalog instalacji; dowiązania nie są usuwane."))
        }
        let kind: PHPRemovalKind
        var homebrew: PHPHomebrewRemoval?
        var service: PHPUserService?
        switch installation.source {
        case "PHP Switcher":
            let rootAttributes = try fm.attributesOfItem(atPath: root.path)
            let expected = root.resolvingSymlinksInPath().appendingPathComponent(installation.version)
            guard rootAttributes[.type] as? FileAttributeType == .typeDirectory,
                  Self.isValidVersion(installation.version),
                  candidate.path == expected.path, resolved.path == expected.path else {
                throw SwitcherError(message: L("Ten katalog nie jest wersją zarządzaną przez DevŻbik."))
            }
            kind = .trash
        case "Dodane ręcznie":
            guard try registeredRoots().contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == resolved.path }) else {
                throw SwitcherError(message: L("Tej instalacji nie ma już na liście dodanych katalogów. Odśwież listę."))
            }
            kind = .forget
        case "Homebrew":
            let brew = try prepareHomebrewRemoval(installation)
            homebrew = brew
            service = try homebrewService(brew, installation: installation)
            if service != nil && !allowingServiceStop {
                throw SwitcherError(message: L("PHP {0} ma zarejestrowaną usługę PHP-FPM. Najpierw wybierz Zatrzymaj usługę w aplikacji, a potem ponów usuwanie.", String(describing: installation.version)))
            }
            kind = .homebrew
        default:
            throw SwitcherError(message: L("Tą instalacją zarządza {0}. Usuń ją w tym narzędziu.", String(describing: installation.source)))
        }
        let checked = try inspect(candidate, source: installation.source)
        guard checked.version == installation.version else {
            throw SwitcherError(message: L("Wersja PHP zmieniła się od ostatniego odświeżenia. Odśwież listę przed usunięciem."))
        }
        guard let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw SwitcherError(message: L("Nie można potwierdzić tożsamości katalogu instalacji."))
        }
        return PHPRemovalPlan(installation: installation, kind: kind, device: device.uint64Value, inode: inode.uint64Value, homebrew: homebrew, service: service)
    }

    /// Revalidates the confirmed directory and active selection under the shared lock.
    /// A failed Trash operation leaves the installation registered and in place.
    @discardableResult
    func remove(_ plan: PHPRemovalPlan, trash: (URL) throws -> URL? = PHPManager.moveToTrash) throws -> URL? {
        try withInstallationLock {
            let currentPlan = try prepareRemoval(plan.installation)
            guard currentPlan.kind == plan.kind, currentPlan.device == plan.device, currentPlan.inode == plan.inode,
                  currentPlan.homebrew == plan.homebrew else {
                throw SwitcherError(message: L("Katalog instalacji zmienił się po otwarciu potwierdzenia. Odśwież listę i spróbuj ponownie."))
            }
            // inspect() can take time; check the current link again immediately before changing files.
            guard activeRoot() != plan.installation.url.resolvingSymlinksInPath().path else {
                throw SwitcherError(message: L("Ta wersja została właśnie aktywowana. Najpierw wybierz inne PHP."))
            }
            switch plan.kind {
            case .trash:
                return try trash(plan.installation.url)
            case .forget:
                let resolved = plan.installation.url.resolvingSymlinksInPath().path
                let remaining = try registeredRoots().filter { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != resolved }
                try JSONEncoder().encode(remaining).write(to: settings, options: .atomic)
                return nil
            case .homebrew:
                guard let brew = currentPlan.homebrew else { throw SwitcherError(message: L("Brakuje danych instalacji Homebrew.")) }
                _ = try brew.checked(["uninstall", "--formula", brew.formula])
                guard !fm.fileExists(atPath: plan.installation.root) else {
                    throw SwitcherError(message: L("Homebrew pozostawiło PHP {0} na dysku. Pakiet może być przypięty (pinned); sprawdź jego stan w Homebrew.", String(describing: plan.installation.version)))
                }
                return nil
            }
        }
    }

    private func prepareHomebrewRemoval(_ installation: PHPInstallation) throws -> PHPHomebrewRemoval {
        let candidate = installation.url.standardizedFileURL
        let rack = candidate.deletingLastPathComponent()
        guard let cellar = brews.first(where: { $0.resolvingSymlinksInPath().path == rack.deletingLastPathComponent().path }),
              rack.lastPathComponent.range(of: #"^php(?:@\d+\.\d+)?$"#, options: .regularExpression) != nil,
              (try fm.attributesOfItem(atPath: rack.path))[.type] as? FileAttributeType == .typeDirectory,
              candidate.resolvingSymlinksInPath().path == candidate.path,
              candidate.lastPathComponent.range(of: #"^\d+\.\d+\.\d+(?:_\d+)?$"#, options: .regularExpression) != nil,
              candidate.lastPathComponent.split(separator: "_").first.map(String.init) == installation.version,
              (try? JSONSerialization.jsonObject(with: Data(contentsOf: candidate.appendingPathComponent("INSTALL_RECEIPT.json")))) is [String: Any] else {
            throw SwitcherError(message: L("Nie można potwierdzić, że ten katalog jest pakietem PHP z Homebrew."))
        }
        let brew = PHPHomebrewRemoval(prefix: cellar.deletingLastPathComponent(), formula: rack.lastPathComponent,
                                      kegVersion: candidate.lastPathComponent)
        guard fm.isExecutableFile(atPath: brew.executable.path) else {
            throw SwitcherError(message: L("Nie znaleziono programu Homebrew: {0}", String(describing: brew.executable.path)))
        }
        let actualCellar = try brew.checked(["--cellar"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard actualCellar.hasPrefix("/"), URL(fileURLWithPath: actualCellar).resolvingSymlinksInPath().path == cellar.resolvingSymlinksInPath().path else {
            throw SwitcherError(message: L("Homebrew wskazuje inny katalog instalacji. Usuwanie zostało przerwane."))
        }
        // brew uninstall selects a keg through opt/linked_kegs. Only proceed when
        // its formula has exactly the selected keg, so no other version can be removed.
        let kegs = try fm.contentsOfDirectory(at: rack, includingPropertiesForKeys: nil, options: .skipsHiddenFiles).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let versions = try brew.checked(["list", "--versions", "--formula", brew.formula]).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard kegs.map({ $0.resolvingSymlinksInPath().path }) == [candidate.path], versions == [brew.formula, brew.kegVersion] else {
            throw SwitcherError(message: L("Pakiet {0} ma kilka wersji lub jego stan się zmienił. Homebrew nie pozwala tu jednoznacznie usunąć tylko PHP {1}. Odśwież listę i uporządkuj starsze wydania tego pakietu w Homebrew.", String(describing: brew.formula), String(describing: installation.version)))
        }
        for link in [brew.prefix.appendingPathComponent("opt/" + brew.formula),
                     brew.prefix.appendingPathComponent("var/homebrew/linked/" + brew.formula)] {
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil,
               link.resolvingSymlinksInPath().path != candidate.path {
                throw SwitcherError(message: L("Dowiązanie Homebrew wskazuje inną wersję PHP. Odśwież listę przed usunięciem."))
            }
        }
        return brew
    }

    private func homebrewService(_ brew: PHPHomebrewRemoval, installation: PHPInstallation) throws -> PHPUserService? {
        struct Service: Decodable { let name: String; let status: String }
        let output = try brew.checked(["services", "list", "--json"])
        guard let data = output.data(using: .utf8), let services = try? JSONDecoder().decode([Service].self, from: data) else {
            throw SwitcherError(message: L("Nie można odczytać stanu usług Homebrew. Usuwanie PHP zostało przerwane."))
        }
        let serviceRunning = services.contains { $0.name == brew.formula && !["none", "stopped"].contains($0.status) }
        let label = "homebrew.mxcl." + brew.formula
        let systemFile = URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist")
        guard (try? fm.attributesOfItem(atPath: systemFile.path)) == nil else {
            throw SwitcherError(message: L("To systemowa usługa PHP-FPM zarządzana przez administratora. Ten przycisk obsługuje usługi bieżącego użytkownika; usługa systemowa nie została zmieniona."))
        }
        let file = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        guard let attributes = try? fm.attributesOfItem(atPath: file.path) else {
            guard !serviceRunning else { throw SwitcherError(message: L("PHP-FPM działa, ale nie znaleziono jego pliku usługi w Twoim katalogu LaunchAgents. Nie można bezpiecznie potwierdzić usługi do zatrzymania.")) }
            return nil
        }
        let contents = try Data(contentsOf: file)
        let binary = installation.url.appendingPathComponent("sbin/php-fpm").resolvingSymlinksInPath()
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let plist = try? PropertyListSerialization.propertyList(from: contents, format: nil) as? [String: Any],
              plist["Label"] as? String == label,
              let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first,
              program.hasPrefix("/"), URL(fileURLWithPath: program).resolvingSymlinksInPath().path == binary.path,
              let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw SwitcherError(message: L("Plik usługi {0} nie odpowiada tej instalacji PHP lub ma innego właściciela. Usługa nie została zmieniona.", String(describing: file.path)))
        }
        return PHPUserService(file: file, label: label, binary: binary, contents: contents, device: device.uint64Value, inode: inode.uint64Value)
    }

    /// Stops only the validated user LaunchAgent. This also handles older installed
    /// PHP taps which current Homebrew refuses to load. No formula code is executed.
    @discardableResult
    func stopService(_ plan: PHPRemovalPlan, launchctl: URL = URL(fileURLWithPath: "/bin/launchctl")) throws -> URL {
        try withInstallationLock {
            let fresh = try prepareServiceStop(plan.installation)
            guard fresh.device == plan.device, fresh.inode == plan.inode, fresh.homebrew == plan.homebrew,
                  let brew = fresh.homebrew, let service = fresh.service, service == plan.service else {
                throw SwitcherError(message: L("Instalacja lub plik usługi zmieniły się po otwarciu potwierdzenia. Spróbuj ponownie."))
            }
            let targets = ["gui/\(getuid())/\(service.label)", "user/\(getuid())/\(service.label)"]
            func isLoaded(_ target: String) throws -> Bool {
                let result = try Command.run(launchctl, ["print", target])
                if result.status == 113 && result.error.contains("Could not find service") { return false }
                guard result.status == 0 else {
                    throw SwitcherError(message: L("Nie można sprawdzić stanu usługi PHP-FPM.\n\n") + String(result.error.prefix(2000)))
                }
                let program = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { $0.hasPrefix("program = ") }.map { String($0.dropFirst("program = ".count)) }
                guard let program, program.hasPrefix("/"), URL(fileURLWithPath: program).resolvingSymlinksInPath().path == service.binary.path else {
                    throw SwitcherError(message: L("Uruchomiona usługa wskazuje inny program niż wybrane PHP. Nie została zatrzymana."))
                }
                return true
            }
            // Validate both domains before stopping either one.
            let loaded = try targets.filter { try isLoaded($0) }
            for target in loaded {
                let result = try Command.run(launchctl, ["bootout", target], timeout: 60)
                if result.status != 0, try isLoaded(target) {
                    throw SwitcherError(message: L("macOS nie zatrzymał usługi PHP-FPM.\n\n") + String(result.error.prefix(2000)))
                }
                guard try !isLoaded(target) else { throw SwitcherError(message: L("Usługa PHP-FPM nadal działa. Odinstalowanie nie zostało rozpoczęte.")) }
            }
            // A service file can change while launchctl runs. Never move a replacement.
            guard try homebrewService(brew, installation: plan.installation) == service else {
                throw SwitcherError(message: L("Plik autostartu zmienił się podczas zatrzymywania usługi. Nie został przeniesiony; odśwież stan i spróbuj ponownie."))
            }
            let backup = home.appendingPathComponent("Library/Application Support/PHP Switcher/stopped-services/\(UUID().uuidString)/\(service.label).plist")
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: service.file, to: backup)
            guard try targets.allSatisfy({ try !isLoaded($0) }) else {
                throw SwitcherError(message: L("Usługa PHP-FPM została ponownie uruchomiona. Odinstalowanie nie zostało rozpoczęte. Kopia ustawień autostartu: {0}", String(describing: backup.path)))
            }
            return backup
        }
    }

    private func registeredRoots() throws -> [String] {
        guard fm.fileExists(atPath: settings.path) else { return [] }
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: settings))
    }

    static func moveToTrash(_ url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    func ensureShellPath() throws {
        let file = home.appendingPathComponent(".zprofile")
        let text = fm.fileExists(atPath: file.path) ? try String(contentsOf: file, encoding: .utf8) : ""
        let desired = #"export PATH="$HOME/.local/php/current/bin:$PATH""#
        if text.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == desired }) { return }
        if (try? fm.destinationOfSymbolicLink(atPath: file.path)) != nil {
            throw SwitcherError(message: L("Plik .zprofile jest dowiązaniem. Dodaj ręcznie: {0}", String(describing: desired)))
        }
        let attrs = try? fm.attributesOfItem(atPath: file.path)
        if fm.fileExists(atPath: file.path) {
            try fm.copyItem(at: file, to: home.appendingPathComponent(".zprofile.php-switcher-" + UUID().uuidString + ".bak"))
        }
        try (text + "\n# DevŻbik — PHP in Terminal\n" + desired + "\n").write(to: file, atomically: true, encoding: .utf8)
        if let permissions = attrs?[.posixPermissions] { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
    }
}
