import Foundation
import X32Kit

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

    /// Whether the driver can use the address. Nil or empty means automatic
    /// discovery, which every console supports.
    func isValidAddress(_ address: String?) -> Bool {
        guard let address,
              !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        switch self {
        case .none, .behringerWing: return true
        case .behringerX32: return X32Endpoint(parsing: address) != nil
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
    /// Only the choices the user changed, by `MixerKind.rawValue` and section
    /// identifier; other sections keep their default. Consoles share section
    /// identifiers such as `ch`, so each console type keeps its own choices.
    /// String keys keep the choices of console types from a newer version.
    private(set) var sectionVisibilityByKind: [String: [String: Bool]] = [:]

    private enum CodingKeys: String, CodingKey {
        case kind
        case address
        case sectionVisibilityByKind
        // The choices of the current console type, for versions before
        // `sectionVisibilityByKind`.
        case sectionVisibility
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decodeIfPresent(MixerKind.self, forKey: .kind)) ?? .none
        address = (try? container.decodeIfPresent(String.self, forKey: .address)) ?? ""
        if let byKind = try? container.decodeIfPresent(
            [String: [String: Bool]].self,
            forKey: .sectionVisibilityByKind
        ) {
            sectionVisibilityByKind = byKind
        } else if kind != .none,
                  let legacy = try? container.decodeIfPresent(
                      [String: Bool].self,
                      forKey: .sectionVisibility
                  ),
                  !legacy.isEmpty {
            sectionVisibilityByKind = [kind.rawValue: legacy]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(address, forKey: .address)
        try container.encode(sectionVisibilityByKind, forKey: .sectionVisibilityByKind)
        try container.encode(
            sectionVisibilityByKind[kind.rawValue] ?? [:],
            forKey: .sectionVisibility
        )
    }

    func isVisible(_ section: MixerMeterSectionDescriptor) -> Bool {
        sectionVisibilityByKind[kind.rawValue]?[section.id] ?? section.isVisibleByDefault
    }

    /// Changes the choice for the current console type only.
    mutating func setVisible(_ section: MixerMeterSectionDescriptor, _ isVisible: Bool) {
        guard kind != .none else { return }
        sectionVisibilityByKind[kind.rawValue, default: [:]][section.id] = isVisible
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
