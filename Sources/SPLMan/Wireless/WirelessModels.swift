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
            .compactMap { Self.normalizedAddress(String($0)) }
            .filter { unique.insert($0).inserted }
    }

    /// One spelling per receiver, so the same one is not connected twice and
    /// matches the addresses discovery reports. Nil for empty text.
    static func normalizedAddress(_ text: String) -> String? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasPrefix("["), let end = address.firstIndex(of: "]") {
            // [IPv6] or [IPv6]:port
            address = String(address[address.index(after: address.startIndex)..<end])
        } else if let colon = address.firstIndex(of: ":"), address.lastIndex(of: ":") == colon {
            // The receiver only listens on its command port, so a port typed
            // with the address is dropped rather than read as part of a name.
            // More than one colon is an IPv6 address.
            let port = address[address.index(after: colon)...]
            if (1...5).contains(port.count), port.allSatisfy({ ("0"..."9").contains($0) }) {
                address = String(address[..<colon])
            }
        }
        guard !address.isEmpty else { return nil }

        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ part in
            (1...3).contains(part.count) && part.allSatisfy { ("0"..."9").contains($0) }
        }) {
            // Receiver displays pad addresses with zeros, which are decimal
            // here; the system would reject them or read them as octal.
            let values = parts.compactMap { Int($0) }
            // An impossible address stays as typed, to show up as unavailable.
            guard values.count == 4, values.allSatisfy({ $0 <= 255 }) else { return address }
            return values.map { String($0) }.joined(separator: ".")
        }
        // Host names are not case sensitive.
        return address.lowercased()
    }
}

/// A receiver found by a network scan stays in use while the scan or a
/// connection has confirmed it lately, so one that was switched off or got
/// another address is eventually let go.
enum WirelessScanExpiry {
    static let lifetime: TimeInterval = 30

    static func isWanted(
        foundAt: TimeInterval,
        lastConnectedAt: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        now - max(foundAt, lastConnectedAt ?? foundAt) < lifetime
    }

    /// Leaves out connections too old to keep anything wanted.
    static func pruned(
        _ lastConnectedAt: [String: TimeInterval],
        now: TimeInterval
    ) -> [String: TimeInterval] {
        lastConnectedAt.filter { now - $0.value < lifetime }
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
