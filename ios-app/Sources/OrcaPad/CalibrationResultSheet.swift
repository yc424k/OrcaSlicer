import SwiftUI

/// Where one calibration's measured result gets written.
private struct CalibrationSaveSpec {
    let title: String
    let prompt: String       // what the user should read off the print
    let unit: String
    let tab: String          // config tab of the target keys
    let keys: [String]       // keys receiving the value
    /// Special math (e.g. flow modifiers combine with the current ratio).
    var transform: ((Double, _ current: Double) -> Double)? = nil
    var currentKey: String? = nil // key whose current value feeds the transform

    static func spec(for mode: String) -> CalibrationSaveSpec? {
        switch mode {
        case "temp":
            return .init(title: "Save best nozzle temperature",
                         prompt: "Enter the temperature of the best-looking block",
                         unit: "℃", tab: "filament",
                         keys: ["nozzle_temperature", "nozzle_temperature_initial_layer"])
        case "volspeed":
            return .init(title: "Save max volumetric speed",
                         prompt: "Enter the value just below where the surface breaks down (start + step × height mm)",
                         unit: "mm³/s", tab: "filament",
                         keys: ["filament_max_volumetric_speed"])
        case "pa_tower", "pa_line":
            return .init(title: "Save pressure advance",
                         prompt: "Enter the PA value where corners and lines look cleanest",
                         unit: "", tab: "filament",
                         keys: ["pressure_advance"])
        case "retraction":
            return .init(title: "Save retraction length",
                         prompt: "Enter the value at the height where stringing disappears (start + step × height mm)",
                         unit: "mm", tab: "printer",
                         keys: ["retraction_length"])
        case "flow_p1", "flow_p2":
            return .init(title: "Save flow ratio",
                         prompt: "Enter the number of the smoothest block (-20 to 20) — it is multiplied into the current flow ratio",
                         unit: "", tab: "filament",
                         keys: ["filament_flow_ratio"],
                         transform: { modifier, current in current * (1.0 + modifier / 100.0) },
                         currentKey: "filament_flow_ratio")
        case "flow_yolo1", "flow_yolo2":
            return .init(title: "Save flow ratio (YOLO)",
                         prompt: "Enter the number of the smoothest block — it is added to the current flow ratio",
                         unit: "", tab: "filament",
                         keys: ["filament_flow_ratio"],
                         transform: { modifier, current in current + modifier },
                         currentKey: "filament_flow_ratio")
        default:
            // VFA / input shaping / cornering results go into the printer
            // firmware (e.g. Klipper's printer.cfg), not the slicer profile.
            return nil
        }
    }
}

/// Applies a measured calibration value to the edited preset, with a nudge to
/// save it as a user preset afterwards.
struct CalibrationResultSheet: View {
    let mode: String
    let label: String
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var message = ""
    @State private var applied = false

    private var spec: CalibrationSaveSpec? { CalibrationSaveSpec.spec(for: mode) }

    var body: some View {
        NavigationStack {
            Form {
                if let spec {
                    Section {
                        Text(spec.prompt)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        HStack {
                            Text("Measured value")
                            Spacer()
                            TextField("", text: $value)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 140)
                                .textFieldStyle(.roundedBorder)
                            if !spec.unit.isEmpty {
                                Text(spec.unit).foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            apply(spec)
                        } label: {
                            Label("Apply to settings", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(Double(value) == nil)
                    }
                    if !message.isEmpty {
                        Section {
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(applied ? Color.orcaAccent : .red)
                            if applied {
                                Text("To keep this across restarts, create a user preset with \"Save current settings as preset\" in the settings editor.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Section {
                        Text("The result of this test (\(label)) belongs in the printer firmware, not the slicer settings. On Klipper, edit the input shaper / square corner velocity values in printer.cfg.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(spec?.title ?? "\(label) result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func apply(_ spec: CalibrationSaveSpec) {
        guard let input = Double(value) else { return }
        var final = input
        if let transform = spec.transform {
            var current = 1.0
            if let key = spec.currentKey,
               let raw = OrcaSlicerCore.configValue(forKey: key, tab: spec.tab),
               let parsed = Double(raw.components(separatedBy: ",").first ?? "") {
                current = parsed
            }
            final = transform(input, current)
        }
        var ok = true
        for key in spec.keys {
            if OrcaSlicerCore.setConfigValue(String(final), forKey: key, tab: spec.tab) == nil {
                ok = false
            }
        }
        applied = ok
        message = ok
            ? "Applied — \(spec.keys.joined(separator: ", ")) = \(String(format: "%g", final))"
            : "Could not apply — check the value"
        if ok { onSaved() }
    }
}
