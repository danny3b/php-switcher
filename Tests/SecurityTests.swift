import Foundation

final class MockPHPProtocol: URLProtocol {
    static var handler: (URLRequest) throws -> (Int, [String: String], Data) = { _ in throw URLError(.badURL) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct SecurityTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { fatalError("FAIL: " + label) }
        count += 1; print("PASS: " + label)
    }
    static func main() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        func data(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name + ".json")) }
        let advisories = try JSONDecoder().decode([PHPAdvisory].self, from: data("advisories"))
        var releases: [String: PHPRelease] = [:]
        for branch in ["8.3", "8.4", "8.5"] { releases[branch] = try JSONDecoder().decode(PHPRelease.self, from: data("releases-" + branch)) }
        let snapshot = PHPSecuritySnapshot(checkedAt: Date(), supportedBranches: ["8.2", "8.3", "8.4", "8.5"], releases: releases, advisories: advisories)
        func assessment(_ version: String, snapshot: PHPSecuritySnapshot = snapshot) -> PHPSecurityAssessment {
            snapshot.assess(PHPInstallation(root: "/fixture/" + version, version: version, source: "Test"))
        }
        check(PHPVersion("8.3.10")! > PHPVersion("8.3.9")!, "Numeric comparison")
        check(PHPVersion("8.5.12RC1") == nil && PHPVersion("8.5") == nil, "Prerelease and ambiguous versions cannot be marked clean")
        for version in ["8.3.35", "8.4.26", "8.5.11"] {
            let result = assessment(version)
            check(result.critical && result.findings.filter { $0.rank == 4 }.count == 2, "Official critical advisories affect " + version)
        }
        for version in ["8.3.36", "8.4.27", "8.5.12"] {
            let result = assessment(version)
            check(!result.needsAttention, "Fixed version is clean without cross-branch false positives: " + version)
        }
        let newer = PHPRelease(version: "8.3.37", date: "fixture", tags: [], supportedVersions: nil)
        let afterOrdinaryRelease = PHPSecuritySnapshot(checkedAt: Date(), supportedBranches: snapshot.supportedBranches, releases: ["8.3": newer], advisories: advisories)
        check(assessment("8.3.35", snapshot: afterOrdinaryRelease).critical, "Later non-security release does not hide missed critical fixes")
        check(assessment("8.3.35", snapshot: afterOrdinaryRelease).update?.version == "8.3.37", "Offers latest release in the same branch")
        check(assessment("8.1.34").unsupported, "Unsupported branch is never marked current")
        check(assessment("8.5.12RC1").uncertain, "Prerelease assessment stays unknown")
        check(assessment("8.2.35").uncertain, "Missing branch response prevents a clean assessment")

        let v = PHPVersion("8.3.6")!
        check(PHPVersionRange.contains(v, in: ">= 8.3.0, < 8.3.7") == true, "Comparison intersections")
        check(PHPVersionRange.contains(v, in: "> 8.3.6, < 8.3.10") == false, "Exclusive lower bound")
        check(PHPVersionRange.contains(v, in: "8.3.6") == true, "Exact version")
        check(PHPVersionRange.contains(v, in: "8.2.0 - 8.2.19, 8.3.0 - 8.3.7") == true, "Comma-separated inclusive ranges")
        check(PHPVersionRange.contains(v, in: "8.1.0 - 8.1.29, 8.2.0 - 8.2.19") == false, "Disjoint branch ranges")
        check(PHPVersionRange.contains(v, in: "<8.3.2 || >=8.3.6, <=8.3.8") == true, "Union of comparison groups")
        check(PHPVersionRange.contains(v, in: "future syntax") == nil, "Unknown syntax stays unknown")
        check(PHPVersionRange.contains(v, in: "") == nil, "Empty range stays unknown")
        check(PHPVersion.extract(from: "8.1.29, 8.2.20, 8.3.8.").map(\.text) == ["8.1.29", "8.2.20", "8.3.8"], "Multiple patched branches with trailing punctuation")
        let uncertain = PHPAdvisory(id: "GHSA-aaaa-bbbb-cccc", cve: nil, summary: "Fixture", severity: "critical", state: "published", withdrawn: nil,
            vulnerabilities: [.init(range: "unrecognized", patched: "8.3.37")])
        check(uncertain.affects(PHPVersion("8.3.36")!) == nil, "Unknown advisory cannot silently disappear")
        let unpatched = PHPAdvisory(id: "GHSA-aaaa-bbbb-dddd", cve: nil, summary: "Fixture", severity: "high", state: "published", withdrawn: nil,
            vulnerabilities: [.init(range: ">=8.3.0, <8.4.0", patched: nil)])
        check(unpatched.affects(v) == true, "Unpatched vulnerability is still reported")
        let withdrawn = PHPAdvisory(id: uncertain.id, cve: nil, summary: "Fixture", severity: "critical", state: "published", withdrawn: "2026-01-01",
            vulnerabilities: unpatched.vulnerabilities)
        check(withdrawn.affects(v) == false, "Withdrawn advisories are ignored")
        let base = Date()
        check(snapshot.isFresh(at: snapshot.checkedAt.addingTimeInterval(6 * 3600 - 1)), "Cache valid within six hours")
        check(!snapshot.isFresh(at: snapshot.checkedAt.addingTimeInterval(6 * 3600)), "Cache expires at six hours")
        check(!snapshot.isFresh(at: snapshot.checkedAt.addingTimeInterval(-600)), "Clock rollback cannot create indefinitely fresh cache")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("php-security-tests-" + UUID().uuidString).appendingPathComponent("security.json")
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        try PHPSecurityCache.save(snapshot, to: cache)
        check(PHPSecurityCache.load(cache)?.advisories.count == advisories.count, "Offline cache round-trip")
        try Data("broken".utf8).write(to: cache)
        check(PHPSecurityCache.load(cache) == nil, "Corrupt cache is not trusted")
        let link = "<https://api.github.com/repos/php/php-src/security-advisories?after=cursor>; rel=\"next\""
        let next = try PHPSecurityClient.nextPage(link)
        check(next?.query == "after=cursor", "Follows cursor pagination")
        do { _ = try PHPSecurityClient.nextPage("<https://example.com/leak>; rel=\"next\""); fatalError("External pagination accepted") }
        catch { check(true, "Rejects external pagination") }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockPHPProtocol.self]
        let client = PHPSecurityClient(session: URLSession(configuration: config))
        let catalogData = try data("releases-latest")
        let releaseData = try Dictionary(uniqueKeysWithValues: ["8.3", "8.4", "8.5"].map { ($0, try data("releases-" + $0)) })
        let page1 = try JSONEncoder().encode(Array(advisories.prefix(1)))
        let page2 = try JSONEncoder().encode(Array(advisories.dropFirst()))
        let successHandler: (URLRequest) throws -> (Int, [String: String], Data) = { request in
            let url = request.url!
            if url.host == "api.github.com" {
                return url.query?.contains("after=cursor") == true ? (200, [:], page2) : (200, ["Link": link], page1)
            }
            let version = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "version" }?.value
            return (200, [:], version.flatMap { releaseData[$0] } ?? catalogData)
        }
        MockPHPProtocol.handler = successHandler
        let fetched = try await client.fetch(branches: ["8.3", "8.1"])
        check(fetched.advisories.count == advisories.count && fetched.releases.count == 3, "Complete fetch including all advisory pages")
        check(fetched.checkedAt >= base && !fetched.supportedBranches.contains("8.1"), "Successful fetch records timestamp and support status")
        for failure in ["offline", "rate-limit", "bad-json", "wrong-branch", "page-two"] {
            MockPHPProtocol.handler = { request in
                if failure == "offline" { throw URLError(.notConnectedToInternet) }
                if failure == "rate-limit" && request.url?.host == "api.github.com" { return (403, [:], Data()) }
                if failure == "bad-json" && request.url?.host == "www.php.net" { return (200, [:], Data("{\"error\":\"Unknown version\"}".utf8)) }
                if failure == "wrong-branch" && request.url?.query?.contains("version=8.3") == true { return (200, [:], releaseData["8.4"]!) }
                if failure == "page-two" && request.url?.query?.contains("after=cursor") == true { return (503, [:], Data()) }
                return try successHandler(request)
            }
            do { _ = try await client.fetch(branches: []); fatalError("Failure produced complete snapshot: " + failure) }
            catch { check(true, "No false clean result on " + failure) }
        }
        if CommandLine.arguments.contains("--live") {
            let live = try await PHPSecurityClient().fetch(branches: ["8.3", "8.4", "8.5"])
            print("LIVE: \(live.releases.values.map(\.version).sorted()) · \(live.advisories.count) advisories")
            check(!live.releases.isEmpty && live.isFresh(), "Live official sources")
        }
        print("All \(count) security checks passed.")
    }
}
