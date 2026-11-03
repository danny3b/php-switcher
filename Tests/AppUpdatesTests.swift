import Foundation
import Sparkle

@main struct AppUpdatesTests {
    @MainActor static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: " + name) }
            count += 1; print("PASS: " + name)
        }
        let suite = "php-switcher-update-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = AppUpdates(defaults: defaults)
        check(updates.automaticDownloads, "Automatic downloads default to enabled")
        var downloads: [SPUUserUpdateChoice] = []
        updates.receiveUpdate(version: "1.7.0", stage: .notDownloaded, informationOnly: false) { downloads.append($0) }
        check(downloads == [.install] && updates.phase == .downloading, "A new update starts downloading automatically")
        updates.showDownloadDidReceiveExpectedContentLength(100)
        updates.showDownloadDidReceiveData(ofLength: 25)
        check(updates.progress == 0.25, "Download progress is reported")
        updates.showDownloadDidReceiveData(ofLength: 200)
        check(updates.progress == 1, "Unexpected content lengths do not overflow the progress bar")
        updates.showDownloadDidStartExtractingUpdate()
        var installation: [SPUUserUpdateChoice] = []
        updates.showReady(toInstallAndRelaunch: { installation.append($0) })
        check(updates.phase == .ready && installation.isEmpty, "A prepared update waits for an explicit installation action")
        updates.canInstall = { false }
        updates.installAndRestart()
        check(installation.isEmpty && updates.phase == .ready && updates.error != nil, "Busy PHP operations and open editors block restart")
        updates.canInstall = { true }
        updates.installAndRestart()
        check(installation == [.install] && updates.phase == .installing, "The install button authorizes replacement and restart")
        updates.installAndRestart()
        check(installation == [.install], "Double clicking does not invoke the installation callback twice")
        check(!updates.prepareForTermination(completion: {}), "An explicitly requested update can terminate the app")
        updates.dismissUpdateInstallation()

        updates.automaticDownloads = false
        let reopened = AppUpdates(defaults: defaults)
        check(!reopened.automaticDownloads, "The download preference survives reopening")
        var choices: [SPUUserUpdateChoice] = []
        reopened.receiveUpdate(version: "1.7.0", stage: .notDownloaded, informationOnly: false) { choices.append($0) }
        check(reopened.phase == .available && choices.isEmpty, "Disabling downloads leaves a manual download action")
        reopened.automaticDownloads = true
        check(choices == [.install], "Enabling downloads starts an already available update")
        var cancelled = 0
        reopened.showDownloadInitiated(cancellation: { cancelled += 1 })
        var quit = 0
        check(reopened.prepareForTermination(completion: { quit += 1 }), "Normal quit waits for an update download to be cancelled")
        check(cancelled == 1 && quit == 0, "Cancellation is requested before the app quits")
        reopened.dismissUpdateInstallation()
        check(quit == 1, "Termination proceeds after Sparkle acknowledges cancellation")
        reopened.dismissUpdateInstallation()
        check(quit == 1, "The termination callback is consumed only once")

        let extracting = AppUpdates(defaults: defaults)
        extracting.showDownloadDidStartExtractingUpdate()
        var extractionQuit = false
        check(extracting.prepareForTermination(completion: { extractionQuit = true }), "Quit during extraction waits for a cancellable stage")
        var extractionChoices: [SPUUserUpdateChoice] = []
        extracting.showReady(toInstallAndRelaunch: { extractionChoices.append($0) })
        check(extractionChoices == [.skip] && !extractionQuit, "Quit cancels prepared installation instead of installing silently")
        extracting.dismissUpdateInstallation()
        check(extractionQuit, "Quit completes after prepared installation is cancelled")

        let ready = AppUpdates(defaults: defaults)
        var readyChoices: [SPUUserUpdateChoice] = []
        ready.showReady(toInstallAndRelaunch: { readyChoices.append($0) })
        check(ready.prepareForTermination(completion: {}), "Normal quit defers when an update is ready")
        check(readyChoices == [.skip], "Normal quit never authorizes installation")

        let information = AppUpdates(defaults: defaults)
        var informationalChoices: [SPUUserUpdateChoice] = []
        information.receiveUpdate(version: "2.0.0", stage: .notDownloaded, informationOnly: true) { informationalChoices.append($0) }
        check(informationalChoices == [.dismiss] && information.error != nil, "Informational releases are not passed to the installer")
        let noUpdate = NSError(domain: SUSparkleErrorDomain, code: SUError.noUpdateError.rawValue,
                               userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.onLatestVersion.rawValue)])
        information.showUpdateNotFoundWithError(noUpdate, acknowledgement: {})
        check(information.phase == .upToDate && information.lastChecked != nil, "A successful latest-version check records its timestamp")
        let lastSuccess = information.lastChecked
        information.showUpdaterError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), acknowledgement: {})
        check(information.phase == .failed && information.lastChecked == lastSuccess, "Offline errors preserve the last successful check without reporting up to date")
        information.showUpdateNotFoundWithError(NSError(domain: SUSparkleErrorDomain, code: SUError.noUpdateError.rawValue,
                                                        userInfo: [NSLocalizedDescriptionKey: "A newer macOS version is required."]), acknowledgement: {})
        check(information.phase == .failed, "An incompatible release is not misreported as up to date")
        print("All \(count) app update checks passed.")
    }
}
