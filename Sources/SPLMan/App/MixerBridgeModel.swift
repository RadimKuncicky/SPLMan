import Combine
import Foundation

/// Runs the console connection on its own queue, so neither blocking network
/// work nor meter traffic can affect the audio measurement or the main thread.
/// Levels go straight to `levels`; only rare changes reach SwiftUI.
final class MixerBridgeModel: ObservableObject {
    @Published private(set) var phase: MixerConnectionController.Phase = .disabled
    @Published private(set) var sections: [MixerBridgeSection] = []

    let levels = MixerLevelStore()

    private static let pollInterval: TimeInterval = 1.0 / 30.0

    private let queue = DispatchQueue(label: "cz.splman.mixer", qos: .userInitiated)
    private let controller = MixerConnectionController()
    private var timer: DispatchSourceTimer?
    private var publishedPhase: MixerConnectionController.Phase = .disabled
    private var publishedSections: [MixerBridgeSection] = []

    func apply(_ settings: MixerSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            self.controller.configure(settings, now: Self.now)
            if self.controller.phase.isActive {
                self.startTimer()
            } else {
                self.stopTimer()
            }
            self.publishChanges()
        }
    }

    func shutdown() {
        queue.sync {
            stopTimer()
            controller.shutdown()
            levels.replace([:])
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(5))
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
        controller.tick(now: Self.now)
        publishChanges()
    }

    private func publishChanges() {
        levels.replace(controller.levels)
        let phase = controller.phase
        let sections = controller.sections
        guard phase != publishedPhase || sections != publishedSections else { return }
        publishedPhase = phase
        publishedSections = sections
        DispatchQueue.main.async { [weak self] in
            self?.phase = phase
            self?.sections = sections
        }
    }
}
