import Foundation

/// A supported mixing console. Adding a console means adding a case here and a
/// `MixerDriver`; the connection logic, display and settings adapt on their own.
enum MixerKind: String, CaseIterable, Codable, Identifiable {
    case none
    case behringerWing
    case behringerX32

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: L10n.text("Žádný")
        case .behringerWing: "Behringer WING"
        case .behringerX32: "Behringer X32 / Midas M32"
        }
    }

    var sections: [MixerMeterSectionDescriptor] {
        switch self {
        case .none: []
        case .behringerWing: WingMixerDriver.definitions.map(\.descriptor)
        case .behringerX32: X32MixerDriver.definitions.map(\.descriptor)
        }
    }

    func makeDriver() -> MixerDriver? {
        switch self {
        case .none: nil
        case .behringerWing: WingMixerDriver()
        case .behringerX32: X32MixerDriver()
        }
    }
}

/// Describes one separated block of the meter bridge.
struct MixerMeterSectionDescriptor: Identifiable, Equatable {
    let id: String
    let title: String
    let shortTitle: String
    /// Number of strips, or nil when only the console knows it.
    let stripCount: Int?
    /// Two for strips that are stereo, one for a single physical connector.
    let barsPerStrip: Int
    let isVisibleByDefault: Bool
}

struct MixerSettings: Codable, Equatable {
    var kind: MixerKind = .none
    /// Empty means the console is found automatically on the network.
    var address = ""
    /// Only the choices the user changed; other sections keep their default.
    var sectionVisibility: [String: Bool] = [:]

    private enum CodingKeys: String, CodingKey {
        case kind
        case address
        case sectionVisibility
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decodeIfPresent(MixerKind.self, forKey: .kind)) ?? .none
        address = (try? container.decodeIfPresent(String.self, forKey: .address)) ?? ""
        sectionVisibility = (try? container.decodeIfPresent(
            [String: Bool].self,
            forKey: .sectionVisibility
        )) ?? [:]
    }

    func isVisible(_ section: MixerMeterSectionDescriptor) -> Bool {
        sectionVisibility[section.id] ?? section.isVisibleByDefault
    }

    var visibleSections: [MixerMeterSectionDescriptor] {
        kind.sections.filter(isVisible)
    }

    var connectionAddress: String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct MixerIdentity: Equatable {
    var address: String
    var name: String
    var model: String
    var firmware: String
}

enum MixerDriverState: Equatable {
    case connecting
    case connected(MixerIdentity)
    case failed
}

struct MixerDriverUpdate {
    var state: MixerDriverState
    /// Nil until the first meter data arrives.
    var secondsSinceMeterData: TimeInterval?
    /// Levels in dB by section identifier, with `barsPerStrip` values per strip.
    var levels: [String: [Float]] = [:]
    /// Strips per section, reported for sections without a fixed count.
    var stripCounts: [String: Int] = [:]
    /// Changed names by section identifier and zero-based strip index.
    var names: [String: [Int: String]] = [:]
}

/// One connection attempt to one console. Every method returns immediately and
/// nothing may change the console's state: this feature only ever reads meters.
protocol MixerDriver: AnyObject {
    func start(address: String?, sections: [MixerMeterSectionDescriptor])
    func poll() -> MixerDriverUpdate
    func stop()
}

struct MixerBridgeStrip: Equatable {
    var number: Int
    var name: String
    var barCount: Int
}

struct MixerBridgeSection: Equatable {
    var id: String
    var shortTitle: String
    var strips: [MixerBridgeStrip]
}

/// Latest levels, written by the connection queue and read while drawing.
final class MixerLevelStore: @unchecked Sendable {
    private let lock = NSLock()
    private var levels: [String: [Float]] = [:]

    func replace(_ newLevels: [String: [Float]]) {
        lock.lock()
        levels = newLevels
        lock.unlock()
    }

    func snapshot() -> [String: [Float]] {
        lock.lock()
        defer { lock.unlock() }
        return levels
    }
}
