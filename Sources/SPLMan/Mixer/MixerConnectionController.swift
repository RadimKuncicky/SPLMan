import Foundation

/// Keeps one configured console connected without involving the user: it starts
/// on its own, watches the meter data, and quietly retries after any failure.
/// Time is passed in, and every call must come from the same queue.
final class MixerConnectionController {
    enum Phase: Equatable {
        case disabled
        /// A console is configured, but every meter bridge section is hidden.
        case noSectionsSelected
        /// The address cannot be used; nothing is retried until it changes.
        case invalidAddress
        case connecting
        case connected(MixerIdentity)
        case waitingToRetry

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        /// Whether the controller needs regular ticks.
        var isActive: Bool {
            switch self {
            case .connecting, .connected, .waitingToRetry: true
            case .disabled, .noSectionsSelected, .invalidAddress: false
            }
        }
    }

    struct Timing {
        var retryDelay: TimeInterval = 5
        /// Covers discovery, which takes up to 5 s, and a slow connection.
        var attemptTimeout: TimeInterval = 20
        /// Consoles send meters many times per second and drivers renew them well
        /// before they expire, so 5 s of silence means a lost console.
        var meterDataTimeout: TimeInterval = 5
        /// Bars must not stay frozen at the last level while the data is missing.
        var staleLevelsAfter: TimeInterval = 1
    }

    private(set) var phase: Phase = .disabled
    private(set) var sections: [MixerBridgeSection] = []
    private(set) var levels: [String: [Float]] = [:]

    private let timing: Timing
    private let makeDriver: (MixerKind) -> MixerDriver?
    private var driver: MixerDriver?
    private var settings = MixerSettings()
    private var descriptors: [MixerMeterSectionDescriptor] = []
    private var stripCounts: [String: Int] = [:]
    private var names: [String: [Int: String]] = [:]
    private var attemptStartedAt: TimeInterval = 0
    private var connectedAt: TimeInterval?
    private var retryAt: TimeInterval = 0

    init(
        timing: Timing = Timing(),
        makeDriver: @escaping (MixerKind) -> MixerDriver? = { $0.makeDriver() }
    ) {
        self.timing = timing
        self.makeDriver = makeDriver
    }

    func configure(_ newSettings: MixerSettings, now: TimeInterval) {
        guard newSettings != settings || phase == .disabled else { return }
        let kindChanged = newSettings.kind != settings.kind
        settings = newSettings
        descriptors = newSettings.visibleSections
        if kindChanged {
            stripCounts = [:]
            names = [:]
        }
        endAttempt()
        rebuildSections()
        if newSettings.kind == .none {
            phase = .disabled
        } else if descriptors.isEmpty {
            phase = .noSectionsSelected
        } else if !newSettings.kind.isValidAddress(newSettings.connectionAddress) {
            phase = .invalidAddress
        } else {
            beginAttempt(now: now)
        }
    }

    func tick(now: TimeInterval) {
        switch phase {
        case .disabled, .noSectionsSelected, .invalidAddress:
            return
        case .waitingToRetry:
            if now >= retryAt { beginAttempt(now: now) }
        case .connecting, .connected:
            guard let driver else {
                scheduleRetry(now: now)
                return
            }
            apply(driver.poll(), now: now)
        }
    }

    func shutdown() {
        endAttempt()
        phase = .disabled
    }

    private func apply(_ update: MixerDriverUpdate, now: TimeInterval) {
        switch update.state {
        case .failed:
            scheduleRetry(now: now)
            return
        case .connecting:
            if now - attemptStartedAt >= timing.attemptTimeout {
                scheduleRetry(now: now)
            }
            return
        case .connected(let identity):
            let connectedAt = self.connectedAt ?? now
            self.connectedAt = connectedAt
            let silence = update.secondsSinceMeterData ?? (now - connectedAt)
            if silence >= timing.meterDataTimeout {
                scheduleRetry(now: now)
                return
            }
            phase = .connected(identity)
            levels = silence >= timing.staleLevelsAfter ? [:] : update.levels
            merge(update)
        }
    }

    private func merge(_ update: MixerDriverUpdate) {
        var changed = false
        for (section, count) in update.stripCounts where stripCounts[section] != count {
            stripCounts[section] = count
            changed = true
        }
        for (section, sectionNames) in update.names {
            for (strip, name) in sectionNames where names[section]?[strip] != name {
                names[section, default: [:]][strip] = name
                changed = true
            }
        }
        if changed { rebuildSections() }
    }

    private func rebuildSections() {
        sections = descriptors.map { descriptor in
            let count = descriptor.stripCount ?? stripCounts[descriptor.id] ?? 0
            return MixerBridgeSection(
                id: descriptor.id,
                shortTitle: descriptor.shortTitle,
                strips: (0..<count).map { strip in
                    MixerBridgeStrip(
                        number: strip + 1,
                        name: names[descriptor.id]?[strip] ?? "",
                        barCount: descriptor.barsPerStrip
                    )
                }
            )
        }
    }

    private func beginAttempt(now: TimeInterval) {
        guard let driver = makeDriver(settings.kind) else {
            phase = .disabled
            return
        }
        self.driver = driver
        attemptStartedAt = now
        connectedAt = nil
        phase = .connecting
        driver.start(address: settings.connectionAddress, sections: descriptors)
    }

    private func scheduleRetry(now: TimeInterval) {
        endAttempt()
        retryAt = now + timing.retryDelay
        phase = .waitingToRetry
    }

    private func endAttempt() {
        driver?.stop()
        driver = nil
        connectedAt = nil
        levels = [:]
    }
}
