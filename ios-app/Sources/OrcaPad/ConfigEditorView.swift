import SwiftUI

/// One editable option row decoded from the bridge.
struct ConfigOption: Identifiable {
    let key: String
    let label: String
    let tooltip: String
    let category: String
    let unit: String
    let type: String // "bool" | "enum" | "int" | "number" | "string"
    var value: String
    let presetValue: String
    let enumValues: [String]
    let enumLabels: [String]

    var id: String { key }
    var isModified: Bool { !presetValue.isEmpty && value != presetValue }

    init?(dictionary: [String: Any]) {
        guard let key = dictionary["key"] as? String,
              let label = dictionary["label"] as? String else { return nil }
        self.key = key
        self.label = label
        tooltip = dictionary["tooltip"] as? String ?? ""
        category = dictionary["category"] as? String ?? "Other"
        unit = dictionary["unit"] as? String ?? ""
        type = dictionary["type"] as? String ?? "string"
        value = dictionary["value"] as? String ?? ""
        presetValue = dictionary["presetValue"] as? String ?? ""
        enumValues = dictionary["enumValues"] as? [String] ?? []
        enumLabels = dictionary["enumLabels"] as? [String] ?? []
    }
}

/// Settings editor generated from the PrintConfig option definitions — the
/// same metadata that drives the desktop parameter tabs. Embeddable in a
/// sidebar (no navigation chrome of its own).
struct ConfigEditorPanel: View {
    /// Bump to make the panel re-read values (e.g. after a preset change).
    let reloadToken: Int
    var onPresetSaved: () -> Void = {}

    @State private var tab = "process"
    @State private var options: [ConfigOption] = []
    @State private var query = ""
    @State private var revision = 0 // bumped to force rows to resync their edit buffers
    @State private var showSaveDialog = false
    @State private var presetName = "내 프리셋"

    private let tabs = [("process", "프로세스"), ("filament", "필라멘트"), ("printer", "프린터")]

    private var filtered: [ConfigOption] {
        query.isEmpty ? options : options.filter {
            $0.label.localizedCaseInsensitiveContains(query) || $0.key.localizedCaseInsensitiveContains(query)
        }
    }

    private var categories: [(String, [ConfigOption])] {
        Dictionary(grouping: filtered, by: \.category)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.label < $1.label }) }
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("탭", selection: $tab) {
                ForEach(tabs, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("설정 검색", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color.orcaCard, in: RoundedRectangle(cornerRadius: 8))

            Button {
                showSaveDialog = true
            } label: {
                Label("현재 설정을 프리셋으로 저장", systemImage: "square.and.arrow.down")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            List {
                ForEach(categories, id: \.0) { category, items in
                    Section(category) {
                        ForEach(items) { option in
                            ConfigOptionRow(option: option, revision: revision) { newValue in
                                commit(option: option, newValue: newValue)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .padding([.horizontal, .top], 12)
        .alert("현재 설정을 프리셋으로 저장", isPresented: $showSaveDialog) {
            TextField("프리셋 이름", text: $presetName)
            Button("저장") {
                if OrcaSlicerCore.saveCurrentPreset(as: presetName, tab: tab) {
                    reload()
                    onPresetSaved()
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("사용자 프리셋은 다음 실행에도 유지됩니다")
        }
        .onChange(of: tab) { _ in reload() }
        .onChange(of: reloadToken) { _ in reload() }
        .onAppear { reload() }
    }

    private func reload() {
        options = OrcaSlicerCore.configOptions(forTab: tab).compactMap { ConfigOption(dictionary: $0) }
        revision += 1
    }

    private func commit(option: ConfigOption, newValue: String) {
        guard newValue != option.value else { return }
        if let normalized = OrcaSlicerCore.setConfigValue(newValue, forKey: option.key, tab: tab),
           let idx = options.firstIndex(where: { $0.key == option.key }) {
            options[idx].value = normalized
        } else {
            // Rejected by the core (parse error) — restore the row's buffer.
            reload()
        }
        revision += 1
    }
}

private struct ConfigOptionRow: View {
    let option: ConfigOption
    let revision: Int
    let onCommit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(option.label)
                        .font(.callout)
                    if option.isModified {
                        Circle().fill(.orange).frame(width: 8, height: 8)
                    }
                }
                if !option.tooltip.isEmpty {
                    Text(option.tooltip)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()

            switch option.type {
            case "bool":
                // An explicit button instead of Toggle: the toggle's binding
                // writes were unreliable inside this List on iPadOS 26.
                Button {
                    onCommit(option.value == "1" ? "0" : "1")
                } label: {
                    Image(systemName: option.value == "1" ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(option.value == "1" ? Color.orcaAccent : .secondary)
                }
                .buttonStyle(.borderless)
            case "enum":
                Picker("", selection: Binding(
                    get: { option.value },
                    set: { onCommit($0) }
                )) {
                    ForEach(Array(option.enumValues.enumerated()), id: \.element) { i, value in
                        Text(option.enumLabels[i]).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            default:
                TextField("", text: $text)
                    .focused($focused)
                    .keyboardType(option.type == "string" ? .default : .numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { text = option.value }
                    .onChange(of: option.value) { text = $0 }
                    .onChange(of: revision) { _ in text = option.value }
                    .onSubmit { onCommit(text) }
                    .onChange(of: focused) { if !$0 { onCommit(text) } }
                if !option.unit.isEmpty {
                    Text(option.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
