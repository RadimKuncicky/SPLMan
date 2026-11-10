import SwiftUI

/// Meter bridge drawn behind the measurements. Bars redraw on a timeline of their
/// own, so meter activity does not invalidate the rest of the display.
struct MixerBridgeView: View {
    @ObservedObject var bridge: MixerBridgeModel

    private static let frameInterval: TimeInterval = 1.0 / 30.0

    var body: some View {
        GeometryReader { geometry in
            let layout = MixerBridgeLayout.compute(
                sections: bridge.sections,
                size: geometry.size
            )
            ZStack {
                ZStack {
                    MixerBridgeLabels(layout: layout)
                    if bridge.phase.isConnected {
                        TimelineView(.animation(minimumInterval: Self.frameInterval)) { timeline in
                            MixerBridgeBars(
                                date: timeline.date,
                                layout: layout,
                                levels: bridge.levels
                            )
                        }
                    }
                }
                .opacity(bridge.phase.isConnected ? 0.6 : 0.3)

                if let notice = MixerBridgeNotice.text(for: bridge.phase) {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Explains, on the meter bridge and in Settings, why the bridge cannot show
/// a configured console.
enum MixerBridgeNotice {
    static var noSections: String {
        L10n.text("Není vybrána žádná sekce meter bridge.")
    }

    static var invalidAddress: String {
        L10n.text("Adresa mixpultu není platná. Zadejte IPv4 adresu nebo název v síti, případně s portem (např. 192.168.1.20:10023).")
    }

    static func text(for phase: MixerConnectionController.Phase) -> String? {
        switch phase {
        case .noSectionsSelected: noSections
        case .invalidAddress: invalidAddress
        case .disabled, .connecting, .connected, .waitingToRetry: nil
        }
    }
}

private struct MixerBridgeBars: View {
    /// A new date on every frame makes the canvas read the latest levels.
    let date: Date
    let layout: MixerBridgeLayout
    let levels: MixerLevelStore

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, _ in
            let currentLevels = levels.snapshot()
            var green = Path()
            var yellow = Path()
            var red = Path()
            for section in layout.sections {
                guard let sectionLevels = currentLevels[section.id] else { continue }
                for bar in section.bars where bar.levelIndex < sectionLevels.count {
                    let level = Double(sectionLevels[bar.levelIndex])
                    for segment in MixerMeterScale.segments(levelDB: level) {
                        let rectangle = CGRect(
                            x: bar.frame.minX,
                            y: bar.frame.maxY - bar.frame.height * segment.upper,
                            width: bar.frame.width,
                            height: bar.frame.height * (segment.upper - segment.lower)
                        )
                        switch segment.zone {
                        case .green: green.addRect(rectangle)
                        case .yellow: yellow.addRect(rectangle)
                        case .red: red.addRect(rectangle)
                        }
                    }
                }
            }
            context.fill(green, with: .color(.green))
            context.fill(yellow, with: .color(.yellow))
            context.fill(red, with: .color(.red))
        }
    }
}

/// Everything that changes only with the layout or a strip name.
private struct MixerBridgeLabels: View {
    let layout: MixerBridgeLayout

    var body: some View {
        Canvas(opaque: false) { context, _ in
            for section in layout.sections {
                for bar in section.bars {
                    context.fill(Path(bar.frame), with: .color(Color(white: 0.09)))
                }
                context.draw(
                    Text(verbatim: section.shortTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white),
                    at: CGPoint(x: section.frame.minX, y: section.frame.minY + 1),
                    anchor: .topLeading
                )
                for strip in section.strips {
                    draw(strip, in: context, bottom: section.frame.maxY)
                }
            }
        }
    }

    private func draw(_ strip: MixerBridgeLayout.Strip, in context: GraphicsContext, bottom: CGFloat) {
        // Narrow strips cannot hold every number, so only some are labeled.
        if strip.frame.width >= 13 || strip.number == 1 || strip.number % 5 == 0 {
            context.draw(
                Text(verbatim: "\(strip.number)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundColor(.white),
                at: CGPoint(x: strip.frame.midX, y: bottom),
                anchor: .bottom
            )
        }
        guard !strip.name.isEmpty, strip.frame.width >= 9 else { return }
        var nameContext = context
        nameContext.translateBy(x: strip.frame.midX, y: strip.frame.maxY - 3)
        nameContext.rotate(by: .degrees(-90))
        nameContext.draw(
            Text(verbatim: strip.name)
                .font(.system(size: 9))
                .foregroundColor(.white),
            at: .zero,
            anchor: .leading
        )
    }
}
