import Foundation
import Darwin

@main struct ConfigurationTests {
    static func main() throws {
        let fm = FileManager.default
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: " + label) }
            count += 1; print("PASS: " + label)
        }
        func rejected(_ label: String, _ action: () throws -> Void) {
            do { try action(); fatalError("FAIL: " + label) } catch { check(true, label) }
        }
        let source = "; Upload comment\r\n[PHP]\r\nupload_max_filesize = 2M ; old default\r\nupload_max_filesize\t=\t\"32M\"  ; keep inline note\r\n[PATH=/example]\r\nupload_max_filesize = 1M\r\n[Date]\r\ndate.timezone = \"UTC\"\r\n"
        let document = PHPIniDocument(source)
        check(document.assignments["upload_max_filesize"]?.value == "32M", "Last global assignment wins, conditional sections are excluded")
        let rewritten = try document.updating(["upload_max_filesize": "128M", "date.timezone": "Europe/Warsaw"])
        check(rewritten.contains("upload_max_filesize\t=\t128M  ; keep inline note\r\n"), "Preserves spacing, inline comments, and CRLF")
        check(rewritten.contains("upload_max_filesize = 2M ; old default") && rewritten.contains("upload_max_filesize = 1M"), "Preserves earlier duplicates and conditional values")
        check(rewritten.contains("date.timezone = \"Europe/Warsaw\""), "Timezone serialized as a quoted value")
        let appended = try PHPIniDocument("[HOST=example.test]\nmemory_limit=64M\n").updating(["memory_limit": "512M"])
        check(appended.hasPrefix("; DevŻbik") && PHPIniDocument(appended).assignments["memory_limit"]?.value == "512M", "Missing global key is inserted outside conditional sections")
        let quoted = PHPIniDocument("extension=\"first\nmax_input_vars=9999\nlast\"\nmax_input_vars=1000\n")
        check(quoted.assignments["max_input_vars"]?.value == "1000", "Assignment-like text in multiline quotes is ignored")
        rejected("Multiline field value cannot be rewritten ambiguously") {
            _ = try PHPIniDocument("memory_limit=\"128\nM\"\n").updating(["memory_limit": "256M"])
        }
        let bom = try PHPIniDocument("\u{feff}; preserved\n").updating(["max_input_vars": "2000"])
        check(bom.hasPrefix("\u{feff}; DevŻbik") && bom.components(separatedBy: "\u{feff}").count == 2, "BOM remains at the beginning")
        check(PHPIniField.bytes("1G") == 1073741824 && PHPIniField.memory.equivalent("1G", "1024M"), "Memory units compare by size")
        rejected("Overflowing memory size rejected") { _ = try PHPIniField.memory.validated("9999999999999999999G", timezones: []) }
        rejected("Injected ini directives rejected") { _ = try PHPIniField.upload.validated("2M\nextension=evil.so", timezones: []) }
        rejected("Negative file size rejected") { _ = try PHPIniField.upload.validated("-1", timezones: []) }
        let unlimitedMemory = try PHPIniField.memory.validated("-1", timezones: [])
        let inputDefault = try PHPIniField.inputTime.validated("-1", timezones: [])
        check(unlimitedMemory == "-1" && inputDefault == "-1", "Supported unlimited/default sentinels accepted")
        rejected("Negative execution time rejected") { _ = try PHPIniField.execution.validated("-1", timezones: []) }
        rejected("Unknown timezone rejected") { _ = try PHPIniField.timezone.validated("Europe/Typo", timezones: ["UTC"]) }

        guard let flag = CommandLine.arguments.firstIndex(of: "--php"), CommandLine.arguments.count > flag + 1 else {
            print("All \(count) parser checks passed. Pass --php /path/to/php for isolated integration tests."); return
        }
        let php = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
        let version = try Command.run(php, ["-n", "-r", "echo PHP_VERSION;"]).output
        let home = fm.temporaryDirectory.appendingPathComponent("php-ini-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let installationRoot = home.appendingPathComponent(".local/php/" + version)
        let etc = installationRoot.appendingPathComponent("etc")
        let scan = etc.appendingPathComponent("conf.d")
        let ini = etc.appendingPathComponent("php.ini")
        let extra = scan.appendingPathComponent("settings.ini")
        try fm.createDirectory(at: scan, withIntermediateDirectories: true)
        try fm.createDirectory(at: installationRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let base = """
        ; user comments stay intact
        [PHP]
        file_uploads = On
        upload_max_filesize = 2M ; upload note
        post_max_size = 8M
        max_file_uploads = 20
        memory_limit = 128M
        max_execution_time = 260
        max_input_time = 260
        max_input_vars = 1000
        display_errors = Off
        display_startup_errors = Off
        log_errors = Off
        ; unrelated setting
        precision = 17
        [Date]
        date.timezone = "UTC"

        """
        try base.write(to: ini, atomically: true, encoding: .utf8)
        try "memory_limit = 256M ; keep override\n".write(to: extra, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: ini.path)
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let wrapper = installationRoot.appendingPathComponent("bin/php")
        let script = "#!/bin/sh\nexport PHP_INI_SCAN_DIR=\(quote(scan.path))\nexec \(quote(php.path)) -c \(quote(ini.path)) \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let installation = PHPInstallation(root: installationRoot.path, version: version, source: "PHP Switcher")
        let manager = PHPManager(home: home, mamp: home.appendingPathComponent("mamp"), brews: [])
        let service = PHPIniService(manager: manager)
        let snapshot = try service.read(installation)
        check(snapshot.values["memory_limit"] == "256M" && snapshot.owners["memory_limit"] == 1, "Loads effective conf.d override and its owner")
        check(snapshot.values["max_execution_time"] == "260" && snapshot.values["max_input_time"] == "260", "Shows configured time limits, not CLI forced values")
        var values = snapshot.values
        values["upload_max_filesize"] = "64m"; values["post_max_size"] = "80M"; values["memory_limit"] = "512M"
        values["max_execution_time"] = "120"; values["max_input_time"] = "60"; values["max_input_vars"] = "2500"
        values["max_file_uploads"] = "40"; values["file_uploads"] = "Off"
        values["display_errors"] = "stderr"; values["display_startup_errors"] = "On"; values["log_errors"] = "On"
        values["date.timezone"] = "Europe/Warsaw"
        let saved = try service.save(snapshot, edited: values)
        check(saved.backups.count == 2 && saved.backups.allSatisfy { fm.fileExists(atPath: $0.path) }, "Backs up every modified ini file")
        let savedMain = try String(contentsOf: ini, encoding: .utf8)
        let savedExtra = try String(contentsOf: extra, encoding: .utf8)
        check(savedMain.contains("memory_limit = 128M") && savedExtra.contains("memory_limit = 512M ; keep override"), "Edits the winning override instead of an ineffective main value")
        check(savedMain.contains("precision = 17") && savedMain.contains("; user comments stay intact") && savedMain.contains("64M ; upload note"), "Preserves unrelated settings and comments")
        check(saved.snapshot.values["max_execution_time"] == "120" && saved.snapshot.probe.values["upload_max_filesize"] == "64M", "Real PHP accepts the saved settings")
        check(saved.snapshot.probe.values["display_errors"] == "stderr" && saved.snapshot.probe.values["date.timezone"] == "Europe/Warsaw", "Enums and timezone survive runtime verification")
        let mode = try fm.attributesOfItem(atPath: ini.path)[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o640, "Original file permissions preserved")
        let noOp = try service.save(saved.snapshot, edited: saved.snapshot.values)
        check(noOp.backups.isEmpty, "Unchanged form does not rewrite files or add backups")
        var bad = saved.snapshot.values; bad["memory_limit"] = "8M\nfoo=1"
        rejected("Invalid changes rejected before writing") { _ = try service.save(saved.snapshot, edited: bad) }
        let unchanged = try String(contentsOf: ini, encoding: .utf8)
        check(unchanged == savedMain, "Validation failure leaves configuration untouched")
        var edited = saved.snapshot.values; edited["upload_max_filesize"] = "128M"
        try (savedMain + "; external edit\n").write(to: ini, atomically: true, encoding: .utf8)
        rejected("External edits since opening prevent overwrite") { _ = try service.save(saved.snapshot, edited: edited) }
        let afterExternal = try String(contentsOf: ini, encoding: .utf8)
        check(afterExternal.hasSuffix("; external edit\n"), "External edits are preserved")
        let beforeOverride = try service.read(installation)
        let newOverride = scan.appendingPathComponent("zz-new.ini")
        try "upload_max_filesize=4M\n".write(to: newOverride, atomically: true, encoding: .utf8)
        rejected("Newly added override prevents stale save") { _ = try service.save(beforeOverride, edited: edited) }
        try fm.removeItem(at: newOverride)

        let rollbackSnapshot = try service.read(installation)
        var rollbackValues = rollbackSnapshot.values
        rollbackValues["upload_max_filesize"] = "16M"; rollbackValues["memory_limit"] = "768M"
        let failing = PHPIniService(manager: manager, run: { binary, arguments in
            let contents = try String(contentsOf: extra, encoding: .utf8)
            if contents.contains("768M") { return CommandResult(status: 0, output: "", error: "PHP Warning: simulated startup failure") }
            return try Command.run(binary, arguments)
        })
        rejected("PHP startup failure triggers rollback") { _ = try failing.save(rollbackSnapshot, edited: rollbackValues) }
        let restored = try service.read(installation)
        check(restored.files.map(\.data) == rollbackSnapshot.files.map(\.data), "Rollback restores all touched files byte for byte")
        let lock = open(manager.root.appendingPathComponent(".installer.lock").path, O_RDWR)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { fatalError("Fixture lock unavailable") }
        rejected("Installer lock blocks conflicting configuration writes") { _ = try service.save(restored, edited: edited) }
        flock(lock, LOCK_UN); close(lock)
        print("All \(count) configuration checks passed with real PHP \(version).")
    }
}
