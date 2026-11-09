import Foundation

/// Keeps every known receiver connected without involving the user: receivers
/// come from the settings and from discovery, and each one quietly retries after
/// any failure. Time is passed in, and every call must come from the same queue.
final class WirelessMonitorController {
    struct Timing {
        var retryDelay: TimeInterval = 5
        /// A model that cannot be read will not change soon.
        var unsupportedRetryDelay: TimeInterval = 60
        var attemptTimeout: TimeInterval = 10
        /// Levels are requested several times per second, so 5 s without any
        /// reply means a lost receiver.
        var dataTimeout: TimeInterval = 5
        /// Bars must not stay frozen at the last level while the data is missing.
        var staleLevelsAfter: TimeInterval = 1
    }

    private final class Slot {
        let address: String
        var driver: WirelessDriver?
        var phase = WirelessReceiverPhase.connecting
        var attemptStartedAt: TimeInterval = 0
        var connectedAt: TimeInterval?
        var retryAt: TimeInterval = 0
        var model = ""
        var deviceName = ""
        var readings: [WirelessChannelReading] = []
        var hasFreshLevels = false

        init(address: String) {
            self.address = address
        }
    }

    private(set) var isEnabled = false
    private(set) var receivers: [WirelessReceiverStatus] = []
    private(set) var channels: [WirelessChannel] = []
    /// By channel identifier, with the values at the positions `WirelessChannel` names.
    private(set) var levels: [String: [Float]] = [:]

    private let timing: Timing
    private let makeDriver: () -> WirelessDriver
    private var slots: [String: Slot] = [:]
    private var manualAddresses: Set<String> = []
    private var discoveredAddresses: Set<String> = []

    init(
        timing: Timing = Timing(),
        makeDriver: @escaping () -> WirelessDriver = { ShureWirelessDriver() }
    ) {
        self.timing = timing
        self.makeDriver = makeDriver
    }

    func configure(_ settings: WirelessSettings, now: TimeInterval) {
        isEnabled = settings.isEnabled
        let newManual = settings.isEnabled ? Set(settings.manualAddresses) : []
        let removed = manualAddresses.subtracting(newManual)
        manualAddresses = newManual
        if !settings.isEnabled {
            discoveredAddresses = []
            for address in Array(slots.keys) {
                removeSlot(address)
            }
        }
        // Removing an address is a request to stop, even from a working receiver.
        for address in removed where !discoveredAddresses.contains(address) {
            removeSlot(address)
        }
        reconcile(now: now)
        rebuild()
    }

    /// A receiver that stops being advertised but still answers stays connected.
    func setDiscovered(_ addresses: Set<String>, now: TimeInterval) {
        guard isEnabled, addresses != discoveredAddresses else { return }
        discoveredAddresses = addresses
        reconcile(now: now)
        rebuild()
    }

    func tick(now: TimeInterval) {
        guard isEnabled else { return }
        for slot in slots.values {
            switch slot.phase {
            case .unsupported, .unavailable:
                if now >= slot.retryAt { beginAttempt(slot, now: now) }
            case .connecting, .connected:
                guard let driver = slot.driver else {
                    scheduleRetry(slot, delay: timing.retryDelay, now: now)
                    continue
                }
                apply(driver.poll(), to: slot, now: now)
            }
        }
        // A slot that just lost its receiver may no longer be wanted at all.
        for slot in Array(slots.values) where slot.phase != .connected && !isWanted(slot.address) {
            removeSlot(slot.address)
        }
        rebuild()
    }

    func shutdown() {
        for address in Array(slots.keys) {
            removeSlot(address)
        }
        isEnabled = false
        manualAddresses = []
        discoveredAddresses = []
        rebuild()
    }

    private func isWanted(_ address: String) -> Bool {
        manualAddresses.contains(address) || discoveredAddresses.contains(address)
    }

    private func reconcile(now: TimeInterval) {
        for slot in Array(slots.values) where slot.phase != .connected && !isWanted(slot.address) {
            removeSlot(slot.address)
        }
        for address in manualAddresses.union(discoveredAddresses) where slots[address] == nil {
            let slot = Slot(address: address)
            slots[address] = slot
            beginAttempt(slot, now: now)
        }
    }

    private func removeSlot(_ address: String) {
        slots[address]?.driver?.stop()
        slots[address] = nil
    }

    private func beginAttempt(_ slot: Slot, now: TimeInterval) {
        let driver = makeDriver()
        slot.driver = driver
        slot.attemptStartedAt = now
        slot.connectedAt = nil
        slot.phase = .connecting
        driver.start(address: slot.address)
    }

    private func scheduleRetry(_ slot: Slot, delay: TimeInterval, now: TimeInterval) {
        slot.driver?.stop()
        slot.driver = nil
        slot.connectedAt = nil
        slot.hasFreshLevels = false
        slot.retryAt = now + delay
        slot.phase = .unavailable
    }

    private func apply(_ update: WirelessDriverUpdate, to slot: Slot, now: TimeInterval) {
        switch update.state {
        case .failed:
            scheduleRetry(slot, delay: timing.retryDelay, now: now)
        case .unsupported:
            slot.model = update.model
            scheduleRetry(slot, delay: timing.unsupportedRetryDelay, now: now)
            slot.phase = .unsupported
        case .connecting:
            if now - slot.attemptStartedAt >= timing.attemptTimeout {
                scheduleRetry(slot, delay: timing.retryDelay, now: now)
            }
        case .connected:
            let connectedAt = slot.connectedAt ?? now
            slot.connectedAt = connectedAt
            let silence = update.secondsSinceData ?? (now - connectedAt)
            if silence >= timing.dataTimeout {
                scheduleRetry(slot, delay: timing.retryDelay, now: now)
                return
            }
            slot.phase = .connected
            slot.model = update.model
            slot.deviceName = update.deviceName
            slot.readings = update.channels
            slot.hasFreshLevels = silence < timing.staleLevelsAfter
        }
    }

    private func rebuild() {
        let ordered = slots.values.sorted {
            $0.address.compare($1.address, options: .numeric) == .orderedAscending
        }
        receivers = ordered.map { slot in
            WirelessReceiverStatus(
                address: slot.address,
                model: slot.model,
                name: slot.deviceName,
                phase: slot.phase
            )
        }
        var newChannels: [WirelessChannel] = []
        var newLevels: [String: [Float]] = [:]
        for slot in ordered {
            // After a lost connection the channels stay listed, because a
            // microphone that disappears is exactly what must be noticed.
            let isOnline = slot.phase == .connected
            for reading in slot.readings {
                let id = "\(slot.address)#\(reading.number)"
                newChannels.append(WirelessChannel(
                    id: id,
                    number: reading.number,
                    name: Self.displayName(reading, in: slot),
                    isOnline: isOnline,
                    batteryBars: isOnline ? reading.batteryBars : nil,
                    batteryMinutes: isOnline ? reading.batteryMinutes : nil,
                    transmitterModel: isOnline ? reading.transmitterModel : nil
                ))
                if isOnline, slot.hasFreshLevels {
                    newLevels[id] = [
                        Float(reading.audioLevelDB ?? -.infinity),
                        Float(reading.rfLevelDBm ?? -.infinity)
                    ]
                }
            }
        }
        channels = newChannels
        levels = newLevels
    }

    private static func displayName(_ reading: WirelessChannelReading, in slot: Slot) -> String {
        if !reading.name.isEmpty { return reading.name }
        let receiver = slot.deviceName.isEmpty ? slot.model : slot.deviceName
        return slot.readings.count > 1 ? "\(receiver) \(reading.number)" : receiver
    }
}
