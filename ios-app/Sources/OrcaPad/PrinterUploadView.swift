import SwiftUI

/// One saved printer connection (Moonraker/Klipper or OctoPrint host).
struct SavedPrinter: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: String // "moonraker" | "octoprint"
    var host: String
    var apiKey: String = ""
}

/// UserDefaults-backed store for the saved printers.
enum PrinterStore {
    private static let listKey = "savedPrinters"
    private static let selectedKey = "selectedSavedPrinter"

    static func load() -> [SavedPrinter] {
        migrateLegacySingle()
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let printers = try? JSONDecoder().decode([SavedPrinter].self, from: data) else { return [] }
        return printers
    }

    static func save(_ printers: [SavedPrinter]) {
        if let data = try? JSONEncoder().encode(printers) {
            UserDefaults.standard.set(data, forKey: listKey)
        }
    }

    static var selectedID: UUID? {
        get { UserDefaults.standard.string(forKey: selectedKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: selectedKey) }
    }

    /// Phase-5 single-printer settings become the first saved printer.
    private static func migrateLegacySingle() {
        let defaults = UserDefaults.standard
        guard defaults.data(forKey: listKey) == nil,
              let host = defaults.string(forKey: "printerHost"), !host.isEmpty else { return }
        let printer = SavedPrinter(
            name: "Printer 1",
            kind: defaults.string(forKey: "printerKind") ?? "moonraker",
            host: host,
            apiKey: defaults.string(forKey: "printerAPIKey") ?? ""
        )
        save([printer])
        selectedID = printer.id
        defaults.removeObject(forKey: "printerHost")
    }
}

/// Send-to-printer sheet: saved printer list (multiple hosts), connection
/// test, open-in-browser for the printer's own web UI (Mainsail/Fluidd/
/// OctoPrint), and the G-code upload.
struct PrinterUploadView: View {
    let gcodeURL: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @AppStorage("printerStartPrint") private var startPrint = false

    @State private var printers: [SavedPrinter] = []
    @State private var selectedID: UUID?
    @State private var testResults: [UUID: String] = [:]

    @State private var editing: SavedPrinter?
    @State private var isNew = false

    @State private var isUploading = false
    @State private var result = ""

    private var selected: SavedPrinter? {
        printers.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Saved printers") {
                    if printers.isEmpty {
                        Text("No saved printers — add one below")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(printers) { printer in
                        printerRow(printer)
                    }
                    .onDelete { offsets in
                        printers.remove(atOffsets: offsets)
                        PrinterStore.save(printers)
                    }

                    Button {
                        editing = SavedPrinter(name: "New printer", kind: "moonraker", host: "http://")
                        isNew = true
                    } label: {
                        Label("Add printer", systemImage: "plus")
                    }
                }

                Section("Send") {
                    Button {
                        startPrint.toggle()
                    } label: {
                        HStack {
                            Image(systemName: startPrint ? "checkmark.square.fill" : "square")
                            Text("Start printing after upload").foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.borderless)

                    Button {
                        upload()
                    } label: {
                        if isUploading {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label(selected.map { "Send to \($0.name)" } ?? "Send G-code",
                                  systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isUploading || selected == nil)

                    if !result.isEmpty {
                        Text(result)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Send to Printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                printers = PrinterStore.load()
                selectedID = PrinterStore.selectedID ?? printers.first?.id
            }
            .sheet(item: $editing) { printer in
                PrinterEditSheet(printer: printer, isNew: isNew) { saved in
                    if let idx = printers.firstIndex(where: { $0.id == saved.id }) {
                        printers[idx] = saved
                    } else {
                        printers.append(saved)
                        selectedID = saved.id
                        PrinterStore.selectedID = saved.id
                    }
                    PrinterStore.save(printers)
                }
            }
        }
    }

    private func printerRow(_ printer: SavedPrinter) -> some View {
        HStack(spacing: 12) {
            Button {
                selectedID = printer.id
                PrinterStore.selectedID = printer.id
            } label: {
                HStack {
                    Image(systemName: printer.id == selectedID ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(printer.id == selectedID ? Color.orcaAccent : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(printer.name).foregroundStyle(.primary)
                        Text("\(printer.kind == "moonraker" ? "Klipper" : "OctoPrint") · \(printer.host)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let test = testResults[printer.id] {
                            Text(test)
                                .font(.caption)
                                .foregroundStyle(test.hasPrefix("Connected") ? Color.orcaAccent : Color.red)
                        }
                    }
                }
            }
            .buttonStyle(.borderless)

            Spacer()

            // Connection test.
            Button {
                testConnection(printer)
            } label: {
                Image(systemName: "bolt.horizontal.circle")
            }
            .buttonStyle(.borderless)

            // The printer's own web UI (Mainsail/Fluidd/OctoPrint) opens in
            // the browser — monitoring/control stays out of the app.
            Button {
                if let url = URL(string: printer.host) {
                    openURL(url)
                }
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.borderless)

            Button {
                editing = printer
                isNew = false
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Networking

    private func testConnection(_ printer: SavedPrinter) {
        guard let base = URL(string: printer.host) else {
            testResults[printer.id] = "Host address is not valid"
            return
        }
        testResults[printer.id] = "Testing…"

        Task {
            var request: URLRequest
            if printer.kind == "moonraker" {
                request = URLRequest(url: base.appendingPathComponent("server/info"))
            } else {
                request = URLRequest(url: base.appendingPathComponent("api/version"))
                request.setValue(printer.apiKey, forHTTPHeaderField: "X-Api-Key")
            }
            request.timeoutInterval = 5

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                var message: String
                if (200...299).contains(code) {
                    message = "Connected"
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let info = json["result"] as? [String: Any],
                           let state = info["klippy_state"] as? String {
                            message = "Connected — Klipper \(state)"
                        } else if let server = json["server"] as? String {
                            message = "Connected — OctoPrint \(server)"
                        }
                    }
                } else {
                    message = "Failed: HTTP \(code)"
                }
                await MainActor.run { testResults[printer.id] = message }
            } catch {
                await MainActor.run {
                    testResults[printer.id] = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func upload() {
        guard let printer = selected, let base = URL(string: printer.host) else {
            result = "Select a printer"
            return
        }
        isUploading = true
        result = "Uploading…"

        Task {
            do {
                let data = try Data(contentsOf: gcodeURL)
                let filename = gcodeURL.lastPathComponent
                var request: URLRequest
                let boundary = "orcapad-\(UUID().uuidString)"

                var body = Data()
                func addField(_ name: String, _ value: String) {
                    body.append("--\(boundary)\r\n".data(using: .utf8)!)
                    body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
                }
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
                body.append(data)
                body.append("\r\n".data(using: .utf8)!)

                if printer.kind == "moonraker" {
                    request = URLRequest(url: base.appendingPathComponent("server/files/upload"))
                    addField("print", startPrint ? "true" : "false")
                } else {
                    request = URLRequest(url: base.appendingPathComponent("api/files/local"))
                    request.setValue(printer.apiKey, forHTTPHeaderField: "X-Api-Key")
                    addField("select", "true")
                    addField("print", startPrint ? "true" : "false")
                }
                body.append("--\(boundary)--\r\n".data(using: .utf8)!)

                request.httpMethod = "POST"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.httpBody = body

                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    result = (200...299).contains(code)
                        ? "Sent (\(filename))" + (startPrint ? " — printing started" : "")
                        : "Failed: HTTP \(code)"
                    isUploading = false
                }
            } catch {
                await MainActor.run {
                    result = "Failed: \(error.localizedDescription)"
                    isUploading = false
                }
            }
        }
    }
}

/// Add/edit form for one saved printer.
private struct PrinterEditSheet: View {
    @State var printer: SavedPrinter
    let isNew: Bool
    let onSave: (SavedPrinter) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $printer.name)
                    Picker("Type", selection: $printer.kind) {
                        Text("Moonraker (Klipper)").tag("moonraker")
                        Text("OctoPrint").tag("octoprint")
                    }
                    .pickerStyle(.segmented)
                    TextField("http://192.168.0.10:7125", text: $printer.host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if printer.kind == "octoprint" {
                        TextField("API key", text: $printer.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text("For Klipper, enter the Moonraker address (usually port 7125, or the web UI address). The Safari button opens that address in the browser.")
                }

                Section {
                    Button(isNew ? "Add" : "Save") {
                        onSave(printer)
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(printer.host.count < 8 || printer.name.isEmpty)
                }
            }
            .navigationTitle(isNew ? "Add printer" : "Edit Printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
