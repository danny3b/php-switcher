import Foundation
import Combine

@main struct NavigationPerformanceTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: " + label) }
            checks += 1; print("PASS: " + label)
        }
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let advisories = try JSONDecoder().decode([PHPAdvisory].self, from: Data(contentsOf: fixtures.appendingPathComponent("advisories.json")))
        let snapshot = PHPSecuritySnapshot(checkedAt: Date(), supportedBranches: ["8.3", "8.4", "8.5"], releases: [:], advisories: advisories)
        var evaluations = 0
        let cache = PHPSecurityAssessmentCache { snapshot, installation in
            evaluations += 1
            return snapshot.assess(installation)
        }
        let store = SwitcherStore(assessmentCache: cache)
        let fixed = PHPInstallation(root: "/fixture/php-a", version: "8.3.36", source: "PHP Switcher")
        let vulnerable = PHPInstallation(root: fixed.root, version: "8.3.35", source: fixed.source)
        let manual = PHPInstallation(root: "/fixture/php-b", version: "8.4.27", source: "Dodane ręcznie")
        let external = PHPInstallation(root: "/fixture/php-c", version: "8.5.11", source: "Homebrew")
        store.installations = [fixed, manual, external]
        check(store.securityAssessments.isEmpty && evaluations == 0, "Missing source data does not produce a cached clean result")
        store.securitySnapshot = snapshot
        check(evaluations == 2 && store.securityAssessments.count == 2, "Assess each monitored installation once when source data arrives")
        var notifications = 0
        let observation = store.objectWillChange.sink { notifications += 1 }
        store.selectTab(.settings)
        check(notifications == 1, "A tab switch emits only the actual selection change")
        let before = evaluations
        let began = Date()
        var checksum = 0
        for _ in 0..<100 {
            for tab in AppTab.allCases {
                store.selectTab(tab)
                checksum += store.securityTitle.count
                _ = store.criticalSecurity
                _ = store.securityAttention
                _ = store.securityAssessments
            }
        }
        let elapsed = Date().timeIntervalSince(began) * 1000
        check(evaluations == before, "Tab changes and status reads do not rerun security analysis")
        print(String(format: "%d tab selections and status reads: %.3f ms (checksum %d)", AppTab.allCases.count * 100, elapsed, checksum))
        store.installations = [fixed, manual, external]
        check(evaluations == before, "Refreshing an unchanged installation list reuses findings")
        store.activeRoot = external.root
        check(evaluations == before + 1 && store.securityAssessments.last?.critical == true, "Activating external PHP adds a fresh assessment to the scope")
        store.installations = [vulnerable, manual, external]
        check(evaluations == before + 2 && store.securityAssessments.first?.critical == true, "Version changes at the same path invalidate cached findings")
        let renamedSource = PHPInstallation(root: manual.root, version: manual.version, source: "PHP Switcher")
        store.installations = [vulnerable, renamedSource, external]
        check(evaluations == before + 3 && store.securityAssessments[1].installation.source == "PHP Switcher", "Source changes update the cached installation metadata")
        store.activeRoot = nil
        check(store.securityAssessments.count == 2, "Deactivating external PHP removes it from the monitored scope")
        store.installations = [vulnerable]
        check(store.securityAssessments.map(\.id) == [vulnerable.id], "Removing an installation removes its cached findings")
        store.securitySnapshot = PHPSecuritySnapshot(checkedAt: snapshot.checkedAt, supportedBranches: snapshot.supportedBranches, releases: [:], advisories: [])
        check(store.securityAssessments.first?.critical == false, "Replacing source data invalidates findings even with the same timestamp")
        store.securitySnapshot = nil
        check(store.securityAssessments.isEmpty, "Clearing source data clears all derived findings")
        store.securitySnapshot = snapshot
        check(store.securityAssessments.first?.critical == true, "Restoring source data recalculates instead of returning stale findings")
        observation.cancel()
        print("All \(checks) navigation and assessment cache checks passed.")
    }
}
