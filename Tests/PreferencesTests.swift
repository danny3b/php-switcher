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
        let preferences = AppPreferences(defaults: defaults, loginItem: login, preferredLanguages: ["pl-PL"])
        check(preferences.language == .polish && !preferences.launchAtLogin, "The suggested language follows macOS; login launch remains disabled")
        check(preferences.needsLanguageSelection && defaults.string(forKey: AppLanguage.defaultsKey) == nil, "First launch waits for explicit language confirmation without saving the suggestion")
        preferences.languageSelection = .french
        check(preferences.language == .polish && preferences.needsLanguageSelection && defaults.string(forKey: AppLanguage.defaultsKey) == nil, "Previewing another language does not persist or confirm it")
        check(AppPreferences(defaults: defaults, loginItem: login).needsLanguageSelection, "Closing before confirmation asks again next launch")
        preferences.completeLanguageSelection(.polish)
        check(!preferences.needsLanguageSelection && defaults.string(forKey: AppLanguage.defaultsKey) == "pl", "Confirming the suggested language completes first launch")
        check(login.registrations == 0, "Opening settings does not register a login item")
        login.status = .notFound
        preferences.refreshLoginStatus()
        check(!preferences.launchAtLogin && preferences.loginError == nil, "An unregistered app reported as not found is not an operation failure")
        preferences.language = .english
        let reopened = AppPreferences(defaults: defaults, loginItem: login, preferredLanguages: ["de-DE"])
        check(reopened.language == .english && !reopened.needsLanguageSelection, "A previously saved language survives reopening and an OS language change without prompting")
        defaults.set("unsupported", forKey: AppLanguage.defaultsKey)
        let invalid = AppPreferences(defaults: defaults, loginItem: login, preferredLanguages: ["fr-CA"])
        check(invalid.language == .french && invalid.needsLanguageSelection, "An unsupported saved language offers a supported macOS language for confirmation")
        check(AppLanguage.preferred(from: ["de-CH"]) == .german, "Regional German resolves to German")
        check(AppLanguage.preferred(from: ["it_IT"]) == .italian, "Italian locale identifiers resolve correctly")
        check(AppLanguage.preferred(from: ["es-ES", "fr-FR"]) == .french, "The first supported macOS language is suggested")
        check(AppLanguage.preferred(from: ["ja-JP"]) == .english, "Unsupported system languages fall back to English")
        for language in AppLanguage.allCases {
            preferences.completeLanguageSelection(language)
            let restored = AppPreferences(defaults: defaults, loginItem: login)
            check(restored.language == language && !restored.needsLanguageSelection, "Confirmed \(language.rawValue) persists without prompting again")
        }
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
        for (language, settings, continuation) in [(AppLanguage.german, "Einstellungen", "Fortfahren"), (.french, "Réglages", "Continuer"), (.italian, "Impostazioni", "Continua")] {
            let url = resources.deletingLastPathComponent().appendingPathComponent(language.rawValue + ".lproj")
            let translated = Bundle(url: url)!
            check(Localization.text("Ustawienia", language: language, bundle: translated) == settings, "\(language.rawValue) loads its own settings translation")
            check(Localization.text("Kontynuuj", language: language, bundle: translated) == continuation, "\(language.rawValue) translates first-launch confirmation")
            let message = Localization.text("PHP {0} jest gotowe. Kliknij Użyj, aby je włączyć.", arguments: ["8.5.12"], language: language, bundle: translated)
            check(message.contains("8.5.12") && !message.contains("{0}") && !message.contains("gotowe"), "\(language.rawValue) translates installer progress and preserves the version")
        }
        print("All \(count) preferences and localization checks passed.")
    }
}
