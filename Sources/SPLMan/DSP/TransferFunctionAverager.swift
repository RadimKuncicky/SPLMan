import Foundation

struct TransferFunctionAverager {
    static let averagingDuration: TimeInterval = 5

    private static let maximumObservationCount = 64

    private struct Observation {
        let points: [TransferFunctionPoint]
        let startUptime: TimeInterval
        let endUptime: TimeInterval
    }

    private struct Accumulator {
        var weightedMagnitudeDB = 0.0
        var duration: TimeInterval = 0
    }

    private var observations: [Observation] = []
    private var frequencyScale: SpectrogramFrequencyScale?
    private var lastStartUptime: TimeInterval?

    mutating func average(
        points: [TransferFunctionPoint],
        frequencyScale: SpectrogramFrequencyScale,
        capturedAtUptime: TimeInterval,
        blockDuration: TimeInterval
    ) -> [TransferFunctionPoint] {
        guard capturedAtUptime.isFinite,
              blockDuration.isFinite,
              blockDuration > 0,
              points.allSatisfy({
                  $0.frequency.isFinite && $0.frequency > 0 && $0.magnitudeDB.isFinite
              }) else {
            reset()
            return points
        }

        let endUptime = capturedAtUptime + blockDuration
        guard endUptime.isFinite else {
            reset()
            return points
        }

        if self.frequencyScale != frequencyScale
            || lastStartUptime.map({ capturedAtUptime <= $0 }) == true {
            reset()
        }
        self.frequencyScale = frequencyScale
        lastStartUptime = capturedAtUptime
        observations.append(Observation(
            points: points,
            startUptime: capturedAtUptime,
            endUptime: endUptime
        ))

        let windowStartUptime = endUptime - Self.averagingDuration
        observations.removeAll {
            $0.endUptime <= windowStartUptime
        }
        if observations.count > Self.maximumObservationCount {
            observations.removeFirst(
                observations.count - Self.maximumObservationCount
            )
        }

        var accumulators: [Double: Accumulator] = [:]
        accumulators.reserveCapacity(
            observations.reduce(0) { $0 + $1.points.count }
        )
        for observation in observations {
            let overlapDuration = max(
                0,
                min(observation.endUptime, endUptime)
                    - max(observation.startUptime, windowStartUptime)
            )
            guard overlapDuration > 0 else { continue }
            for point in observation.points {
                var accumulator = accumulators[point.frequency] ?? Accumulator()
                accumulator.weightedMagnitudeDB += point.magnitudeDB * overlapDuration
                accumulator.duration += overlapDuration
                accumulators[point.frequency] = accumulator
            }
        }

        return accumulators.keys.sorted().compactMap { frequency in
            guard let accumulator = accumulators[frequency],
                  accumulator.duration > 0 else { return nil }
            return TransferFunctionPoint(
                frequency: frequency,
                magnitudeDB: accumulator.weightedMagnitudeDB / accumulator.duration
            )
        }
    }

    mutating func reset() {
        observations.removeAll(keepingCapacity: true)
        frequencyScale = nil
        lastStartUptime = nil
    }
}
