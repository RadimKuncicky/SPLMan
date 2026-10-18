import Foundation

/// Estimates true peak between samples at 4x resolution with a causal,
/// eight-tap Lanczos-windowed sinc interpolator.
struct FourTimesIntersamplePeakDetector {
    private static let tapCount = 8
    private static let precomputedCoefficients: [[Double]] = [0.25, 0.5, 0.75].map { phase in
        var values = (0..<tapCount).map { tap -> Double in
            let distance = Double(tap) - 4 + phase
            return sinc(distance) * sinc(distance / 4)
        }
        let gain = values.reduce(0, +)
        for index in values.indices { values[index] /= gain }
        return values
    }

    private let coefficients: [[Double]]
    private var history = Array(repeating: 0.0, count: tapCount)
    private var sampleCount = 0
    private(set) var maximumAmplitude = 0.0

    init() { coefficients = Self.precomputedCoefficients }

    mutating func process(_ sample: Double) {
        maximumAmplitude = max(maximumAmplitude, abs(sample))
        history[7] = history[6]
        history[6] = history[5]
        history[5] = history[4]
        history[4] = history[3]
        history[3] = history[2]
        history[2] = history[1]
        history[1] = history[0]
        history[0] = sample
        sampleCount = min(Self.tapCount, sampleCount + 1)
        guard sampleCount == Self.tapCount else { return }

        for phase in coefficients {
            let interpolated = phase[0] * history[0]
                + phase[1] * history[1]
                + phase[2] * history[2]
                + phase[3] * history[3]
                + phase[4] * history[4]
                + phase[5] * history[5]
                + phase[6] * history[6]
                + phase[7] * history[7]
            maximumAmplitude = max(maximumAmplitude, abs(interpolated))
        }
    }

    /// Starts a new peak interval without discarding interpolation history.
    mutating func resetMaximum() { maximumAmplitude = 0 }

    mutating func reset() {
        for index in history.indices { history[index] = 0 }
        sampleCount = 0
        maximumAmplitude = 0
    }

    private static func sinc(_ value: Double) -> Double {
        guard abs(value) > 1e-12 else { return 1 }
        let angle = Double.pi * value
        return sin(angle) / angle
    }
}

struct ExponentialTimeWeighting {
    private let smoothing: Double
    private(set) var energy = 0.0

    init(timeConstant: Double, sampleRate: Double) {
        smoothing = -expm1(-1 / (timeConstant * sampleRate))
    }

    mutating func process(_ inputEnergy: Double) -> Double {
        energy += smoothing * (inputEnergy - energy)
        return energy
    }

    mutating func reset() { energy = 0 }
}

struct RawMeterSnapshot: Equatable {
    var aSlow: Double?
    var cSlow: Double?
    var laeq1: Double?
    var laeq10: Double?
    var laeq15: Double?
    var lceq1: Double?
    var lceq10: Double?
    var lcPeak: Double?
    var lafMax: Double?
    var oneKilohertzConcentration: Double?

    var laeq1Second: Double?
    var lceq1Second: Double?
    var lzeq1Second: Double?
    var lafMax1Second: Double?
    var lasMax1Second: Double?
    var lcPeak1Second: Double?
    var laeq30: Double?
    var lceq30: Double?
    var processedFrameCount: UInt64 = 0
    var completedSecondCount: UInt64 = 0
    var clippedFrameCount: UInt64 = 0
    var lostSecondIntervals: UInt64 = 0
}

/// Single-owner streaming processor. It retains aggregated one-second energy,
/// never microphone samples. All interval boundaries derive from audio frames.
final class SPLProcessor {
    static let binDuration = 0.1
    static let supportedSampleRateRange = 32_000.0...192_000.0
    private static let completedSecondCapacity = 8

    private let sampleRate: Double
    private let framesPerSecond: Int
    private var displayPhase = 0
    private var aFilter: FrequencyWeightingFilter
    private var cFilter: FrequencyWeightingFilter
    private var aSlow: ExponentialTimeWeighting
    private var cSlow: ExponentialTimeWeighting
    private var aFast: ExponentialTimeWeighting
    private var aFastMaximumEnergy = 0.0
    private var cPeakMaximumAmplitude = 0.0
    private var secondAFastMaximumEnergy = 0.0
    private var secondASlowMaximumEnergy = 0.0
    private var secondCPeakDetector = FourTimesIntersamplePeakDetector()
    private var displayBroadbandEnergy = 0.0
    private var samplesInDisplayBin = 0
    private var secondAEnergy = 0.0
    private var secondCEnergy = 0.0
    private var secondZEnergy = 0.0
    private var framesInSecond = 0
    private var processedFrameCount: UInt64 = 0
    private var completedSecondCount: UInt64 = 0
    private var clippedFrameCount: UInt64 = 0
    private(set) var lostSecondIntervals: UInt64 = 0
    private let toneCoefficients: [Double]
    private var toneQ1: [Double]
    private var toneQ2: [Double]
    private var aOneMinute = RollingEnergy(capacity: 60)
    private var cOneMinute = RollingEnergy(capacity: 60)
    private var aTenMinutes = RollingEnergy(capacity: 600)
    private var cTenMinutes = RollingEnergy(capacity: 600)
    private var aFifteenMinutes = RollingEnergy(capacity: 900)
    private var aThirtyMinutes = RollingEnergy(capacity: 1_800)
    private var cThirtyMinutes = RollingEnergy(capacity: 1_800)
    private var latestSecondLAeq: Double?
    private var latestSecondLCeq: Double?
    private var latestSecondLZeq: Double?
    private var latestSecondLAFMax: Double?
    private var latestSecondLASMax: Double?
    private var latestSecondLCPeak: Double?
    private var latestToneConcentration: Double?
    private var latest = RawMeterSnapshot()
    private var completedSeconds = Array<RawMeterSnapshot?>(
        repeating: nil,
        count: completedSecondCapacity
    )
    private var completedSecondReadIndex = 0
    private var completedSecondWriteIndex = 0
    private var queuedSecondCount = 0

    var currentCompletedSecondCount: UInt64 { completedSecondCount }

    static func isValidSampleRate(_ sampleRate: Double) -> Bool {
        sampleRate.isFinite
            && supportedSampleRateRange.contains(sampleRate)
            && abs(sampleRate.rounded() - sampleRate) < 1e-6
    }

    init(sampleRate: Double) {
        precondition(Self.isValidSampleRate(sampleRate), "Unsupported audio sample rate")
        self.sampleRate = sampleRate
        framesPerSecond = Int(sampleRate.rounded())
        aFilter = FrequencyWeightingFilter(kind: .a, sampleRate: sampleRate)
        cFilter = FrequencyWeightingFilter(kind: .c, sampleRate: sampleRate)
        aSlow = ExponentialTimeWeighting(timeConstant: 1, sampleRate: sampleRate)
        cSlow = ExponentialTimeWeighting(timeConstant: 1, sampleRate: sampleRate)
        aFast = ExponentialTimeWeighting(timeConstant: 0.125, sampleRate: sampleRate)
        toneCoefficients = [980.0, 990.0, 1_000.0, 1_010.0, 1_020.0].map {
            2 * cos(2 * Double.pi * $0 / sampleRate)
        }
        toneQ1 = Array(repeating: 0, count: toneCoefficients.count)
        toneQ2 = Array(repeating: 0, count: toneCoefficients.count)
    }

    /// Returns a display snapshot at most every 100 ms. Drain exact-second
    /// snapshots with `popCompletedSecond()` after each call.
    func process(_ samples: UnsafePointer<Float>, count: Int) -> RawMeterSnapshot? {
        guard count > 0 else { return nil }
        var producedSnapshot: RawMeterSnapshot?

        for index in 0..<count {
            let input = Double(samples[index])
            let a = aFilter.process(input)
            let c = cFilter.process(input)
            let aEnergy = a * a
            let cEnergy = c * c
            let currentASlowEnergy = aSlow.process(aEnergy)
            _ = cSlow.process(cEnergy)
            let currentAFastEnergy = aFast.process(aEnergy)
            aFastMaximumEnergy = max(aFastMaximumEnergy, currentAFastEnergy)
            secondAFastMaximumEnergy = max(secondAFastMaximumEnergy, currentAFastEnergy)
            secondASlowMaximumEnergy = max(secondASlowMaximumEnergy, currentASlowEnergy)
            secondCPeakDetector.process(c)
            cPeakMaximumAmplitude = max(cPeakMaximumAmplitude, secondCPeakDetector.maximumAmplitude)

            displayBroadbandEnergy += input * input
            secondAEnergy += aEnergy
            secondCEnergy += cEnergy
            secondZEnergy += input * input
            if abs(input) >= 1 { clippedFrameCount &+= 1 }
            for toneIndex in toneCoefficients.indices {
                let q0 = toneCoefficients[toneIndex] * toneQ1[toneIndex]
                    - toneQ2[toneIndex] + input
                toneQ2[toneIndex] = toneQ1[toneIndex]
                toneQ1[toneIndex] = q0
            }

            processedFrameCount &+= 1
            framesInSecond += 1
            samplesInDisplayBin += 1
            displayPhase += 10
            if displayPhase >= framesPerSecond {
                displayPhase -= framesPerSecond
                latestToneConcentration = oneKilohertzConcentration(sampleCount: samplesInDisplayBin)
                resetDisplayBin()
                latest = makeSnapshot()
                producedSnapshot = latest
            }
            if framesInSecond == framesPerSecond {
                completeSecond()
                latest = makeSnapshot()
                enqueueCompletedSecond(latest)
                producedSnapshot = latest
            }
        }
        return producedSnapshot
    }

    func popCompletedSecond() -> RawMeterSnapshot? {
        guard queuedSecondCount > 0 else { return nil }
        let snapshot = completedSeconds[completedSecondReadIndex]
        completedSeconds[completedSecondReadIndex] = nil
        completedSecondReadIndex = (completedSecondReadIndex + 1) % completedSeconds.count
        queuedSecondCount -= 1
        return snapshot
    }

    /// Discards the incomplete interval and windows that can no longer be
    /// proven continuous. Lifetime frame and completed-interval counters stay
    /// monotonic so downstream code can identify the gap explicitly.
    @discardableResult
    func invalidateTimeContinuity() -> UInt64 {
        let discardedPartialFrameCount = UInt64(framesInSecond)
        aFilter.reset()
        cFilter.reset()
        aSlow.reset()
        cSlow.reset()
        aFast.reset()
        secondAFastMaximumEnergy = 0
        secondASlowMaximumEnergy = 0
        secondCPeakDetector.reset()
        displayBroadbandEnergy = 0
        samplesInDisplayBin = 0
        displayPhase = 0
        secondAEnergy = 0
        secondCEnergy = 0
        secondZEnergy = 0
        framesInSecond = 0
        aOneMinute.reset()
        cOneMinute.reset()
        aTenMinutes.reset()
        cTenMinutes.reset()
        aFifteenMinutes.reset()
        aThirtyMinutes.reset()
        cThirtyMinutes.reset()
        latestSecondLAeq = nil
        latestSecondLCeq = nil
        latestSecondLZeq = nil
        latestSecondLAFMax = nil
        latestSecondLASMax = nil
        latestSecondLCPeak = nil
        latestToneConcentration = nil
        for index in toneQ1.indices {
            toneQ1[index] = 0
            toneQ2[index] = 0
        }
        return discardedPartialFrameCount
    }

    func reset() {
        aFilter = FrequencyWeightingFilter(kind: .a, sampleRate: sampleRate)
        cFilter = FrequencyWeightingFilter(kind: .c, sampleRate: sampleRate)
        aSlow = ExponentialTimeWeighting(timeConstant: 1, sampleRate: sampleRate)
        cSlow = ExponentialTimeWeighting(timeConstant: 1, sampleRate: sampleRate)
        aFast = ExponentialTimeWeighting(timeConstant: 0.125, sampleRate: sampleRate)
        aFastMaximumEnergy = 0
        cPeakMaximumAmplitude = 0
        secondAFastMaximumEnergy = 0
        secondASlowMaximumEnergy = 0
        secondCPeakDetector.reset()
        displayBroadbandEnergy = 0
        samplesInDisplayBin = 0
        displayPhase = 0
        secondAEnergy = 0
        secondCEnergy = 0
        secondZEnergy = 0
        framesInSecond = 0
        processedFrameCount = 0
        completedSecondCount = 0
        clippedFrameCount = 0
        lostSecondIntervals = 0
        aOneMinute = RollingEnergy(capacity: 60)
        cOneMinute = RollingEnergy(capacity: 60)
        aTenMinutes = RollingEnergy(capacity: 600)
        cTenMinutes = RollingEnergy(capacity: 600)
        aFifteenMinutes = RollingEnergy(capacity: 900)
        aThirtyMinutes = RollingEnergy(capacity: 1_800)
        cThirtyMinutes = RollingEnergy(capacity: 1_800)
        latestSecondLAeq = nil
        latestSecondLCeq = nil
        latestSecondLZeq = nil
        latestSecondLAFMax = nil
        latestSecondLASMax = nil
        latestSecondLCPeak = nil
        latestToneConcentration = nil
        latest = RawMeterSnapshot()
        completedSeconds = Array(repeating: nil, count: Self.completedSecondCapacity)
        completedSecondReadIndex = 0
        completedSecondWriteIndex = 0
        queuedSecondCount = 0
        toneQ1 = Array(repeating: 0, count: toneCoefficients.count)
        toneQ2 = Array(repeating: 0, count: toneCoefficients.count)
    }

    static func decibels(_ meanSquare: Double) -> Double? {
        guard meanSquare.isFinite, meanSquare > 1e-20 else { return nil }
        return 10 * log10(meanSquare)
    }

    private func completeSecond() {
        let divisor = Double(framesInSecond)
        let aMeanSquare = secondAEnergy / divisor
        let cMeanSquare = secondCEnergy / divisor
        let zMeanSquare = secondZEnergy / divisor
        aOneMinute.append(aMeanSquare)
        cOneMinute.append(cMeanSquare)
        aTenMinutes.append(aMeanSquare)
        cTenMinutes.append(cMeanSquare)
        aFifteenMinutes.append(aMeanSquare)
        aThirtyMinutes.append(aMeanSquare)
        cThirtyMinutes.append(cMeanSquare)
        latestSecondLAeq = Self.decibels(aMeanSquare)
        latestSecondLCeq = Self.decibels(cMeanSquare)
        latestSecondLZeq = Self.decibels(zMeanSquare)
        latestSecondLAFMax = Self.decibels(secondAFastMaximumEnergy)
        latestSecondLASMax = Self.decibels(secondASlowMaximumEnergy)
        latestSecondLCPeak = Self.decibels(
            secondCPeakDetector.maximumAmplitude * secondCPeakDetector.maximumAmplitude
        )
        completedSecondCount &+= 1
        secondAEnergy = 0
        secondCEnergy = 0
        secondZEnergy = 0
        secondAFastMaximumEnergy = 0
        secondASlowMaximumEnergy = 0
        // The interpolator is causal, so retaining its history would assign
        // delayed fractional peaks from the preceding second to the new one.
        secondCPeakDetector.reset()
        framesInSecond = 0
    }

    private func makeSnapshot() -> RawMeterSnapshot {
        RawMeterSnapshot(
            aSlow: Self.decibels(aSlow.energy),
            cSlow: Self.decibels(cSlow.energy),
            laeq1: aOneMinute.average.flatMap(Self.decibels),
            laeq10: aTenMinutes.average.flatMap(Self.decibels),
            laeq15: aFifteenMinutes.average.flatMap(Self.decibels),
            lceq1: cOneMinute.average.flatMap(Self.decibels),
            lceq10: cTenMinutes.average.flatMap(Self.decibels),
            lcPeak: Self.decibels(cPeakMaximumAmplitude * cPeakMaximumAmplitude),
            lafMax: Self.decibels(aFastMaximumEnergy),
            oneKilohertzConcentration: latestToneConcentration,
            laeq1Second: latestSecondLAeq,
            lceq1Second: latestSecondLCeq,
            lzeq1Second: latestSecondLZeq,
            lafMax1Second: latestSecondLAFMax,
            lasMax1Second: latestSecondLASMax,
            lcPeak1Second: latestSecondLCPeak,
            laeq30: aThirtyMinutes.average.flatMap(Self.decibels),
            lceq30: cThirtyMinutes.average.flatMap(Self.decibels),
            processedFrameCount: processedFrameCount,
            completedSecondCount: completedSecondCount,
            clippedFrameCount: clippedFrameCount,
            lostSecondIntervals: lostSecondIntervals
        )
    }

    private func enqueueCompletedSecond(_ snapshot: RawMeterSnapshot) {
        guard queuedSecondCount < completedSeconds.count else {
            lostSecondIntervals &+= 1
            return
        }
        completedSeconds[completedSecondWriteIndex] = snapshot
        completedSecondWriteIndex = (completedSecondWriteIndex + 1) % completedSeconds.count
        queuedSecondCount += 1
    }

    private func resetDisplayBin() {
        displayBroadbandEnergy = 0
        samplesInDisplayBin = 0
        for toneIndex in toneCoefficients.indices {
            toneQ1[toneIndex] = 0
            toneQ2[toneIndex] = 0
        }
    }

    private func oneKilohertzConcentration(sampleCount: Int) -> Double? {
        guard sampleCount > 0, displayBroadbandEnergy > 1e-16 else { return nil }
        var toneEnergy = 0.0
        for index in toneCoefficients.indices {
            let power = toneQ1[index] * toneQ1[index]
                + toneQ2[index] * toneQ2[index]
                - toneCoefficients[index] * toneQ1[index] * toneQ2[index]
            toneEnergy += 2 * power / Double(sampleCount * sampleCount)
        }
        let broadbandMeanSquare = displayBroadbandEnergy / Double(sampleCount)
        return min(1, max(0, toneEnergy / broadbandMeanSquare))
    }
}
