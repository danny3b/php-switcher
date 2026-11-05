import Foundation

private final class MemoryPasswordStore: DatabasePasswordStoring {
    var passwords: [DatabaseCredentialAccount: String] = [:]
    var reads = 0
    var writes = 0
    var removals = 0
    var failRead = false
    var failWrite = false
    var failRemoval = false
    private let failure = NSError(domain: "DatabaseCredentialsTests", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Simulated Keychain failure"])

    func password(for account: DatabaseCredentialAccount) throws -> String? {
        reads += 1
        if failRead { throw failure }
        return passwords[account]
    }

    func save(_ credential: DatabaseCredential) throws {
        writes += 1
        if failWrite { throw failure }
        passwords[credential.account] = credential.password
    }

    func removePassword(for account: DatabaseCredentialAccount) throws {
        removals += 1
        if failRemoval { throw failure }
        passwords.removeValue(forKey: account)
    }
}

@main struct DatabaseCredentialsTests {
    @MainActor static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: " + name) }
            count += 1; print("PASS: " + name)
        }
        let suite = "devzbik-credential-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("3306", forKey: "mysqlPort")
        defaults.set("root", forKey: "mysqlUser")
        let passwords = MemoryPasswordStore()
        let root = DatabaseCredentialAccount(port: "3306", user: "root")!
        let mamp = DatabaseCredentialAccount(port: "8889", user: "root")!
        let other = DatabaseCredentialAccount(port: "3306", user: "other")!
        let original = DatabaseCredential(account: root, password: "original-test-secret")
        let updated = DatabaseCredential(account: root, password: "updated-test-secret-ą🔑")
        passwords.passwords = [root: original.password, mamp: "mamp-test-secret", other: "other-test-secret"]

        let store = DatabaseStore(defaults: defaults, passwordStore: passwords)
        check(store.rememberPassword && passwords.reads == 0 && store.password.isEmpty,
              "Remembering defaults to enabled without accessing Keychain during initialization")
        store.restorePassword()
        check(store.password == original.password && store.passwordIsSaved, "Opening Databases restores the saved account password")
        store.password = updated.password
        store.restorePassword()
        check(store.password == updated.password && passwords.reads == 1, "Reopening the tab preserves edited input")
        check(passwords.writes == 0 && passwords.passwords[root] == original.password && !store.passwordIsSaved,
              "Typing an unverified password does not overwrite the saved credential")
        store.recordSuccessfulConnection(original)
        check(passwords.writes == 0, "A stale success for an older password cannot save edited input")
        store.recordSuccessfulConnection(updated)
        check(passwords.passwords[root] == updated.password && store.passwordIsSaved, "Successful authentication saves the exact Unicode password")
        store.recordSuccessfulConnection(updated)
        check(passwords.writes == 1, "Repeated connections do not rewrite an unchanged saved password")

        let reopened = DatabaseStore(defaults: defaults, passwordStore: passwords)
        reopened.restorePassword()
        check(reopened.password == updated.password && reopened.passwordIsSaved, "A new app session restores the saved password")
        reopened.port = "8889"
        check(reopened.password == passwords.passwords[mamp], "Changing port loads only that port's credential")
        reopened.recordSuccessfulConnection(updated)
        check(passwords.writes == 1, "A stale success for another port is ignored")
        reopened.port = "3306"
        reopened.user = "other"
        check(reopened.password == passwords.passwords[other], "Changing user loads only that user's credential")
        reopened.user = "missing"
        check(reopened.password.isEmpty && !reopened.passwordIsSaved, "An unknown account never retains the previous account's password")
        reopened.user = "root"
        let reads = passwords.reads
        reopened.port = "03306"
        check(reopened.password == updated.password && passwords.reads == reads, "Equivalent numeric ports use the same credential")
        reopened.port = "0"
        check(reopened.password.isEmpty && passwords.reads == reads, "Invalid endpoints clear the field without querying Keychain")
        reopened.port = "3306"
        reopened.password = "unverified-test-secret"
        reopened.setRememberPassword(false)
        check(!reopened.rememberPassword && passwords.passwords[root] == nil && !reopened.passwordIsSaved,
              "Turning remembering off removes the current account's stored password")
        check(reopened.password == "unverified-test-secret" && passwords.passwords[mamp] != nil && passwords.passwords[other] != nil,
              "Forgetting preserves the in-memory input and other accounts")
        let disabled = DatabaseStore(defaults: defaults, passwordStore: passwords)
        let readsBeforeDisabled = passwords.reads
        disabled.restorePassword()
        disabled.port = "8889"
        check(!disabled.rememberPassword && disabled.password.isEmpty && passwords.reads == readsBeforeDisabled,
              "The disabled preference survives restart and suppresses reads for every account")
        let writesBeforeDisabled = passwords.writes
        disabled.password = "disabled-test-secret"
        disabled.recordSuccessfulConnection(DatabaseCredential(account: mamp, password: disabled.password))
        check(passwords.writes == writesBeforeDisabled, "Successful connections do not save when remembering is off")
        disabled.setRememberPassword(true)
        check(disabled.passwordIsSaved && passwords.passwords[mamp] == "disabled-test-secret",
              "Enabling after successful authentication saves the verified current password")
        reopened.setRememberPassword(true)
        check(passwords.passwords[root] == nil && !reopened.passwordIsSaved,
              "Enabling with unverified text does not save it")

        // Read, write, and delete failures must stay distinct from MySQL errors.
        defaults.set("3306", forKey: "mysqlPort")
        passwords.passwords[root] = original.password
        passwords.failRead = true
        let failing = DatabaseStore(defaults: defaults, passwordStore: passwords)
        failing.restorePassword()
        check(failing.password.isEmpty && failing.passwordReadFailed && failing.credentialError != nil && failing.error == nil,
              "A locked or denied Keychain read is reported without pretending the password was loaded")
        passwords.failRead = false
        failing.restorePassword(force: true)
        check(failing.password == original.password && !failing.passwordReadFailed && failing.credentialError == nil,
              "Retrying a denied read restores the password and clears the storage error")
        failing.password = updated.password
        passwords.failWrite = true
        failing.recordSuccessfulConnection(updated)
        check(failing.credentialError != nil && failing.error == nil && !failing.passwordIsSaved && passwords.passwords[root] == original.password,
              "A failed save keeps the previous secret and reports a storage error separately")
        passwords.failWrite = false
        failing.recordSuccessfulConnection(updated)
        check(failing.passwordIsSaved && failing.credentialError == nil, "A later successful connection retries a failed save")
        passwords.failRemoval = true
        failing.setRememberPassword(false)
        check(failing.rememberPassword && defaults.bool(forKey: "rememberMySQLPassword") && passwords.passwords[root] == updated.password && failing.credentialError != nil,
              "A failed removal does not claim that remembering has been disabled")
        passwords.failRemoval = false
        failing.setRememberPassword(false)
        check(!failing.rememberPassword && failing.credentialError == nil && passwords.passwords[root] == nil, "Retrying removal forgets the credential")
        failing.setRememberPassword(true)
        check(failing.passwordIsSaved && passwords.passwords[root] == updated.password, "Re-enabling can restore the last verified in-memory credential")

        failing.password = ""
        failing.recordSuccessfulConnection(DatabaseCredential(account: root, password: ""))
        let passwordless = DatabaseStore(defaults: defaults, passwordStore: passwords)
        passwordless.restorePassword()
        check(passwords.passwords[root] == "" && passwordless.passwordIsSaved, "Passwordless accounts are distinguishable from missing credentials")
        check(DatabaseCredentialAccount(port: "65536", user: "root") == nil && DatabaseCredentialAccount(port: "3306", user: " \n") == nil,
              "Invalid ports and blank usernames cannot create Keychain entries")
        check(DatabaseCredentialAccount(port: "3306", user: "Root") != root, "Case-sensitive MySQL usernames remain distinct")
        let preferences = defaults.persistentDomain(forName: suite) ?? [:]
        check(Set(preferences.keys) == Set(["mysqlPort", "mysqlUser", "rememberMySQLPassword"]),
              "Only connection metadata and the remembering preference are persisted in UserDefaults")
        print("All \(count) MySQL credential checks passed without accessing the real Keychain or MySQL.")
    }
}
