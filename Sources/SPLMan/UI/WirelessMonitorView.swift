import SwiftUI

/// Wireless channels drawn behind the measurements. Bars redraw on a timeline of
/// their own, so meter activity does not invalidate the rest of the display.
struct WirelessMonitorView: View {
    @ObservedObject var monitor: WirelessMonitorModel

    private static let frameInterval: TimeInterval = 1.0 / 15.0

    var body: some View {
        GeometryReader { geometry in
            let layout = WirelessMonitorLayout.compute(
                channels: monitor.channels,
                size: geometry.size
            )
            ZStack {
                WirelessMonitorLabels(layout: layout)
                TimelineView(.animation(minimumInterval: Self.frameInterval)) { timeline in
                    WirelessMonitorBars(
                        date: timeline.date,
                        layout: layout,
                        levels: monitor.levels
                    )
                }
                if monitor.channels.isEmpty {
                    Text(L10n.text("Hledám přijímače…"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .opacity(monitor.channels.contains(where: \.isOnline) ? 0.6 : 0.3)
        }
    }
}

private struct WirelessMonitorBars: View {
    /// A new date on every frame makes the canvas read the latest levels.
    let date: Date
    let layout: WirelessMonitorLayout
    let levels: MixerLevelStore

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, _ in
            let currentLevels = levels.snapshot()
            var green = Path()
            var yellow = Path()
            var red = Path()
            for column in layout.columns {
                guard let values = currentLevels[column.channel.id],
                      values.count > WirelessChannel.rfLevelIndex else { continue }

                let audio = column.audioBar
                let audioLevel = Double(values[WirelessChannel.audioLevelIndex])
                for segment in MixerMeterScale.segments(levelDB: audioLevel) {
                    let rectangle = CGRect(
                        x: audio.minX,
                        y: audio.maxY - audio.height * segment.upper,
                        width: audio.width,
                        height: audio.height * (segment.upper - segment.lower)
                    )
                    switch segment.zone {
                    case .green: green.addRect(rectangle)
                    case .yellow: yellow.addRect(rectangle)
                    case .red: red.addRect(rectangle)
                    }
                }

                let rf = column.rfBar
                let rfLevel = Double(values[WirelessChannel.rfLevelIndex])
                let height: CGFloat = rf.height * WirelessRFScale.fraction(rfLevel)
                guard height > 0 else { continue }
                let rectangle = CGRect(x: rf.minX, y: rf.maxY - height, width: rf.width, height: height)
                switch WirelessRFScale.zone(rfLevel) {
                case .strong: green.addRect(rectangle)
                case .fair: yellow.addRect(rectangle)
                case .weak: red.addRect(rectangle)
                }
            }
            context.fill(green, with: .color(.green))
            context.fill(yellow, with: .color(.yellow))
            context.fill(red, with: .color(.red))
        }
    }
}

/// Everything that changes only with the layout or a channel's status.
private struct WirelessMonitorLabels: View {
    private static let batterySegments = 5
    private static let batterySegmentGap: CGFloat = 1

    let layout: WirelessMonitorLayout

    var body: some View {
        Canvas(opaque: false) { context, _ in
            for column in layout.columns {
                draw(column, in: context)
            }
        }
    }

    private func draw(_ column: WirelessMonitorLayout.Column, in context: GraphicsContext) {
        context.fill(Path(column.audioBar), with: .color(Color(white: 0.09)))
        context.fill(Path(column.rfBar), with: .color(Color(white: 0.09)))

        // A long name is cut at the column instead of running into the next one.
        var clipped = context
        clipped.clip(to: Path(column.frame))
        if column.showsName {
            clipped.draw(
                Text(verbatim: column.channel.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white),
                at: CGPoint(x: column.frame.minX, y: column.frame.minY),
                anchor: .topLeading
            )
        }
        drawBattery(column, in: clipped)

        if column.showsBarLabels {
            for (label, bar) in [("AF", column.audioBar), ("RF", column.rfBar)] {
                clipped.draw(
                    Text(verbatim: label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white),
                    at: CGPoint(x: bar.midX, y: column.frame.maxY),
                    anchor: .bottom
                )
            }
        }
        if !column.channel.isOnline, column.showsName {
            clipped.draw(
                Text(L10n.text("NEDOSTUPNÝ"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.red),
                at: CGPoint(x: column.frame.midX, y: column.audioBar.midY),
                anchor: .center
            )
        }
    }

    private func drawBattery(_ column: WirelessMonitorLayout.Column, in context: GraphicsContext) {
        let area = column.battery
        let gaps = Self.batterySegmentGap * CGFloat(Self.batterySegments - 1)
        let width = max(0, area.width - gaps) / CGFloat(Self.batterySegments)
        let bars = column.channel.batteryBars
        for segment in 0..<Self.batterySegments {
            let rectangle = CGRect(
                x: area.minX + CGFloat(segment) * (width + Self.batterySegmentGap),
                y: area.minY,
                width: width,
                height: area.height
            )
            let isLit = bars.map { segment < $0 } ?? false
            context.fill(
                Path(rectangle),
                with: .color(isLit ? batteryColor(bars: bars ?? 0) : Color(white: 0.2))
            )
        }
        if column.showsBatteryMinutes, let minutes = column.channel.batteryMinutes {
            context.draw(
                Text(verbatim: "\(minutes) min")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.white),
                at: CGPoint(x: column.frame.maxX, y: area.midY),
                anchor: .trailing
            )
        }
    }

    private func batteryColor(bars: Int) -> Color {
        switch bars {
        case ...1: .red
        case 2: .yellow
        default: .green
        }
    }
}
