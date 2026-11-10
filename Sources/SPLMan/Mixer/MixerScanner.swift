import Combine
import Foundation
import WingKit
import X32Kit

extension DiscoveredMixer {
    init(wing info: WingConsoleInfo) {
        self.init(
            kind: .behringerWing,
            address: info.ip,
            name: info.name,
            model: info.model,
            serial: info.serial,
            firmware: info.firmware
        )
    }

    /// The sender is the address the connection uses, so it is the one shown.
    init(x32 info: X32ConsoleInfo, sender: String) {
        self.init(
            kind: .behringerX32,
            address: sender,
            name: info.name,
            model: info.model,
            serial: "",
            firmware: info.firmware
        )
    }
}

/// The consoles that answered a scan lately, one entry per console. A console
/// that stops answering, for example because it was switched off, is dropped.
/// Time is passed in.
struct MixerScanList {
    /// Scans repeat every 2 s, so this tolerates several lost replies.
    static let lifetime: TimeInterval = 10
    /// Far more than any rig. Anyone on the network can answer, so forged
    /// replies must not grow the list without end.
    static let maximumConsoles = 32

    private struct Entry {
        var console: DiscoveredMixer
        var seenAt: TimeInterval
    }

    private var entries: [String: Entry] = [:]

    mutating func record(_ console: DiscoveredMixer, now: TimeInterval) {
        prune(now: now)
        guard entries[console.id] != nil || entries.count < Self.maximumConsoles else { return }
        entries[console.id] = Entry(console: console, seenAt: now)
    }

    mutating func prune(now: TimeInterval) {
        entries = entries.filter { now - $0.value.seenAt < Self.lifetime }
    }

    /// Sorted by console type, name and address, so rows do not jump around.
    var consoles: [DiscoveredMixer] {
        entries.values.map(\.console).sorted { first, second in
            if first.kind != second.kind {
                let order = MixerKind.allCases
                return (order.firstIndex(of: first.kind) ?? 0) < (order.firstIndex(of: second.kind) ?? 0)
            }
            let byName = first.name.localizedStandardCompare(second.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return first.address < second.address
        }
    }
}

/// Lists every supported console on the network while Settings shows the
/// console page. It asks on its own sockets and queue and never connects, so the
/// meter bridge connection is not affected. Call `start` and `stop` from the
/// main thread; `consoles` changes there.
final class MixerScanner: ObservableObject {
    @Published private(set) var consoles: [DiscoveredMixer] = []

    private static let probeInterval: TimeInterval = 2

    private let queue = DispatchQueue(label: "cz.splman.mixer.scan", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var wingScanner: WingScanner?
    private var x32Scanner: X32Scanner?
    private var list = MixerScanList()
    private var published: [DiscoveredMixer] = []

    deinit { timer?.cancel() }

    func start() {
        queue.async { [weak self] in
            self?.begin()
        }
    }

    /// Forgets the found consoles, so a later scan does not show stale ones.
    func stop() {
        queue.async { [weak self] in
            self?.end()
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func begin() {
        guard timer == nil else { return }
        wingScanner = WingScanner(queue: queue) { [weak self] info in
            self?.found(DiscoveredMixer(wing: info))
        }
        x32Scanner = X32Scanner(queue: queue) { [weak self] info, sender in
            self?.found(DiscoveredMixer(x32: info, sender: sender))
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.probeInterval)
        timer.setEventHandler { [weak self] in
            self?.probe()
        }
        timer.resume()
        self.timer = timer
    }

    private func end() {
        timer?.cancel()
        timer = nil
        wingScanner?.stop()
        wingScanner = nil
        x32Scanner?.stop()
        x32Scanner = nil
        list = MixerScanList()
        publish()
    }

    private func probe() {
        wingScanner?.probe()
        x32Scanner?.probe()
        list.prune(now: Self.now)
        publish()
    }

    private func found(_ console: DiscoveredMixer) {
        guard timer != nil else { return }
        list.record(console, now: Self.now)
        publish()
    }

    /// Updates reach the main thread in the order they were made, so the empty
    /// list of `stop` is never overtaken by an older one.
    private func publish() {
        let consoles = list.consoles
        guard consoles != published else { return }
        published = consoles
        DispatchQueue.main.async { [weak self] in
            self?.consoles = consoles
        }
    }
}
