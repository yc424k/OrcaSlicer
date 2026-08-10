import SwiftUI
import UniformTypeIdentifiers

/// Desktop-slicer style layout: 3D viewport in the center, a collapsible
/// settings sidebar on the right, and a collapsible slice/results sidebar on
/// the left.
struct ContentView: View {
    // MARK: Core / preset state
    @State private var status = "프로파일 로딩 중…"
    @State private var isSlicing = false
    @State private var isReady = false
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
    @State private var showConfigEditor = false
    @State private var showImporter = false

    // MARK: Scene state
    @State private var objects: [SceneObject] = []
    @State private var selectedObject = 0
    @State private var sceneRevision = 0

    // MARK: Slice / preview state
    @State private var gcodeURL: URL?
    @State private var previewData: ToolpathData?
    @State private var layerFraction = 1.0
    @State private var showTravels = false
    @State private var sliceProgress = -1
    @State private var showUpload = false
    @State private var bedSize = CGSize.zero

    // Restored on the next launch.
    @AppStorage("selectedPrinter") private var storedPrinter = ""
    @AppStorage("selectedProcess") private var storedProcess = ""
    @AppStorage("selectedFilament") private var storedFilament = ""

    // MARK: Layout state
    @State private var showLeftPanel = true
    @State private var showRightPanel = true
    private enum CenterMode { case scene, preview }
    @State private var centerMode: CenterMode = .scene

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if showLeftPanel {
                    leftPanel
                        .frame(width: 300)
                        .transition(.move(edge: .leading))
                    Divider()
                }

                centerViewport
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showRightPanel {
                    Divider()
                    rightPanel
                        .frame(width: 340)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showLeftPanel)
            .animation(.easeInOut(duration: 0.2), value: showRightPanel)
            .navigationTitle("OrcaPad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        showLeftPanel.toggle()
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .disabled(!isReady || isSlicing)
                    Button {
                        try? OrcaSlicerCore.addTestCubeToScene()
                        reloadScene()
                    } label: {
                        Image(systemName: "plus.square")
                    }
                    .disabled(!isReady || isSlicing)
                    Button {
                        try? OrcaSlicerCore.arrangeScene()
                        reloadScene()
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .disabled(!isReady || isSlicing || objects.isEmpty)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Text("core \(OrcaSlicerCore.coreVersion())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        showRightPanel.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                }
            }
        }
        .task { initializeCore() }
        .task(id: isSlicing) {
            // Poll the core's slicing progress while a slice runs.
            while isSlicing {
                sliceProgress = OrcaSlicerCore.slicingProgress()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            sliceProgress = -1
        }
        .sheet(isPresented: $showConfigEditor, onDismiss: { refreshPresetLists() }) {
            ConfigEditorView()
        }
        .sheet(isPresented: $showUpload) {
            if let gcodeURL {
                PrinterUploadView(gcodeURL: gcodeURL)
            }
        }
        .sheet(item: $activePicker) { kind in
            PresetPickerSheet(title: kind.rawValue, items: items(for: kind)) { name in
                select(name, for: kind)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .item]) { result in
            if case let .success(url) = result {
                importFile(at: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openModelURL)) { note in
            if let url = note.object as? URL {
                importFile(at: url)
            }
        }
    }

    // MARK: - Center viewport

    @ViewBuilder
    private var centerViewport: some View {
        ZStack {
            switch centerMode {
            case .scene:
                SceneKitModelView(objects: objects, selected: selectedObject,
                                  bedSize: bedSize, revision: sceneRevision)
            case .preview:
                if let previewData {
                    SceneKitToolpathView(
                        toolpaths: previewData,
                        maxZ: previewData.zForLayerFraction(layerFraction),
                        showTravels: showTravels
                    )
                } else {
                    Text("먼저 슬라이스하세요").foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 10) {
                Spacer()

                if centerMode == .scene {
                    if !objects.isEmpty {
                        sceneControls
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    } else {
                        Text("왼쪽 위 도구로 모델 파일이나 테스트 큐브를 추가하세요")
                            .padding(10)
                            .background(.regularMaterial, in: Capsule())
                    }
                }

                // The slice bar lives at the bottom center of the viewport,
                // like the desktop slicer's slice button.
                HStack(spacing: 12) {
                    if isSlicing {
                        ProgressView(value: Double(max(sliceProgress, 0)), total: 100)
                            .frame(width: 140)
                        Text("\(max(sliceProgress, 0))%")
                            .font(.callout.monospacedDigit())
                        Button(role: .destructive) {
                            OrcaSlicerCore.cancelSlicing()
                        } label: {
                            Text("취소")
                        }
                    } else {
                        if !isReady { ProgressView() }
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button {
                            sliceScene()
                        } label: {
                            Label("씬 슬라이스", systemImage: "cube.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isReady || objects.isEmpty)
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal)
        }
    }

    private var sceneControls: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(objects) { object in
                        Button {
                            selectedObject = object.index
                            sceneRevision += 1
                        } label: {
                            Text("\(object.name) #\(object.index)")
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(object.index == selectedObject ? Color.accentColor : Color(.systemGray5))
                                .foregroundStyle(object.index == selectedObject ? .white : .primary)
                                .clipShape(Capsule())
                        }
                    }
                    Button(role: .destructive) {
                        OrcaSlicerCore.removeSceneObject(at: selectedObject)
                        reloadScene()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .padding(.leading, 6)
                }
            }

            if let object = objects.first(where: { $0.index == selectedObject }) {
                let maxX = Double(bedSize.width > 0 ? bedSize.width : 256)
                let maxY = Double(bedSize.height > 0 ? bedSize.height : 256)
                transformSlider("X", value: object.positionX, range: 0...maxX, unit: "mm") {
                    apply(positionX: $0)
                }
                transformSlider("Y", value: object.positionY, range: 0...maxY, unit: "mm") {
                    apply(positionY: $0)
                }
                transformSlider("회전", value: object.rotationZ, range: 0...360, unit: "°") {
                    apply(rotationZ: $0)
                }
                transformSlider("크기", value: object.scale * 100, range: 10...300, unit: "%") {
                    apply(scale: $0 / 100)
                }
            }
        }
        .frame(maxWidth: 520)
    }

    private func transformSlider(
        _ title: String, value: Double, range: ClosedRange<Double>, unit: String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Text(title).font(.callout).frame(width: 40, alignment: .leading)
            Slider(value: Binding(get: { value }, set: onChange), in: range)
            Text("\(Int(value))\(unit)")
                .font(.callout.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
        }
    }

    // MARK: - Left panel (slice & results)

    private var leftPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("프리뷰")
                    .font(.headline)

                if previewData == nil {
                    Text("슬라이스하면 결과가 여기에 표시됩니다")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if previewData != nil {
                    Picker("보기", selection: $centerMode) {
                        Text("씬").tag(CenterMode.scene)
                        Text("G-code").tag(CenterMode.preview)
                    }
                    .pickerStyle(.segmented)

                    if let previewData {
                        HStack {
                            Text("레이어").font(.callout)
                            Slider(value: $layerFraction, in: 0.01...1.0)
                            Text("\(previewData.layerIndex(for: layerFraction) + 1)/\(previewData.layerCount)")
                                .font(.callout.monospacedDigit())
                        }

                        Button {
                            showTravels.toggle()
                        } label: {
                            HStack {
                                Image(systemName: showTravels ? "checkmark.square.fill" : "square")
                                Text("이동 경로 표시").foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderless)
                    }

                    if gcodeURL != nil {
                        Button {
                            showUpload = true
                        } label: {
                            Label("프린터로 전송", systemImage: "paperplane")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let gcodeURL {
                        ShareLink(item: gcodeURL) {
                            Label("G-code 내보내기", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orcaAccent)
                    }
                }

                Spacer()
            }
            .padding()
        }
        .background(Color.orcaPanel)
    }

    // MARK: - Right panel (settings)

    private var rightPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("설정")
                    .font(.headline)

                presetRow(title: "프린터", value: selectedPrinter, kind: .printer)
                presetRow(title: "프로세스 (품질)", value: selectedProcess, kind: .process)
                presetRow(title: "필라멘트", value: selectedFilament, kind: .filament)

                Divider()

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
                    .padding(10)
                    .background(Color.orcaCard, in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(!isReady || isSlicing)

                Spacer()
            }
            .padding()
        }
        .background(Color.orcaPanel)
    }

    private func presetRow(title: String, value: String, kind: PickerKind) -> some View {
        Button {
            activePicker = kind
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(value.isEmpty ? "선택 안 됨" : value)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .background(Color.orcaCard, in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(!isReady || isSlicing)
    }

    // MARK: - Actions

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
        bedSize = OrcaSlicerCore.bedSize()
        sceneRevision += 1 // bed may have changed with the printer
    }

    private func apply(positionX: Double? = nil, positionY: Double? = nil,
                       rotationZ: Double? = nil, scale: Double? = nil) {
        guard let object = objects.first(where: { $0.index == selectedObject }) else { return }
        OrcaSlicerCore.setSceneObject(
            at: object.index,
            positionX: positionX ?? object.positionX,
            positionY: positionY ?? object.positionY,
            rotationZ: rotationZ ?? object.rotationZ,
            scale: scale ?? object.scale
        )
        reloadScene()
    }

    private func reloadScene() {
        objects = OrcaSlicerCore.sceneObjects().compactMap { SceneObject(dictionary: $0) }
        if !objects.contains(where: { $0.index == selectedObject }) {
            selectedObject = objects.first?.index ?? 0
        }
        sceneRevision += 1
        centerMode = .scene
    }

    private func importFile(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: input)
        do {
            try FileManager.default.copyItem(at: url, to: input)
            try OrcaSlicerCore.addModelToScene(atPath: input.path)
            reloadScene()
            status = "\(url.lastPathComponent) 추가됨 — 씬에 \(objects.count)개 오브젝트"
        } catch {
            status = "가져오기 실패: \(error.localizedDescription)"
        }
    }

    private func sliceScene() {
        isSlicing = true
        status = "슬라이싱 중…"
        gcodeURL = nil
        previewData = nil
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("scene.gcode")
        try? FileManager.default.removeItem(at: output)

        Task.detached(priority: .userInitiated) {
            do {
                try OrcaSlicerCore.sliceScene(toGcodePath: output.path)
                let toolpaths = OrcaSlicerCore.lastToolpaths().flatMap { ToolpathData(dictionary: $0) }
                let summary = Self.sliceSummary(stats: OrcaSlicerCore.lastSliceStats())
                await MainActor.run {
                    gcodeURL = output
                    previewData = toolpaths
                    layerFraction = 1.0
                    centerMode = toolpaths != nil ? .preview : .scene
                    status = summary
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

    /// "23분 · 2.1m · 6.3g" style summary of the print estimates.
    private static func sliceSummary(stats: [String: NSNumber]?) -> String {
        guard let stats else { return "완료" }
        var parts: [String] = []
        if let time = stats["time"]?.doubleValue, time > 0 {
            let hours = Int(time) / 3600
            let minutes = (Int(time) % 3600 + 59) / 60
            parts.append(hours > 0 ? "\(hours)시간 \(minutes)분" : "\(minutes)분")
        }
        if let mm = stats["filamentMM"]?.doubleValue, mm > 0 {
            parts.append(String(format: "%.1fm", mm / 1000))
        }
        if let grams = stats["filamentG"]?.doubleValue, grams > 0 {
            parts.append(String(format: "%.1fg", grams))
        }
        return parts.isEmpty ? "완료" : "완료 — " + parts.joined(separator: " · ")
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
                    // Restore last session's preset selections.
                    if !storedPrinter.isEmpty { try? OrcaSlicerCore.selectPrinter(storedPrinter) }
                    if !storedProcess.isEmpty { try? OrcaSlicerCore.selectProcess(storedProcess) }
                    if !storedFilament.isEmpty { try? OrcaSlicerCore.selectFilament(storedFilament) }
                    refreshPresetLists()
                    bedSize = OrcaSlicerCore.bedSize()
                    reloadScene()
                    status = "준비 완료 — \(printers.count)개 프린터 프로파일"
                    // Test hook: automated UI runs seed this defaults key to
                    // import a model without driving the document picker.
                    if let path = UserDefaults.standard.string(forKey: "debugImportPath"),
                       FileManager.default.fileExists(atPath: path) {
                        do {
                            try OrcaSlicerCore.addModelToScene(atPath: path)
                            reloadScene()
                            status = "가져옴: \((path as NSString).lastPathComponent)"
                        } catch {
                            status = "가져오기 실패: \(error.localizedDescription)"
                        }
                    }
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
        storedPrinter = selectedPrinter
        storedProcess = selectedProcess
        storedFilament = selectedFilament
    }
}

/// Searchable full-screen preset chooser (1000+ entries need search, and a
/// plain sheet List avoids the navigation-link Picker hit-testing quirks).
struct PresetPickerSheet: View {
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
