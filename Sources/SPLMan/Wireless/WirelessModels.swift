import Foundation

struct WirelessSettings: Codable, Equatable {
    var isEnabled = false
    /// Receivers to use besides those found automatically, as the user typed them.
    var addresses = ""

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case addresses
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? false
        addresses = (try? container.decodeIfPresent(String.self, forKey: .addresses)) ?? ""
    }

    var manualAddresses: [String] {
        var unique = Set<String>()
        return addresses
            .split { $0 == "," || $0 == ";" || $0.isWhitespace }
            .map(String.init)
            .filter { unique.insert($0).inserted }
    }
}

struct WirelessChannelReading: Equatable {
    var number: Int
    var name = ""
    var audioLevelDB: Double?
    var rfLevelDBm: Double?
    var batteryBars: Int?
    var batteryMinutes: Int?
    var transmitterModel: String?
}

enum WirelessDriverState: Equatable {
    case connecting
    case connected
    case unsupported
    case failed
}

struct WirelessDriverUpdate {
    var state: WirelessDriverState
    var model = ""
    var deviceName = ""
    /// Nil until the receiver's first message.
    var secondsSinceData: TimeInterval?
    var channels: [WirelessChannelReading] = []
}

/// One connection attempt to one receiver. Every method returns immediately and
/// nothing may change the receiver's state: this feature only ever reads.
protocol WirelessDriver: AnyObject {
    func start(address: String)
    func poll() -> WirelessDriverUpdate
    func stop()
}

/// Everything about a channel that changes rarely. Levels go through
/// `MixerLevelStore`, under the channel's `id`, so they do not reach SwiftUI.
struct WirelessChannel: Equatable, Identifiable {
    /// Positions of the values stored for each channel.
    static let audioLevelIndex = 0
    static let rfLevelIndex = 1

    var id: String
    var number: Int
    var name: String
    var isOnline: Bool
    var batteryBars: Int?
    var batteryMinutes: Int?
    var transmitterModel: String?
}

enum WirelessReceiverPhase: Equatable {
    case connecting
    case connected
    case unsupported
    case unavailable
}

struct WirelessReceiverStatus: Equatable, Identifiable {
    var address: String
    var model: String
    var name: String
    var phase: WirelessReceiverPhase

    var id: String { address }
}

/// Received signal strength as a bar. The thresholds are a practical reading of
/// typical wireless systems, not values published by a manufacturer.
enum WirelessRFScale {
    enum Zone: Equatable {
        case weak
        case fair
        case strong
    }

    static let minimumDBm = -100.0
    static let maximumDBm = -40.0
    static let fairStartDBm = -85.0
    static let strongStartDBm = -70.0

    static func fraction(_ levelDBm: Double) -> Double {
        guard levelDBm.isFinite else { return 0 }
        return min(1, max(0, (levelDBm - minimumDBm) / (maximumDBm - minimumDBm)))
    }

    static func zone(_ levelDBm: Double) -> Zone {
        if levelDBm >= strongStartDBm { return .strong }
        return levelDBm >= fairStartDBm ? .fair : .weak
    }
}
