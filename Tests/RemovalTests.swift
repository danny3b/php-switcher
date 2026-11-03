import Foundation
import Darwin

@main struct RemovalTests {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("php-removal-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let manager = PHPManager(home: home, mamp: home.appendingPathComponent("mamp"), brews: [home.appendingPathComponent("brew")])
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: " + label) }
            count += 1; print("PASS: " + label)
        }
        func rejected(_ label: String, _ action: () throws -> Void) {
            do { try action(); fatalError("FAIL: " + label) }
            catch { check(true, label) }
        }
        func fixture(_ url: URL, _ version: String, source: String = "PHP Switcher") throws -> PHPInstallation {
            try fm.createDirectory(at: url.appendingPathComponent("bin"), withIntermediateDirectories: true)
            let binary = url.appendingPathComponent("bin/php")
            try "#!/bin/sh\nprintf '\\nPHP_SWITCHER_VERSION=\(version)'\n".write(to: binary, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            try "custom php.ini and extensions must survive".write(to: url.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
            return PHPInstallation(root: url.path, version: version, source: source)
        }
        let old = try fixture(manager.root.appendingPathComponent("8.3.36"), "8.3.36")
        let active = try fixture(manager.root.appendingPathComponent("8.5.12"), "8.5.12")
        try manager.activate(active)
        let profileBefore = try Data(contentsOf: home.appendingPathComponent(".zprofile"))
        rejected("Active PHP cannot be removed") { _ = try manager.prepareRemoval(active) }
        let plan = try manager.prepareRemoval(old)
        check(plan.kind == .trash, "Inactive managed version can be moved to Trash")
        let savedTrash = home.appendingPathComponent("test-trash")
        let result = try manager.remove(plan, trash: { url in
            try fm.moveItem(at: url, to: savedTrash)
            return savedTrash
        })
        check(result == savedTrash && !fm.fileExists(atPath: old.root), "Removes only the approved version from installations")
        check(fm.fileExists(atPath: savedTrash.appendingPathComponent("keep.txt").path), "Moved installation keeps its configuration for recovery")
        check(manager.activeRoot() == active.root && fm.isExecutableFile(atPath: active.binary.path), "Active installation and link are preserved")
        let profileAfter = try Data(contentsOf: home.appendingPathComponent(".zprofile"))
        check(profileBefore == profileAfter, "Removing PHP does not change shell configuration")
        check(!manager.discover().installations.contains { $0.root == old.root }, "Removed version disappears on refresh")
        try fm.moveItem(at: savedTrash, to: old.url)
        check(manager.discover().installations.contains { $0.root == old.root }, "Restored installation reappears on refresh")

        let failurePlan = try manager.prepareRemoval(old)
        rejected("Trash errors are propagated") {
            try manager.remove(failurePlan, trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        }
        check(fm.fileExists(atPath: old.root), "Trash failure does not permanently delete the installation")
        rejected("A stale plan cannot remove newly active PHP") {
            try manager.activate(old)
            try manager.remove(failurePlan, trash: { _ in fatalError("Moved active PHP") })
        }
        try manager.activate(active)
        try manager.remove(failurePlan, trash: { _ in nil })
        check(true, "Failed removal releases the shared lock")

        let renamed = manager.root.appendingPathComponent("saved-old")
        try fm.moveItem(at: old.url, to: renamed)
        _ = try fixture(old.url, "8.3.36")
        rejected("Directory replacement after confirmation is rejected") {
            try manager.remove(failurePlan, trash: { _ in fatalError("Moved a replacement directory") })
        }
        try fm.removeItem(at: old.url)
        try fm.createSymbolicLink(at: old.url, withDestinationURL: renamed)
        rejected("Symlink cannot stand in for a removable version") { _ = try manager.prepareRemoval(old) }
        try fm.removeItem(at: old.url)
        try fm.moveItem(at: renamed, to: old.url)
        let beforeChangedVersion = try manager.prepareRemoval(old)
        _ = try fixture(old.url, "8.3.37")
        rejected("Changed PHP version after confirmation is rejected") { try manager.remove(beforeChangedVersion) }
        _ = try fixture(old.url, "8.3.36")
        try Data().write(to: old.url.appendingPathComponent(".installing"))
        rejected("Incomplete installations cannot be removed") { _ = try manager.prepareRemoval(old) }
        try fm.removeItem(at: old.url.appendingPathComponent(".installing"))

        let external = try fixture(home.appendingPathComponent("external folder ' with spaces"), "8.4.27", source: "Dodane ręcznie")
        let forged = PHPInstallation(root: external.root, version: external.version, source: "PHP Switcher")
        rejected("Managed label cannot authorize removal of an external directory") { _ = try manager.prepareRemoval(forged) }
        rejected("Unregistered external directory cannot be forgotten") { _ = try manager.prepareRemoval(external) }
        try manager.add(external.url)
        let another = try fixture(home.appendingPathComponent("another"), "8.4.26", source: "Dodane ręcznie")
        try manager.add(another.url)
        let customPlan = try manager.prepareRemoval(external)
        check(customPlan.kind == .forget, "Manually added installation uses list removal")
        try manager.remove(customPlan, trash: { _ in fatalError("External files must never be trashed") })
        check(fm.fileExists(atPath: external.binary.path) && manager.customRoots() == [another.root], "List removal preserves files and unrelated entries")
        try manager.add(external.url)
        try manager.activate(external)
        rejected("Active custom installation cannot be forgotten") { _ = try manager.prepareRemoval(external) }
        try manager.activate(active)
        let corruptionPlan = try manager.prepareRemoval(external)
        try Data("not valid JSON".utf8).write(to: manager.settings)
        rejected("Corrupt registry is not overwritten by removal") { try manager.remove(corruptionPlan) }
        let corruptContents = try String(contentsOf: manager.settings, encoding: .utf8)
        check(corruptContents == "not valid JSON", "Corrupt registry remains available for recovery")

        for source in ["MAMP", "Homebrew"] {
            let item = PHPInstallation(root: old.root, version: old.version, source: source)
            rejected(source + " installation cannot be trashed directly") { _ = try manager.prepareRemoval(item) }
        }
        let lock = open(manager.root.appendingPathComponent(".installer.lock").path, O_RDWR)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { fatalError("Could not acquire fixture lock") }
        let lockedPlan = try manager.prepareRemoval(old)
        rejected("Concurrent installer prevents removal of its build template") { try manager.remove(lockedPlan) }
        rejected("Concurrent mutation prevents activation") { try manager.activate(old) }
        flock(lock, LOCK_UN); close(lock)
        try manager.remove(lockedPlan, trash: { _ in nil })
        check(true, "Mutation succeeds after installer lock is released")

        if CommandLine.arguments.contains("--trash-integration") {
            // Only the tiny test fixture is sent to the real macOS Trash, then restored.
            let trashPlan = try manager.prepareRemoval(old)
            guard let trashed = try manager.remove(trashPlan) else { fatalError("Trash did not return a recovery path") }
            check(!fm.fileExists(atPath: old.root) && fm.fileExists(atPath: trashed.path), "Real macOS Trash moves the test directory")
            try fm.moveItem(at: trashed, to: old.url)
            check(fm.fileExists(atPath: old.url.appendingPathComponent("keep.txt").path), "Real Trash item can be restored with its contents")
        }
        print("All \(count) removal checks passed.")
    }
}
