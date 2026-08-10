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
            return .init(title: "최적 노즐 온도 저장",
                         prompt: "가장 품질이 좋은 블록의 온도를 입력하세요",
                         unit: "℃", tab: "filament",
                         keys: ["nozzle_temperature", "nozzle_temperature_initial_layer"])
        case "volspeed":
            return .init(title: "최대 체적 속도 저장",
                         prompt: "표면이 무너지기 직전 높이의 값(시작 + 스텝×높이mm)을 입력하세요",
                         unit: "mm³/s", tab: "filament",
                         keys: ["filament_max_volumetric_speed"])
        case "pa_tower", "pa_line":
            return .init(title: "Pressure Advance 저장",
                         prompt: "모서리/라인이 가장 깔끔한 지점의 PA 값을 입력하세요",
                         unit: "", tab: "filament",
                         keys: ["pressure_advance"])
        case "retraction":
            return .init(title: "리트랙션 길이 저장",
                         prompt: "스트링이 사라지는 높이의 값(시작 + 스텝×높이mm)을 입력하세요",
                         unit: "mm", tab: "printer",
                         keys: ["retraction_length"])
        case "flow_p1", "flow_p2":
            return .init(title: "유량비 저장",
                         prompt: "가장 매끈한 블록의 숫자(-20~20)를 입력하세요 — 현재 유량비에 곱해 반영합니다",
                         unit: "", tab: "filament",
                         keys: ["filament_flow_ratio"],
                         transform: { modifier, current in current * (1.0 + modifier / 100.0) },
                         currentKey: "filament_flow_ratio")
        case "flow_yolo1", "flow_yolo2":
            return .init(title: "유량비 저장 (YOLO)",
                         prompt: "가장 매끈한 블록의 숫자를 입력하세요 — 현재 유량비에 더해 반영합니다",
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
                            Text("측정값")
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
                            Label("설정에 적용", systemImage: "checkmark.circle")
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
                                Text("재시작 후에도 유지하려면 설정 편집의 \"현재 설정을 프리셋으로 저장\"으로 사용자 프리셋을 만드세요.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Section {
                        Text("이 테스트(\(label))의 결과는 슬라이서 설정이 아니라 프린터 펌웨어에 반영합니다. Klipper라면 printer.cfg의 input shaper / square corner velocity 값을 수정하세요.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(spec?.title ?? "\(label) 결과")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
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
            ? "적용됨 — \(spec.keys.joined(separator: ", ")) = \(String(format: "%g", final))"
            : "적용 실패 — 값을 확인하세요"
        if ok { onSaved() }
    }
}
