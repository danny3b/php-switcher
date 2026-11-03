import Foundation
import ServiceManagement

@MainActor final class FakeLoginItem: LoginItemManaging {
    var status: SMAppService.Status = .notRegistered
    var registrationResult: SMAppService.Status = .enabled
    var failure: Error?
    var registrations = 0
    var unregistrations = 0
    func register() throws {
        registrations += 1
        if let failure { throw failure }
        status = registrationResult
    }
    func unregister() throws {
        unregistrations += 1
        if let failure { throw failure }
        status = .notRegistered
    }
}

@main struct PreferencesTests {
    @MainActor static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: " + name) }
            count += 1
            print("PASS: " + name)
        }
        let suite = "php-switcher-preferences-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let login = FakeLoginItem()
        let preferences = AppPreferences(defaults: defaults, loginItem: login)
        check(preferences.language == .polish && !preferences.launchAtLogin, "Existing users keep Polish; launch at login is not enabled implicitly")
        check(login.registrations == 0, "Opening settings does not register a login item")
        login.status = .notFound
        preferences.refreshLoginStatus()
        check(!preferences.launchAtLogin && preferences.loginError == nil, "An unregistered app reported as not found is not an operation failure")
        preferences.language = .english
        let reopened = AppPreferences(defaults: defaults, loginItem: login)
        check(reopened.language == .english, "Language survives reopening preferences")
        defaults.set("unsupported", forKey: AppLanguage.defaultsKey)
        check(AppPreferences(defaults: defaults, loginItem: login).language == .polish, "Unknown saved language safely falls back to Polish")
        preferences.setLaunchAtLogin(true)
        check(preferences.launchAtLogin && login.registrations == 1, "Enable registers the app and reads the system result")
        preferences.setLaunchAtLogin(true)
        check(login.registrations == 1, "Already enabled login item is not registered again")
        preferences.setLaunchAtLogin(false)
        check(!preferences.launchAtLogin && login.unregistrations == 1, "Disable unregisters the login item")
        login.registrationResult = .requiresApproval
        preferences.setLaunchAtLogin(true)
        check(!preferences.launchAtLogin && preferences.loginStatus == .requiresApproval, "Pending system approval is not presented as enabled")
        preferences.setLaunchAtLogin(true)
        check(login.registrations == 2, "Pending approval does not repeatedly register")
        preferences.setLaunchAtLogin(false)
        check(preferences.loginStatus == .notRegistered, "Pending registration can be cancelled")
        login.failure = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Registration failed"])
        preferences.setLaunchAtLogin(true)
        check(!preferences.launchAtLogin && preferences.loginError == "Registration failed", "Registration failure preserves the actual disabled state")
        login.failure = nil
        login.registrationResult = .enabled
        preferences.setLaunchAtLogin(true)
        check(preferences.launchAtLogin && preferences.loginError == nil, "A successful retry clears the error")
        login.failure = NSError(domain: "test", code: 2)
        preferences.setLaunchAtLogin(false)
        check(preferences.launchAtLogin && preferences.loginError != nil, "Unregistration failure preserves the actual enabled state")
        login.status = .requiresApproval
        preferences.refreshLoginStatus()
        check(!preferences.launchAtLogin && preferences.loginStatus == .requiresApproval, "External System Settings changes are reflected")

        let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/en.lproj")
        let bundle = Bundle(url: resources)!
        check(Localization.text("Ustawienia", language: .english, bundle: bundle) == "Settings", "English strings load from the packaged language bundle")
        check(Localization.text("Ustawienia", language: .polish, bundle: bundle) == "Ustawienia", "Polish uses the source text")
        check(Localization.text("unknown", language: .english, bundle: bundle) == "unknown", "Missing translations preserve the source")
        check(Localization.text("Wersja {0} ({1})", arguments: ["1.5.0", "8"], language: .english, bundle: bundle) == "Version 1.5.0 (8)", "Version and build interpolate correctly")
        check(Localization.text("{1} {0} {1}", arguments: ["100% %@ {1}", "PHP"], language: .english, bundle: bundle) == "PHP 100% %@ {1} PHP", "Reordered arguments remain literal, including percent signs and placeholders")
        check(Localization.text("PHP {0} jest gotowe. Kliknij Użyj, aby je włączyć.", arguments: ["8.5.12"], language: .english, bundle: bundle) == "PHP 8.5.12 is ready. Click Use to activate it.", "Installer messages use the same translation catalog")
        print("All \(count) preferences and localization checks passed.")
    }
}
