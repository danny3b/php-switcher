import Foundation

enum PHPIniField: String, CaseIterable, Identifiable, Sendable {
    case fileUploads = "file_uploads", upload = "upload_max_filesize", post = "post_max_size", files = "max_file_uploads"
    case memory = "memory_limit", execution = "max_execution_time", inputTime = "max_input_time", inputVars = "max_input_vars"
    case display = "display_errors", startup = "display_startup_errors", log = "log_errors", timezone = "date.timezone"
    var id: String { rawValue }
    var group: String {
        switch self {
        case .fileUploads, .upload, .post, .files: return "Wysyłanie plików"
        case .memory, .execution, .inputTime, .inputVars: return "Pamięć i limity"
        case .display, .startup, .log: return "Błędy i dzienniki"
        case .timezone: return "Data i czas"
        }
    }
    var title: String {
        switch self {
        case .fileUploads: return L("Zezwalaj na wysyłanie plików")
        case .upload: return L("Maksymalny rozmiar pliku")
        case .post: return L("Maksymalny rozmiar żądania POST")
        case .files: return L("Liczba plików w jednym żądaniu")
        case .memory: return L("Pamięć na jeden skrypt")
        case .execution: return L("Czas wykonywania skryptu")
        case .inputTime: return L("Czas przetwarzania danych wejściowych")
        case .inputVars: return L("Liczba zmiennych formularza")
        case .display: return L("Wyświetlanie błędów")
        case .startup: return L("Wyświetlanie błędów uruchamiania")
        case .log: return L("Zapisywanie błędów w dzienniku")
        case .timezone: return L("Strefa czasowa")
        }
    }
    var hint: String {
        switch self {
        case .upload: return L("Np. 32M, 128M lub 1G.")
        case .post: return L("Cały formularz wraz z plikami; ustaw więcej niż limit pliku. 0 wyłącza limit dla części typów żądań.")
        case .memory: return L("Np. 256M lub 1G; -1 oznacza brak limitu.")
        case .execution: return L("Sekundy; 0 oznacza brak limitu. CLI używa 0 niezależnie od zapisu w pliku.")
        case .inputTime: return L("Sekundy; -1 używa limitu wykonywania, 0 oznacza brak limitu. CLI pomija ten limit.")
        case .inputVars: return L("Łączny limit parametrów GET, POST lub COOKIE, np. 1000.")
        case .files: return L("Np. 20; puste pola przesyłania nie są wliczane.")
        case .display: return L("Włączenie jest przydatne podczas lokalnego debugowania.")
        case .log: return L("Miejsce zapisu określa istniejące ustawienie error_log.")
        case .timezone: return L("Np. Europe/Warsaw lub UTC.")
        default: return ""
        }
    }
    var isBoolean: Bool { [.fileUploads, .startup, .log].contains(self) }
    var isSize: Bool { [.upload, .post, .memory].contains(self) }
    func canonical(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isBoolean || self == .display {
            if ["1", "on", "true", "yes"].contains(value.lowercased()) { return "On" }
            if ["", "0", "off", "false", "no", "none"].contains(value.lowercased()) { return "Off" }
            if self == .display && value.lowercased() == "stderr" { return "stderr" }
        }
        return isSize ? value.uppercased() : value
    }
    func validated(_ raw: String, timezones: [String]) throws -> String {
        let value = canonical(raw)
        var valid = false
        if isBoolean { valid = ["On", "Off"].contains(value) }
        else if self == .display { valid = ["On", "Off", "stderr"].contains(value) }
        else if self == .timezone { valid = timezones.contains(value) }
        else if isSize {
            if self == .memory && value == "-1" { valid = true }
            else if let size = Self.bytes(value) { valid = self == .memory ? size > 0 : size >= 0 }
        } else if value.range(of: #"^-?\d{1,10}$"#, options: .regularExpression) != nil, let number = Int64(value) {
            valid = number >= (self == .inputTime ? -1 : 0) && number <= Int32.max
        }
        guard valid else { throw SwitcherError(message: L("{0}: nieprawidłowa wartość „{1}”. {2}", String(describing: title), String(describing: raw), String(describing: hint))) }
        return value
    }
    static func bytes(_ raw: String) -> Int64? {
        let value = raw.uppercased()
        guard value.range(of: #"^\d{1,19}[KMG]?$"#, options: .regularExpression) != nil else { return nil }
        let multipliers: [Character: Int64] = ["K": 1024, "M": 1024 * 1024, "G": 1024 * 1024 * 1024]
        let multiplier = value.last.flatMap { multipliers[$0] } ?? 1
        let numberText = multiplier == 1 ? value : String(value.dropLast())
        guard let number = Int64(numberText) else { return nil }
        let (result, overflow) = number.multipliedReportingOverflow(by: multiplier)
        return overflow ? nil : result
    }
    func equivalent(_ a: String, _ b: String) -> Bool {
        if isSize, let left = Self.bytes(canonical(a)), let right = Self.bytes(canonical(b)) { return left == right }
        return canonical(a) == canonical(b)
    }
}

struct PHPIniAssignment {
    let line: Int
    let prefix: String
    let suffix: String
    let value: String
}

struct PHPIniDocument {
    let text: String
    let assignments: [String: PHPIniAssignment]
    let multilineFields: Set<String>

    init(_ text: String) {
        self.text = text
        var found: [String: PHPIniAssignment] = [:], multiline = Set<String>()
        var conditional = false, carriedQuote: Character?
        let pattern = try! NSRegularExpression(pattern: #"^([ \t]*)([A-Za-z_][A-Za-z0-9_.]*)([ \t]*=[ \t]*)(.*)$"#)
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            var line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let bom = index == 0 && line.hasPrefix("\u{feff}") ? "\u{feff}" : ""
            if !bom.isEmpty { line.removeFirst() }
            if let quote = carriedQuote { carriedQuote = Self.splitValue(line, quote: quote).quote; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(";") || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("[") {
                conditional = trimmed.range(of: #"^\[\s*(PATH|HOST)\s*="#, options: [.regularExpression, .caseInsensitive]) != nil
                continue
            }
            guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let keyRange = Range(match.range(at: 2), in: line), let valueRange = Range(match.range(at: 4), in: line) else { continue }
            let key = String(line[keyRange]), value = String(line[valueRange])
            let parts = Self.splitValue(value)
            carriedQuote = parts.quote
            guard !conditional, PHPIniField(rawValue: key) != nil else { continue }
            if carriedQuote != nil { multiline.insert(key); continue }
            let token = parts.value.trimmingCharacters(in: .whitespaces)
            let rawValue: String
            if token.count >= 2 && ((token.first == "\"" && token.last == "\"") || (token.first == "'" && token.last == "'")) {
                rawValue = String(token.dropFirst().dropLast())
            } else { rawValue = token }
            found[key] = PHPIniAssignment(line: index, prefix: bom + String(line[..<valueRange.lowerBound]),
                suffix: String(parts.value.dropFirst(parts.value.trimmingCharacters(in: .whitespaces).count)) + parts.comment + (rawLine.hasSuffix("\r") ? "\r" : ""), value: rawValue)
        }
        assignments = found; multilineFields = multiline
    }
    private static func splitValue(_ value: String, quote initial: Character? = nil) -> (value: String, comment: String, quote: Character?) {
        var quote = initial, escaped = false
        for index in value.indices {
            let c = value[index]
            if escaped { escaped = false; continue }
            if c == "\\" && quote != nil { escaped = true; continue }
            if let current = quote { if c == current { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == ";" { return (String(value[..<index]), String(value[index...]), nil) }
        }
        return (value, "", quote)
    }
    func updating(_ changes: [String: String]) throws -> String {
        var lines = text.components(separatedBy: "\n"), added: [String] = []
        for key in changes.keys.sorted() {
            guard let field = PHPIniField(rawValue: key) else { throw SwitcherError(message: L("Nieobsługiwane ustawienie: {0}", String(describing: key))) }
            guard !multilineFields.contains(key) else { throw SwitcherError(message: L("{0} ma wartość wielowierszową. Zmień ją w edytorze tekstowym.", String(describing: key))) }
            let value = field == .timezone ? "\"\(changes[key]!)\"" : changes[key]!
            if let entry = assignments[key] { lines[entry.line] = entry.prefix + value + entry.suffix }
            else { added.append("\(key) = \(value)") }
        }
        let rewritten = lines.joined(separator: "\n")
        guard !added.isEmpty else { return rewritten }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let bom = rewritten.hasPrefix("\u{feff}") ? "\u{feff}" : ""
        return bom + "; DevŻbik settings" + newline + added.joined(separator: newline) + newline + (bom.isEmpty ? rewritten : String(rewritten.dropFirst()))
    }
}

struct PHPIniFile {
    let url: URL
    let data: Data
    let permissions: NSNumber
    let document: PHPIniDocument
}

struct PHPIniProbe: Decodable {
    let version: String
    let loaded: String?
    let scanned: [String]
    let values: [String: String]
    let timezones: [String]
}

struct PHPIniSnapshot {
    let installation: PHPInstallation
    let files: [PHPIniFile]
    let values: [String: String]
    let owners: [String: Int]
    let probe: PHPIniProbe
    func changes(_ edited: [String: String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for field in PHPIniField.allCases {
            let value = edited[field.rawValue] ?? values[field.rawValue] ?? ""
            if value != values[field.rawValue] {
                result[field.rawValue] = try field.validated(value, timezones: probe.timezones)
            }
        }
        return result
    }
    func warnings(_ edited: [String: String]) -> [String] {
        var messages: [String] = []
        if let upload = PHPIniField.bytes(edited["upload_max_filesize"] ?? ""),
           let post = PHPIniField.bytes(edited["post_max_size"] ?? ""), post > 0, post <= upload {
            messages.append(L("Limit POST powinien być większy niż limit pojedynczego pliku, aby pomieścić także pozostałe dane formularza."))
        }
        return messages
    }
}

struct PHPIniSaveResult {
    let snapshot: PHPIniSnapshot
    let backups: [URL]
}

final class PHPIniService: Sendable {
    let manager: PHPManager
    let run: @Sendable (URL, [String]) throws -> CommandResult
    init(manager: PHPManager, run: @escaping @Sendable (URL, [String]) throws -> CommandResult = { try Command.run($0, $1) }) {
        self.manager = manager; self.run = run
    }
    func read(_ installation: PHPInstallation) throws -> PHPIniSnapshot {
        let keys = PHPIniField.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let script = """
        $values=[]; foreach ([\(keys)] as $key) {$values[$key]=(string)ini_get($key);}
        $scanned=php_ini_scanned_files();
        echo 'PHP_SWITCHER_INI=',json_encode(['version'=>PHP_VERSION,'loaded'=>php_ini_loaded_file()?:null,
        'scanned'=>$scanned?array_values(array_filter(array_map('trim',explode(',',$scanned)))):[],
        'values'=>$values,'timezones'=>DateTimeZone::listIdentifiers(DateTimeZone::ALL_WITH_BC)]);
        """
        let result = try run(installation.binary, ["-r", script])
        guard result.status == 0, result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.output.hasPrefix("PHP_SWITCHER_INI="), let data = result.output.dropFirst("PHP_SWITCHER_INI=".count).data(using: .utf8) else {
            throw SwitcherError(message: L("PHP nie wczytało konfiguracji poprawnie. ") + String((result.error + result.output).prefix(450)))
        }
        let probe = try JSONDecoder().decode(PHPIniProbe.self, from: data)
        guard probe.version == installation.version else { throw SwitcherError(message: L("Wersja PHP zmieniła się. Odśwież listę instalacji.")) }
        guard let loaded = probe.loaded else { throw SwitcherError(message: L("Ta instalacja nie wczytuje pliku php.ini. Najpierw utwórz jej konfigurację.")) }
        var files: [PHPIniFile] = [], seen = Set<String>()
        for path in [loaded] + probe.scanned {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard seen.insert(url.path).inserted else { throw SwitcherError(message: L("Ten sam plik .ini jest wczytywany więcej niż raz. Uporządkuj konfigurację przed edycją.")) }
            let attributes = try manager.fm.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 2_000_000 else {
                throw SwitcherError(message: L("Nieobsługiwany plik konfiguracji: {0}", String(describing: url.path)))
            }
            let bytes = try Data(contentsOf: url)
            guard let text = String(data: bytes, encoding: .utf8) else { throw SwitcherError(message: L("Plik {0} nie jest zapisany w UTF-8.", String(describing: url.path))) }
            files.append(PHPIniFile(url: url, data: bytes, permissions: attributes[.posixPermissions] as? NSNumber ?? 0o644, document: PHPIniDocument(text)))
        }
        var values = probe.values, owners: [String: Int] = [:]
        for (index, file) in files.enumerated() {
            for (key, entry) in file.document.assignments { values[key] = entry.value; owners[key] = index }
        }
        for field in PHPIniField.allCases {
            values[field.rawValue] = field.canonical(values[field.rawValue] ?? "")
            if field == .timezone && values[field.rawValue] == "" { values[field.rawValue] = probe.values[field.rawValue] ?? "UTC" }
        }
        return PHPIniSnapshot(installation: installation, files: files, values: values, owners: owners, probe: probe)
    }

    func save(_ snapshot: PHPIniSnapshot, edited: [String: String]) throws -> PHPIniSaveResult {
        try manager.withInstallationLock {
            let changes = try snapshot.changes(edited)
            guard !changes.isEmpty else { return PHPIniSaveResult(snapshot: snapshot, backups: []) }
            let fresh = try read(snapshot.installation)
            guard fresh.files.map(\.url) == snapshot.files.map(\.url), fresh.files.map(\.data) == snapshot.files.map(\.data) else {
                throw SwitcherError(message: L("Konfiguracja zmieniła się od otwarcia okna. Wczytaj ją ponownie, aby nie nadpisać cudzych zmian."))
            }
            var perFile: [Int: [String: String]] = [:]
            for (key, value) in changes { perFile[snapshot.owners[key] ?? 0, default: [:]][key] = value }
            var replacements: [Int: Data] = [:], backups: [URL] = [], written: [Int] = []
            for index in perFile.keys.sorted() {
                let file = snapshot.files[index]
                guard manager.fm.isWritableFile(atPath: file.url.path), manager.fm.isWritableFile(atPath: file.url.deletingLastPathComponent().path) else {
                    throw SwitcherError(message: L("Brak uprawnień do zapisu {0}.", String(describing: file.url.path)))
                }
                replacements[index] = Data(try file.document.updating(perFile[index]!).utf8)
            }
            for index in replacements.keys.sorted() {
                let file = snapshot.files[index]
                let backup = file.url.appendingPathExtension("php-switcher-" + UUID().uuidString + ".bak")
                try manager.fm.copyItem(at: file.url, to: backup)
                backups.append(backup)
            }
            do {
                for index in replacements.keys.sorted() {
                    let file = snapshot.files[index]
                    guard try Data(contentsOf: file.url) == file.data else { throw SwitcherError(message: L("Plik zmienił się podczas zapisu: {0}", String(describing: file.url.path))) }
                    try replacements[index]!.write(to: file.url, options: .atomic)
                    written.append(index)
                    try manager.fm.setAttributes([.posixPermissions: file.permissions], ofItemAtPath: file.url.path)
                }
                let checked = try read(snapshot.installation)
                for (key, value) in changes {
                    let field = PHPIniField(rawValue: key)!
                    guard field.equivalent(value, checked.values[key] ?? "") else {
                        throw SwitcherError(message: L("PHP nie wczytało ustawienia {0} zgodnie z zapisem.", String(describing: key)))
                    }
                    if ![PHPIniField.execution, .inputTime].contains(field), !field.equivalent(value, checked.probe.values[key] ?? "") {
                        throw SwitcherError(message: L("PHP nadpisuje lub odrzuca ustawienie {0}. Sprawdź dodatkowe limity konfiguracji.", String(describing: key)))
                    }
                }
                return PHPIniSaveResult(snapshot: checked, backups: backups)
            } catch {
                var failed: [String] = []
                for index in written.reversed() {
                    let file = snapshot.files[index]
                    do {
                        guard try Data(contentsOf: file.url) == replacements[index] else { throw SwitcherError(message: L("Zmiana zewnętrzna")) }
                        try file.data.write(to: file.url, options: .atomic)
                        try manager.fm.setAttributes([.posixPermissions: file.permissions], ofItemAtPath: file.url.path)
                    } catch { failed.append(file.url.path) }
                }
                let recovery = failed.isEmpty ? L("Przywrócono poprzednią konfigurację.") : L("Nie udało się przywrócić: {0}. Kopie: {1}.", String(describing: failed.joined(separator: ", ")), String(describing: backups.map(\.path).joined(separator: ", ")))
                throw SwitcherError(message: error.localizedDescription + " " + recovery)
            }
        }
    }
}
