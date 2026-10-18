import Foundation

enum Metric: String, CaseIterable, Codable, Identifiable {
    case laeq1Second
    case lceq1Second
    case lzeq1Second
    case lafMax1Second
    case lasMax1Second
    case lcPeak1Second
    case laeq1
    case laeq10
    case laeq15
    case laeq30
    case lceq1
    case lceq10
    case lceq30
    case lcPeak
    case lafMax
    case aSlow
    case cSlow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .laeq1Second: "LAeq 1 s"
        case .lceq1Second: "LCeq 1 s"
        case .lzeq1Second: "LZeq 1 s"
        case .lafMax1Second: "LAFmax 1 s"
        case .lasMax1Second: "LASmax 1 s"
        case .lcPeak1Second: "LCpeak 1 s"
        case .laeq1: "LAeq 1 min"
        case .laeq10: "LAeq 10 min"
        case .laeq15: "LAeq 15 min"
        case .laeq30: "LAeq 30 min"
        case .lceq1: "LCeq 1 min"
        case .lceq10: "LCeq 10 min"
        case .lceq30: "LCeq 30 min"
        case .lcPeak: "LCpeak"
        case .lafMax: "LAFmax"
        case .aSlow: "dBA Slow"
        case .cSlow: "dBC Slow"
        }
    }

    var isCWeighted: Bool {
        switch self {
        case .lceq1Second, .lcPeak1Second, .lceq1, .lceq10, .lceq30, .lcPeak, .cSlow: true
        default: false
        }
    }

    var matchingAMetric: Metric? {
        switch self {
        case .lceq1Second: .laeq1Second
        case .lceq1: .laeq1
        case .lceq10: .laeq10
        case .lceq30: .laeq30
        case .cSlow: .aSlow
        default: nil
        }
    }
}

struct MeterSnapshot: Equatable {
    var values: [Metric: Double] = [:]

    static let empty = MeterSnapshot()
}

enum MeterOperationalStatus: Equatable {
    case ready
    case notice(String)
    case warning(String)
    case storageError

    var title: String {
        switch self {
        case .ready: "OK"
        case let .notice(message), let .warning(message): message
        case .storageError: L10n.text("CHYBA ZÁZNAMU")
        }
    }
}

struct VisualThresholds: Codable, Equatable {
    var aTransitionStart = 95.0
    var aYellow = 100.0
    var cTransitionStart = 105.0
    var cYellow = 110.0

    func range(for metric: Metric) -> ClosedRange<Double> {
        let endpoints = metric.isCWeighted
            ? (cTransitionStart, cYellow)
            : (aTransitionStart, aYellow)
        return min(endpoints.0, endpoints.1)...max(endpoints.0, endpoints.1)
    }
}
