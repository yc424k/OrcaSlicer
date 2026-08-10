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
            name: "프린터 1",
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
                Section("저장된 프린터") {
                    if printers.isEmpty {
                        Text("저장된 프린터가 없습니다 — 아래에서 추가하세요")
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
                        editing = SavedPrinter(name: "새 프린터", kind: "moonraker", host: "http://")
                        isNew = true
                    } label: {
                        Label("프린터 추가", systemImage: "plus")
                    }
                }

                Section("전송") {
                    Button {
                        startPrint.toggle()
                    } label: {
                        HStack {
                            Image(systemName: startPrint ? "checkmark.square.fill" : "square")
                            Text("업로드 후 바로 출력 시작").foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.borderless)

                    Button {
                        upload()
                    } label: {
                        if isUploading {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label(selected.map { "\($0.name)(으)로 전송" } ?? "G-code 전송",
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
            .navigationTitle("프린터로 전송")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
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
                                .foregroundStyle(test.hasPrefix("연결 성공") ? Color.orcaAccent : Color.red)
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
            testResults[printer.id] = "호스트 주소가 올바르지 않습니다"
            return
        }
        testResults[printer.id] = "테스트 중…"

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
                    message = "연결 성공"
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let info = json["result"] as? [String: Any],
                           let state = info["klippy_state"] as? String {
                            message = "연결 성공 — Klipper \(state)"
                        } else if let server = json["server"] as? String {
                            message = "연결 성공 — OctoPrint \(server)"
                        }
                    }
                } else {
                    message = "실패: HTTP \(code)"
                }
                await MainActor.run { testResults[printer.id] = message }
            } catch {
                await MainActor.run {
                    testResults[printer.id] = "실패: \(error.localizedDescription)"
                }
            }
        }
    }

    private func upload() {
        guard let printer = selected, let base = URL(string: printer.host) else {
            result = "프린터를 선택하세요"
            return
        }
        isUploading = true
        result = "업로드 중…"

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
                        ? "전송 완료 (\(filename))" + (startPrint ? " — 출력 시작됨" : "")
                        : "실패: HTTP \(code)"
                    isUploading = false
                }
            } catch {
                await MainActor.run {
                    result = "실패: \(error.localizedDescription)"
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
                    TextField("이름", text: $printer.name)
                    Picker("종류", selection: $printer.kind) {
                        Text("Moonraker (Klipper)").tag("moonraker")
                        Text("OctoPrint").tag("octoprint")
                    }
                    .pickerStyle(.segmented)
                    TextField("http://192.168.0.10:7125", text: $printer.host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if printer.kind == "octoprint" {
                        TextField("API 키", text: $printer.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text("Klipper는 Moonraker 주소(보통 포트 7125 또는 웹 UI 주소)를 입력하세요. 사파리 버튼은 이 주소를 브라우저에서 엽니다.")
                }

                Section {
                    Button(isNew ? "추가" : "저장") {
                        onSave(printer)
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(printer.host.count < 8 || printer.name.isEmpty)
                }
            }
            .navigationTitle(isNew ? "프린터 추가" : "프린터 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") { dismiss() }
                }
            }
        }
    }
}
