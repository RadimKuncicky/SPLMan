import Foundation

/// Keeps one configured console connected without involving the user: it starts
/// on its own, watches the meter data, and quietly retries after any failure.
/// Time is passed in, and every call must come from the same queue.
final class MixerConnectionController {
    enum Phase: Equatable {
        case disabled
        /// A console is configured, but every meter bridge section is hidden
        /// and the analyzer is not wanted.
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
        /// Drivers learn at connection time which analyzer data a console sends,
        /// so analyzer data missing this long while other meters arrive makes
        /// the connection start again.
        var rtaMissingRetryAfter: TimeInterval = 15
    }

    private(set) var phase: Phase = .disabled
    private(set) var sections: [MixerBridgeSection] = []
    private(set) var levels: [String: [Float]] = [:]
    /// Nil while the analyzer is not wanted or its data is missing or stale.
    private(set) var rta: MixerRTAFrame?
    private(set) var rtaInfo: MixerRTAInfo?
    /// The analyzer is wanted, but a connected console has not sent its data
    /// for a while, so it is not merely about to arrive.
    private(set) var isRTAMissing = false

    private let timing: Timing
    private let makeDriver: (MixerKind) -> MixerDriver?
    private var driver: MixerDriver?
    private var settings = MixerSettings()
    private var includeRTA = false
    private var descriptors: [MixerMeterSectionDescriptor] = []
    private var stripCounts: [String: Int] = [:]
    private var names: [String: [Int: String]] = [:]
    private var attemptStartedAt: TimeInterval = 0
    private var connectedAt: TimeInterval?
    /// Since when a live connection has delivered no analyzer data.
    private var rtaMissingSince: TimeInterval?
    private var retryAt: TimeInterval = 0

    init(
        timing: Timing = Timing(),
        makeDriver: @escaping (MixerKind) -> MixerDriver? = { $0.makeDriver() }
    ) {
        self.timing = timing
        self.makeDriver = makeDriver
    }

    /// - Parameter includeRTA: Whether to also read the console's real-time
    ///   analyzer. A change restarts the connection, like a section change.
    func configure(_ newSettings: MixerSettings, includeRTA: Bool = false, now: TimeInterval) {
        guard newSettings != settings
            || includeRTA != self.includeRTA
            || phase == .disabled else { return }
        // Names and connector counts belong to one console; retries to the same
        // console keep them, but another console must not show them.
        let consoleChanged = newSettings.kind != settings.kind
            || newSettings.connectionAddress != settings.connectionAddress
            || newSettings.connectionTarget != settings.connectionTarget
        settings = newSettings
        self.includeRTA = includeRTA
        descriptors = newSettings.visibleSections
        if consoleChanged {
            stripCounts = [:]
            names = [:]
        }
        endAttempt()
        rebuildSections()
        if newSettings.kind == .none {
            phase = .disabled
        } else if descriptors.isEmpty, !includeRTA {
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
            let isStale = silence >= timing.staleLevelsAfter
            if includeRTA, !isStale, update.rta == nil {
                let missingSince = rtaMissingSince ?? now
                rtaMissingSince = missingSince
                if now - missingSince >= timing.rtaMissingRetryAfter {
                    scheduleRetry(now: now)
                    return
                }
            } else {
                rtaMissingSince = nil
            }
            phase = .connected(identity)
            levels = isStale ? [:] : update.levels
            rta = isStale || !includeRTA ? nil : update.rta
            rtaInfo = includeRTA ? update.rtaInfo : nil
            // During a full data outage the connection state explains enough.
            isRTAMissing = includeRTA && !isStale && rta == nil
                && now - connectedAt >= timing.staleLevelsAfter
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
        driver.start(
            address: settings.connectionAddress,
            target: settings.connectionTarget,
            sections: descriptors,
            includeRTA: includeRTA
        )
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
        rta = nil
        rtaInfo = nil
        isRTAMissing = false
        rtaMissingSince = nil
    }
}
