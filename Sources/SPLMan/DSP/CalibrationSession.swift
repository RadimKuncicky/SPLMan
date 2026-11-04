import Foundation

struct CalibrationSession {
    enum Result: Equatable {
        case collecting(progress: Double)
        case calibrated(offsetDB: Double)
        case unstable(spreadDB: Double)
        case invalidSignal(toneConcentration: Double, cMinusA: Double)
    }

    static let targetDB = 94.0
    /// Snapshots arrive at 10 Hz from a freshly started processor whose
    /// A-Slow integrator (τ = 1 s) begins at zero energy. Six seconds (6τ)
    /// leave a settling error below 0.011 dB; accepting earlier windows
    /// biased the offset by about +0.2 dB.
    static let settlingSamples = 60
    static let requiredSamples = 30
    static let maximumSamples = settlingSamples + 100
    /// Wall-clock limit for the UI; snapshots may be dropped, never added.
    static let timeout: TimeInterval = 20
    static let maximumSpreadDB = 0.6
    static let minimumRawLevelDB = -70.0
    static let minimumToneConcentration = 0.65
    static let maximumCMinusA = 2.0
    private var aSamples: [Double] = []
    private var cSamples: [Double] = []
    private var toneConcentrations: [Double] = []
    private var receivedSampleCount = 0

    mutating func add(
        rawASlowDB: Double,
        rawCSlowDB: Double,
        toneConcentration: Double
    ) -> Result {
        receivedSampleCount += 1
        guard receivedSampleCount > Self.settlingSamples else {
            return .collecting(
                progress: Double(receivedSampleCount)
                    / Double(Self.settlingSamples + Self.requiredSamples)
            )
        }
        aSamples.append(rawASlowDB)
        cSamples.append(rawCSlowDB)
        toneConcentrations.append(toneConcentration)
        if aSamples.count > Self.requiredSamples {
            aSamples.removeFirst()
            cSamples.removeFirst()
            toneConcentrations.removeFirst()
        }
        guard aSamples.count >= Self.requiredSamples else {
            return .collecting(
                progress: Double(Self.settlingSamples + aSamples.count)
                    / Double(Self.settlingSamples + Self.requiredSamples)
            )
        }
        let minimum = aSamples.min() ?? rawASlowDB
        let maximum = aSamples.max() ?? rawASlowDB
        let spread = maximum - minimum
        guard spread <= Self.maximumSpreadDB else {
            if receivedSampleCount < Self.maximumSamples {
                return .collecting(progress: 1)
            }
            return .unstable(spreadDB: spread)
        }
        let meanTone = toneConcentrations.reduce(0, +) / Double(toneConcentrations.count)
        let meanCMinusA = zip(cSamples, aSamples).reduce(0.0) { $0 + ($1.0 - $1.1) }
            / Double(aSamples.count)
        guard minimum >= Self.minimumRawLevelDB,
              meanTone >= Self.minimumToneConcentration,
              abs(meanCMinusA) <= Self.maximumCMinusA else {
            if receivedSampleCount < Self.maximumSamples {
                return .collecting(progress: 1)
            }
            return .invalidSignal(toneConcentration: meanTone, cMinusA: meanCMinusA)
        }
        let meanEnergy = aSamples.reduce(0.0) { $0 + pow(10, $1 / 10) } / Double(aSamples.count)
        let measured = 10 * log10(meanEnergy)
        return .calibrated(offsetDB: Self.targetDB - measured)
    }
}
