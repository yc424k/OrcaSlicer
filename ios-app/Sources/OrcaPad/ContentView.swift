import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var status = "프로파일 로딩 중…"
    @State private var isSlicing = false
    @State private var isReady = false
    @State private var showImporter = false
    @State private var gcodeURL: URL?

    @State private var printers: [String] = []
    @State private var processes: [String] = []
    @State private var filaments: [String] = []
    @State private var selectedPrinter = ""
    @State private var selectedProcess = ""
    @State private var selectedFilament = ""

    private enum PickerKind: String, Identifiable {
        case printer = "프린터", process = "프로세스", filament = "필라멘트"
        var id: String { rawValue }
    }
    @State private var activePicker: PickerKind?
    @State private var previewData: ToolpathData?
    @State private var showConfigEditor = false
    @State private var showSceneEditor = false
    @State private var sceneCount = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("설정") {
                    presetRow(title: "프린터", value: selectedPrinter, kind: .printer)
                    presetRow(title: "프로세스 (품질)", value: selectedProcess, kind: .process)
                    presetRow(title: "필라멘트", value: selectedFilament, kind: .filament)

                    Button {
                        showConfigEditor = true
                    } label: {
                        HStack {
                            Label("설정 편집", systemImage: "slider.horizontal.3")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .disabled(!isReady || isSlicing)
                }

                Section("씬 (\(sceneCount)개 오브젝트)") {
                    VStack(spacing: 16) {
                        Button {
                            showImporter = true
                        } label: {
                            Label("모델 파일 추가 (STL/3MF/OBJ)", systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSlicing || !isReady)

                        Button {
                            try? OrcaSlicerCore.addTestCubeToScene()
                            refreshScene()
                        } label: {
                            Label("테스트 큐브 추가", systemImage: "plus.square")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSlicing || !isReady)

                        Button {
                            showSceneEditor = true
                        } label: {
                            Label("씬 편집 (이동·회전·크기·배치)", systemImage: "move.3d")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSlicing || !isReady || sceneCount == 0)
                    }
                    .padding(.vertical, 8)
                }

                Section("슬라이스") {
                    VStack(spacing: 16) {
                        Text(status)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)

                        if isSlicing || !isReady {
                            ProgressView().frame(maxWidth: .infinity)
                        }

                        Button {
                            sliceScene()
                        } label: {
                            Label("씬 슬라이스", systemImage: "cube.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSlicing || !isReady || sceneCount == 0)

                        if let gcodeURL {
                            Button {
                                openPreview()
                            } label: {
                                Label("3D 프리뷰", systemImage: "cube")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            ShareLink(item: gcodeURL) {
                                Label("G-code 내보내기", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("OrcaPad")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("core \(OrcaSlicerCore.coreVersion())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { initializeCore() }
        .fullScreenCover(item: $previewData) { data in
            GcodePreviewView(toolpaths: data)
        }
        .sheet(isPresented: $showConfigEditor) {
            ConfigEditorView()
        }
        .fullScreenCover(isPresented: $showSceneEditor, onDismiss: { refreshScene() }) {
            SceneEditorView()
        }
        .sheet(item: $activePicker) { kind in
            PresetPickerSheet(title: kind.rawValue, items: items(for: kind)) { name in
                select(name, for: kind)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .item]) { result in
            if case let .success(url) = result {
                sliceFile(at: url)
            }
        }
    }

    private func presetRow(title: String, value: String, kind: PickerKind) -> some View {
        Button {
            activePicker = kind
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(value.isEmpty ? "선택 안 됨" : value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .disabled(!isReady || isSlicing)
    }

    private func openPreview() {
        if let dict = OrcaSlicerCore.lastToolpaths(), let data = ToolpathData(dictionary: dict) {
            previewData = data
        } else {
            status = "프리뷰 데이터가 없습니다 — 먼저 슬라이스하세요"
        }
    }

    private func items(for kind: PickerKind) -> [String] {
        switch kind {
        case .printer: return printers
        case .process: return processes
        case .filament: return filaments
        }
    }

    private func select(_ name: String, for kind: PickerKind) {
        switch kind {
        case .printer: try? OrcaSlicerCore.selectPrinter(name)
        case .process: try? OrcaSlicerCore.selectProcess(name)
        case .filament: try? OrcaSlicerCore.selectFilament(name)
        }
        refreshPresetLists()
    }

    // MARK: - Core lifecycle

    private func initializeCore() {
        Task.detached(priority: .userInitiated) {
            let resources = Bundle.main.resourcePath ?? ""
            let data = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OrcaSlicer").path
            do {
                try OrcaSlicerCore.initialize(withResourcesPath: resources, dataPath: data)
                await MainActor.run {
                    isReady = true
                    refreshPresetLists()
                    status = "준비 완료 — 프린터를 선택하고 슬라이스하세요 (\(printers.count)개 프린터 프로파일)"
                }
            } catch {
                await MainActor.run {
                    // Presets are optional: slicing still works with defaults.
                    isReady = true
                    status = "프로파일 로드 실패(기본 설정 사용): \(error.localizedDescription)"
                }
            }
        }
    }

    private func refreshPresetLists() {
        printers = OrcaSlicerCore.printerPresets()
        processes = OrcaSlicerCore.processPresets()
        filaments = OrcaSlicerCore.filamentPresets()
        selectedPrinter = OrcaSlicerCore.selectedPrinter() ?? ""
        selectedProcess = OrcaSlicerCore.selectedProcess() ?? ""
        selectedFilament = OrcaSlicerCore.selectedFilament() ?? ""
    }

    // MARK: - Scene & slicing

    private func refreshScene() {
        sceneCount = OrcaSlicerCore.sceneObjects().count
    }

    private func sliceFile(at url: URL) {
        // Adds the picked file to the scene (slicing stays a separate step).
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: input)
        do {
            try FileManager.default.copyItem(at: url, to: input)
            try OrcaSlicerCore.addModelToScene(atPath: input.path)
            refreshScene()
            status = "\(url.lastPathComponent) 추가됨 — 씬에 \(sceneCount)개 오브젝트"
        } catch {
            status = "가져오기 실패: \(error.localizedDescription)"
        }
    }

    private func sliceScene() {
        startSlicing(named: "scene") { output in
            try OrcaSlicerCore.sliceScene(toGcodePath: output.path)
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

/// Searchable full-screen preset chooser (1000+ entries need search, and a
/// plain sheet List avoids the navigation-link Picker hit-testing quirks).
private struct PresetPickerSheet: View {
    let title: String
    let items: [String]
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [String] {
        query.isEmpty ? items : items.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.self) { name in
                Button {
                    onPick(name)
                    dismiss()
                } label: {
                    Text(name).foregroundStyle(.primary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}
