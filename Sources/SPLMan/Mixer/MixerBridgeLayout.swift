import CoreGraphics
import Foundation

/// Green up to -18 dB, yellow from -18 dB and red from 0 dB.
enum MixerMeterScale {
    enum Zone: Equatable {
        case green
        case yellow
        case red
    }

    struct Segment: Equatable {
        var zone: Zone
        /// Fractions of the bar height, from the bottom.
        var lower: Double
        var upper: Double
    }

    static let minimumDB = -60.0
    static let maximumDB = 6.0
    static let yellowStartDB = -18.0
    static let redStartDB = 0.0
    /// Keeps a level of exactly 0 dB visible as red.
    private static let smallestRedTopDB = 0.75

    static func fraction(_ levelDB: Double) -> Double {
        min(1, max(0, (levelDB - minimumDB) / (maximumDB - minimumDB)))
    }

    static func segments(levelDB: Double) -> [Segment] {
        guard levelDB.isFinite, levelDB > minimumDB else { return [] }
        var segments = [
            Segment(
                zone: .green,
                lower: 0,
                upper: fraction(min(levelDB, yellowStartDB))
            )
        ]
        if levelDB > yellowStartDB {
            segments.append(Segment(
                zone: .yellow,
                lower: fraction(yellowStartDB),
                upper: fraction(min(levelDB, redStartDB))
            ))
        }
        if levelDB >= redStartDB {
            segments.append(Segment(
                zone: .red,
                lower: fraction(redStartDB),
                upper: fraction(max(levelDB, smallestRedTopDB))
            ))
        }
        return segments
    }
}

/// Places sections side by side and separated. When bars would become too narrow
/// in one row, the sections wrap into two rows; a section is never split.
struct MixerBridgeLayout: Equatable {
    struct Bar: Equatable {
        var levelIndex: Int
        var frame: CGRect
    }

    struct Strip: Equatable {
        var number: Int
        var name: String
        /// The area of the strip's bars.
        var frame: CGRect
    }

    struct Section: Equatable {
        var id: String
        var shortTitle: String
        var frame: CGRect
        var strips: [Strip]
        var bars: [Bar]
    }

    static let smallestBarPitchForOneRow: CGFloat = 4
    private static let largestBarPitch: CGFloat = 14
    private static let barGap: CGFloat = 1
    private static let stripGap: CGFloat = 3
    private static let sectionGap: CGFloat = 14
    private static let rowGap: CGFloat = 6
    private static let edgeInset: CGFloat = 4
    private static let headerHeight: CGFloat = 16
    private static let footerHeight: CGFloat = 14

    var rowCount: Int
    var sections: [Section]

    static func compute(sections: [MixerBridgeSection], size: CGSize) -> MixerBridgeLayout {
        let shown = sections.filter { !$0.strips.isEmpty }
        guard !shown.isEmpty, size.width > 0, size.height > 0 else {
            return MixerBridgeLayout(rowCount: 0, sections: [])
        }

        let width = size.width - 2 * edgeInset
        var rows = [shown]
        if shown.count > 1, barPitch(for: shown, width: width) < smallestBarPitchForOneRow {
            rows = bestTwoRows(for: shown, width: width)
        }

        let pitch = min(
            largestBarPitch,
            rows.map { barPitch(for: $0, width: width) }.min() ?? largestBarPitch
        )
        let rowHeight = (size.height - CGFloat(rows.count - 1) * rowGap) / CGFloat(rows.count)
        var placed: [Section] = []
        for (rowIndex, row) in rows.enumerated() {
            let top = CGFloat(rowIndex) * (rowHeight + rowGap)
            var x = edgeInset
            for section in row {
                let result = place(section, x: x, top: top, height: rowHeight, pitch: pitch)
                placed.append(result)
                x = result.frame.maxX + sectionGap
            }
        }
        return MixerBridgeLayout(rowCount: rows.count, sections: placed)
    }

    private static func barPitch(for row: [MixerBridgeSection], width: CGFloat) -> CGFloat {
        let strips = row.reduce(0) { $0 + $1.strips.count }
        let bars = row.reduce(0) { total, section in
            total + section.strips.reduce(0) { $0 + $1.barCount }
        }
        guard bars > 0 else { return largestBarPitch }
        let gaps = CGFloat(strips) * stripGap + CGFloat(row.count - 1) * sectionGap
        return max(0.5, (width - gaps) / CGFloat(bars))
    }

    private static func bestTwoRows(
        for sections: [MixerBridgeSection],
        width: CGFloat
    ) -> [[MixerBridgeSection]] {
        var best = [sections]
        var bestPitch: CGFloat = 0
        for split in 1..<sections.count {
            let first = Array(sections[..<split])
            let second = Array(sections[split...])
            let pitch = min(barPitch(for: first, width: width), barPitch(for: second, width: width))
            if pitch > bestPitch {
                best = [first, second]
                bestPitch = pitch
            }
        }
        return best
    }

    private static func place(
        _ section: MixerBridgeSection,
        x startX: CGFloat,
        top: CGFloat,
        height: CGFloat,
        pitch: CGFloat
    ) -> Section {
        let barTop = top + headerHeight
        let barHeight = max(0, height - headerHeight - footerHeight)
        let barWidth = pitch > 2 * barGap ? pitch - barGap : pitch
        var x = startX
        var levelIndex = 0
        var strips: [Strip] = []
        var bars: [Bar] = []
        for strip in section.strips {
            let stripX = x
            for _ in 0..<strip.barCount {
                bars.append(Bar(
                    levelIndex: levelIndex,
                    frame: CGRect(x: x, y: barTop, width: barWidth, height: barHeight)
                ))
                levelIndex += 1
                x += pitch
            }
            strips.append(Strip(
                number: strip.number,
                name: strip.name,
                frame: CGRect(x: stripX, y: barTop, width: x - stripX, height: barHeight)
            ))
            x += stripGap
        }
        return Section(
            id: section.id,
            shortTitle: section.shortTitle,
            frame: CGRect(x: startX, y: top, width: x - stripGap - startX, height: height),
            strips: strips,
            bars: bars
        )
    }
}
