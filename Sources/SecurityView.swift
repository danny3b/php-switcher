import SwiftUI

struct SecurityView: View {
    @ObservedObject var store: SwitcherStore
    @ObservedObject private var preferences = AppPreferences.shared
    private var color: Color {
        if store.criticalSecurity { return .red }
        if store.securityError != nil || (store.securitySnapshot != nil && !store.securityFresh) || store.securityAttention { return .orange }
        return store.securitySnapshot != nil && !store.monitored.isEmpty ? .green : .secondary
    }
    private var symbol: String {
        store.criticalSecurity ? "exclamationmark.shield.fill" : (store.securityFresh && !store.securityAttention ? "checkmark.shield.fill" : "shield.lefthalf.filled")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Bezpieczeństwo PHP")).font(.system(size: 13, weight: .semibold))
                    Text(store.securityTitle).font(.system(size: 12)).foregroundStyle(color)
                }
                Spacer()
                if store.securityChecking { ProgressView().controlSize(.small) }
                Button(L("Sprawdź teraz")) { store.checkSecurity(force: true) }
                    .disabled(store.securityChecking || store.loading).font(.system(size: 11))
            }
            if let error = store.securityError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline) {
                if let snapshot = store.securitySnapshot {
                    Text(L("Ostatni udany odczyt: ") + snapshot.checkedAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(preferences.language.locale)))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text(L("Źródła: php.net i komunikaty zespołu PHP na GitHub.")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.securityDetails ? L("Ukryj szczegóły") : L("Szczegóły")) { store.securityDetails.toggle() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            if store.securityDetails {
                Divider()
                Toggle(L("Sprawdzaj automatycznie co 6 godzin"), isOn: $store.autoSecurity)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                Text(L("Sprawdzanie działa, gdy aplikacja jest uruchomiona, także w pasku menu. Zakres: wersje PHP Switcher, dodane ręcznie oraz aktywne PHP w terminalu."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let snapshot = store.securitySnapshot, !snapshot.isFresh() || store.securityError != nil {
                    Text(L("Poniżej ostatni zapisany wynik — może nie uwzględniać nowych publikacji."))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                }
                ForEach(store.securityAssessments) { assessment in
                    assessmentRow(assessment)
                }
                HStack(spacing: 16) {
                    Link(L("Wydania PHP ↗"), destination: URL(string: "https://www.php.net/downloads.php")!)
                    Link(L("Komunikaty bezpieczeństwa ↗"), destination: URL(string: "https://github.com/php/php-src/security/advisories")!)
                }.font(.system(size: 10))
                Text(L("Ocena według numeru PHP i komunikatów projektu; nie jest audytem bibliotek ani rozszerzeń PECL. Warunki podatności opisano w komunikacie."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let assessment = store.securityAssessments.first(where: { $0.critical }) ?? store.securityAssessments.first(where: { $0.needsAttention }) {
                HStack {
                    Text("PHP \(assessment.installation.version): \(assessment.label)")
                        .font(.system(size: 11)).foregroundStyle(color)
                    Spacer()
                    updateButton(assessment)
                }
            }
        }
        .padding(15)
        .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.18), lineWidth: 1))
    }

    @ViewBuilder private func assessmentRow(_ item: PHPSecurityAssessment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PHP " + item.installation.version + (item.id == store.activeRoot ? L(" · aktywne") : ""))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                updateButton(item)
            }
            Text(item.label).font(.system(size: 11)).foregroundStyle(item.critical ? Color.red : (item.needsAttention ? .orange : .secondary))
            if let release = item.release {
                Link(L("Najnowsze w tej serii: {0} · {1} ↗", String(describing: release.version), String(describing: release.date)), destination: release.url).font(.system(size: 10))
            }
            if item.unsupported {
                Text(L("Ta seria nie otrzymuje już oficjalnych poprawek PHP. Wybierz wspieraną serię po sprawdzeniu zgodności projektu."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if item.uncertain {
                Text(L("Nie udało się jednoznacznie porównać wszystkich komunikatów z tą wersją."))
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            ForEach(item.findings) { finding in
                Link("\(finding.severityLabel) · \(finding.cve ?? finding.id) · \(finding.summary) ↗", destination: finding.url)
                    .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(10).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func updateButton(_ item: PHPSecurityAssessment) -> some View {
        if let update = item.update, PHPManager.isValidVersion(update.version) {
            if let installed = store.installations.first(where: { $0.version == update.version && ($0.source == "PHP Switcher" || $0.source == "Dodane ręcznie") }) {
                if store.activeRoot != installed.root {
                    Button(L("Użyj ") + update.version) { store.activate(installed) }.disabled(store.busy).font(.system(size: 11))
                } else {
                    Text(L("{0} już aktywne", String(describing: update.version))).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Button(L("Zainstaluj ") + update.version) { store.install(update.version) }.disabled(store.busy).font(.system(size: 11))
            }
        }
    }
}
