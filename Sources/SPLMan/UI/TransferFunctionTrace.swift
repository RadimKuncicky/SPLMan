import SwiftUI

struct TransferFunctionTrace: View {
    // Overlap normal analysis updates so the live trace does not pause between curves.
    private static let transitionDuration: TimeInterval = 0.45
    private static let traceColor = Color(red: 0.16, green: 0.82, blue: 1)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let points: [TransferFunctionPoint]
    let frequencyScale: SpectrogramFrequencyScale
    let displayLowerDB: Double
    let displayUpperDB: Double

    var body: some View {
        GeometryReader { geometry in
            if let data = TransferFunctionTraceData(
                points: points,
                frequencyScale: frequencyScale,
                displayLowerDB: displayLowerDB,
                displayUpperDB: displayUpperDB
            ) {
                let graphHeight = max(1, geometry.size.height - 26)
                TransferFunctionTraceShape(
                    positions: data.positions
                )
                .stroke(
                    LinearGradient(
                        stops: data.opacityStops.map {
                            Gradient.Stop(
                                color: Self.traceColor.opacity($0.opacity),
                                location: $0.location
                            )
                        },
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 3, lineJoin: .round)
                )
                .frame(width: geometry.size.width, height: graphHeight)
                .clipped()
                .animation(
                    reduceMotion ? nil : .linear(duration: Self.transitionDuration),
                    value: data.positions
                )
                .id(data.topology)
                .transition(.identity)
            }
        }
    }
}

struct TransferFunctionTraceData {
    struct Topology: Hashable {
        let lowerFrequency: Double
        let upperFrequency: Double
    }

    static let maximumOpacity = 0.85
    static let minimumOpacity = 0.12
    /// Coherence (magnitude-squared) at or below which the trace is faintest.
    static let lowCoherence = 0.3
    /// Coherence at or above which the trace is fully opaque.
    static let highCoherence = 0.8

    let topology: Topology
    let positions: TransferFunctionTraceVector
    /// Horizontal gradient stops (0...1) fading the trace where coherence is low.
    let opacityStops: [(location: Double, opacity: Double)]

    static func opacity(forCoherence coherence: Double) -> Double {
        guard coherence.isFinite else { return minimumOpacity }
        let fraction = min(1, max(0,
            (coherence - lowCoherence) / (highCoherence - lowCoherence)
        ))
        return minimumOpacity + fraction * (maximumOpacity - minimumOpacity)
    }

    init?(
        points: [TransferFunctionPoint],
        frequencyScale: SpectrogramFrequencyScale,
        displayLowerDB: Double,
        displayUpperDB: Double
    ) {
        let levelSpan = displayUpperDB - displayLowerDB
        guard !points.isEmpty,
              displayLowerDB.isFinite,
              displayUpperDB.isFinite,
              levelSpan > 0 else { return nil }

        var sourcePositions: [(horizontal: Double, vertical: Double, coherence: Double)] = []
        sourcePositions.reserveCapacity(points.count)
        var previousFrequency = 0.0
        for point in points {
            guard point.frequency.isFinite,
                  point.frequency > previousFrequency,
                  point.magnitudeDB.isFinite,
                  let horizontalPosition = frequencyScale.position(for: point.frequency) else {
                return nil
            }
            sourcePositions.append((
                horizontalPosition,
                (displayUpperDB - point.magnitudeDB) / levelSpan,
                point.coherence.isFinite ? min(1, max(0, point.coherence)) : 0
            ))
            previousFrequency = point.frequency
        }

        topology = Topology(
            lowerFrequency: frequencyScale.lowerFrequency,
            upperFrequency: frequencyScale.upperFrequency
        )
        let canonicalFrequencies = SpectrogramAnalyzer.bandCenterFrequencies(
            for: frequencyScale
        )
        var positions: [Double] = []
        positions.reserveCapacity(canonicalFrequencies.count * 2)
        var opacityStops: [(location: Double, opacity: Double)] = []
        opacityStops.reserveCapacity(canonicalFrequencies.count)
        let first = sourcePositions[0]
        let last = sourcePositions[sourcePositions.count - 1]
        var sourceIndex = 0
        for frequency in canonicalFrequencies {
            guard let canonicalHorizontal = frequencyScale.position(for: frequency) else {
                return nil
            }
            let horizontal = min(last.horizontal, max(first.horizontal, canonicalHorizontal))
            while sourceIndex + 1 < sourcePositions.count
                && sourcePositions[sourceIndex + 1].horizontal < horizontal {
                sourceIndex += 1
            }

            let vertical: Double
            let coherence: Double
            if horizontal <= first.horizontal {
                vertical = first.vertical
                coherence = first.coherence
            } else if horizontal >= last.horizontal {
                vertical = last.vertical
                coherence = last.coherence
            } else {
                let lower = sourcePositions[sourceIndex]
                let upper = sourcePositions[sourceIndex + 1]
                let fraction = (horizontal - lower.horizontal)
                    / (upper.horizontal - lower.horizontal)
                vertical = lower.vertical + fraction * (upper.vertical - lower.vertical)
                coherence = lower.coherence + fraction * (upper.coherence - lower.coherence)
            }
            positions.append(horizontal)
            positions.append(vertical)
            opacityStops.append((
                min(1, max(0, horizontal)),
                Self.opacity(forCoherence: coherence)
            ))
        }
        self.positions = TransferFunctionTraceVector(positions)
        self.opacityStops = opacityStops
    }
}

private struct TransferFunctionTraceShape: Shape {
    var positions: TransferFunctionTraceVector

    var animatableData: TransferFunctionTraceVector {
        get { positions }
        set { positions = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var valueIndex = 0
        var isFirstPoint = true
        while valueIndex + 1 < positions.values.count {
            let position = CGPoint(
                x: rect.width * CGFloat(positions.values[valueIndex]),
                y: rect.height * CGFloat(positions.values[valueIndex + 1])
            )
            if isFirstPoint {
                path.move(to: position)
                isFirstPoint = false
            } else {
                path.addLine(to: position)
            }
            valueIndex += 2
        }
        return path
    }
}

struct TransferFunctionTraceVector: VectorArithmetic {
    static let zero = TransferFunctionTraceVector([])

    var values: [Double]

    init(_ values: [Double]) {
        self.values = values
    }

    static func + (
        lhs: TransferFunctionTraceVector,
        rhs: TransferFunctionTraceVector
    ) -> TransferFunctionTraceVector {
        TransferFunctionTraceVector(combine(lhs.values, rhs.values, +))
    }

    static func - (
        lhs: TransferFunctionTraceVector,
        rhs: TransferFunctionTraceVector
    ) -> TransferFunctionTraceVector {
        TransferFunctionTraceVector(combine(lhs.values, rhs.values, -))
    }

    mutating func scale(by rhs: Double) {
        for index in values.indices {
            values[index] *= rhs
        }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }

    private static func combine(
        _ lhs: [Double],
        _ rhs: [Double],
        _ operation: (Double, Double) -> Double
    ) -> [Double] {
        let count = max(lhs.count, rhs.count)
        return (0..<count).map { index in
            operation(
                index < lhs.count ? lhs[index] : 0,
                index < rhs.count ? rhs[index] : 0
            )
        }
    }
}
