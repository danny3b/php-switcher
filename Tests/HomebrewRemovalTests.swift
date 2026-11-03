import Foundation

@main struct HomebrewRemovalTests {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("php-brew-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home")
        let prefix = base.appendingPathComponent("brew prefix ' with spaces")
        let cellar = prefix.appendingPathComponent("Cellar")
        let keg = cellar.appendingPathComponent("php@8.3/8.3.20")
        let manager = PHPManager(home: home, mamp: base.appendingPathComponent("mamp"), brews: [cellar])
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: " + label) }
            count += 1; print("PASS: " + label)
        }
        func rejected(_ label: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError("FAIL: " + label) }
            catch { check(true, label) }
        }
        func write(_ text: String, _ file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        func fixture(_ folder: URL, _ version: String) throws {
            try write("#!/bin/sh\nprintf '\\nPHP_SWITCHER_VERSION=\(version)'\n", folder.appendingPathComponent("bin/php"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent("bin/php").path)
            try write("{}", folder.appendingPathComponent("INSTALL_RECEIPT.json"))
        }
        try fixture(keg, "8.3.20")
        let local = manager.root.appendingPathComponent("8.5.12")
        try fixture(local, "8.5.12")
        let active = try manager.inspect(local, source: "PHP Switcher")
        try manager.activate(active)
        let ini = prefix.appendingPathComponent("etc/php/8.3/php.ini")
        let library = cellar.appendingPathComponent("libpng/1.6/lib/libpng.dylib")
        try write("upload_max_filesize=128M", ini)
        try write("shared library", library)
        let brew = prefix.appendingPathComponent("bin/brew")
        try write(#"""
        #!/bin/sh
        set -eu
        base=${0%/bin/brew}
        case "$*" in
          --cellar) printf '%s\n' "$base/Cellar" ;;
          'list --versions --formula php@8.3') cat "$base/versions" ;;
          'services list --json') cat "$base/services.json" ;;
          'uninstall --formula php@8.3')
            printf '%s\n' "$@" > "$base/uninstall-args"
            printf '%s\n' "$HOMEBREW_NO_AUTOREMOVE" "$HOMEBREW_NO_AUTO_UPDATE" "$HOMEBREW_NO_INSTALL_CLEANUP" "$HOMEBREW_NO_ANALYTICS" > "$base/uninstall-env"
            if [ -f "$base/refuse" ]; then printf 'Error: PHP is required by another package\n' >&2; exit 1; fi
            if [ -f "$base/pinned" ]; then printf 'PHP is pinned\n' >&2; exit 0; fi
            mv "$base/Cellar/php@8.3/8.3.20" "$base/removed-test-keg"
            ;;
          *) printf 'Unexpected arguments\n' >&2; exit 91 ;;
        esac
        """# + "\n", brew)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        try write("php@8.3 8.3.20\n", prefix.appendingPathComponent("versions"))
        let services = prefix.appendingPathComponent("services.json")
        try write(#"[{"name":"php@8.3","status":"none"}]"#, services)
        let item = try manager.inspect(keg, source: "Homebrew")
        let plan = try manager.prepareRemoval(item)
        check(plan.kind == .homebrew && plan.homebrew?.formula == "php@8.3", "Homebrew PHP produces an uninstall plan")
        check(plan.homebrew?.prefix.resolvingSymlinksInPath().path == prefix.resolvingSymlinksInPath().path && plan.homebrew?.kegVersion == "8.3.20", "Plan records the correct Homebrew prefix and exact keg")
        check(!fm.fileExists(atPath: prefix.appendingPathComponent("uninstall-args").path), "Preflight only reads Homebrew state")

        let forged = PHPInstallation(root: local.path, version: "8.5.12", source: "Homebrew")
        rejected("External paths cannot masquerade as Homebrew") { _ = try manager.prepareRemoval(forged) }
        let receipt = keg.appendingPathComponent("INSTALL_RECEIPT.json")
        try write("invalid", receipt)
        rejected("Invalid install receipt blocks uninstall") { _ = try manager.prepareRemoval(item) }
        try write("{}", receipt)

        let other = cellar.appendingPathComponent("php@8.3/8.3.19")
        try fixture(other, "8.3.19")
        rejected("A new sibling keg after confirmation prevents uninstall of the wrong version") { try manager.remove(plan) }
        try fm.removeItem(at: other)
        try write("php@8.3 8.3.21\n", prefix.appendingPathComponent("versions"))
        rejected("Changed Homebrew version is rejected") { _ = try manager.prepareRemoval(item) }
        try write("php@8.3 8.3.20\n", prefix.appendingPathComponent("versions"))
        let opt = prefix.appendingPathComponent("opt/php@8.3")
        try fm.createDirectory(at: opt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: opt, withDestinationURL: local)
        rejected("Homebrew opt pointing at another keg blocks removal") { _ = try manager.prepareRemoval(item) }
        try fm.removeItem(at: opt)
        try fm.createSymbolicLink(at: opt, withDestinationURL: keg)
        _ = try manager.prepareRemoval(item)
        check(true, "Matching Homebrew opt link is accepted")

        try write(#"[{"name":"php@8.3","status":"started"}]"#, services)
        rejected("Running PHP-FPM service is protected") { try manager.remove(plan) }
        try write("invalid JSON", services)
        rejected("Unknown service status fails safely") { _ = try manager.prepareRemoval(item) }
        try write("[]", services)
        let agent = home.appendingPathComponent("Library/LaunchAgents/homebrew.mxcl.php@8.3.plist")
        try write("registered service", agent)
        rejected("Registered launch agent is protected even when services omits it") { _ = try manager.prepareRemoval(item) }
        try fm.removeItem(at: agent)

        let fpm = keg.appendingPathComponent("sbin/php-fpm")
        try write("#!/bin/sh\nexit 0\n", fpm)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fpm.path)
        let agentContents = try PropertyListSerialization.data(fromPropertyList: [
            "Label": "homebrew.mxcl.php@8.3", "ProgramArguments": [fpm.path, "--nodaemonize"],
            "RunAtLoad": true, "KeepAlive": true
        ], format: .xml, options: 0)
        try agentContents.write(to: agent)
        let launchctl = prefix.appendingPathComponent("launchctl-fixture")
        try write(#"""
        #!/bin/sh
        set -eu
        base=${0%/launchctl-fixture}
        printf '%s %s\n' "$1" "$2" >> "$base/launchctl-calls"
        case "$2" in
          "gui/$(id -u)/homebrew.mxcl.php@8.3"|"user/$(id -u)/homebrew.mxcl.php@8.3") ;;
          *) exit 99 ;;
        esac
        case "$1" in
          print)
            if [ -f "$base/read-fails" ]; then printf 'Permission denied\n' >&2; exit 5; fi
            case "$2" in user/*) printf 'Could not find service\n' >&2; exit 113;; esac
            if [ ! -f "$base/loaded" ]; then printf 'Could not find service\n' >&2; exit 113; fi
            if [ -f "$base/wrong-program" ]; then printf 'program = /unrelated/program\n'; else printf 'program = %s/Cellar/php@8.3/8.3.20/sbin/php-fpm\n' "$base"; fi
            ;;
          bootout)
            if [ -f "$base/stop-fails" ]; then printf 'Stop refused\n' >&2; exit 5; fi
            if [ ! -f "$base/still-running" ]; then rm "$base/loaded"; fi
            ;;
          *) exit 98 ;;
        esac
        """# + "\n", launchctl)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        let servicePlan = try manager.prepareServiceStop(item)
        check(servicePlan.service?.label == "homebrew.mxcl.php@8.3", "Registered legacy service can be prepared without trusting its tap")
        let removalWithService = try manager.prepareRemoval(item, allowingServiceStop: true)
        check(removalWithService.service != nil, "Removal UI can offer service stopping before uninstall")
        rejected("A removal plan with a service never uninstalls before an explicit stop") { try manager.remove(removalWithService) }
        try write("loaded", prefix.appendingPathComponent("loaded"))
        try write("wrong", prefix.appendingPathComponent("wrong-program"))
        rejected("A running job for another program is not stopped") { _ = try manager.stopService(servicePlan, launchctl: launchctl) }
        try fm.removeItem(at: prefix.appendingPathComponent("wrong-program"))
        try write("denied", prefix.appendingPathComponent("read-fails"))
        rejected("Permission errors are not treated as an already stopped service") { _ = try manager.stopService(servicePlan, launchctl: launchctl) }
        try fm.removeItem(at: prefix.appendingPathComponent("read-fails"))
        try write("denied", prefix.appendingPathComponent("stop-fails"))
        rejected("Failed bootout keeps the launch agent in place") { _ = try manager.stopService(servicePlan, launchctl: launchctl) }
        check(fm.fileExists(atPath: agent.path), "Stop failure preserves autostart configuration")
        try fm.removeItem(at: prefix.appendingPathComponent("stop-fails"))
        try write("still running", prefix.appendingPathComponent("still-running"))
        rejected("Exit zero without actually stopping the service is rejected") { _ = try manager.stopService(servicePlan, launchctl: launchctl) }
        try fm.removeItem(at: prefix.appendingPathComponent("still-running"))
        try agentContents.write(to: agent, options: .atomic)
        rejected("Replacing a launch agent invalidates a previous confirmation") { _ = try manager.stopService(servicePlan, launchctl: launchctl) }
        try manager.activate(item)
        let activeServicePlan = try manager.prepareServiceStop(item)
        let savedService = try manager.stopService(activeServicePlan, launchctl: launchctl)
        let savedContents = try Data(contentsOf: savedService)
        check(!fm.fileExists(atPath: agent.path) && savedContents == agentContents, "Stopping preserves a backup and disables autostart")
        check(manager.activeRoot() == item.root && fm.isExecutableFile(atPath: item.binary.path), "Stopping PHP-FPM does not uninstall or switch CLI PHP")
        try manager.activate(active)
        let stoppedPlan = try manager.prepareRemoval(item)
        check(stoppedPlan.service == nil, "Stopping unlocks the separate uninstall confirmation")
        try agentContents.write(to: agent)
        try write("", prefix.appendingPathComponent("launchctl-calls"))
        let inactivePlan = try manager.prepareServiceStop(item)
        _ = try manager.stopService(inactivePlan, launchctl: launchctl)
        let calls = try String(contentsOf: prefix.appendingPathComponent("launchctl-calls"), encoding: .utf8)
        check(!calls.contains("bootout"), "Inactive legacy autostart can be disabled without stopping unrelated jobs")
        check(!fm.fileExists(atPath: prefix.appendingPathComponent("uninstall-args").path), "Service stopping never invokes uninstall")

        try manager.activate(item)
        rejected("Homebrew PHP selected after confirmation cannot be removed") { try manager.remove(plan) }
        try manager.activate(active)
        let preserved = prefix.appendingPathComponent("preserved-keg")
        try fm.moveItem(at: keg, to: preserved)
        try fixture(keg, "8.3.20")
        rejected("Replaced directory invalidates the confirmed plan") { try manager.remove(plan) }
        try fm.removeItem(at: keg)
        try fm.moveItem(at: preserved, to: keg)
        check(!fm.fileExists(atPath: prefix.appendingPathComponent("uninstall-args").path), "All guard failures leave uninstall unexecuted")

        try write("dependency", prefix.appendingPathComponent("refuse"))
        do {
            try manager.remove(plan); fatalError("Dependency refusal was ignored")
        } catch {
            check(error.localizedDescription.contains("required by another package"), "Homebrew dependency error is shown to the user")
        }
        check(fm.fileExists(atPath: keg.path), "A refused uninstall preserves PHP")
        try fm.removeItem(at: prefix.appendingPathComponent("refuse"))
        try write("pinned", prefix.appendingPathComponent("pinned"))
        rejected("Exit zero without removing a pinned keg is not reported as success") { try manager.remove(plan) }
        try fm.removeItem(at: prefix.appendingPathComponent("pinned"))
        try manager.remove(plan, trash: { _ in fatalError("Homebrew must not bypass its package manager via Trash") })
        check(!fm.fileExists(atPath: keg.path), "Successful uninstall removes the selected keg")
        let arguments = try String(contentsOf: prefix.appendingPathComponent("uninstall-args"), encoding: .utf8)
        check(arguments == "uninstall\n--formula\nphp@8.3\n", "Exact formula is uninstalled without force or ignoring dependencies")
        let environment = try String(contentsOf: prefix.appendingPathComponent("uninstall-env"), encoding: .utf8)
        check(environment == "1\n1\n1\n1\n", "Autoremove, auto-update, cleanup and analytics are disabled")
        check(fm.fileExists(atPath: ini.path) && fm.fileExists(atPath: library.path), "Shared configuration and libraries survive")
        check(manager.activeRoot() == active.root && fm.isExecutableFile(atPath: active.binary.path), "Active managed PHP remains untouched")
        check(!manager.discover().installations.contains { $0.root == item.root }, "Uninstalled version disappears after refresh")
        print("All \(count) Homebrew removal checks passed.")

        if CommandLine.arguments.contains("--live") {
            let live = PHPManager()
            for item in live.discover().installations where item.source == "Homebrew" {
                do {
                    let prepared = try live.prepareRemoval(item)
                    print("LIVE READ-ONLY: \(item.version) → \(prepared.homebrew!.formula), confirmation ready")
                } catch {
                    print("LIVE READ-ONLY: \(item.version) → \(error.localizedDescription)")
                }
            }
        }
        if CommandLine.arguments.contains("--live-services") {
            let live = PHPManager()
            for item in live.discover().installations where item.source == "Homebrew" && (item.version.hasPrefix("7.3.") || item.version.hasPrefix("7.4.")) {
                let prepared = try live.prepareServiceStop(item)
                print("LIVE READ-ONLY: \(item.version) → \(prepared.service!.label), stop confirmation ready")
            }
        }
    }
}
