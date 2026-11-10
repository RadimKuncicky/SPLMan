import Foundation
import X32Kit

/// How one meter bridge section maps to the values of an X32 meter page.
struct X32MeterDefinition {
    let descriptor: MixerMeterSectionDescriptor
    let page: Int
    let firstValue: Int
    /// Name parameter of each strip, in strip order.
    let nameAddresses: [String]

    private var valueCount: Int {
        (descriptor.stripCount ?? 0) * descriptor.barsPerStrip
    }

    /// Converts linear values, with 1.0 at full scale, to dB. Silence becomes
    /// negative infinity, which the bridge draws as an empty bar.
    func levels(from page: [Float]) -> [Float]? {
        guard firstValue + valueCount <= page.count else { return nil }
        return page[firstValue..<(firstValue + valueCount)].map {
            $0 > 0 ? 20 * log10($0) : -Float.infinity
        }
    }
}

/// Adapts `X32Client` to the application's generic mixer layer. X32 strips are
/// mono, with the exception of main LR and the effect returns.
final class X32MixerDriver: MixerDriver {
    static let definitions: [X32MeterDefinition] = {
        // Page 0: 32 channels, 8 aux returns, 8 effect returns, 16 buses, 6 matrices.
        // Page 2: 16 buses, 6 matrices, main L and R, mono, then gain reductions.
        // Page 3: 6 aux sends, then aux and effect returns.
        // Page 4: 32 channels, 8 aux returns, 16 outputs, 16 P16 outputs,
        // 6 aux sends, 2 AES outputs, 2 monitor outputs.
        [
            section(
                "ch",
                L10n.text("Kanály"),
                "CH",
                page: 0,
                first: 0,
                strips: 32,
                nameAddresses: numbered("/ch", through: 32)
            ),
            section(
                "auxin",
                L10n.format("Vstupy %@", "AUX"),
                "AUX IN",
                page: 0,
                first: 32,
                strips: 8,
                nameAddresses: numbered("/auxin", through: 8)
            ),
            section(
                "fxrtn",
                L10n.format("Vstupy %@", "FX"),
                "FX",
                page: 0,
                first: 40,
                strips: 4,
                bars: 2,
                nameAddresses: stride(from: 1, through: 7, by: 2).map {
                    numberedName("/fxrtn", $0)
                }
            ),
            section(
                "bus",
                L10n.text("Busy"),
                "BUS",
                page: 0,
                first: 48,
                strips: 16,
                nameAddresses: numbered("/bus", through: 16)
            ),
            section(
                "mtx",
                L10n.text("Matrix"),
                "MTX",
                page: 0,
                first: 64,
                strips: 6,
                nameAddresses: numbered("/mtx", through: 6)
            ),
            section(
                "main",
                L10n.text("Main"),
                "MAIN",
                page: 2,
                first: 22,
                strips: 1,
                bars: 2,
                nameAddresses: ["/main/st/config/name"]
            ),
            section(
                "mono",
                "M/C",
                "M/C",
                page: 2,
                first: 24,
                strips: 1,
                nameAddresses: ["/main/m/config/name"]
            ),
            section(
                "auxout",
                L10n.format("Výstupy %@", "AUX"),
                "AUX OUT",
                page: 3,
                first: 0,
                strips: 6,
                isVisibleByDefault: false
            ),
            section(
                "out",
                L10n.format("Výstupy %@", "1–16"),
                "OUT",
                page: 4,
                first: 40,
                strips: 16
            ),
            section(
                "p16",
                L10n.format("Výstupy %@", "P16"),
                "P16",
                page: 4,
                first: 56,
                strips: 16,
                isVisibleByDefault: false
            ),
            section(
                "aes",
                L10n.format("Výstupy %@", "AES"),
                "AES",
                page: 4,
                first: 78,
                strips: 2,
                isVisibleByDefault: false
            ),
            section(
                "mon",
                L10n.format("Výstupy %@", "MON"),
                "MON",
                page: 4,
                first: 80,
                strips: 2,
                isVisibleByDefault: false
            )
        ]
    }()

    /// Levels of a page this old are not shown, so a page that stopped arriving
    /// does not look live while other pages keep the connection alive.
    private let staleLevelsAfter: TimeInterval
    private var client: X32Client?
    private var active: [X32MeterDefinition] = []
    private var nameTargets: [String: (section: String, strip: Int)] = [:]
    private var namesRevision = 0

    init(staleLevelsAfter: TimeInterval = MixerConnectionController.Timing().staleLevelsAfter) {
        self.staleLevelsAfter = staleLevelsAfter
    }

    /// Levels in dB of every section whose meter page is fresh.
    static func levels(
        for definitions: [X32MeterDefinition],
        pages: [Int: [Float]],
        ages: [Int: TimeInterval],
        staleAfter: TimeInterval
    ) -> [String: [Float]] {
        var levels: [String: [Float]] = [:]
        for definition in definitions {
            guard let age = ages[definition.page],
                  age < staleAfter,
                  let page = pages[definition.page],
                  let sectionLevels = definition.levels(from: page) else { continue }
            levels[definition.descriptor.id] = sectionLevels
        }
        return levels
    }

    /// Accepts only the `/xinfo` reply of the selected console, with the
    /// reply's sender as its address; nil accepts the first console that answers.
    static func discoveryFilter(
        for target: PreferredMixer?
    ) -> ((X32ConsoleInfo, String) -> Bool)? {
        guard let target else { return nil }
        return { info, sender in
            target.matches(
                kind: .behringerX32,
                name: info.name,
                model: info.model,
                serial: "",
                address: sender
            )
        }
    }

    func start(
        address: String?,
        target: PreferredMixer?,
        sections: [MixerMeterSectionDescriptor]
    ) {
        stop()
        let requested = Set(sections.map(\.id))
        active = Self.definitions.filter { requested.contains($0.descriptor.id) }
        nameTargets = [:]
        for definition in active {
            for (strip, address) in definition.nameAddresses.enumerated() {
                nameTargets[address] = (definition.descriptor.id, strip)
            }
        }
        let client = X32Client(
            address: address,
            meterPages: Array(Set(active.map(\.page))).sorted(),
            nameAddresses: active.flatMap(\.nameAddresses),
            discoveryFilter: address == nil ? Self.discoveryFilter(for: target) : nil
        )
        self.client = client
        client.start()
    }

    func poll() -> MixerDriverUpdate {
        guard let client else { return MixerDriverUpdate(state: .failed) }
        let snapshot = client.snapshot()
        switch snapshot.state {
        case .connecting:
            return MixerDriverUpdate(state: .connecting)
        case .failed:
            return MixerDriverUpdate(state: .failed)
        case .connected:
            break
        }

        var update = MixerDriverUpdate(
            state: .connected(MixerIdentity(
                address: snapshot.address ?? "",
                name: snapshot.name.isEmpty ? snapshot.model : snapshot.name,
                model: snapshot.model,
                firmware: snapshot.firmware
            )),
            secondsSinceMeterData: snapshot.secondsSinceMeterData,
            levels: Self.levels(
                for: active,
                pages: snapshot.meterPages,
                ages: snapshot.secondsSinceMeterPage,
                staleAfter: staleLevelsAfter
            )
        )

        if snapshot.namesRevision != namesRevision {
            namesRevision = snapshot.namesRevision
            for (address, target) in nameTargets {
                if let name = snapshot.names[address] {
                    update.names[target.section, default: [:]][target.strip] = name
                }
            }
        }
        return update
    }

    func stop() {
        client?.stop()
        client = nil
        namesRevision = 0
    }

    private static func section(
        _ id: String,
        _ title: String,
        _ shortTitle: String,
        page: Int,
        first: Int,
        strips: Int,
        bars: Int = 1,
        isVisibleByDefault: Bool = true,
        nameAddresses: [String] = []
    ) -> X32MeterDefinition {
        X32MeterDefinition(
            descriptor: MixerMeterSectionDescriptor(
                id: id,
                title: title,
                shortTitle: shortTitle,
                stripCount: strips,
                barsPerStrip: bars,
                isVisibleByDefault: isVisibleByDefault
            ),
            page: page,
            firstValue: first,
            nameAddresses: nameAddresses
        )
    }

    private static func numbered(_ prefix: String, through count: Int) -> [String] {
        (1...count).map { numberedName(prefix, $0) }
    }

    private static func numberedName(_ prefix: String, _ number: Int) -> String {
        prefix + "/" + String(format: "%02d", number) + "/config/name"
    }
}
