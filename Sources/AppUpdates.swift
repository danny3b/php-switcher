import AppKit
import Combine
import Sparkle

enum AppUpdatePhase: Equatable {
    case idle, checking, available, downloading, extracting, ready, installing, upToDate, failed
}

/// Sparkle owns version selection, signature verification, extraction, replacement,
/// and relaunch. This driver keeps update UI inside the app's settings.
@MainActor final class AppUpdates: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    static let shared = AppUpdates()
    private let defaults: UserDefaults
    private var engine: SPUUpdater?
    private var observations: [AnyCancellable] = []
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var quitCompletion: (() -> Void)?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var installRequested = false
    private var retryTermination: (() -> Void)?
    var canInstall: () -> Bool = { true }
    var revealSettings: () -> Void = {}

    @Published private(set) var phase: AppUpdatePhase = .idle
    @Published private(set) var version: String?
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var automaticChecks = true
    @Published var automaticDownloads: Bool {
        didSet {
            defaults.set(automaticDownloads, forKey: "automaticallyDownloadAppUpdates")
            if automaticDownloads && phase == .available { download() }
        }
    }
    @Published private(set) var canCheck = false
    var isBusy: Bool { [.checking, .downloading, .extracting, .installing].contains(phase) }
    var hasUpdate: Bool { version != nil && [.available, .downloading, .extracting, .ready].contains(phase) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticDownloads = defaults.object(forKey: "automaticallyDownloadAppUpdates") as? Bool ?? true
        lastChecked = defaults.object(forKey: "lastSuccessfulAppUpdateCheck") as? Date
        super.init()
    }

    func start() {
        guard engine == nil else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        engine = updater
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] value in self?.automaticChecks = value }.store(in: &observations)
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in self?.canCheck = value }.store(in: &observations)
        do {
            try updater.start()
            // Sparkle owns all later scheduling, including wake handling and backoff.
            if updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
        } catch { fail(error) }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        engine?.automaticallyChecksForUpdates = enabled
    }

    func check() {
        guard canCheck, !isBusy else { return }
        engine?.checkForUpdates()
    }

    func download() {
        guard phase == .available, let reply = choice else { return }
        choice = nil; phase = .downloading; progress = nil; error = nil
        reply(.install)
    }

    func installAndRestart() {
        guard phase == .ready || (phase == .installing && retryTermination != nil) else { return }
        guard canInstall() else {
            error = L("Zakończ bieżącą operację i zapisz lub zamknij edytor ustawień przed aktualizacją.")
            return
        }
        error = nil; installRequested = true; phase = .installing
        if let retryTermination { retryTermination(); return }
        let reply = choice
        choice = nil
        reply?(.install)
    }

    func cancel() {
        if let cancellation {
            self.cancellation = nil; cancellation()
        } else if let reply = choice {
            choice = nil
            // Skip at the prepared stage cancels installation; it does not skip
            // the release in future checks. Before download, simply dismiss it.
            reply(phase == .ready ? .skip : .dismiss)
        }
    }

    /// A normal Quit must not silently install an automatically downloaded update.
    /// Wait for Sparkle to acknowledge cancellation before allowing termination.
    func prepareForTermination(completion: @escaping () -> Void) -> Bool {
        guard !installRequested, [.available, .downloading, .extracting, .ready].contains(phase) else { return false }
        quitCompletion = completion
        cancel()
        return true
    }

    private func checked() {
        lastChecked = Date()
        defaults.set(lastChecked, forKey: "lastSuccessfulAppUpdateCheck")
    }

    private func fail(_ issue: Error) {
        error = issue.localizedDescription
        phase = .failed; progress = nil
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        phase = .checking; error = nil; version = nil; progress = nil
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { checked() }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        recordNoUpdate(error)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let issue = error as NSError
        if issue.domain == SUSparkleErrorDomain && issue.code == SUError.noUpdateError.rawValue { return }
        if quitCompletion == nil { fail(error) }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finishQuitIfNeeded()
    }

    // The automatic installer is disabled in Info.plist. Downloads are explicitly
    // started through this user driver so we can cancel on normal application quit.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: automaticChecks, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation; phase = .checking; error = nil
    }

    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        receiveUpdate(version: item.displayVersionString, stage: state.stage, informationOnly: item.isInformationOnlyUpdate, reply: reply)
    }

    // Kept separate from Sparkle's immutable state object for deterministic tests.
    func receiveUpdate(version: String, stage: SPUUserUpdateStage, informationOnly: Bool,
                       reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.version = version; error = nil; cancellation = nil; choice = reply
        if quitCompletion != nil { choice = nil; reply(stage == .installing ? .skip : .dismiss); return }
        if informationOnly {
            choice = nil; phase = .failed
            error = L("To wydanie wymaga ręcznej instalacji. Otwórz wydania na GitHubie.")
            reply(.dismiss); return
        }
        switch stage {
        case .installing: phase = .ready
        case .downloaded:
            phase = .available
            download()
        default:
            phase = .available
            if automaticDownloads { download() }
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        recordNoUpdate(error); acknowledgement()
    }

    private func recordNoUpdate(_ issue: Error) {
        checked(); version = nil; progress = nil
        let reason = (issue as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        if reason?.intValue == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue) {
            phase = .upToDate; error = nil
        } else {
            phase = .failed; error = issue.localizedDescription
        }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if quitCompletion == nil { fail(error) }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation; phase = .downloading; progress = nil
        expectedBytes = 0; receivedBytes = 0
        if quitCompletion != nil { cancel() }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expectedBytes = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes = receivedBytes.addingReportingOverflow(length).partialValue
        if expectedBytes > 0 { progress = min(1, Double(receivedBytes) / Double(expectedBytes)) }
    }
    func showDownloadDidStartExtractingUpdate() { cancellation = nil; phase = .extracting; progress = nil }
    func showExtractionReceivedProgress(_ progress: Double) { self.progress = min(1, max(0, progress)) }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        choice = reply; cancellation = nil; phase = .ready; progress = nil
        if quitCompletion != nil { cancel() }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }

    func dismissUpdateInstallation() {
        choice = nil; cancellation = nil; retryTermination = nil; installRequested = false; progress = nil
        if phase != .upToDate && phase != .failed { phase = .idle; version = nil }
        finishQuitIfNeeded()
    }
    private func finishQuitIfNeeded() {
        let completion = quitCompletion; quitCompletion = nil
        completion?()
    }
    func showUpdateInFocus() { revealSettings() }
}
