import SwiftUI
import UniformTypeIdentifiers

/// Desktop-OrcaSlicer style layout: a top bar with the Prepare/Preview tabs
/// and the slice button on the right, a single left sidebar with the preset
/// cards and the parameter tree, and a wide viewport with a floating tool
/// strip — mirroring the desktop arrangement.
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
        case printer = "프린터", filament = "필라멘트", process = "프로세스"
        var id: String { rawValue }
    }
    @State private var activePicker: PickerKind?
    @State private var showImporter = false
    @State private var presetsRevision = 0 // reload token for the embedded editor
    @State private var activeCalibration: CalibrationKind?

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
    @State private var showSidebar = true
    private enum CenterMode { case scene, preview }
    @State private var centerMode: CenterMode = .scene

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                if showSidebar {
                    sidebar
                        .frame(width: 360)
                        .transition(.move(edge: .leading))
                    Divider()
                }
                viewport
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSidebar)
        .background(Color.orcaWindow)
        .task { initializeCore() }
        .task(id: isSlicing) {
            // Poll the core's slicing progress while a slice runs.
            while isSlicing {
                sliceProgress = OrcaSlicerCore.slicingProgress()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            sliceProgress = -1
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
        .sheet(item: $activeCalibration) { kind in
            CalibrationSheet(kind: kind) {
                objects = OrcaSlicerCore.sceneObjects().compactMap { SceneObject(dictionary: $0) }
                selectedObject = objects.first?.index ?? 0
                sceneRevision += 1
                centerMode = .scene
                status = "\(kind.name) 준비됨 — 슬라이스하세요"
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

    // MARK: - Top bar (main tabs + slice actions, like the desktop title bar)

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                showSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }

            Text("OrcaPad")
                .font(.headline)

            Picker("모드", selection: $centerMode) {
                Text("준비").tag(CenterMode.scene)
                Text("프리뷰").tag(CenterMode.preview)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Menu {
                ForEach(CalibrationKind.all) { kind in
                    Button(kind.name) {
                        activeCalibration = kind
                    }
                }
            } label: {
                Label("캘리브레이션", systemImage: "gauge.with.needle")
            }
            .disabled(!isReady || isSlicing)

            Spacer()

            if isSlicing {
                ProgressView(value: Double(max(sliceProgress, 0)), total: 100)
                    .frame(width: 120)
                Text("\(max(sliceProgress, 0))%")
                    .font(.callout.monospacedDigit())
                Button("취소", role: .destructive) {
                    OrcaSlicerCore.cancelSlicing()
                }
            } else {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button {
                    sliceScene()
                } label: {
                    Label("슬라이스", systemImage: "cube.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isReady || objects.isEmpty)

                Menu {
                    Button {
                        showUpload = true
                    } label: {
                        Label("프린터로 전송", systemImage: "paperplane")
                    }
                    if let gcodeURL {
                        ShareLink(item: gcodeURL) {
                            Label("G-code 내보내기", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(gcodeURL == nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orcaPanel)
    }

    // MARK: - Left sidebar (preset cards + parameter tree, desktop order)

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                presetRow(title: "프린터", icon: "printer", value: selectedPrinter, kind: .printer)
                presetRow(title: "필라멘트", icon: "circle.hexagongrid", value: selectedFilament, kind: .filament)
                presetRow(title: "프로세스 (품질)", icon: "gearshape.2", value: selectedProcess, kind: .process)
            }
            .padding(12)

            Divider()

            ConfigEditorPanel(reloadToken: presetsRevision) {
                refreshPresetLists()
            }
        }
        .background(Color.orcaPanel)
    }

    private func presetRow(title: String, icon: String, value: String, kind: PickerKind) -> some View {
        Button {
            activePicker = kind
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value.isEmpty ? "선택 안 됨" : value)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.orcaCard, in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(!isReady || isSlicing)
    }

    // MARK: - Viewport (tool strip top-left, transform controls bottom,
    //         vertical layer slider on the right in preview)

    @ViewBuilder
    private var viewport: some View {
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
                    Text("슬라이스하면 프리뷰가 표시됩니다").foregroundStyle(.secondary)
                }
            }

            // Floating tool strip, like the desktop viewport toolbar.
            if centerMode == .scene {
                VStack(spacing: 14) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    Button {
                        try? OrcaSlicerCore.addTestCubeToScene()
                        reloadScene()
                    } label: {
                        Image(systemName: "plus.square")
                    }
                    Button {
                        try? OrcaSlicerCore.arrangeScene()
                        reloadScene()
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .disabled(objects.isEmpty)
                    Button(role: .destructive) {
                        OrcaSlicerCore.removeSceneObject(at: selectedObject)
                        reloadScene()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(objects.isEmpty)
                }
                .font(.title3)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
                .disabled(!isReady || isSlicing)
            }

            // Scene transform controls at the bottom (desktop keeps these in
            // the object manipulation gizmos; sliders are the touch stand-in).
            if centerMode == .scene {
                VStack {
                    Spacer()
                    if !objects.isEmpty {
                        sceneControls
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.bottom, 12)
                    } else {
                        Text("왼쪽 위 도구로 모델 파일이나 테스트 큐브를 추가하세요")
                            .padding(10)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 16)
                    }
                }
                .frame(maxWidth: 560)
            }

            // Vertical layer slider on the right edge, like the desktop preview.
            if centerMode == .preview, let previewData {
                HStack {
                    Spacer()
                    VStack {
                        Text("\(previewData.layerIndex(for: layerFraction) + 1)")
                            .font(.caption.monospacedDigit())
                        Slider(value: $layerFraction, in: 0.01...1.0)
                            .frame(width: 280)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 44, height: 280)
                        Text("\(previewData.layerCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.trailing, 10)
                }

                VStack {
                    Spacer()
                    Button {
                        showTravels.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showTravels ? "checkmark.square.fill" : "square")
                            Text("이동 경로")
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 14)
                }
            }
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
                                .background(object.index == selectedObject ? Color.orcaAccent : Color.orcaCard)
                                .foregroundStyle(object.index == selectedObject ? .white : .primary)
                                .clipShape(Capsule())
                        }
                    }
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
        presetsRevision += 1 // the embedded editor re-reads current values
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
