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
        .init(id: "temp", name: "온도 타워",
              explanation: "블록마다 노즐 온도를 낮춰가며 출력합니다. 가장 품질이 좋은 블록의 온도를 사용하세요. (PLA 기본값)",
              startLabel: "시작 온도 ℃", endLabel: "끝 온도 ℃", stepLabel: "스텝 ℃",
              defaults: (230, 190, 5)),
        .init(id: "volspeed", name: "최대 체적 속도",
              explanation: "속도를 올려가며 압출 한계를 찾습니다. 표면이 갈라지기 시작하는 높이의 속도가 한계값입니다.",
              startLabel: "시작 mm³/s", endLabel: "끝 mm³/s", stepLabel: "스텝 mm³/s",
              defaults: (5, 20, 0.5)),
        .init(id: "pa_tower", name: "Pressure Advance 타워",
              explanation: "높이에 따라 PA 값을 올려가며 출력합니다. 모서리가 가장 깔끔한 높이의 값을 사용하세요.",
              startLabel: "시작 PA", endLabel: "끝 PA", stepLabel: "스텝 PA",
              defaults: (0, 0.1, 0.002)),
        .init(id: "retraction", name: "리트랙션 타워",
              explanation: "높이에 따라 리트랙션 길이를 늘려가며 출력합니다. 스트링이 사라지는 높이의 값을 사용하세요.",
              startLabel: "시작 mm", endLabel: "끝 mm", stepLabel: "스텝 mm",
              defaults: (0, 2, 0.1)),
        .init(id: "vfa", name: "VFA (미세 진동)",
              explanation: "속도를 올려가며 벽면의 미세 진동 무늬(VFA)를 관찰합니다.",
              startLabel: "시작 mm/s", endLabel: "끝 mm/s", stepLabel: "스텝 mm/s",
              defaults: (40, 200, 10)),
        .init(id: "pa_line", name: "PA 라인",
              explanation: "PA 값을 바꿔가며 라인을 출력합니다. 라인이 가장 균일한 값을 사용하세요. (다이렉트 기본값, 보우덴은 0~1 / 0.05)",
              startLabel: "시작 PA", endLabel: "끝 PA", stepLabel: "스텝 PA",
              defaults: (0, 0.08, 0.005)),
        .init(id: "flow_p1", name: "유량 Pass 1",
              explanation: "9개 블록을 서로 다른 유량 보정으로 출력합니다. 윗면이 가장 매끈한 블록의 수치로 필라멘트 유량비를 곱해 보정하세요.",
              startLabel: "", endLabel: "", stepLabel: "", defaults: (0, 0, 1)),
        .init(id: "flow_p2", name: "유량 Pass 2 (미세)",
              explanation: "Pass 1 결과를 반영한 뒤 ±5% 범위에서 미세 조정합니다.",
              startLabel: "", endLabel: "", stepLabel: "", defaults: (0, 0, 1)),
        .init(id: "flow_yolo1", name: "유량 YOLO",
              explanation: "Orca YOLO 방식 유량 캘리브레이션 — 결과 수치를 유량비에 더하면 됩니다.",
              startLabel: "", endLabel: "", stepLabel: "", defaults: (0, 0, 1)),
        .init(id: "flow_yolo2", name: "유량 YOLO (미세)",
              explanation: "YOLO 미세 버전 (±0.035 범위).",
              startLabel: "", endLabel: "", stepLabel: "", defaults: (0, 0, 1)),
        .init(id: "is_freq", name: "인풋 셰이핑 주파수",
              explanation: "높이에 따라 셰이퍼 주파수를 바꿔가며 링잉 타워를 출력합니다. (Klipper/Marlin 입력 셰이핑)",
              startLabel: "시작 Hz", endLabel: "끝 Hz", stepLabel: "스텝",
              defaults: (15, 110, 1)),
        .init(id: "is_damp", name: "인풋 셰이핑 댐핑",
              explanation: "주파수를 고정하고 높이에 따라 댐핑 계수를 바꿔가며 출력합니다.",
              startLabel: "시작", endLabel: "끝", stepLabel: "스텝",
              defaults: (0, 0.4, 1)),
        .init(id: "cornering", name: "코너링 (Jerk/JD)",
              explanation: "높이에 따라 저크(또는 정션 편차)를 바꿔가며 코너 품질을 관찰합니다. 끝 값이 기계 한계로 설정됩니다.",
              startLabel: "시작", endLabel: "끝", stepLabel: "스텝",
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
                    Section("파라미터") {
                        numberField(kind.startLabel, text: $start)
                        numberField(kind.endLabel, text: $end)
                        numberField(kind.stepLabel, text: $step)
                    }
                }
                Section {
                    Button {
                        prepare()
                    } label: {
                        Label("테스트 모델 준비", systemImage: "wand.and.stars")
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
                    Button("닫기") { dismiss() }
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
            message = "숫자를 확인하세요 (스텝은 0보다 커야 합니다)"
            return
        }
        do {
            try OrcaSlicerCore.startCalibration(kind.id, start: s, end: e, step: st)
            onPrepared()
            dismiss()
        } catch {
            message = "준비 실패: \(error.localizedDescription)"
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
