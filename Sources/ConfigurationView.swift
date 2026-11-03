import SwiftUI
import AppKit

@MainActor final class PHPIniEditor: ObservableObject, Identifiable {
    let id = UUID()
    let service: PHPIniService
    @Published var snapshot: PHPIniSnapshot
    @Published var values: [String: String]
    @Published var group = "Wysyłanie plików"
    @Published var saving = false
    @Published var error: String?
    @Published var message = ""
    @Published var backups: [URL] = []
    var isDirty: Bool { values != snapshot.values }
    var validationError: String? {
        do { _ = try snapshot.changes(values); return nil }
        catch { return error.localizedDescription }
    }
    init(snapshot: PHPIniSnapshot, service: PHPIniService) {
        self.snapshot = snapshot; self.values = snapshot.values; self.service = service
    }
    func save() {
        guard !saving, isDirty, validationError == nil else { return }
        saving = true; error = nil; message = ""
        let snapshot = snapshot, values = values, service = service
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try service.save(snapshot, edited: values)
                DispatchQueue.main.async {
                    self.snapshot = result.snapshot; self.values = result.snapshot.values
                    self.backups = result.backups
                    self.message = L("Zapisano i sprawdzono ustawienia PHP. Utworzono kopię poprzedniej konfiguracji.")
                    self.saving = false
                }
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription; self.saving = false }
            }
        }
    }
    func reload() {
        guard !saving, canClose() else { return }
        saving = true; error = nil; message = ""
        let installation = snapshot.installation, service = service
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try service.read(installation)
                DispatchQueue.main.async { self.snapshot = result; self.values = result.values; self.saving = false }
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription; self.saving = false }
            }
        }
    }
    func canClose() -> Bool {
        guard !saving else { return false }
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L("Odrzucić niezapisane ustawienia?")
        alert.informativeText = L("Zmiany w formularzu nie zostały jeszcze zapisane do konfiguracji PHP.")
        alert.addButton(withTitle: L("Wróć do edycji"))
        alert.addButton(withTitle: L("Odrzuć zmiany"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    func binding(_ field: PHPIniField) -> Binding<String> {
        Binding(get: { self.values[field.rawValue] ?? "" }, set: { self.values[field.rawValue] = $0; self.message = ""; self.error = nil })
    }
}

struct PHPConfigurationView: View {
    @ObservedObject var editor: PHPIniEditor
    @ObservedObject private var preferences = AppPreferences.shared
    let close: () -> Void
    private let groups = ["Wysyłanie plików", "Pamięć i limity", "Błędy i dzienniki", "Data i czas"]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Ustawienia PHP ") + editor.snapshot.installation.version).font(.title2.bold())
                    Text(editor.snapshot.files[0].url.path).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([editor.snapshot.files[0].url]) } label: { Image(systemName: "folder") }
                    .help(L("Pokaż php.ini w Finderze")).disabled(editor.saving)
            }.padding(24)
            Picker(L("Kategoria"), selection: $editor.group) {
                ForEach(groups, id: \.self) { Text(L($0)).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 14).disabled(editor.saving)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(PHPIniField.allCases.filter { $0.group == editor.group }) { field in
                        settingRow(field)
                    }
                    ForEach(editor.snapshot.warnings(editor.values), id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if let issue = editor.validationError {
                        Label(issue, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = editor.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if !editor.message.isEmpty {
                        Label(editor.message, systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                    }
                }.padding(.horizontal, 24).padding(.vertical, 10)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Zmiany dotyczą tej instalacji PHP. Terminal wczyta je przy następnym uruchomieniu PHP. Jeśli serwer WWW korzysta z tego pliku, uruchom go ponownie."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("Wczytaj ponownie")) { editor.reload() }.disabled(editor.saving)
                    if !editor.backups.isEmpty {
                        Button(L("Pokaż kopię")) { NSWorkspace.shared.activateFileViewerSelecting(editor.backups) }.buttonStyle(.link)
                    }
                    Spacer()
                    if editor.saving { ProgressView().controlSize(.small) }
                    Button(L("Zamknij")) { if editor.canClose() { close() } }.keyboardShortcut(.cancelAction).disabled(editor.saving)
                    Button(L("Zapisz ustawienia")) { editor.save() }.keyboardShortcut(.defaultAction)
                        .disabled(editor.saving || !editor.isDirty || editor.validationError != nil)
                }
            }.padding(24)
        }.frame(width: 700, height: 650)
        .interactiveDismissDisabled(editor.isDirty || editor.saving)
    }
    @ViewBuilder private func settingRow(_ field: PHPIniField) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.title).font(.system(size: 13, weight: .semibold))
                    Text(field.rawValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                control(field).disabled(editor.saving)
            }
            if !field.hint.isEmpty { Text(field.hint).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let index = editor.snapshot.owners[field.rawValue], index > 0 {
                Text(L("Wartość z dodatkowego pliku: ") + editor.snapshot.files[index].url.lastPathComponent)
                    .font(.system(size: 10)).foregroundStyle(.secondary).help(editor.snapshot.files[index].url.path)
            }
        }.padding(13).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
    @ViewBuilder private func control(_ field: PHPIniField) -> some View {
        if field.isBoolean {
            Toggle(field.title, isOn: Binding(get: { editor.values[field.rawValue] == "On" }, set: { editor.binding(field).wrappedValue = $0 ? "On" : "Off" }))
                .labelsHidden().toggleStyle(.switch).accessibilityLabel(field.title)
        } else if field == .display {
            Picker(field.title, selection: editor.binding(field)) {
                Text(L("Wyłączone")).tag("Off")
                Text(L("Włączone")).tag("On")
                Text(L("Standardowe wyjście błędów")).tag("stderr")
                if let value = editor.values[field.rawValue], !["On", "Off", "stderr"].contains(value) { Text(value).tag(value) }
            }.labelsHidden().frame(width: 210).accessibilityLabel(field.title)
        } else {
            HStack(spacing: 6) {
                TextField(field.isSize ? L("np. 128M") : (field == .timezone ? "Europe/Warsaw" : L("Liczba")), text: editor.binding(field))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .frame(width: field == .timezone ? 175 : 115).accessibilityLabel(field.title)
                if field == .timezone {
                    Menu {
                        ForEach(["Europe/Warsaw", "UTC", "Europe/London", "Europe/Berlin", "America/New_York"], id: \.self) { zone in
                            Button(zone) { editor.binding(field).wrappedValue = zone }
                        }
                    } label: { Image(systemName: "globe") }.menuStyle(.borderlessButton).frame(width: 24).help(L("Popularne strefy czasowe"))
                }
            }
        }
    }
}
