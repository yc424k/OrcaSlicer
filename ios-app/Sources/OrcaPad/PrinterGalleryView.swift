import SwiftUI

/// A printer the user has added — one entry per model, not per nozzle. The
/// nozzle is switched inside the workspace; this only remembers the last one.
struct MyPrinter: Codable, Identifiable, Equatable {
    var id = UUID()
    var model: String
    var vendor: String
    var nozzle: String

    var catalogModel: PrinterModel? {
        PrinterCatalog.shared.models.first { $0.model == model }
    }

    /// The bundled cover art for this model, if the vendor ships one.
    var coverPath: String? { catalogModel?.coverPath }

    /// Nozzles this model can be used with, for the workspace's nozzle picker.
    var nozzles: [String] { catalogModel?.nozzles ?? [] }

    init(model: String, vendor: String, nozzle: String) {
        self.model = model
        self.vendor = vendor
        self.nozzle = nozzle
    }
}

/// Printer models offered by the bundled vendor profiles.
struct PrinterModel: Identifiable {
    let model: String
    let vendor: String
    let nozzles: [String]
    let coverPath: String?
    var id: String { model }

    /// Nozzle to start with: the 0.4 mm most printers ship with, else the
    /// smallest one the profiles offer.
    var defaultNozzle: String { nozzles.first { $0 == "0.4" } ?? nozzles.first ?? "0.4" }

    init?(dictionary: [String: Any]) {
        guard let model = dictionary["model"] as? String else { return nil }
        self.model = model
        vendor = dictionary["vendor"] as? String ?? ""
        nozzles = dictionary["nozzles"] as? [String] ?? []
        coverPath = dictionary["coverPath"] as? String
    }
}

/// Loaded once from the bridge; the profiles do not change at runtime.
final class PrinterCatalog {
    static let shared = PrinterCatalog()
    private(set) var models: [PrinterModel] = []

    func load() {
        guard models.isEmpty else { return }
        models = OrcaSlicerCore.printerModels().compactMap { PrinterModel(dictionary: $0) }
    }
}

/// UserDefaults-backed list of the printers the user added.
enum MyPrinterStore {
    private static let key = "myPrinters"

    static func load() -> [MyPrinter] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let printers = try? JSONDecoder().decode([MyPrinter].self, from: data) else { return [] }
        return printers
    }

    static func save(_ printers: [MyPrinter]) {
        if let data = try? JSONEncoder().encode(printers) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Cover art card used by both the "my printers" grid and the model picker.
private struct PrinterCard: View {
    let title: String
    let subtitle: String
    let coverPath: String?
    var highlighted = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orcaCard)
                if let coverPath, let image = UIImage(contentsOfFile: coverPath) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                } else {
                    Image(systemName: "printer")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 150)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(highlighted ? Color.orcaAccent : Color.orcaSeparator,
                                  lineWidth: highlighted ? 2 : 1)
            )

            Text(title)
                .font(.callout)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// "My printers": the added printers plus an add tile, in the gallery layout.
struct PrinterGalleryView: View {
    @Binding var printers: [MyPrinter]
    /// `id` of the printer the core is currently set to, so it reads as active.
    var activeID = ""
    /// Called with the printer to work with (also on first pick).
    let onSelect: (MyPrinter) -> Void
    /// Nil on the first run, so the sheet cannot be dismissed without a printer.
    var onClose: (() -> Void)?

    @State private var showPicker = false

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(printers) { printer in
                        Button {
                            onSelect(printer)
                        } label: {
                            PrinterCard(title: printer.model,
                                        subtitle: printer.vendor,
                                        coverPath: printer.coverPath,
                                        highlighted: printer.id.uuidString == activeID)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                printers.removeAll { $0.id == printer.id }
                                MyPrinterStore.save(printers)
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                    }

                    Button {
                        showPicker = true
                    } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.orcaSeparator, style: StrokeStyle(lineWidth: 1, dash: [6]))
                                Image(systemName: "plus")
                                    .font(.system(size: 38))
                                    .foregroundStyle(Color.orcaAccent)
                            }
                            .frame(height: 150)
                            Text("프린터 추가").font(.callout)
                            Text(" ").font(.caption)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.orcaWindow)
            .navigationTitle("내 프린터")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("닫기") { onClose() }
                    }
                }
            }
            .overlay {
                if printers.isEmpty {
                    Text("사용할 프린터를 추가하세요")
                        .foregroundStyle(.secondary)
                        .offset(y: 140)
                }
            }
        }
        // On the very first run, go straight to picking a printer instead of
        // making the user tap through an empty gallery.
        .onAppear { if printers.isEmpty { showPicker = true } }
        .sheet(isPresented: $showPicker) {
            // The first pick is mandatory, so it has nothing to cancel back to.
            PrinterModelPicker(cancellable: !printers.isEmpty) { model in
                // One entry per model — the nozzle is switched in the workspace.
                if let existing = printers.first(where: { $0.model == model.model }) {
                    onSelect(existing)
                    return
                }
                let printer = MyPrinter(model: model.model, vendor: model.vendor,
                                        nozzle: model.defaultNozzle)
                printers.append(printer)
                MyPrinterStore.save(printers)
                onSelect(printer)
            }
        }
    }
}

/// Searchable model gallery. Picking a model adds it right away; the nozzle is
/// chosen later in the workspace, so one model never needs several entries.
private struct PrinterModelPicker: View {
    var cancellable = true
    let onPick: (PrinterModel) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 16)]

    private var filtered: [PrinterModel] {
        let models = PrinterCatalog.shared.models
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.model.localizedCaseInsensitiveContains(query) ||
            $0.vendor.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(filtered) { model in
                        Button {
                            onPick(model)
                            dismiss()
                        } label: {
                            PrinterCard(title: model.model,
                                        subtitle: model.vendor,
                                        coverPath: model.coverPath)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.orcaWindow)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "제조사 또는 모델 검색")
            .navigationTitle("프린터 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if cancellable {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("취소") { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(!cancellable)
        }
    }
}
