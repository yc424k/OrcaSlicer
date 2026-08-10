import SwiftUI

// MARK: - View modes

/// The desktop preview's colour schemes, in the same order as its dropdown.
enum PreviewViewMode: String, CaseIterable, Identifiable {
    case summary, lineType, filament, speed, actualSpeed, acceleration, jerk
    case layerHeight, lineWidth, flow, actualFlow, layerTime, layerTimeLog
    case fanSpeed, temperature, pressureAdvance

    var id: String { rawValue }

    var label: String {
        switch self {
        case .summary: return "Summary"
        case .lineType: return "Line Type"
        case .filament: return "Filament"
        case .speed: return "Speed"
        case .actualSpeed: return "Actual Speed"
        case .acceleration: return "Acceleration"
        case .jerk: return "Jerk"
        case .layerHeight: return "Layer Height"
        case .lineWidth: return "Line Width"
        case .flow: return "Flow"
        case .actualFlow: return "Actual Flow"
        case .layerTime: return "Layer Time"
        case .layerTimeLog: return "Layer Time (log)"
        case .fanSpeed: return "Fan Speed"
        case .temperature: return "Temperature"
        case .pressureAdvance: return "Pressure Advance"
        }
    }

    /// Unit shown next to the colour scale. Empty for the categorical modes.
    var unit: String {
        switch self {
        case .speed, .actualSpeed, .jerk: return "mm/s"
        case .acceleration: return "mm/s²"
        case .layerHeight, .lineWidth: return "mm"
        case .flow, .actualFlow: return "mm³/s"
        case .layerTime, .layerTimeLog: return "s"
        case .fanSpeed: return "%"
        case .temperature: return "°C"
        default: return ""
        }
    }

    /// Categorical modes colour by role/extruder; the rest map a value onto a ramp.
    var isRange: Bool {
        switch self {
        case .summary, .lineType, .filament: return false
        default: return true
        }
    }

    var isLogarithmic: Bool { self == .layerTimeLog }
}

// MARK: - Palettes (matching the desktop viewer)

enum OrcaPalette {
    /// libvgcode DEFAULT_EXTRUSION_ROLES_COLORS, keyed by ExtrusionRole.
    static func role(_ role: UInt8) -> Color {
        switch role {
        case 1: return rgb(255, 230, 77)   // Inner wall
        case 2: return rgb(255, 125, 56)   // Outer wall
        case 3: return rgb(31, 31, 255)    // Overhang wall
        case 4: return rgb(176, 48, 41)    // Sparse infill
        case 5: return rgb(150, 84, 204)   // Internal solid infill
        case 6: return rgb(240, 64, 64)    // Top surface
        case 7: return rgb(102, 92, 199)   // Bottom surface
        case 8: return rgb(255, 140, 105)  // Ironing
        case 9: return rgb(77, 128, 186)   // Bridge
        case 10: return rgb(77, 128, 186)  // Internal bridge
        case 11: return rgb(255, 255, 255) // Gap infill
        case 12: return rgb(0, 135, 110)   // Skirt
        case 13: return rgb(0, 59, 110)    // Brim
        case 14: return rgb(0, 255, 0)     // Support
        case 15: return rgb(0, 128, 0)     // Support interface
        case 16: return rgb(0, 64, 0)      // Support transition
        case 17: return rgb(179, 227, 171) // Prime tower
        case 18: return rgb(94, 209, 148)  // Custom
        default: return rgb(230, 179, 179)
        }
    }

    /// libvgcode DEFAULT_OPTIONS_COLORS, keyed by EMoveType.
    static func moveType(_ type: UInt8) -> Color {
        switch type {
        case 1: return rgb(205, 34, 214)  // Retract
        case 2: return rgb(73, 173, 207)  // Unretract
        case 3: return rgb(230, 230, 230) // Seam
        case 4: return rgb(193, 190, 99)  // Tool change
        case 5: return rgb(218, 148, 139) // Color change
        case 6: return rgb(82, 240, 131)  // Pause print
        case 7: return rgb(226, 210, 67)  // Custom g-code
        case 8: return rgb(56, 72, 155)   // Travel
        case 9: return rgb(255, 255, 0)   // Wipe
        default: return rgb(128, 128, 128)
        }
    }

    /// libvgcode DEFAULT_RANGES_COLORS — blue through green to red.
    static let range: [SIMD3<Float>] = [
        SIMD3(11, 44, 122), SIMD3(19, 89, 133), SIMD3(28, 136, 145), SIMD3(4, 214, 15),
        SIMD3(170, 242, 0), SIMD3(252, 249, 3), SIMD3(245, 206, 10), SIMD3(227, 136, 32),
        SIMD3(209, 104, 48), SIMD3(194, 82, 60), SIMD3(148, 38, 22),
    ].map { $0 / 255 }

    /// Colour for `value` inside `[low, high]`, interpolated like ColorRange.
    static func rangeColor(_ value: Float, low: Float, high: Float, logarithmic: Bool) -> SIMD3<Float> {
        let maxIndex = range.count - 1
        var t: Float = 0
        if logarithmic {
            if low > 0, high > low, value > 0 {
                t = log(min(max(value, low), high) / low) / log(high / low) * Float(maxIndex)
            }
        } else if high > low {
            t = (min(max(value, low), high) - low) / (high - low) * Float(maxIndex)
        }
        let lowIndex = min(max(Int(t), 0), maxIndex)
        let highIndex = min(lowIndex + 1, maxIndex)
        let f = t - Float(lowIndex)
        return range[lowIndex] * (1 - f) + range[highIndex] * f
    }

    static func swatch(_ rgbColor: SIMD3<Float>) -> Color {
        Color(red: Double(rgbColor.x), green: Double(rgbColor.y), blue: Double(rgbColor.z))
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }
}

// MARK: - Statistics

/// One legend row: either an extrusion role or a non-extruding move type.
struct LegendRow: Identifiable {
    enum Kind: Hashable {
        case role(UInt8)
        case moveType(UInt8)
    }

    let kind: Kind
    let name: String
    let color: Color
    let seconds: Double
    /// Filament used, for extrusion roles.
    let meters: Double
    let grams: Double
    /// Distance travelled and move count, for the non-extruding types.
    let distanceMM: Double
    let count: Int

    var id: Kind { kind }
    var isRole: Bool { if case .role = kind { return true }; return false }
    /// Filament changes have neither a distance nor a length to show.
    var showsUsage: Bool { isRole || count > 0 }
}

/// Decoded `lastPrintStatistics`, shaped for the legend.
struct PreviewStatistics {
    let rows: [LegendRow]
    let totalTime: Double
    let prepareTime: Double
    let totalFilamentMM: Double
    let totalFilamentG: Double
    let modelFilamentMM: Double
    let modelFilamentG: Double
    let cost: Double
    let filamentChanges: Int

    /// Move types the desktop legend lists, in its order.
    private static let listedMoveTypes: [UInt8] = [8, 9, 1, 2, 3]

    private static let moveTypeNames: [UInt8: String] = [
        1: "Retract", 2: "Unretract", 3: "Seams", 8: "Travel", 9: "Wipe",
    ]

    init?(dictionary: [String: Any]) {
        guard let roleEntries = dictionary["roles"] as? [[String: Any]] else { return nil }

        var rows: [LegendRow] = []
        for entry in roleEntries {
            guard let role = entry["role"] as? Int, role != 0 else { continue }
            rows.append(LegendRow(kind: .role(UInt8(role)),
                                  name: entry["name"] as? String ?? "",
                                  color: OrcaPalette.role(UInt8(role)),
                                  seconds: entry["time"] as? Double ?? 0,
                                  meters: entry["meters"] as? Double ?? 0,
                                  grams: entry["grams"] as? Double ?? 0,
                                  distanceMM: 0, count: 0))
        }
        rows.sort { $0.seconds > $1.seconds }

        let moveEntries = dictionary["moveTypes"] as? [[String: Any]] ?? []
        let byType = Dictionary(uniqueKeysWithValues: moveEntries.compactMap { entry -> (UInt8, [String: Any])? in
            guard let type = entry["type"] as? Int else { return nil }
            return (UInt8(type), entry)
        })
        for type in Self.listedMoveTypes {
            guard let entry = byType[type] else { continue }
            rows.append(LegendRow(kind: .moveType(type),
                                  name: Self.moveTypeNames[type] ?? "\(type)",
                                  color: OrcaPalette.moveType(type),
                                  seconds: entry["time"] as? Double ?? 0,
                                  meters: 0, grams: 0,
                                  distanceMM: entry["distance"] as? Double ?? 0,
                                  count: entry["count"] as? Int ?? 0))
        }

        // Filament changes are a count, not a path — shown without a toggle.
        let changes = dictionary["filamentChanges"] as? Int ?? 0
        if changes > 0 {
            rows.append(LegendRow(kind: .moveType(4), name: "Filament changes",
                                  color: OrcaPalette.moveType(4),
                                  seconds: dictionary["toolChangeTime"] as? Double ?? 0,
                                  meters: 0, grams: 0, distanceMM: 0, count: 0))
        }

        self.rows = rows
        totalTime = dictionary["totalTime"] as? Double ?? 0
        prepareTime = dictionary["prepareTime"] as? Double ?? 0
        totalFilamentMM = dictionary["totalFilamentMM"] as? Double ?? 0
        totalFilamentG = dictionary["totalFilamentG"] as? Double ?? 0
        modelFilamentMM = dictionary["modelFilamentMM"] as? Double ?? 0
        modelFilamentG = dictionary["modelFilamentG"] as? Double ?? 0
        cost = dictionary["cost"] as? Double ?? 0
        filamentChanges = changes
    }

    var modelPrintTime: Double { max(0, totalTime - prepareTime) }
}

// MARK: - Formatting

enum PreviewFormat {
    /// Desktop's short form: 1h2m3s, dropping empty leading units.
    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        if h > 0 { return m > 0 ? "\(h)h\(m)m\(s)s" : "\(h)h\(s)s" }
        if m > 0 { return "\(m)m\(s)s" }
        return "\(s)s"
    }

    static func distance(_ mm: Double) -> String {
        abs(mm) < 1000 ? String(format: "%.0fmm", mm) : String(format: "%.2fm", mm / 1000)
    }

    static func count(_ value: Int) -> String {
        value >= 1000 ? String(format: "%.1fK", Double(value) / 1000) : "\(value)"
    }

    /// Trims trailing zeros so a scale reads 20 rather than 20.00.
    static func value(_ value: Float) -> String {
        let magnitude = abs(value)
        if magnitude >= 100 { return String(format: "%.0f", value) }
        if magnitude >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}

// MARK: - Legend panel

/// The desktop preview's right-hand legend: colour scheme picker, per-item
/// breakdown with visibility toggles, and the total estimation block.
struct PreviewLegendPanel: View {
    @Binding var mode: PreviewViewMode
    @Binding var hidden: Set<LegendRow.Kind>
    let statistics: PreviewStatistics?
    let range: ClosedRange<Float>?
    let presetSummary: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Menu {
                ForEach(PreviewViewMode.allCases) { item in
                    Button {
                        mode = item
                    } label: {
                        if item == mode {
                            Label(item.label, systemImage: "checkmark")
                        } else {
                            Text(item.label)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(mode.label).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(10)
                .background(Color.orcaCard, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch mode {
                    case .summary: summarySection
                    case .lineType, .filament: breakdownSection
                    default: rangeSection
                    }
                    totalsSection
                }
                .padding(12)
            }
        }
        .background(Color.orcaPanel)
    }

    // Per-role/per-move table with the eye toggles.
    @ViewBuilder
    private var breakdownSection: some View {
        if let statistics {
            // Fixed numeric columns so the name column keeps whatever is left —
            // "Internal solid infill" needs the room.
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text(mode.label).gridColumnAlignment(.leading)
                    Text("Time").frame(width: 52, alignment: .leading)
                    Text("%").frame(width: 30, alignment: .trailing)
                    Text("Usage").gridCellColumns(2)
                    Color.clear.frame(width: 16)
                }
                .font(.caption2.bold())
                .foregroundStyle(.secondary)

                ForEach(statistics.rows) { row in
                    GridRow {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(row.color)
                                .frame(width: 10, height: 10)
                            Text(row.name)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        Text(PreviewFormat.time(row.seconds))
                            .frame(width: 52, alignment: .leading)
                        Text(percent(row.seconds))
                            .frame(width: 30, alignment: .trailing)
                        Text(primaryUsage(row))
                            .frame(width: 50, alignment: .trailing)
                        Text(secondaryUsage(row))
                            .frame(width: 44, alignment: .trailing)
                        toggle(for: row)
                    }
                    .font(.caption2.monospacedDigit())
                }
            }
        }
    }

    // Colour scale for the value-mapped modes.
    @ViewBuilder
    private var rangeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode.unit.isEmpty ? mode.label : "\(mode.label) (\(mode.unit))")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if let range {
                LinearGradient(colors: OrcaPalette.range.map(OrcaPalette.swatch),
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                HStack {
                    Text(PreviewFormat.value(range.lowerBound))
                    Spacer()
                    Text(PreviewFormat.value((range.lowerBound + range.upperBound) / 2))
                    Spacer()
                    Text(PreviewFormat.value(range.upperBound))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text("이 모드에 표시할 값이 없습니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Travels and markers stay togglable in every mode.
            if let statistics {
                Divider().padding(.vertical, 2)
                ForEach(statistics.rows.filter { !$0.isRole }) { row in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(row.color).frame(width: 11, height: 11)
                        Text(row.name).font(.caption)
                        Spacer()
                        toggle(for: row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(presetSummary.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text(item.0).foregroundStyle(.secondary)
                    Spacer()
                    Text(item.1).multilineTextAlignment(.trailing)
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var totalsSection: some View {
        if let statistics {
            Divider()
            Text("Total estimation").font(.callout.bold())
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                totalRow("Total Filament:",
                         String(format: "%.2f m", statistics.totalFilamentMM / 1000),
                         String(format: "%.2fg", statistics.totalFilamentG))
                totalRow("Model Filament:",
                         String(format: "%.2f m", statistics.modelFilamentMM / 1000),
                         String(format: "%.2fg", statistics.modelFilamentG))
                if statistics.cost > 0 {
                    totalRow("Cost:", String(format: "%.2f", statistics.cost), "")
                }
                totalRow("Prepare time:", PreviewFormat.time(statistics.prepareTime), "")
                totalRow("Model printing time:", PreviewFormat.time(statistics.modelPrintTime), "")
                totalRow("Total time:", PreviewFormat.time(statistics.totalTime), "")
            }
            .font(.caption)
        }
    }

    private func totalRow(_ label: String, _ value: String, _ extra: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
            Text(extra)
        }
    }

    private func toggle(for row: LegendRow) -> some View {
        Button {
            if hidden.contains(row.kind) { hidden.remove(row.kind) } else { hidden.insert(row.kind) }
        } label: {
            Image(systemName: hidden.contains(row.kind) ? "eye.slash" : "eye")
                .font(.caption)
                .foregroundStyle(hidden.contains(row.kind) ? Color.secondary : Color.orcaAccent)
        }
        .buttonStyle(.plain)
        // Filament changes are a count with nothing to draw.
        .opacity(row.kind == .moveType(4) ? 0 : 1)
        .disabled(row.kind == .moveType(4))
    }

    private func percent(_ seconds: Double) -> String {
        guard let total = statistics?.totalTime, total > 0 else { return "" }
        return String(format: "%.1f", seconds / total * 100)
    }

    private func primaryUsage(_ row: LegendRow) -> String {
        if row.isRole { return String(format: "%.2fm", row.meters) }
        return row.count > 0 ? PreviewFormat.distance(row.distanceMM) : "\(statistics?.filamentChanges ?? 0)"
    }

    private func secondaryUsage(_ row: LegendRow) -> String {
        if row.isRole { return String(format: "%.2fg", row.grams) }
        return row.count > 0 ? PreviewFormat.count(row.count) : ""
    }
}
