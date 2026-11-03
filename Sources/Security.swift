import Foundation

struct PHPVersion: Comparable, Hashable {
    let major: Int
    let minor: Int
    let patch: Int
    var branch: String { "\(major).\(minor)" }
    var text: String { "\(branch).\(patch)" }

    init?(_ text: String) {
        guard text.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,4}$"#, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        major = parts[0]; minor = parts[1]; patch = parts[2]
    }
    static func < (a: Self, b: Self) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
    static func extract(from text: String) -> [Self] {
        let regex = try! NSRegularExpression(pattern: #"(?<![\d.])\d{1,3}\.\d{1,3}\.\d{1,4}(?![\dA-Za-z])"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).flatMap { Self(String(text[$0])) }
        }
    }
}

/// GitHub advisories use comparisons, comma-separated intersections, and inclusive hyphen ranges.
/// Unknown grammar stays unknown: it must never turn into a clean security result.
enum PHPVersionRange {
    static func contains(_ version: PHPVersion, in expression: String) -> Bool? {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("||") {
            return union(text.components(separatedBy: "||").map { contains(version, in: $0) })
        }
        let parts = text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if text.contains(" - ") {
            return union(parts.map { part in
                let bounds = part.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
                guard bounds.count == 2, let lower = PHPVersion(bounds[0]), let upper = PHPVersion(bounds[1]) else { return nil }
                return lower <= version && version <= upper
            })
        }
        let checks: [Bool?] = parts.map { part in
            let regex = try! NSRegularExpression(pattern: #"^(<=|>=|<|>|=)?\s*(\d{1,3}\.\d{1,3}\.\d{1,4})$"#)
            guard let match = regex.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)),
                  let number = Range(match.range(at: 2), in: part), let bound = PHPVersion(String(part[number])) else { return nil }
            let op = Range(match.range(at: 1), in: part).map { String(part[$0]) } ?? "="
            switch op {
            case "<": return version < bound
            case "<=": return version <= bound
            case ">": return version > bound
            case ">=": return version >= bound
            default: return version == bound
            }
        }
        if checks.contains(where: { $0 == false }) { return false }
        return checks.contains(where: { $0 == nil }) ? nil : true
    }
    private static func union(_ values: [Bool?]) -> Bool? {
        if values.contains(where: { $0 == true }) { return true }
        return values.contains(where: { $0 == nil }) ? nil : false
    }
}

struct PHPRelease: Codable {
    let version: String
    let date: String
    let tags: [String]?
    let supportedVersions: [String]?
    enum CodingKeys: String, CodingKey { case version, date, tags; case supportedVersions = "supported_versions" }
    var isSecurity: Bool { tags?.contains("security") == true }
    var url: URL { URL(string: "https://www.php.net/releases/" + version.replacingOccurrences(of: ".", with: "_") + ".php")! }
}

struct PHPAdvisory: Codable, Identifiable {
    struct Vulnerability: Codable {
        let range: String?
        let patched: String?
        enum CodingKeys: String, CodingKey { case range = "vulnerable_version_range"; case patched = "patched_versions" }
    }
    let id: String
    let cve: String?
    let summary: String
    let severity: String?
    let state: String
    let withdrawn: String?
    let vulnerabilities: [Vulnerability]
    enum CodingKeys: String, CodingKey {
        case id = "ghsa_id", cve = "cve_id", summary, severity, state, withdrawn = "withdrawn_at", vulnerabilities
    }
    var rank: Int { ["low": 1, "medium": 2, "high": 3, "critical": 4][severity ?? ""] ?? 0 }
    var severityLabel: String { ["low": L("Niska"), "medium": L("Średnia"), "high": L("Wysoka"), "critical": L("Krytyczna")][severity ?? ""] ?? L("Nieokreślona") }
    var url: URL {
        guard id.range(of: #"^GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}$"#, options: .regularExpression) != nil else {
            return URL(string: "https://github.com/php/php-src/security/advisories")!
        }
        return URL(string: "https://github.com/php/php-src/security/advisories/" + id)!
    }
    func affects(_ installed: PHPVersion) -> Bool? {
        guard state == "published", withdrawn == nil else { return false }
        var unknown = false
        for item in vulnerabilities {
            let fixes = PHPVersion.extract(from: item.patched ?? "")
            let sameBranch = fixes.filter { $0.branch == installed.branch }
            // PHP publishes one record per branch, often with only an upper bound.
            if !fixes.isEmpty && sameBranch.isEmpty { continue }
            if let fixed = sameBranch.min(), installed >= fixed { continue }
            let affected = PHPVersionRange.contains(installed, in: item.range ?? "")
            if affected == true { return true }
            if affected == nil { unknown = true }
        }
        return unknown ? nil : false
    }
}

struct PHPSecuritySnapshot: Codable {
    let checkedAt: Date
    let supportedBranches: [String]
    let releases: [String: PHPRelease]
    let advisories: [PHPAdvisory]
    func isFresh(at date: Date = Date()) -> Bool {
        let age = date.timeIntervalSince(checkedAt)
        return age >= -300 && age < 6 * 3600
    }
    func assess(_ installation: PHPInstallation) -> PHPSecurityAssessment {
        guard let version = PHPVersion(installation.version) else {
            return PHPSecurityAssessment(installation: installation, release: nil, findings: [], uncertain: true, unsupported: false)
        }
        let matches = advisories.map { ($0, $0.affects(version)) }
        return PHPSecurityAssessment(installation: installation, release: releases[version.branch],
            findings: matches.filter { $0.1 == true }.map { $0.0 }.sorted { $0.rank == $1.rank ? $0.id < $1.id : $0.rank > $1.rank },
            uncertain: matches.contains { $0.1 == nil } || (supportedBranches.contains(version.branch) && releases[version.branch] == nil),
            unsupported: !supportedBranches.contains(version.branch))
    }
}

struct PHPSecurityAssessment: Identifiable {
    let installation: PHPInstallation
    let release: PHPRelease?
    let findings: [PHPAdvisory]
    let uncertain: Bool
    let unsupported: Bool
    var id: String { installation.id }
    var critical: Bool { findings.contains { $0.rank == 4 } }
    var update: PHPRelease? {
        guard let installed = PHPVersion(installation.version), let release,
              let latest = PHPVersion(release.version), latest > installed else { return nil }
        return release
    }
    var needsAttention: Bool { !findings.isEmpty || uncertain || unsupported || update != nil }
    var label: String {
        if critical { return L("Krytyczne poprawki bezpieczeństwa") }
        if !findings.isEmpty || update?.isSecurity == true { return L("Poprawki bezpieczeństwa") }
        if unsupported { return L("Seria bez wsparcia PHP") }
        if uncertain { return L("Wymaga ręcznego sprawdzenia") }
        if update != nil { return L("Dostępna nowsza wersja") }
        return L("Brak nowszych poprawek w sprawdzonych źródłach")
    }
}

struct PHPSecurityClient {
    let session: URLSession
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        self.session = session ?? URLSession(configuration: config)
    }
    func request(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme == "https", ["www.php.net", "api.github.com"].contains(url.host ?? "") else {
            throw SwitcherError(message: L("Źródło odpowiedzi nie jest oficjalnym źródłem PHP."))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("PHP-Switcher/1.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SwitcherError(message: L("{0} zwróciło HTTP {1}. Spróbuj ponownie później.", String(describing: url.host ?? L("Źródło")), String(describing: code)))
        }
        guard data.count <= 12_000_000 else { throw SwitcherError(message: L("Odpowiedź źródła jest zbyt duża.")) }
        return (data, http)
    }
    static func nextPage(_ header: String?) throws -> URL? {
        guard let header else { return nil }
        for part in header.components(separatedBy: ",") where part.contains("rel=\"next\"") {
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end,
                  let url = URL(string: String(part[part.index(after: start)..<end])), url.scheme == "https",
                  url.host == "api.github.com", url.path == "/repos/php/php-src/security-advisories" else {
                throw SwitcherError(message: L("Nieprawidłowa paginacja komunikatów bezpieczeństwa."))
            }
            return url
        }
        return nil
    }
    func fetchAdvisories() async throws -> [PHPAdvisory] {
        var next: URL? = URL(string: "https://api.github.com/repos/php/php-src/security-advisories?per_page=100&state=published&sort=published&direction=desc")!
        var visited = Set<URL>(), result: [PHPAdvisory] = []
        while let url = next {
            guard visited.count < 20, visited.insert(url).inserted else {
                throw SwitcherError(message: L("Nie udało się pobrać pełnej listy komunikatów bezpieczeństwa."))
            }
            let (data, response) = try await request(url)
            result += try JSONDecoder().decode([PHPAdvisory].self, from: data)
            next = try Self.nextPage(response.value(forHTTPHeaderField: "Link"))
        }
        guard !result.isEmpty else { throw SwitcherError(message: L("Źródło zwróciło pustą listę komunikatów bezpieczeństwa.")) }
        var ids = Set<String>()
        return result.filter { ids.insert($0.id).inserted }
    }
    func fetch(branches: [String]) async throws -> PHPSecuritySnapshot {
        do {
            async let advisories = fetchAdvisories()
            let (data, _) = try await request(URL(string: "https://www.php.net/releases/?json")!)
            let catalog = try JSONDecoder().decode([String: PHPRelease].self, from: data)
            let supported = Set(catalog.values.flatMap { $0.supportedVersions ?? [] })
            guard !supported.isEmpty else { throw SwitcherError(message: L("Brak listy wspieranych serii w odpowiedzi PHP.")) }
            let wanted = Set(branches + ["8.3", "8.4", "8.5"]).intersection(supported)
            let releases = try await withThrowingTaskGroup(of: (String, PHPRelease).self) { group in
                for branch in wanted {
                    guard branch.range(of: #"^\d{1,3}\.\d{1,3}$"#, options: .regularExpression) != nil else { continue }
                    group.addTask {
                        let (data, _) = try await request(URL(string: "https://www.php.net/releases/?json&version=" + branch)!)
                        let release = try JSONDecoder().decode(PHPRelease.self, from: data)
                        guard PHPVersion(release.version)?.branch == branch else {
                            throw SwitcherError(message: L("API PHP zwróciło nieprawidłową wersję dla serii {0}.", String(describing: branch)))
                        }
                        return (branch, release)
                    }
                }
                var result: [String: PHPRelease] = [:]
                for try await (branch, release) in group { result[branch] = release }
                return result
            }
            return try await PHPSecuritySnapshot(checkedAt: Date(), supportedBranches: supported.sorted(), releases: releases, advisories: advisories)
        } catch is DecodingError {
            throw SwitcherError(message: L("Format danych źródła uległ zmianie. Nie można potwierdzić stanu poprawek."))
        }
    }
}

enum PHPSecurityCache {
    static func load(_ url: URL) -> PHPSecuritySnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PHPSecuritySnapshot.self, from: data)
    }
    static func save(_ snapshot: PHPSecuritySnapshot, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
