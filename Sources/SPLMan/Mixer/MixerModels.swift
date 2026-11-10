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

    /// Centre frequency in Hz of each band of the console's real-time analyzer,
    /// in the order the console sends the bands.
    var rtaBandFrequencies: [Double] {
        switch self {
        case .none: []
        case .behringerWing: WingMixerDriver.rtaBandFrequencies
        case .behringerX32: X32MixerDriver.rtaBandFrequencies
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

/// The console the user chose from the consoles found on the network. While it
/// is selected, the application connects to no other console.
struct PreferredMixer: Codable, Equatable {
    var kind: MixerKind
    var name: String
    var model: String
    /// Empty for consoles that do not report one, such as the X32.
    var serial: String
    /// The address it was last found at.
    var address: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
        case model
        case serial
        case address
    }

    init(
        kind: MixerKind,
        name: String = "",
        model: String = "",
        serial: String = "",
        address: String = ""
    ) {
        self.kind = kind
        self.name = name
        self.model = model
        self.serial = serial
        self.address = address
    }

    init(_ console: DiscoveredMixer) {
        self.init(
            kind: console.kind,
            name: console.name,
            model: console.model,
            serial: console.serial,
            address: console.address
        )
    }

    /// An unknown console type, for example from a newer version, fails, so
    /// only the preference is dropped.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(MixerKind.self, forKey: .kind)
        guard kind != .none else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "A preferred console needs a console type"
            )
        }
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? ""
        serial = (try? container.decodeIfPresent(String.self, forKey: .serial)) ?? ""
        address = (try? container.decodeIfPresent(String.self, forKey: .address)) ?? ""
    }

    /// The name shown to the user.
    var displayName: String {
        for text in [name, model, address] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return kind.title
    }

    /// Whether a console that answered discovery is this one. A WING is
    /// recognized by its serial number; an X32 or M32, which reports none, by its
    /// network name and model. Only without those is the last address compared,
    /// so a console that got another address is still found.
    func matches(
        kind: MixerKind,
        name: String,
        model: String,
        serial: String,
        address: String
    ) -> Bool {
        guard kind == self.kind, kind != .none else { return false }
        let ownSerial = Self.trimmed(self.serial)
        if !ownSerial.isEmpty {
            return ownSerial.caseInsensitiveCompare(Self.trimmed(serial)) == .orderedSame
        }
        let ownName = Self.trimmed(self.name)
        if !ownName.isEmpty {
            return ownName == Self.trimmed(name)
                && Self.trimmed(self.model).caseInsensitiveCompare(Self.trimmed(model)) == .orderedSame
        }
        let ownAddress = Self.trimmed(self.address)
        return !ownAddress.isEmpty && ownAddress == Self.trimmed(address)
    }

    func matches(_ console: DiscoveredMixer) -> Bool {
        matches(
            kind: console.kind,
            name: console.name,
            model: console.model,
            serial: console.serial,
            address: console.address
        )
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A console that answered a network scan.
struct DiscoveredMixer: Equatable, Identifiable {
    var kind: MixerKind
    var address: String
    var name: String
    var model: String
    var serial: String
    var firmware: String

    /// One entry per console: a WING answers with its serial number, which stays
    /// the same when its address changes; other consoles are told apart by address.
    var id: String {
        let key = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        return kind.rawValue + "|" + (key.isEmpty ? address : key)
    }
}

struct MixerSettings: Codable, Equatable {
    var kind: MixerKind = .none
    /// Empty means the console is found automatically on the network. An
    /// address takes precedence over `preferredConsole`.
    var address = ""
    /// The console chosen from the network, always of type `kind`. Nil connects
    /// to the first console found.
    var preferredConsole: PreferredMixer?
    /// Only the choices the user changed, by `MixerKind.rawValue` and section
    /// identifier; other sections keep their default. Consoles share section
    /// identifiers such as `ch`, so each console type keeps its own choices.
    /// String keys keep the choices of console types from a newer version.
    private(set) var sectionVisibilityByKind: [String: [String: Bool]] = [:]

    private enum CodingKeys: String, CodingKey {
        case kind
        case address
        case preferredConsole
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
        // Missing before console selection, and unreadable or of another type
        // only drops the selection.
        if let preferred = try? container.decodeIfPresent(
            PreferredMixer.self,
            forKey: .preferredConsole
        ), preferred.kind == kind {
            preferredConsole = preferred
        }
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
        try container.encodeIfPresent(preferredConsole, forKey: .preferredConsole)
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

    /// The only console discovery may connect to: the selected one, unless an
    /// address is entered, which takes precedence.
    var connectionTarget: PreferredMixer? {
        guard connectionAddress == nil,
              let preferredConsole,
              preferredConsole.kind == kind else { return nil }
        return preferredConsole
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
    /// Fresh analyzer levels; nil when the analyzer is not requested or its
    /// data stopped arriving, even while other meters still arrive.
    var rta: MixerRTAFrame?
    /// What the analyzer measures, nil when it is not requested.
    var rtaInfo: MixerRTAInfo?
}

/// Levels of the console's real-time analyzer in dB, one per band, in the
/// order of `MixerKind.rtaBandFrequencies`.
struct MixerRTAFrame: Equatable {
    var levels: [Float]
}

/// The analyzer settings as the console reports them. They are chosen on the
/// console and only ever read. A part is nil until the console reports a
/// value it can be shown for.
struct MixerRTAInfo: Equatable {
    var source: String?
    /// The console reports that no source is selected.
    var sourceIsNone = false
    /// Where in the source the analyzer listens, such as before the equalizer.
    var tap: String?
    var detector: String?
}

/// One connection attempt to one console. Every method returns immediately and
/// nothing may change the console's state: this feature only ever reads meters
/// and settings.
protocol MixerDriver: AnyObject {
    /// - Parameters:
    ///   - address: The console's address, or nil for discovery.
    ///   - target: With discovery, the only console that may be connected;
    ///     nil connects to the first console found.
    ///   - includeRTA: Whether to also read the console's real-time analyzer.
    func start(
        address: String?,
        target: PreferredMixer?,
        sections: [MixerMeterSectionDescriptor],
        includeRTA: Bool
    )
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

/// Holds each bar's highest level for `holdDuration`, then lets it fall to the
/// current level. Not thread-safe; used from one queue.
struct MixerPeakHold {
    static let holdDuration: TimeInterval = 3

    private struct Peak {
        var level: Float
        var time: TimeInterval
    }

    private var peaks: [String: [Peak]] = [:]

    /// Returns the held peaks in the same shape as `levels`.
    mutating func update(_ levels: [String: [Float]], now: TimeInterval) -> [String: [Float]] {
        var updated: [String: [Peak]] = [:]
        var result: [String: [Float]] = [:]
        for (id, sectionLevels) in levels {
            let previous = peaks[id]
            var sectionPeaks: [Peak] = []
            sectionPeaks.reserveCapacity(sectionLevels.count)
            for (index, level) in sectionLevels.enumerated() {
                var peak = Peak(level: level, time: now)
                if let previous, index < previous.count {
                    let held = previous[index]
                    if !(level >= held.level), now - held.time < Self.holdDuration {
                        peak = held
                    }
                }
                sectionPeaks.append(peak)
            }
            updated[id] = sectionPeaks
            result[id] = sectionPeaks.map(\.level)
        }
        peaks = updated
        return result
    }

    mutating func reset() {
        peaks = [:]
    }
}

/// Latest levels, written by the connection queue and read while drawing.
final class MixerLevelStore: @unchecked Sendable {
    private let lock = NSLock()
    private var levels: [String: [Float]] = [:]
    private var peakLevels: [String: [Float]] = [:]
    private var rtaLevels: [Float] = []

    /// - Parameter peaks: Held peaks in the same shape as the levels.
    func replace(_ newLevels: [String: [Float]], peaks newPeaks: [String: [Float]] = [:]) {
        lock.lock()
        levels = newLevels
        peakLevels = newPeaks
        lock.unlock()
    }

    func snapshot() -> [String: [Float]] {
        lock.lock()
        defer { lock.unlock() }
        return levels
    }

    /// Levels and their held peaks from the same moment.
    func snapshotWithPeaks() -> (levels: [String: [Float]], peaks: [String: [Float]]) {
        lock.lock()
        defer { lock.unlock() }
        return (levels, peakLevels)
    }

    /// Analyzer levels in dB, empty when there are none to show.
    func replaceRTA(_ newLevels: [Float]) {
        lock.lock()
        rtaLevels = newLevels
        lock.unlock()
    }

    func rtaSnapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return rtaLevels
    }
}
