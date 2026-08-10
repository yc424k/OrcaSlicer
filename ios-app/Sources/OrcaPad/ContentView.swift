import SwiftUI
import UniformTypeIdentifiers

/// Desktop-OrcaSlicer style layout: a top bar with the Prepare/Preview tabs
/// and the slice button on the right, a single left sidebar with the preset
/// cards and the parameter tree, and a wide viewport with a floating tool
/// strip — mirroring the desktop arrangement.
struct ContentView: View {
    // MARK: Core / preset state
    @State private var status = "Loading profiles…"
    @State private var isSlicing = false
    @State private var isReady = false
    @State private var printers: [String] = []
    @State private var processes: [String] = []
    @State private var filaments: [String] = []
    @State private var selectedPrinter = ""
    @State private var selectedProcess = ""
    @State private var selectedFilament = ""

    private enum PickerKind: String, Identifiable {
        case printer = "Printer", filament = "Filament", process = "Process"
        var id: String { rawValue }
    }
    @State private var activePicker: PickerKind?
    @State private var showImporter = false
    @State private var presetsRevision = 0 // reload token for the embedded editor
    @State private var activeCalibration: CalibrationKind?
    @State private var showCalibrationResult = false
    @State private var myPrinters: [MyPrinter] = []
    @State private var showPrinterGallery = false
    @AppStorage("activePrinterID") private var activePrinterID = ""
    @State private var projectURL: URL?
    @State private var nozzleDiameter = ""
    @State private var bedType = ""
    @State private var bedTypes: [(value: String, label: String)] = []

    // MARK: Scene state
    @State private var objects: [SceneObject] = []
    @State private var selectedObject = 0
    @State private var sceneRevision = 0

    // MARK: Slice / preview state
    @State private var gcodeURL: URL?
    @State private var previewData: ToolpathData?
    @State private var layerFraction = 1.0
    @State private var previewStats: PreviewStatistics?
    @State private var previewMode = PreviewViewMode.lineType
    /// Desktop starts with travels, wipes and retractions off and seams on.
    @State private var hiddenLegendRows: Set<LegendRow.Kind> = [
        .moveType(ToolpathData.travelType), .moveType(ToolpathData.wipeType),
        .moveType(ToolpathData.retractType), .moveType(ToolpathData.unretractType),
    ]
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
    @State private var splashCycleDone = false
    @State private var splashTimerStarted = false

    private var showSplash: Bool { !isReady || !splashCycleDone }

    /// Keeps the splash up until the nozzle has finished one full stack,
    /// timed from the animation's first frame.
    private func startSplashTimer() {
        guard !splashTimerStarted else { return }
        splashTimerStarted = true
        Task {
            try? await Task.sleep(nanoseconds: UInt64(LaunchLoadingView.cycleDuration * 1_000_000_000))
            splashCycleDone = true
        }
    }

    var body: some View {
        ZStack {
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

                    // The desktop keeps its preview legend on the right.
                    if centerMode == .preview, previewData != nil {
                        Divider()
                        PreviewLegendPanel(mode: $previewMode,
                                           hidden: $hiddenLegendRows,
                                           statistics: previewStats,
                                           range: previewRange,
                                           presetSummary: presetSummary)
                            .frame(width: 400)
                            .transition(.move(edge: .trailing))
                    }
                }
            }

            if showSplash {
                LaunchLoadingView(status: status) { startSplashTimer() }
                    .transition(.opacity)
            }
        }
        // First run has no printer yet, so the gallery is the start screen and
        // cannot be dismissed until one is picked.
        .fullScreenCover(isPresented: Binding(
            get: { isReady && !showSplash && (myPrinters.isEmpty || showPrinterGallery) },
            set: { if !$0 { showPrinterGallery = false } }
        )) {
            PrinterGalleryView(printers: $myPrinters, activeID: activePrinterID, onSelect: { printer in
                usePrinter(printer)
                showPrinterGallery = false
            }, onClose: myPrinters.isEmpty ? nil : { showPrinterGallery = false })
        }
        .animation(.easeInOut(duration: 0.2), value: showSidebar)
        .animation(.easeOut(duration: 0.4), value: showSplash)
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
        .sheet(isPresented: $showCalibrationResult) {
            CalibrationResultSheet(
                mode: OrcaSlicerCore.activeCalibrationMode() ?? "",
                label: OrcaSlicerCore.activeCalibration() ?? ""
            ) {
                presetsRevision += 1 // the settings editor shows the new value
            }
        }
        .sheet(item: $activeCalibration) { kind in
            CalibrationSheet(kind: kind) {
                objects = OrcaSlicerCore.sceneObjects().compactMap { SceneObject(dictionary: $0) }
                selectedObject = objects.first?.index ?? 0
                sceneRevision += 1
                centerMode = .scene
                status = "\(kind.name) ready — slice to generate"
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

            Button {
                showPrinterGallery = true
            } label: {
                Image(systemName: "printer.filled.and.paper")
            }
            .disabled(!isReady || isSlicing)

            Picker("Mode", selection: $centerMode) {
                Text("Prepare").tag(CenterMode.scene)
                Text("Preview").tag(CenterMode.preview)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Menu {
                ForEach(CalibrationKind.all) { kind in
                    Button(kind.name) {
                        activeCalibration = kind
                    }
                }
                if OrcaSlicerCore.activeCalibrationMode() != nil {
                    Divider()
                    Button {
                        showCalibrationResult = true
                    } label: {
                        Label("Save result…", systemImage: "checkmark.seal")
                    }
                }
            } label: {
                Label("Calibration", systemImage: "gauge.with.needle")
            }
            .disabled(!isReady || isSlicing)

            Spacer()

            if isSlicing {
                ProgressView(value: Double(max(sliceProgress, 0)), total: 100)
                    .frame(width: 120)
                Text("\(max(sliceProgress, 0))%")
                    .font(.callout.monospacedDigit())
                Button("Cancel", role: .destructive) {
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
                    Label("Slice", systemImage: "cube.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isReady || objects.isEmpty)

                Menu {
                    Button {
                        showUpload = true
                    } label: {
                        Label("Send to printer", systemImage: "paperplane")
                    }
                    .disabled(gcodeURL == nil)

                    if let gcodeURL {
                        ShareLink(item: gcodeURL) {
                            Label("Export G-code", systemImage: "square.and.arrow.up")
                        }
                    }

                    Divider()

                    Button {
                        saveProject()
                    } label: {
                        Label("Save project (3MF)", systemImage: "doc.badge.plus")
                    }
                    .disabled(objects.isEmpty)

                    if let projectURL {
                        ShareLink(item: projectURL) {
                            Label("Export project", systemImage: "square.and.arrow.up.on.square")
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(!isReady)
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
                presetRow(title: "Printer", icon: "printer", value: selectedPrinter, kind: .printer)
                printerDetailRow
                filamentRow
                presetRow(title: "Process (quality)", icon: "gearshape.2", value: selectedProcess, kind: .process)
            }
            .padding(12)

            Divider()

            ConfigEditorPanel(reloadToken: presetsRevision) {
                refreshPresetLists()
            }
        }
        .background(Color.orcaPanel)
    }

    /// Nozzle diameter (from the printer preset) and bed type, like the
    /// desktop's nozzle and plate cards next to the printer.
    private var printerDetailRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(activePrinterNozzles, id: \.self) { nozzle in
                    Button("\(nozzle) mm") { useNozzle(nozzle) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nozzle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(nozzleDiameter.isEmpty ? "—" : "\(nozzleDiameter) mm")
                            .foregroundStyle(.primary)
                        Spacer()
                        if activePrinterNozzles.count > 1 {
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.orcaCard, in: RoundedRectangle(cornerRadius: 10))
            }
            .disabled(!isReady || isSlicing || activePrinterNozzles.count < 2)

            Menu {
                ForEach(Array(bedTypes.enumerated()), id: \.offset) { _, item in
                    Button(item.label) {
                        if OrcaSlicerCore.setProjectValue(item.value, forKey: "curr_bed_type") {
                            bedType = item.value
                        }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(bedTypeLabel)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.orcaCard, in: RoundedRectangle(cornerRadius: 10))
            }
            .disabled(!isReady || isSlicing || bedTypes.isEmpty)
        }
    }

    /// Filament card with the desktop's extruder-number badge.
    private var filamentRow: some View {
        Button {
            activePicker = .filament
        } label: {
            HStack(spacing: 10) {
                Text("1")
                    .font(.caption.weight(.bold))
                    .frame(width: 22, height: 22)
                    .background(Color.orcaAccent.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Filament")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(selectedFilament.isEmpty ? "Not selected" : selectedFilament)
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

    private var bedTypeLabel: String {
        bedTypes.first { $0.value == bedType }?.label ?? bedType
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
                    Text(value.isEmpty ? "Not selected" : value)
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
                        maxLayer: previewData.layerIndex(for: layerFraction),
                        hidden: hiddenLegendRows,
                        mode: previewMode,
                        range: previewRange
                    )
                } else {
                    Text("Slice to see the preview").foregroundStyle(.secondary)
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
                        Text("Use the tools at the top left to add a model or a test cube")
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

            }
        }
    }

    /// Value span the current colour mode maps onto the ramp.
    private var previewRange: ClosedRange<Float>? {
        previewData?.range(for: previewMode)
    }

    /// Preset names for the legend's Summary mode.
    private var presetSummary: [(String, String)] {
        [("Printer", selectedPrinter), ("Nozzle", nozzleDiameter.isEmpty ? "—" : "\(nozzleDiameter) mm"),
         ("Filament", selectedFilament), ("Process", selectedProcess)]
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
                transformSlider("Rotate", value: object.rotationZ, range: 0...360, unit: "°") {
                    apply(rotationZ: $0)
                }
                transformSlider("Scale", value: object.scale * 100, range: 10...300, unit: "%") {
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
            // A 3MF may be a full project (models + settings); open it as one
            // and fall back to plain model import when it carries no config.
            if url.pathExtension.lowercased() == "3mf",
               (try? OrcaSlicerCore.openProject(atPath: input.path)) != nil {
                refreshPresetLists()
                bedSize = OrcaSlicerCore.bedSize()
                reloadScene()
                status = "Opened \(url.lastPathComponent) — \(objects.count) object(s)"
                return
            }
            try OrcaSlicerCore.addModelToScene(atPath: input.path)
            reloadScene()
            status = "Added \(url.lastPathComponent) — \(objects.count) object(s) in the scene"
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }

    private func saveProject() {
        let name = objects.first.map { $0.name.replacingOccurrences(of: ".", with: "_") } ?? "project"
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).3mf")
        try? FileManager.default.removeItem(at: output)
        do {
            try OrcaSlicerCore.saveProject(toPath: output.path)
            projectURL = output
            let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
            status = "Project saved — \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func sliceScene() {
        isSlicing = true
        status = "Slicing…"
        gcodeURL = nil
        previewData = nil
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("scene.gcode")
        try? FileManager.default.removeItem(at: output)

        Task.detached(priority: .userInitiated) {
            do {
                try OrcaSlicerCore.sliceScene(toGcodePath: output.path)
                let toolpaths = OrcaSlicerCore.lastToolpaths().flatMap { ToolpathData(dictionary: $0) }
                let stats = OrcaSlicerCore.lastPrintStatistics().flatMap { PreviewStatistics(dictionary: $0) }
                let summary = Self.sliceSummary(stats: OrcaSlicerCore.lastSliceStats())
                await MainActor.run {
                    gcodeURL = output
                    previewData = toolpaths
                    previewStats = stats
                    layerFraction = 1.0
                    centerMode = toolpaths != nil ? .preview : .scene
                    status = summary
                    isSlicing = false
                }
            } catch {
                await MainActor.run {
                    status = "Failed: \(error.localizedDescription)"
                    isSlicing = false
                }
            }
        }
    }

    /// "23m · 2.1m · 6.3g" style summary of the print estimates.
    /// nonisolated: formatted on the slicing task before hopping to the main actor.
    private nonisolated static func sliceSummary(stats: [String: NSNumber]?) -> String {
        guard let stats else { return "Done" }
        var parts: [String] = []
        if let time = stats["time"]?.doubleValue, time > 0 {
            let hours = Int(time) / 3600
            let minutes = (Int(time) % 3600 + 59) / 60
            parts.append(hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m")
        }
        if let mm = stats["filamentMM"]?.doubleValue, mm > 0 {
            parts.append(String(format: "%.1fm", mm / 1000))
        }
        if let grams = stats["filamentG"]?.doubleValue, grams > 0 {
            parts.append(String(format: "%.1fg", grams))
        }
        return parts.isEmpty ? "Done" : "Done — " + parts.joined(separator: " · ")
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
                    PrinterCatalog.shared.load()
                    myPrinters = MyPrinterStore.load()
                    // Restore last session's preset selections. Read them before
                    // refreshPresetLists(), which writes the core's current
                    // (still default) selection back into the same storage.
                    let (wantPrinter, wantProcess, wantFilament) = (storedPrinter, storedProcess, storedFilament)
                    if !wantPrinter.isEmpty { try? OrcaSlicerCore.selectPrinter(wantPrinter) }
                    if !wantProcess.isEmpty { try? OrcaSlicerCore.selectProcess(wantProcess) }
                    if !wantFilament.isEmpty { try? OrcaSlicerCore.selectFilament(wantFilament) }
                    refreshPresetLists()
                    bedSize = OrcaSlicerCore.bedSize()
                    reloadScene()
                    status = "Ready — \(printers.count) printer profiles"
                    // Test hook: automated UI runs seed this defaults key to
                    // import a model without driving the document picker.
                    if let path = UserDefaults.standard.string(forKey: "debugImportPath"),
                       FileManager.default.fileExists(atPath: path) {
                        importFile(at: URL(fileURLWithPath: path))
                    }
                }
            } catch {
                await MainActor.run {
                    // Presets are optional: slicing still works with defaults.
                    isReady = true
                    status = "Profile load failed (using defaults): \(error.localizedDescription)"
                }
            }
        }
    }

    /// The printer the workspace is currently set to, when it came from the gallery.
    private var activePrinter: MyPrinter? {
        myPrinters.first { $0.id.uuidString == activePrinterID }
    }

    /// Nozzles the active printer's model can be used with.
    private var activePrinterNozzles: [String] { activePrinter?.nozzles ?? [] }

    /// Switches the core to a printer picked from the gallery.
    private func usePrinter(_ printer: MyPrinter) {
        do {
            try OrcaSlicerCore.selectPrinterModel(printer.model, nozzle: printer.nozzle)
            activePrinterID = printer.id.uuidString
            refreshPresetLists()
            bedSize = OrcaSlicerCore.bedSize()
            sceneRevision += 1
            status = "\(printer.model) · \(printer.nozzle) mm nozzle"
        } catch {
            status = "Printer selection failed: \(error.localizedDescription)"
        }
    }

    /// Switches the active printer to another of its model's nozzles, and
    /// remembers it so the printer comes back with the same one next time.
    private func useNozzle(_ nozzle: String) {
        guard var printer = activePrinter, printer.nozzle != nozzle else { return }
        printer.nozzle = nozzle
        do {
            try OrcaSlicerCore.selectPrinterModel(printer.model, nozzle: nozzle)
            if let index = myPrinters.firstIndex(where: { $0.id == printer.id }) {
                myPrinters[index] = printer
                MyPrinterStore.save(myPrinters)
            }
            refreshPresetLists()
            bedSize = OrcaSlicerCore.bedSize()
            sceneRevision += 1
            status = "\(printer.model) · \(nozzle) mm nozzle"
        } catch {
            status = "Nozzle change failed: \(error.localizedDescription)"
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

        // Nozzle comes from the printer preset (first extruder); bed type is a
        // project-level setting.
        nozzleDiameter = (OrcaSlicerCore.configValue(forKey: "nozzle_diameter", tab: "printer") ?? "")
            .components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if let bed = OrcaSlicerCore.projectOption(forKey: "curr_bed_type") {
            bedType = bed["value"] as? String ?? ""
            let values = bed["enumValues"] as? [String] ?? []
            let labels = bed["enumLabels"] as? [String] ?? []
            bedTypes = zip(values, labels).map { ($0, $1) }
        }
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
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
