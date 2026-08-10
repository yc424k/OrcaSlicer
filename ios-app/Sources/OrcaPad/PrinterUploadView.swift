import SwiftUI

/// Uploads the sliced G-code to a Moonraker (Klipper) or OctoPrint host over
/// their plain HTTP APIs, optionally starting the print.
struct PrinterUploadView: View {
    let gcodeURL: URL

    @Environment(\.dismiss) private var dismiss

    @AppStorage("printerKind") private var kind = "moonraker"
    @AppStorage("printerHost") private var host = ""
    @AppStorage("printerAPIKey") private var apiKey = ""
    @AppStorage("printerStartPrint") private var startPrint = false

    @State private var isUploading = false
    @State private var result = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("프린터") {
                    Picker("종류", selection: $kind) {
                        Text("Moonraker (Klipper)").tag("moonraker")
                        Text("OctoPrint").tag("octoprint")
                    }
                    .pickerStyle(.segmented)

                    TextField("http://192.168.0.10:7125", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if kind == "octoprint" {
                        TextField("API 키", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Button {
                        startPrint.toggle()
                    } label: {
                        HStack {
                            Image(systemName: startPrint ? "checkmark.square.fill" : "square")
                            Text("업로드 후 바로 출력 시작").foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.borderless)
                }

                Section {
                    Button {
                        upload()
                    } label: {
                        if isUploading {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("G-code 전송", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isUploading || host.isEmpty)

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
        }
    }

    private func upload() {
        guard let base = URL(string: host) else {
            result = "호스트 주소가 올바르지 않습니다"
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

                if kind == "moonraker" {
                    request = URLRequest(url: base.appendingPathComponent("server/files/upload"))
                    addField("print", startPrint ? "true" : "false")
                } else {
                    request = URLRequest(url: base.appendingPathComponent("api/files/local"))
                    request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
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
