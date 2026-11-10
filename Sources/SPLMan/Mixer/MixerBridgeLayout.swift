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
        fraction(levelDB, minimumDB: minimumDB, maximumDB: maximumDB)
    }

    /// The fraction of a scale from `minimumDB` to `maximumDB`.
    static func fraction(_ levelDB: Double, minimumDB: Double, maximumDB: Double) -> Double {
        min(1, max(0, (levelDB - minimumDB) / (maximumDB - minimumDB)))
    }

    /// The zone a level falls in, consistent with `segments`.
    static func zone(levelDB: Double) -> Zone {
        if levelDB >= redStartDB { return .red }
        if levelDB > yellowStartDB { return .yellow }
        return .green
    }

    static func segments(levelDB: Double) -> [Segment] {
        segments(levelDB: levelDB, minimumDB: minimumDB, maximumDB: maximumDB)
    }

    /// The same zones on another scale, such as the console analyzer's.
    static func segments(levelDB: Double, minimumDB: Double, maximumDB: Double) -> [Segment] {
        func position(_ level: Double) -> Double {
            fraction(level, minimumDB: minimumDB, maximumDB: maximumDB)
        }
        guard levelDB.isFinite, levelDB > minimumDB else { return [] }
        var segments = [
            Segment(
                zone: .green,
                lower: 0,
                upper: position(min(levelDB, yellowStartDB))
            )
        ]
        if levelDB > yellowStartDB {
            segments.append(Segment(
                zone: .yellow,
                lower: position(yellowStartDB),
                upper: position(min(levelDB, redStartDB))
            ))
        }
        if levelDB >= redStartDB {
            segments.append(Segment(
                zone: .red,
                lower: position(redStartDB),
                upper: position(max(levelDB, smallestRedTopDB))
            ))
        }
        return segments
    }
}

/// Places sections side by side and separated. When bars would become too narrow
/// in one row, the sections wrap into as many rows as the height allows; a
/// section is never split. When even that is not enough, gaps and then bars
/// shrink, so that every bar stays on the display.
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

    /// Another row is added while bars would be narrower than this.
    static let smallestBarPitchForOneRow: CGFloat = 4
    private static let largestBarPitch: CGFloat = 14
    /// Gaps shrink before bars become narrower than this.
    private static let smallestBarPitch: CGFloat = 0.5
    /// A row is added only when every row keeps bars at least this tall.
    private static let smallestBarHeight: CGFloat = 24
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

        let width = max(0, size.width - 2 * edgeInset)
        let smallestRowHeight = headerHeight + footerHeight + smallestBarHeight
        let fittingRows = ((size.height + rowGap) / (smallestRowHeight + rowGap)).rounded(.down)
        let largestRowCount = Int(max(1, min(CGFloat(shown.count), fittingRows)))

        var partition = bestRows(for: shown, rowCount: 1, width: width)
        if partition.pitch < smallestBarPitchForOneRow, largestRowCount > 1 {
            for rowCount in 2...largestRowCount {
                partition = bestRows(for: shown, rowCount: rowCount, width: width)
                if partition.pitch >= smallestBarPitchForOneRow { break }
            }
        }

        let rows = partition.rows
        let pitch = min(largestBarPitch, partition.pitch)
        let rowHeight = (size.height - CGFloat(rows.count - 1) * rowGap) / CGFloat(rows.count)
        var placed: [Section] = []
        for (rowIndex, row) in rows.enumerated() {
            let top = CGFloat(rowIndex) * (rowHeight + rowGap)
            let rowSpacing = spacing(for: row, width: width, pitch: pitch)
            var x = edgeInset
            for section in row {
                let result = place(section, x: x, top: top, height: rowHeight, spacing: rowSpacing)
                placed.append(result)
                x = result.frame.maxX + rowSpacing.sectionGap
            }
        }
        return MixerBridgeLayout(rowCount: rows.count, sections: placed)
    }

    private struct Spacing {
        var pitch: CGFloat
        var stripGap: CGFloat
        var sectionGap: CGFloat
    }

    private static func barCount(_ section: MixerBridgeSection) -> Int {
        section.strips.reduce(0) { $0 + $1.barCount }
    }

    /// Width of the full-size gaps between the strips and sections of a row.
    private static func gapWidth(strips: Int, sections: Int) -> CGFloat {
        CGFloat(strips - sections) * stripGap + CGFloat(sections - 1) * sectionGap
    }

    /// The bar pitch at which a row exactly fills the width; negative when its
    /// gaps alone are wider.
    private static func fittingPitch(
        bars: Int,
        strips: Int,
        sections: Int,
        width: CGFloat
    ) -> CGFloat {
        guard bars > 0 else { return .infinity }
        return (width - gapWidth(strips: strips, sections: sections)) / CGFloat(bars)
    }

    /// Splits the sections, in order, into `rowCount` rows so that the narrowest
    /// fitting pitch of any row is as wide as possible.
    private static func bestRows(
        for sections: [MixerBridgeSection],
        rowCount: Int,
        width: CGFloat
    ) -> (rows: [[MixerBridgeSection]], pitch: CGFloat) {
        let count = sections.count
        var bars = [0]
        var strips = [0]
        for section in sections {
            bars.append(bars[bars.count - 1] + barCount(section))
            strips.append(strips[strips.count - 1] + section.strips.count)
        }
        func pitch(from start: Int, to end: Int) -> CGFloat {
            fittingPitch(
                bars: bars[end] - bars[start],
                strips: strips[end] - strips[start],
                sections: end - start,
                width: width
            )
        }

        // best[rows][end] is the widest narrowest pitch of the first `end`
        // sections in `rows` rows, and split[rows][end] where the last row starts.
        var best = Array(
            repeating: Array(repeating: -CGFloat.infinity, count: count + 1),
            count: rowCount + 1
        )
        var split = Array(repeating: Array(repeating: 0, count: count + 1), count: rowCount + 1)
        best[0][0] = .infinity
        for usedRows in 1...rowCount {
            for end in usedRows...count {
                for start in (usedRows - 1)..<end where best[usedRows - 1][start] > -.infinity {
                    let candidate = min(best[usedRows - 1][start], pitch(from: start, to: end))
                    if candidate > best[usedRows][end] {
                        best[usedRows][end] = candidate
                        split[usedRows][end] = start
                    }
                }
            }
        }

        var rows: [[MixerBridgeSection]] = []
        var end = count
        for usedRows in stride(from: rowCount, through: 1, by: -1) {
            let start = split[usedRows][end]
            rows.insert(Array(sections[start..<end]), at: 0)
            end = start
        }
        return (rows, best[rowCount][count])
    }

    /// Full gaps at `pitch` when it is wide enough. Otherwise bars keep the
    /// smallest pitch while the gaps shrink, and only a row whose bars alone do
    /// not fit makes its bars narrower too.
    private static func spacing(
        for row: [MixerBridgeSection],
        width: CGFloat,
        pitch: CGFloat
    ) -> Spacing {
        guard pitch < smallestBarPitch else {
            return Spacing(pitch: pitch, stripGap: stripGap, sectionGap: sectionGap)
        }
        let bars = row.reduce(0) { $0 + barCount($1) }
        let strips = row.reduce(0) { $0 + $1.strips.count }
        let gaps = gapWidth(strips: strips, sections: row.count)
        let barsWidth = CGFloat(bars) * smallestBarPitch
        if barsWidth + gaps <= width {
            return Spacing(pitch: smallestBarPitch, stripGap: stripGap, sectionGap: sectionGap)
        }
        if barsWidth < width, gaps > 0 {
            let scale = (width - barsWidth) / gaps
            return Spacing(
                pitch: smallestBarPitch,
                stripGap: stripGap * scale,
                sectionGap: sectionGap * scale
            )
        }
        return Spacing(
            pitch: bars > 0 ? width / CGFloat(bars) : smallestBarPitch,
            stripGap: 0,
            sectionGap: 0
        )
    }

    private static func place(
        _ section: MixerBridgeSection,
        x startX: CGFloat,
        top: CGFloat,
        height: CGFloat,
        spacing: Spacing
    ) -> Section {
        let pitch = spacing.pitch
        let stripGap = spacing.stripGap
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
