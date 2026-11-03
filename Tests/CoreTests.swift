import Foundation

@main struct CoreTests {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("php-switcher-tests-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let manager = PHPManager(home: home, mamp: home.appendingPathComponent("mamp"), brews: [home.appendingPathComponent("brew")])
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: " + name) }
            print("PASS: " + name)
        }
        func fixture(_ path: URL, _ version: String, fails: Bool = false) throws {
            try fm.createDirectory(at: path.appendingPathComponent("bin"), withIntermediateDirectories: true)
            let binary = path.appendingPathComponent("bin/php")
            let text = fails ? "#!/bin/sh\nexit 1\n" : "#!/bin/sh\nprintf '\\nPHP_SWITCHER_VERSION=\(version)'\n"
            try text.write(to: binary, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        let old = manager.root.appendingPathComponent("8.3.36")
        let new = manager.root.appendingPathComponent("8.5.12")
        let incomplete = manager.root.appendingPathComponent("8.4.27")
        try fixture(old, "8.3.36"); try fixture(new, "8.5.12"); try fixture(incomplete, "8.4.27")
        try Data().write(to: incomplete.appendingPathComponent(".installing"))
        try fixture(manager.mamp.appendingPathComponent("php8.4.17"), "8.4.17")
        try fixture(manager.brews[0].appendingPathComponent("php@8.3/8.3.20"), "8.3.20")
        let discovery = manager.discover()
        check(discovery.installations.count == 4, "Discovery covers local, MAMP and Homebrew; hides incomplete builds")
        check(discovery.installations.first?.version == "8.5.12", "Versions sorted numerically")
        let profile = home.appendingPathComponent(".zprofile")
        try "# existing settings\nexport EXAMPLE=kept\n".write(to: profile, atomically: true, encoding: .utf8)
        let first = try manager.inspect(old, source: "Test")
        let second = try manager.inspect(new, source: "Test")
        try manager.activate(first)
        check(manager.activeRoot() == first.root, "First activation")
        try manager.activate(second)
        check(manager.activeRoot() == second.root, "Atomic switch to another version")
        let profileText = try String(contentsOf: profile, encoding: .utf8)
        check(profileText.contains("export EXAMPLE=kept"), "Preserves shell settings")
        check(profileText.components(separatedBy: "export PATH=").count == 2, "Adds PATH only once")
        let allFiles = try fm.contentsOfDirectory(atPath: home.path)
        check(allFiles.filter { $0.hasPrefix(".zprofile.php-switcher-") }.count == 1, "Creates one profile backup")
        let bad = home.appendingPathComponent("broken")
        try fixture(bad, "8.5.12", fails: true)
        do { try manager.activate(PHPInstallation(root: bad.path, version: "8.5.12", source: "Test")); fatalError("Invalid PHP was activated") }
        catch { check(manager.activeRoot() == second.root, "Failed activation preserves active PHP") }
        let custom = home.appendingPathComponent("custom install ' with spaces")
        try fixture(custom, "8.4.27")
        try manager.add(custom.appendingPathComponent("bin/php"))
        check(manager.discover().installations.contains { $0.version == "8.4.27" }, "Adds arbitrary paths safely")
        try manager.add(custom)
        check(manager.customRoots().count == 1, "Custom paths are not duplicated")
        try fm.removeItem(at: manager.current)
        try fm.createDirectory(at: manager.current, withIntermediateDirectories: false)
        do { try manager.activate(first); fatalError("Replaced a real directory") }
        catch { check(fm.fileExists(atPath: manager.current.path), "Never replaces a real current directory") }
        check(PHPManager.isValidVersion("8.4.27") && !PHPManager.isValidVersion("8.4.27;touch /tmp/pwn"), "Rejects malformed release input")
        check(!PHPManager.isValidVersion("../8.5.12") && !PHPManager.isValidVersion("8.6.0"), "Rejects path traversal and unsupported series")
        print("All core checks passed.")
    }
}
