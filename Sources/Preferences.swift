import Combine
import Foundation
import ServiceManagement

@MainActor protocol LoginItemManaging {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor struct SystemLoginItem: LoginItemManaging {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    private let defaults: UserDefaults
    private let loginItem: any LoginItemManaging
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: AppLanguage.defaultsKey)
            languageSelection = language
            needsLanguageSelection = false
        }
    }
    @Published private(set) var needsLanguageSelection: Bool
    // Previewing a first-launch choice must not persist it before confirmation.
    @Published var languageSelection: AppLanguage
    @Published private(set) var loginStatus: SMAppService.Status
    @Published private(set) var loginError: String?
    var launchAtLogin: Bool { loginStatus == .enabled }

    init(defaults: UserDefaults = .standard, loginItem: (any LoginItemManaging)? = nil,
         preferredLanguages: [String] = Locale.preferredLanguages) {
        let loginItem = loginItem ?? SystemLoginItem()
        self.defaults = defaults
        self.loginItem = loginItem
        let savedLanguage = AppLanguage(rawValue: defaults.string(forKey: AppLanguage.defaultsKey) ?? "")
        let initialLanguage = savedLanguage ?? AppLanguage.preferred(from: preferredLanguages)
        language = initialLanguage
        languageSelection = initialLanguage
        needsLanguageSelection = savedLanguage == nil
        loginStatus = loginItem.status
    }

    func completeLanguageSelection(_ selected: AppLanguage) { language = selected }

    func refreshLoginStatus() {
        let status = loginItem.status
        if loginStatus != status { loginStatus = status }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        refreshLoginStatus()
        do {
            if enabled {
                // A denied registration already exists. The user must re-enable
                // it in System Settings; registering it again cannot grant consent.
                if loginStatus != .enabled && loginStatus != .requiresApproval { try loginItem.register() }
            } else if loginStatus == .enabled || loginStatus == .requiresApproval {
                try loginItem.unregister()
            }
        } catch {
            loginError = error.localizedDescription
        }
        refreshLoginStatus()
    }
}

