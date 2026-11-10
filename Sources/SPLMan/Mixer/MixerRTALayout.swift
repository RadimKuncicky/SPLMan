import CoreGraphics
import Foundation

/// Places the bands of a console's real-time analyzer on a logarithmic
/// frequency axis, between a header line and the frequency labels, on a fixed
/// dB scale. Each band reaches halfway to its neighbours.
struct MixerRTALayout: Equatable {
    struct Band: Equatable {
        /// Index into the analyzer levels.
        var index: Int
        /// The full-height column of the band.
        var frame: CGRect
    }

    struct Tick: Equatable {
        var frequency: Double
        var x: CGFloat
    }

    struct GridLine: Equatable {
        var levelDB: Double
        var y: CGFloat
        var isLabeled: Bool
    }

    static let displayFloorDB = -80.0
    static let displayCeilingDB = 0.0
    /// A band at least this loud is marked as clipping.
    static let clipThresholdDB = -0.1
    static let clipMarkHeight: CGFloat = 2
    static let headerHeight: CGFloat = 16
    static let axisHeight: CGFloat = 26
    /// Room for the dB labels left of the bands.
    static let leadingInset: CGFloat = 30
    static let trailingInset: CGFloat = 4
    static let tickLabelWidth: CGFloat = 44
    private static let gridStepDB = 10.0
    private static let labelStepDB = 20.0
    private static let barGap: CGFloat = 1
    private static let minimumTickSpacing: CGFloat = 52
    private static let preferredFrequencies: [Double] = [
        20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000
    ]

    /// The area of the bands.
    var plot: CGRect
    var lowerFrequency: Double
    var upperFrequency: Double
    var bands: [Band]
    var ticks: [Tick]
    var gridLines: [GridLine]

    /// - Parameter frequencies: Centre frequency of each band in Hz, ascending.
    static func compute(frequencies: [Double], size: CGSize) -> MixerRTALayout {
        let plot = CGRect(
            x: leadingInset,
            y: headerHeight,
            width: max(0, size.width - leadingInset - trailingInset),
            height: max(0, size.height - headerHeight - axisHeight)
        )
        let usable = frequencies.allSatisfy { $0.isFinite && $0 > 0 } ? frequencies : []
        let range = frequencyRange(for: usable)
        var layout = MixerRTALayout(
            plot: plot,
            lowerFrequency: range.lower,
            upperFrequency: range.upper,
            bands: [],
            ticks: [],
            gridLines: []
        )
        guard plot.width > 0, plot.height > 0 else { return layout }
        layout.bands = layout.placeBands(usable)
        layout.ticks = layout.selectTicks()
        layout.gridLines = stride(from: displayFloorDB, through: displayCeilingDB, by: gridStepDB)
            .map { level in
                GridLine(
                    levelDB: level,
                    y: plot.maxY - plot.height * CGFloat(fraction(levelDB: level)),
                    isLabeled: level.truncatingRemainder(dividingBy: labelStepDB) == 0
                )
            }
        return layout
    }

    /// At least 20 Hz to 20 kHz, widened so that the outer bands fit whole.
    static func frequencyRange(for frequencies: [Double]) -> (lower: Double, upper: Double) {
        var lower = 20.0
        var upper = 20_000.0
        let count = frequencies.count
        if count > 1 {
            let first = frequencies[0]
            let last = frequencies[count - 1]
            lower = min(lower, first / max(1, frequencies[1] / first).squareRoot())
            upper = max(upper, last * max(1, last / frequencies[count - 2]).squareRoot())
        } else if let only = frequencies.first {
            lower = min(lower, only)
            upper = max(upper, only)
        }
        return (lower, upper)
    }

    /// Horizontal position of a frequency, nil outside the axis.
    func x(for frequency: Double) -> CGFloat? {
        guard frequency.isFinite, frequency >= lowerFrequency, frequency <= upperFrequency,
              upperFrequency > lowerFrequency else { return nil }
        let position = log(frequency / lowerFrequency) / log(upperFrequency / lowerFrequency)
        return plot.minX + plot.width * CGFloat(position)
    }

    /// Height fraction of a level on the fixed scale.
    static func fraction(levelDB: Double) -> Double {
        MixerMeterScale.fraction(levelDB, minimumDB: displayFloorDB, maximumDB: displayCeilingDB)
    }

    static func isClipped(levelDB: Double) -> Bool {
        levelDB.isFinite && levelDB >= clipThresholdDB
    }

    static func levelLabel(_ levelDB: Double) -> String {
        String(format: "%.0f", levelDB)
    }

    /// Like the spectrogram's frequency axis.
    static func frequencyLabel(_ frequency: Double) -> String {
        if frequency >= 1_000 {
            let kilohertz = frequency / 1_000
            return kilohertz.rounded() == kilohertz
                ? String(format: "%.0f kHz", kilohertz)
                : String(format: "%.1f kHz", kilohertz)
        }
        return String(format: "%.0f Hz", frequency)
    }

    private func placeBands(_ frequencies: [Double]) -> [Band] {
        let centres = frequencies.compactMap { x(for: $0) }
        guard centres.count == frequencies.count, !centres.isEmpty else { return [] }
        let count = centres.count
        var bands: [Band] = []
        bands.reserveCapacity(count)
        for index in 0..<count {
            let centre = centres[index]
            let left: CGFloat
            let right: CGFloat
            if count == 1 {
                left = plot.minX
                right = plot.maxX
            } else {
                left = index > 0
                    ? (centres[index - 1] + centre) / 2
                    : centre - (centres[1] - centre) / 2
                right = index < count - 1
                    ? (centre + centres[index + 1]) / 2
                    : centre + (centre - centres[count - 2]) / 2
            }
            let minX = max(plot.minX, left)
            let maxX = min(plot.maxX, right)
            let pitch = maxX - minX
            guard pitch > 0 else { continue }
            bands.append(Band(
                index: index,
                frame: CGRect(
                    x: minX,
                    y: plot.minY,
                    width: pitch > 2 * Self.barGap ? pitch - Self.barGap : pitch,
                    height: plot.height
                )
            ))
        }
        return bands
    }

    /// The first and last labels always, others only where they do not crowd.
    private func selectTicks() -> [Tick] {
        let positioned = Self.preferredFrequencies.compactMap { frequency in
            x(for: frequency).map { Tick(frequency: frequency, x: $0) }
        }
        guard positioned.count > 2, let last = positioned.last else { return positioned }
        var selected = [positioned[0]]
        for tick in positioned.dropFirst().dropLast() {
            let previous = selected[selected.count - 1].x
            if tick.x - previous >= Self.minimumTickSpacing,
               last.x - tick.x >= Self.minimumTickSpacing {
                selected.append(tick)
            }
        }
        selected.append(last)
        return selected
    }
}
