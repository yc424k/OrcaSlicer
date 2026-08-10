import SwiftUI

/// Startup splash: a nozzle laying down filament, layer by layer, instead of
/// a plain progress bar. Indeterminate — it loops while profiles load.
struct LaunchLoadingView: View {
    let status: String

    private let layerCount = 7
    private let sweepDuration = 0.85

    var body: some View {
        ZStack {
            Color.orcaWindow.ignoresSafeArea()

            VStack(spacing: 28) {
                Text("OrcaPad")
                    .font(.system(size: 40, weight: .bold, design: .rounded))

                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        draw(context: &context, size: size,
                             time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                    .frame(width: 260, height: 130)
                }

                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func draw(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let accent = Color.orcaAccent
        let lineHeight: CGFloat = 9
        let lineGap: CGFloat = 3
        let margin: CGFloat = 24
        let printWidth = size.width - margin * 2

        // Which layer the nozzle is on, and how far through the sweep.
        let total = time / sweepDuration
        let cycle = Int(total) % (layerCount + 2) // +2: brief pause with the full stack
        let phase = CGFloat(total.truncatingRemainder(dividingBy: 1))
        let layer = min(cycle, layerCount - 1)
        let printing = cycle < layerCount

        let bedY = size.height - 14

        // Print bed.
        let bed = CGRect(x: margin - 10, y: bedY, width: printWidth + 20, height: 5)
        context.fill(Path(roundedRect: bed, cornerRadius: 2.5), with: .color(.gray.opacity(0.45)))

        func layerY(_ index: Int) -> CGFloat {
            bedY - lineHeight - CGFloat(index) * (lineHeight + lineGap)
        }

        // Finished layers (slight width taper makes it read as a little pyramid).
        let finished = printing ? layer : layerCount
        for i in 0..<finished {
            let inset = CGFloat(i) * 9
            let rect = CGRect(x: margin + inset, y: layerY(i),
                              width: printWidth - inset * 2, height: lineHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: lineHeight / 2),
                         with: .color(accent.opacity(0.85)))
        }

        guard printing else { return }

        // Current layer: zig-zag sweep, partially extruded.
        let inset = CGFloat(layer) * 9
        let rowX = margin + inset
        let rowWidth = printWidth - inset * 2
        let leftToRight = layer % 2 == 0
        let head = leftToRight ? rowX + rowWidth * phase : rowX + rowWidth * (1 - phase)

        let extruded = leftToRight
            ? CGRect(x: rowX, y: layerY(layer), width: head - rowX, height: lineHeight)
            : CGRect(x: head, y: layerY(layer), width: rowX + rowWidth - head, height: lineHeight)
        context.fill(Path(roundedRect: extruded, cornerRadius: lineHeight / 2),
                     with: .color(accent))

        // Nozzle above the head position: body + tapered tip.
        let tipY = layerY(layer) - 2
        var nozzle = Path()
        nozzle.move(to: CGPoint(x: head - 3, y: tipY))
        nozzle.addLine(to: CGPoint(x: head + 3, y: tipY))
        nozzle.addLine(to: CGPoint(x: head + 8, y: tipY - 12))
        nozzle.addLine(to: CGPoint(x: head - 8, y: tipY - 12))
        nozzle.closeSubpath()
        context.fill(nozzle, with: .color(.gray))

        let body = CGRect(x: head - 8, y: tipY - 34, width: 16, height: 22)
        context.fill(Path(roundedRect: body, cornerRadius: 3), with: .color(.gray.opacity(0.8)))
        // Filament going into the nozzle.
        let filament = CGRect(x: head - 1.5, y: 0, width: 3, height: max(0, tipY - 34))
        context.fill(Path(filament), with: .color(accent.opacity(0.6)))
    }
}
