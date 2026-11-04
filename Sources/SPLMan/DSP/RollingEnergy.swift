import Foundation

struct RollingEnergy {
    private var values: [Double]
    private var nextIndex = 0
    private(set) var count = 0
    private var total = 0.0

    init(capacity: Int) {
        precondition(capacity > 0)
        values = Array(repeating: 0, count: capacity)
    }

    mutating func append(_ energy: Double) {
        if count == values.count {
            total -= values[nextIndex]
        } else {
            count += 1
        }
        values[nextIndex] = energy
        total += energy
        nextIndex = (nextIndex + 1) % values.count
        // Re-sum once per window (amortized O(1)) so cancellation error from
        // evicting loud intervals cannot accumulate during quiet passages.
        if nextIndex == 0 {
            total = values.reduce(0, +)
        }
    }

    mutating func reset() {
        for index in values.indices { values[index] = 0 }
        nextIndex = 0
        count = 0
        total = 0
    }

    var average: Double? {
        count == values.count ? total / Double(count) : nil
    }
}
