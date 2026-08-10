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
                Section("파라미터") {
                    numberField(kind.startLabel, text: $start)
                    numberField(kind.endLabel, text: $end)
                    numberField(kind.stepLabel, text: $step)
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
