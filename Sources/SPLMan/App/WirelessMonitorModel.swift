import Combine
import Foundation
import ShureKit

/// Runs discovery and the receiver connections on its own queue, so neither
/// blocking network work nor meter traffic can affect the audio measurement or
/// the main thread. Levels go straight to `levels`; only rare changes reach SwiftUI.
final class WirelessMonitorModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var receivers: [WirelessReceiverStatus] = []
    @Published private(set) var channels: [WirelessChannel] = []
    @Published private(set) var isScanning = false

    let levels = MixerLevelStore()

    private static let pollInterval: TimeInterval = 1.0 / 15.0
    private static let ticksPerDiscoveryUpdate = 15
    /// Receivers advertise about every 2 s, so this tolerates many lost datagrams.
    private static let advertisementLifetime: TimeInterval = 30

    private let queue = DispatchQueue(label: "cz.splman.wireless", qos: .userInitiated)
    private let controller = WirelessMonitorController()
    private let discovery = ShureDiscovery()
    private let scanner = ShureNetworkScanner()
    private var timer: DispatchSourceTimer?
    private var ticksSinceDiscoveryUpdate = 0
    private var publishedEnabled = false
    private var publishedReceivers: [WirelessReceiverStatus] = []
    private var publishedChannels: [WirelessChannel] = []
    private var publishedScanning = false

    func apply(_ settings: WirelessSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            self.controller.configure(settings, now: Self.now)
            if settings.isEnabled {
                self.discovery.start()
                self.startTimer()
                self.updateDiscovered()
            } else {
                self.discovery.stop()
                self.scanner.stop()
                self.stopTimer()
            }
            self.publishChanges()
        }
    }

    /// Runs only on the user's request: it connects to every neighbor on the network.
    func scanNetwork() {
        queue.async { [weak self] in
            guard let self, self.controller.isEnabled else { return }
            self.scanner.start()
            self.publishChanges()
        }
    }

    func shutdown() {
        queue.sync {
            stopTimer()
            discovery.stop()
            scanner.stop()
            controller.shutdown()
            levels.replace([:])
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        levels.replace([:])
    }

    private func tick() {
        ticksSinceDiscoveryUpdate += 1
        if ticksSinceDiscoveryUpdate >= Self.ticksPerDiscoveryUpdate {
            ticksSinceDiscoveryUpdate = 0
            updateDiscovered()
        }
        controller.tick(now: Self.now)
        publishChanges()
    }

    private func updateDiscovered() {
        var addresses = Set(scanner.snapshot().addresses)
        for receiver in discovery.snapshot()
        where receiver.secondsSinceSeen < Self.advertisementLifetime {
            addresses.insert(receiver.address)
        }
        controller.setDiscovered(addresses, now: Self.now)
    }

    private func publishChanges() {
        levels.replace(controller.levels)
        let isEnabled = controller.isEnabled
        let receivers = controller.receivers
        let channels = controller.channels
        let isScanning = scanner.snapshot().isScanning
        guard isEnabled != publishedEnabled
                || receivers != publishedReceivers
                || channels != publishedChannels
                || isScanning != publishedScanning else { return }
        publishedEnabled = isEnabled
        publishedReceivers = receivers
        publishedChannels = channels
        publishedScanning = isScanning
        DispatchQueue.main.async { [weak self] in
            self?.isEnabled = isEnabled
            self?.receivers = receivers
            self?.channels = channels
            self?.isScanning = isScanning
        }
    }
}
