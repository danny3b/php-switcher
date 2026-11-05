import SwiftUI

// Disambiguate the property wrapper from the State macro in newer SDKs.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct DatabasesView: View {
    @ObservedObject private var database = DatabaseStore.shared
    @ObservedObject private var store = SwitcherStore.shared
    @ViewState private var confirming = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(L("Bazy danych"), systemImage: "externaldrive")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(L("Zastąp lokalną bazę MySQL zawartością pliku SQL."))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("MySQL · 127.0.0.1").font(.headline)
                        Spacer()
                        Text(L("Tylko localhost")).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        field(L("Port"), width: 85) { TextField("3306", text: $database.port) }
                        field(L("Użytkownik")) { TextField("root", text: $database.user) }
                        field(L("Hasło")) { SecureField(L("Hasło"), text: $database.password) }
                    }.textFieldStyle(.roundedBorder)
                    Text(L("Hasło jest pamiętane tylko do zamknięcia aplikacji."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Klient MySQL")).font(.caption).foregroundStyle(.secondary)
                            Text(database.clientPath.isEmpty ? L("Nie znaleziono klienta mysql. Wskaż program z MAMP lub Homebrew.") : database.clientPath)
                                .font(.system(size: 11, design: .monospaced)).lineLimit(2).help(database.clientPath)
                        }
                        Spacer()
                        Button(L("Wybierz…")) { database.chooseClient() }
                    }
                    Button(database.connected ? L("Odśwież bazy") : L("Połącz i pobierz bazy")) { database.connect() }
                        .disabled(!database.canConnect || store.busy)
                }
                .padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .disabled(database.isBusy)

                VStack(alignment: .leading, spacing: 16) {
                    Text(L("Baza do zastąpienia")).font(.headline)
                    if database.connected && database.databases.isEmpty {
                        Text(L("Brak dostępnych baz użytkownika. Bazy systemowe są ukryte."))
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Picker(L("Lokalna baza"), selection: $database.selectedDatabase) {
                            Text(L("Wybierz bazę…")).tag("")
                            ForEach(database.databases, id: \.self) { Text($0).tag($0) }
                        }.disabled(!database.connected || database.isBusy)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(database.sqlFile?.lastPathComponent ?? L("Nie wybrano pliku SQL"))
                                .font(.system(size: 13, weight: .medium)).lineLimit(2)
                            if let file = database.sqlFile {
                                Text(file.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Button(L("Wybierz plik SQL…")) { database.chooseSQLFile() }.disabled(database.isBusy)
                    }
                    Text(L("Plik z tabelami i danymi jednej bazy, np. z mysqldump lub phpMyAdmin. Widoki, procedury i wyzwalacze nie są jeszcze obsługiwane."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Toggle(L("Utwórz kopię obecnej bazy przed czyszczeniem"), isOn: $database.createBackup)
                        .toggleStyle(.checkbox).disabled(database.isBusy)
                    Text(L("Na czas importu zatrzymaj lokalną stronę lub inne zapisy do tej bazy."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button(L("Zastąp bazę…")) { confirming = true }
                            .buttonStyle(.borderedProminent).tint(.orange)
                            .disabled(!database.canReplace || store.busy)
                    }
                }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

                if database.isBusy {
                    ProgressView(value: database.state?.fraction ?? 0)
                    HStack {
                        Text(database.cancelling ? L("Anulowanie operacji…") : database.message).font(.callout)
                        Spacer()
                        Button(L("Anuluj")) { database.cancel() }.disabled(database.cancelling)
                    }
                } else if database.error == nil && !database.message.isEmpty {
                    Label(database.message, systemImage: database.state?.status == "complete" ? "checkmark.circle.fill" : "info.circle")
                        .foregroundStyle(database.state?.status == "complete" ? .green : .secondary)
                        .font(.callout)
                }
                if let error = database.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                if database.databaseMayBePartial && !database.isBusy {
                    Text(L("Baza może być pusta lub zawierać niepełne dane. Popraw plik i ponów import albo przywróć kopię zapasową."))
                        .font(.callout).foregroundStyle(.orange)
                }
                if let backup = database.backupURL {
                    HStack {
                        Text(L("Kopia zapasowa: {0}", backup.lastPathComponent)).font(.caption).lineLimit(2)
                        Spacer()
                        Button(L("Pokaż kopię")) { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                    }
                }
            }.padding(28)
        }
        .sheet(isPresented: $confirming) { DatabaseReplacementConfirmation(database: database) }
    }

    private func field<Content: View>(_ title: String, width: CGFloat? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().accessibilityLabel(title)
        }.frame(width: width)
    }
}

private struct DatabaseReplacementConfirmation: View {
    @ObservedObject var database: DatabaseStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var typedName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L("Zastąpić zawartość bazy?"), systemImage: "exclamationmark.triangle")
                .font(.title2.bold()).foregroundStyle(.orange)
            Text(database.selectedDatabase).font(.title2.monospaced().bold()).textSelection(.enabled)
            Text("127.0.0.1:\(database.port) · \(database.sqlFile?.lastPathComponent ?? "")")
                .font(.callout).foregroundStyle(.secondary)
            Text(L("Cała obecna zawartość tej bazy zostanie usunięta i zastąpiona plikiem SQL. Operacja nie jest transakcją; błąd importu może pozostawić niepełne dane."))
            Text(database.createBackup ? L("Przed czyszczeniem zostanie zapisana kopia zapasowa. Jeśli jej utworzenie się nie powiedzie, import nie rozpocznie się.") : L("Kopia zapasowa jest wyłączona. Obecne dane zostaną utracone."))
                .font(.callout).foregroundStyle(database.createBackup ? Color.secondary : Color.orange)
            TextField(L("Wpisz nazwę bazy, aby potwierdzić"), text: $typedName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(L("Anuluj")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Wyczyść i importuj"), role: .destructive) {
                    database.replace(confirmedName: typedName)
                    dismiss()
                }.disabled(typedName != database.selectedDatabase || !database.canReplace)
            }
        }.padding(28).frame(width: 530)
    }
}
