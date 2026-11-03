import Foundation
import Darwin

/// Starts and stops a disposable sleep process under a unique, non-production
/// PHP-like label. Never loads or changes any installed PHP service.
@main struct ServiceIntegrationTests {
    static func main() throws {
        guard CommandLine.arguments.contains("--run") else {
            print("Use --run to start and stop a disposable macOS LaunchAgent."); return
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("php-service-integration-" + UUID().uuidString).resolvingSymlinksInPath()
        let home = base.appendingPathComponent("home")
        let prefix = base.appendingPathComponent("brew")
        let cellar = prefix.appendingPathComponent("Cellar")
        let keg = cellar.appendingPathComponent("php@99.99/99.99.99")
        let launchctl = URL(fileURLWithPath: "/bin/launchctl")
        let label = "homebrew.mxcl.php@99.99"
        let target = "gui/\(getuid())/\(label)"
        var bootstrapped = false
        defer {
            if bootstrapped { _ = try? Command.run(launchctl, ["bootout", target]) }
            try? fm.removeItem(at: base)
        }
        let before = try Command.run(launchctl, ["print", target])
        guard before.status == 113 && before.error.contains("Could not find service") else {
            throw SwitcherError(message: "The reserved test service label is not available; no changes made.")
        }
        func write(_ text: String, _ file: URL, executable: Bool = false) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        }
        try write("#!/bin/sh\nprintf '\\nPHP_SWITCHER_VERSION=99.99.99'\n", keg.appendingPathComponent("bin/php"), executable: true)
        let fpm = keg.appendingPathComponent("sbin/php-fpm")
        try write("#!/bin/sh\nexec /bin/sleep 120\n", fpm, executable: true)
        try write("{}", keg.appendingPathComponent("INSTALL_RECEIPT.json"))
        try write(#"""
        #!/bin/sh
        set -eu
        base=${0%/bin/brew}
        case "$*" in
          --cellar) printf '%s\n' "$base/Cellar" ;;
          'list --versions --formula php@99.99') printf 'php@99.99 99.99.99\n' ;;
          'services list --json') printf '[]\n' ;;
          *) printf 'Unsupported operation in isolated test\n' >&2; exit 97 ;;
        esac
        """# + "\n", prefix.appendingPathComponent("bin/brew"), executable: true)
        let agent = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        try fm.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = try PropertyListSerialization.data(fromPropertyList: [
            "Label": label, "ProgramArguments": [fpm.path], "RunAtLoad": true, "KeepAlive": false
        ], format: .xml, options: 0)
        try contents.write(to: agent)
        let start = try Command.run(launchctl, ["bootstrap", "gui/\(getuid())", agent.path])
        guard start.status == 0 else { throw SwitcherError(message: "Could not load disposable test agent: " + start.error) }
        bootstrapped = true
        let loaded = try Command.run(launchctl, ["print", target])
        guard loaded.status == 0 else { throw SwitcherError(message: "Test service was not loaded") }
        let manager = PHPManager(home: home, mamp: base.appendingPathComponent("mamp"), brews: [cellar])
        let installation = try manager.inspect(keg, source: "Homebrew")
        let plan = try manager.prepareServiceStop(installation)
        let backup = try manager.stopService(plan)
        let stopped = try Command.run(launchctl, ["print", target])
        guard stopped.status == 113, !fm.fileExists(atPath: agent.path),
              try Data(contentsOf: backup) == contents,
              fm.isExecutableFile(atPath: installation.binary.path),
              try manager.prepareRemoval(installation).service == nil else {
            throw SwitcherError(message: "Native service stop or preservation checks failed")
        }
        print("PASS: Real macOS launchctl stopped the disposable service, backed up autostart and preserved the PHP fixture.")
    }
}
