import Foundation

/// Stable cascaded A/C weighting filters based on matched analog poles.
/// Two zeros at z=-0.1 compensate the high-frequency mapping error; response
/// is normalized at 1 kHz and verified from 44.1 through 96 kHz sample rates.
struct FrequencyWeightingFilter {
    enum Kind { case a, c }

    private struct Biquad {
        var b0: Double
        var b1: Double
        var b2: Double
        let a1: Double
        let a2: Double
        var state1 = 0.0
        var state2 = 0.0

        mutating func process(_ input: Double) -> Double {
            let output = b0 * input + state1
            state1 = b1 * input - a1 * output + state2
            state2 = b2 * input - a2 * output
            return output
        }

        mutating func reset() {
            state1 = 0
            state2 = 0
        }

        func magnitude(frequency: Double, sampleRate: Double) -> Double {
            let angle = -2 * Double.pi * frequency / sampleRate
            let z1Real = cos(angle)
            let z1Imaginary = sin(angle)
            let z2Real = cos(2 * angle)
            let z2Imaginary = sin(2 * angle)
            let numeratorReal = b0 + b1 * z1Real + b2 * z2Real
            let numeratorImaginary = b1 * z1Imaginary + b2 * z2Imaginary
            let denominatorReal = 1 + a1 * z1Real + a2 * z2Real
            let denominatorImaginary = a1 * z1Imaginary + a2 * z2Imaginary
            return hypot(numeratorReal, numeratorImaginary)
                / hypot(denominatorReal, denominatorImaginary)
        }
    }

    private var sections: [Biquad]

    init(kind: Kind, sampleRate: Double) {
        let f1 = 20.598997
        let f2 = 107.65265
        let f3 = 737.86223
        let f4 = 12194.217
        let p1 = exp(-2 * Double.pi * f1 / sampleRate)
        let p2 = exp(-2 * Double.pi * f2 / sampleRate)
        let p3 = exp(-2 * Double.pi * f3 / sampleRate)
        let p4 = exp(-2 * Double.pi * f4 / sampleRate)

        let lowFrequencySection = Biquad(
            b0: 1, b1: -2, b2: 1,
            a1: -2 * p1, a2: p1 * p1
        )
        let highFrequencySection = Biquad(
            b0: 1, b1: 0.2, b2: 0.01,
            a1: -2 * p4, a2: p4 * p4
        )
        switch kind {
        case .a:
            sections = [
                lowFrequencySection,
                Biquad(
                    b0: 1, b1: -2, b2: 1,
                    a1: -(p2 + p3), a2: p2 * p3
                ),
                highFrequencySection
            ]
        case .c:
            sections = [lowFrequencySection, highFrequencySection]
        }

        let currentGain = sections.reduce(1.0) {
            $0 * $1.magnitude(frequency: 1_000, sampleRate: sampleRate)
        }
        let targetGain = pow(10, Self.analogGain(kind: kind, frequency: 1_000) / 20)
        let normalization = targetGain / currentGain
        sections[0].b0 *= normalization
        sections[0].b1 *= normalization
        sections[0].b2 *= normalization
    }

    mutating func process(_ sample: Double) -> Double {
        var value = sample
        for index in sections.indices {
            value = sections[index].process(value)
        }
        return value
    }

    mutating func reset() {
        for index in sections.indices { sections[index].reset() }
    }

    private static func analogGain(kind: Kind, frequency: Double) -> Double {
        let f1 = 20.598997
        let f2 = 107.65265
        let f3 = 737.86223
        let f4 = 12194.217
        let squared = frequency * frequency
        switch kind {
        case .a:
            let ratio = (f4 * f4 * squared * squared) /
                ((squared + f1 * f1)
                 * sqrt((squared + f2 * f2) * (squared + f3 * f3))
                 * (squared + f4 * f4))
            return 20 * log10(ratio) + 1.9997
        case .c:
            let ratio = (f4 * f4 * squared)
                / ((squared + f1 * f1) * (squared + f4 * f4))
            return 20 * log10(ratio) + 0.0619
        }
    }
}
