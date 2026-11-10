import Combine
import Foundation

/// Runs the console connection on its own queue, so neither blocking network
/// work nor meter traffic can affect the audio measurement or the main thread.
/// Levels go straight to `levels`; only rare changes reach SwiftUI.
final class MixerBridgeModel: ObservableObject {
    @Published private(set) var phase: MixerConnectionController.Phase = .disabled
    @Published private(set) var sections: [MixerBridgeSection] = []
    /// The selected console that discovery waits for, nil when any console
    /// found, or the entered address, is used.
    @Published private(set) var target: PreferredMixer?
    /// What the console's analyzer measures, while it is wanted and connected.
    @Published private(set) var rtaInfo: MixerRTAInfo?
    /// The analyzer is wanted, but the connected console does not send its
    /// data. The levels themselves are in `levels`.
    @Published private(set) var isRTAMissing = false

    let levels = MixerLevelStore()

    private static let pollInterval: TimeInterval = 1.0 / 30.0

    private let queue = DispatchQueue(label: "cz.splman.mixer", qos: .userInitiated)
    private let controller = MixerConnectionController()
    private var timer: DispatchSourceTimer?
    private var peakHold = MixerPeakHold()
    private var publishedPhase: MixerConnectionController.Phase = .disabled
    private var publishedSections: [MixerBridgeSection] = []
    private var currentTarget: PreferredMixer?
    private var publishedTarget: PreferredMixer?
    private var publishedRTAInfo: MixerRTAInfo?
    private var publishedIsRTAMissing = false

    /// - Parameter includeRTA: Whether to also read the console's real-time analyzer.
    func apply(_ settings: MixerSettings, includeRTA: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            self.controller.configure(settings, includeRTA: includeRTA, now: Self.now)
            self.currentTarget = settings.connectionTarget
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
            peakHold.reset()
            levels.replace([:])
            levels.replaceRTA([])
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
        peakHold.reset()
        levels.replace([:])
        levels.replaceRTA([])
    }

    private func tick() {
        controller.tick(now: Self.now)
        publishChanges()
    }

    private func publishChanges() {
        let currentLevels = controller.levels
        levels.replace(currentLevels, peaks: peakHold.update(currentLevels, now: Self.now))
        let rtaLevels = controller.rta?.levels ?? []
        levels.replaceRTA(rtaLevels)
        let phase = controller.phase
        let sections = controller.sections
        let target = currentTarget
        let rtaInfo = controller.rtaInfo
        let isRTAMissing = controller.isRTAMissing
        guard phase != publishedPhase
            || sections != publishedSections
            || target != publishedTarget
            || rtaInfo != publishedRTAInfo
            || isRTAMissing != publishedIsRTAMissing else { return }
        publishedPhase = phase
        publishedSections = sections
        publishedTarget = target
        publishedRTAInfo = rtaInfo
        publishedIsRTAMissing = isRTAMissing
        DispatchQueue.main.async { [weak self] in
            self?.phase = phase
            self?.sections = sections
            self?.target = target
            self?.rtaInfo = rtaInfo
            self?.isRTAMissing = isRTAMissing
        }
    }
}
