import SwiftUI

/// The console's real-time analyzer drawn behind the measurements, as bars on a
/// logarithmic frequency axis. Bars redraw on a timeline of their own, so the
/// analyzer does not invalidate the rest of the display.
struct MixerRTAView: View {
    @ObservedObject var bridge: MixerBridgeModel
    /// Centre frequency of each band of the configured console.
    let bandFrequencies: [Double]

    private static let frameInterval: TimeInterval = 1.0 / 30.0

    var body: some View {
        let header = MixerRTAText.header(for: bridge.rtaInfo)
        let notice = MixerRTAText.notice(
            for: bridge.phase,
            target: bridge.target,
            info: bridge.rtaInfo,
            isRTAMissing: bridge.isRTAMissing
        )
        GeometryReader { geometry in
            let layout = MixerRTALayout.compute(
                frequencies: bandFrequencies,
                size: geometry.size
            )
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    MixerRTABackground(layout: layout)
                    if bridge.phase.isConnected {
                        TimelineView(.animation(minimumInterval: Self.frameInterval)) { timeline in
                            MixerRTABars(
                                date: timeline.date,
                                layout: layout,
                                levels: bridge.levels
                            )
                        }
                    }
                    if let header {
                        Text(verbatim: header)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(height: MixerRTALayout.headerHeight)
                            .padding(.leading, layout.plot.minX)
                    }
                }
                .opacity(bridge.phase.isConnected ? 0.6 : 0.3)

                if let notice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // The bars cannot be read out; the header and notice can.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MixerRTAText.accessibilityLabel(header: header, notice: notice))
    }
}

/// Texts of the analyzer display.
enum MixerRTAText {
    static var noData: String {
        L10n.text("Mixpult neposílá data RTA. Zkontrolujte nastavení RTA na pultu.")
    }

    static var noSource: String {
        L10n.text("Na pultu není vybrán zdroj RTA.")
    }

    /// The analyzer settings the console reports, omitting the unknown ones;
    /// nil when none is known.
    static func header(for info: MixerRTAInfo?) -> String? {
        guard let info else { return nil }
        var parts: [String] = []
        if info.sourceIsNone {
            parts.append(L10n.format("Zdroj: %@", L10n.text("žádný")))
        } else if let source = info.source, !source.isEmpty {
            parts.append(L10n.format("Zdroj: %@", source))
        }
        if let tap = info.tap, !tap.isEmpty {
            parts.append(tap)
        }
        if let detector = info.detector, !detector.isEmpty {
            parts.append(detector)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func accessibilityLabel(header: String?, notice: String?) -> String {
        let details = [header, notice].compactMap { $0 }.joined(separator: ", ")
        return details.isEmpty
            ? AnalysisDisplayMode.rta.title
            : L10n.format("Analyzátor RTA, %@", details)
    }

    static func notice(
        for phase: MixerConnectionController.Phase,
        target: PreferredMixer?,
        info: MixerRTAInfo?,
        isRTAMissing: Bool
    ) -> String? {
        switch phase {
        case .connected:
            if info?.sourceIsNone == true { return noSource }
            return isRTAMissing ? noData : nil
        case .noSectionsSelected:
            // The analyzer keeps the connection without sections; this phase
            // lasts only until the connection learns that it is wanted.
            return nil
        case .disabled, .invalidAddress, .connecting, .waitingToRetry:
            return MixerBridgeNotice.text(for: phase, target: target)
        }
    }
}

private struct MixerRTABars: View {
    /// A new date on every frame makes the canvas read the latest levels.
    let date: Date
    let layout: MixerRTALayout
    let levels: MixerLevelStore

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, _ in
            let currentLevels = levels.rtaSnapshot()
            var bars = Path()
            var clips = Path()
            for band in layout.bands where band.index < currentLevels.count {
                let level = Double(currentLevels[band.index])
                let frame = band.frame
                let height = frame.height * CGFloat(MixerRTALayout.fraction(levelDB: level))
                if height > 0 {
                    bars.addRect(CGRect(
                        x: frame.minX,
                        y: frame.maxY - height,
                        width: frame.width,
                        height: height
                    ))
                }
                if MixerRTALayout.isClipped(levelDB: level) {
                    clips.addRect(CGRect(
                        x: frame.minX,
                        y: frame.minY,
                        width: frame.width,
                        height: min(MixerRTALayout.clipMarkHeight, frame.height)
                    ))
                }
            }
            // One muted blue, so the analyzer stays in the background under the
            // SPL readings; clipping is only a lighter blue.
            context.fill(bars, with: .color(Color(red: 0.12, green: 0.36, blue: 0.85)))
            context.fill(clips, with: .color(Color(red: 0.55, green: 0.78, blue: 1)))
        }
    }
}

/// Everything that changes only with the layout: band columns, the dB grid and
/// the frequency axis.
private struct MixerRTABackground: View {
    let layout: MixerRTALayout

    var body: some View {
        Canvas(opaque: false) { context, size in
            let plot = layout.plot
            for band in layout.bands {
                context.fill(Path(band.frame), with: .color(Color(white: 0.09)))
            }

            var grid = Path()
            for line in layout.gridLines {
                grid.move(to: CGPoint(x: plot.minX, y: line.y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: line.y))
            }
            context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)
            for line in layout.gridLines where line.isLabeled {
                context.draw(
                    Text(verbatim: MixerRTALayout.levelLabel(line.levelDB))
                        .font(.system(size: 9, weight: .regular, design: .rounded).monospacedDigit())
                        .foregroundColor(.white.opacity(0.72)),
                    at: CGPoint(x: plot.minX - 4, y: line.y),
                    anchor: .trailing
                )
            }

            let axisTop = plot.maxY
            context.fill(
                Path(CGRect(x: 0, y: axisTop, width: size.width, height: MixerRTALayout.axisHeight)),
                with: .color(.black.opacity(0.28))
            )
            var axis = Path()
            axis.move(to: CGPoint(x: plot.minX, y: axisTop + 0.5))
            axis.addLine(to: CGPoint(x: plot.maxX, y: axisTop + 0.5))
            for tick in layout.ticks {
                axis.move(to: CGPoint(x: tick.x, y: axisTop))
                axis.addLine(to: CGPoint(x: tick.x, y: axisTop + 5))
            }
            context.stroke(axis, with: .color(.white.opacity(0.32)), lineWidth: 0.5)

            let halfLabel = MixerRTALayout.tickLabelWidth / 2
            for tick in layout.ticks {
                context.draw(
                    Text(verbatim: MixerRTALayout.frequencyLabel(tick.frequency))
                        .font(.system(size: 9, weight: .regular, design: .rounded).monospacedDigit())
                        .foregroundColor(.white.opacity(0.72)),
                    at: CGPoint(
                        x: min(max(tick.x, halfLabel), max(halfLabel, size.width - halfLabel)),
                        y: axisTop + 14
                    ),
                    anchor: .center
                )
            }
        }
    }
}
