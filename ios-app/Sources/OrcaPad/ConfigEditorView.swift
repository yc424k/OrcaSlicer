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

/// Settings editor laid out like the desktop sidebar: a tab per settings page
/// (Quality / Strength / Speed / …), the page's option groups with their icons
/// and titles, and one row per option in the desktop's order.
struct ConfigEditorPanel: View {
    /// Bump to make the panel re-read values (e.g. after a preset change).
    let reloadToken: Int
    var onPresetSaved: () -> Void = {}

    @State private var tab = "process"
    @State private var page = ""
    @State private var options: [String: ConfigOption] = [:] // by key
    @State private var query = ""
    @State private var revision = 0 // bumped to force rows to resync their buffers
    @State private var showSaveDialog = false
    @State private var presetName = "내 프리셋"

    private let tabs = [("process", "프로세스"), ("filament", "필라멘트"), ("printer", "프린터")]

    private var pages: [SettingsLayout.Page] { SettingsLayout.shared.pages(for: tab) }

    private var currentPage: SettingsLayout.Page? {
        pages.first { $0.title == page } ?? pages.first
    }

    /// Search looks across every page of the tab; otherwise the selected page.
    private var searchResults: [(group: String, icon: String, options: [ConfigOption])] {
        let needle = query.lowercased()
        return pages.flatMap { page in
            page.groups.compactMap { group -> (String, String, [ConfigOption])? in
                let matches = group.keys.compactMap { options[$0] }.filter {
                    $0.label.lowercased().contains(needle) || $0.key.lowercased().contains(needle)
                }
                guard !matches.isEmpty else { return nil }
                return ("\(page.title) › \(group.title)", group.icon, matches)
            }
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("탭", selection: $tab) {
                ForEach(tabs, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.segmented)

            searchField

            if query.isEmpty {
                pageTabs
            }

            List {
                if query.isEmpty {
                    ForEach(currentPage?.groups ?? []) { group in
                        Section {
                            ForEach(group.keys.compactMap { options[$0] }) { option in
                                row(option)
                            }
                        } header: {
                            groupHeader(title: group.title, icon: group.icon)
                        }
                    }
                } else {
                    ForEach(searchResults, id: \.group) { result in
                        Section {
                            ForEach(result.options) { option in
                                row(option)
                            }
                        } header: {
                            groupHeader(title: result.group, icon: result.icon)
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
        .onChange(of: tab) { _ in
            page = SettingsLayout.shared.pages(for: tab).first?.title ?? ""
            reload()
        }
        .onChange(of: reloadToken) { _ in reload() }
        .onAppear {
            if page.isEmpty { page = pages.first?.title ?? "" }
            reload()
        }
    }

    private var searchField: some View {
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
            Button {
                showSaveDialog = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("현재 설정을 프리셋으로 저장")
        }
        .padding(8)
        .background(Color.orcaCard, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Page tabs (Quality / Strength / …), like the desktop's tab row.
    private var pageTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(pages) { item in
                    Button {
                        page = item.title
                    } label: {
                        VStack(spacing: 4) {
                            Text(item.title)
                                .font(.callout.weight(item.title == currentPage?.title ? .semibold : .regular))
                                .foregroundStyle(item.title == currentPage?.title ? Color.primary : .secondary)
                            Rectangle()
                                .fill(item.title == currentPage?.title ? Color.orcaAccent : .clear)
                                .frame(height: 2)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func groupHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            if !icon.isEmpty, UIImage(named: icon) != nil {
                Image(icon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Color.orcaAccent)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Rectangle()
                .fill(Color.orcaSeparator)
                .frame(height: 1)
        }
        .textCase(nil)
        .padding(.top, 4)
    }

    private func row(_ option: ConfigOption) -> some View {
        ConfigOptionRow(option: option, revision: revision) { newValue in
            commit(option: option, newValue: newValue)
        }
        .listRowBackground(Color.clear)
    }

    private func reload() {
        var byKey: [String: ConfigOption] = [:]
        for dictionary in OrcaSlicerCore.configOptions(forTab: tab) {
            if let option = ConfigOption(dictionary: dictionary) {
                byKey[option.key] = option
            }
        }
        options = byKey
        revision += 1
    }

    private func commit(option: ConfigOption, newValue: String) {
        guard newValue != option.value else { return }
        if let normalized = OrcaSlicerCore.setConfigValue(newValue, forKey: option.key, tab: tab) {
            options[option.key]?.value = normalized
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
