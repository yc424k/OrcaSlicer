import SwiftUI

/// One calibration test type, with the same defaults as the desktop dialogs.
struct CalibrationKind: Identifiable {
    let id: String        // bridge mode key
    let name: String
    let explanation: String
    let startLabel: String
    let endLabel: String
    let stepLabel: String
    let defaults: (start: Double, end: Double, step: Double)

    /// Tests without adjustable parameters run with fixed defaults.
    var needsParams: Bool {
        !id.hasPrefix("flow_")
    }

    static let all: [CalibrationKind] = [
        .init(id: "temp", name: "Temperature tower",
              explanation: "Prints a tower, lowering the nozzle temperature block by block. Use the temperature of the best-looking block. (PLA defaults)",
              startLabel: "Start °C", endLabel: "End °C", stepLabel: "Step °C",
              defaults: (230, 190, 5)),
        .init(id: "volspeed", name: "Max volumetric speed",
              explanation: "Ramps the speed up to find the extrusion limit. The height where the surface starts breaking up marks the limit.",
              startLabel: "Start mm³/s", endLabel: "End mm³/s", stepLabel: "Step mm³/s",
              defaults: (5, 20, 0.5)),
        .init(id: "pa_tower", name: "Pressure advance tower",
              explanation: "Raises the PA value with height. Use the value at the height with the cleanest corners.",
              startLabel: "Start PA", endLabel: "End PA", stepLabel: "Step PA",
              defaults: (0, 0.1, 0.002)),
        .init(id: "retraction", name: "Retraction tower",
              explanation: "Increases the retraction length with height. Use the value at the height where stringing disappears.",
              startLabel: "Start mm", endLabel: "End mm", stepLabel: "Step mm",
              defaults: (0, 2, 0.1)),
        .init(id: "vfa", name: "VFA (fine artefacts)",
              explanation: "Ramps the speed up so you can spot vertical fine artefacts on the wall.",
              startLabel: "Start mm/s", endLabel: "End mm/s", stepLabel: "Step mm/s",
              defaults: (40, 200, 10)),
        .init(id: "pa_line", name: "PA line",
              explanation: "Prints lines across a range of PA values. Use the value where the line is most even. (Direct-drive defaults; for bowden try 0–1 / 0.05.)",
              startLabel: "Start PA", endLabel: "End PA", stepLabel: "Step PA",
              defaults: (0, 0.08, 0.005)),
        .init(id: "flow_p1", name: "Flow rate pass 1",
              explanation: "Prints nine blocks at different flow corrections. Multiply the filament flow ratio by the number of the block with the smoothest top.",
              startLabel: "", endLabel: "", stepLabel: "", defaults: (0, 0, 1)),
        .init(id: "flow_p2", name: "Flow rate pass 2 (fine)",
              explanation: "Fine-tunes within ±5% after pass 1 has been applied.",
              startLabel: "", endLabel: "", stepLabel: "", defaults: (0, 0, 1)),
        .init(id: "flow_yolo1", name: "Flow rate YOLO",
              explanation: "Orca's YOLO flow calibration — add the resulting number to the flow ratio.",
              startLabel: "", endLabel: "", stepLabel: "", defaults: (0, 0, 1)),
        .init(id: "flow_yolo2", name: "Flow rate YOLO (fine)",
              explanation: "Fine YOLO variant (±0.035 range).",
              startLabel: "", endLabel: "", stepLabel: "", defaults: (0, 0, 1)),
        .init(id: "is_freq", name: "Input shaping frequency",
              explanation: "Prints a ringing tower, sweeping the shaper frequency with height. (Klipper/Marlin input shaping)",
              startLabel: "Start Hz", endLabel: "End Hz", stepLabel: "Step",
              defaults: (15, 110, 1)),
        .init(id: "is_damp", name: "Input shaping damping",
              explanation: "Holds the frequency and sweeps the damping factor with height.",
              startLabel: "Start", endLabel: "End", stepLabel: "Step",
              defaults: (0, 0.4, 1)),
        .init(id: "cornering", name: "Cornering (jerk/JD)",
              explanation: "Sweeps jerk (or junction deviation) with height so you can judge corner quality. The end value is set as the machine limit.",
              startLabel: "Start", endLabel: "End", stepLabel: "Step",
              defaults: (0, 20, 1)),
    ]
}

/// Parameter sheet for one calibration test; prepares the scene on confirm.
struct CalibrationSheet: View {
    let kind: CalibrationKind
    let onPrepared: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var start = ""
    @State private var end = ""
    @State private var step = ""
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(kind.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if kind.needsParams {
                    Section("Parameters") {
                        numberField(kind.startLabel, text: $start)
                        numberField(kind.endLabel, text: $end)
                        numberField(kind.stepLabel, text: $step)
                    }
                }
                Section {
                    Button {
                        prepare()
                    } label: {
                        Label("Prepare test model", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if !message.isEmpty {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(kind.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                start = Self.format(kind.defaults.start)
                end = Self.format(kind.defaults.end)
                step = Self.format(kind.defaults.step)
            }
        }
    }

    private func numberField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func prepare() {
        guard let s = Double(start), let e = Double(end), let st = Double(step), st > 0 else {
            message = "Check the numbers (step must be greater than 0)"
            return
        }
        do {
            try OrcaSlicerCore.startCalibration(kind.id, start: s, end: e, step: st)
            onPrepared()
            dismiss()
        } catch {
            message = "Preparation failed: \(error.localizedDescription)"
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
