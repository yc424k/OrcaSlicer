import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var status = "모델 파일을 선택하거나 테스트 큐브를 슬라이스하세요"
    @State private var isSlicing = false
    @State private var showImporter = false
    @State private var gcodeURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)

                Text(status)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if isSlicing {
                    ProgressView()
                }

                Button {
                    showImporter = true
                } label: {
                    Label("모델 파일 선택 (STL/3MF/OBJ)", systemImage: "folder")
                        .frame(maxWidth: 360)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSlicing)

                Button {
                    sliceTestCube()
                } label: {
                    Label("테스트 큐브 슬라이스", systemImage: "shippingbox")
                        .frame(maxWidth: 360)
                }
                .buttonStyle(.bordered)
                .disabled(isSlicing)

                if let gcodeURL {
                    ShareLink(item: gcodeURL) {
                        Label("G-code 내보내기", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: 360)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
            .padding()
            .navigationTitle("OrcaPad")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("core \(OrcaSlicerCore.coreVersion())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .item]) { result in
            if case let .success(url) = result {
                sliceFile(at: url)
            }
        }
    }

    private func sliceFile(at url: URL) {
        startSlicing(named: url.deletingPathExtension().lastPathComponent) { output in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            // Work on a private copy: the picked URL may point outside the sandbox.
            let input = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: input)
            try FileManager.default.copyItem(at: url, to: input)
            try OrcaSlicerCore.sliceModel(atPath: input.path, toGcodePath: output.path)
        }
    }

    private func sliceTestCube() {
        startSlicing(named: "test_cube") { output in
            try OrcaSlicerCore.sliceTestCube(toGcodePath: output.path)
        }
    }

    private func startSlicing(named name: String, _ work: @escaping (URL) throws -> Void) {
        isSlicing = true
        status = "슬라이싱 중…"
        gcodeURL = nil
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).gcode")
        try? FileManager.default.removeItem(at: output)

        Task.detached(priority: .userInitiated) {
            let started = Date()
            do {
                try work(output)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                await MainActor.run {
                    gcodeURL = output
                    status = "완료 — \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), \(seconds)초"
                    isSlicing = false
                }
            } catch {
                await MainActor.run {
                    status = "실패: \(error.localizedDescription)"
                    isSlicing = false
                }
            }
        }
    }
}
