import ConsoleSockets
import Foundation
import Network

/// Finds receivers by listening for what they multicast about themselves. It
/// sends nothing. Shure does not document this for third parties, so a receiver
/// that stays silent is found by `ShureNetworkScanner` or by its address instead.
public final class ShureDiscovery {
    public struct Receiver: Equatable {
        public let address: String
        public let model: String
        public let name: String
        public let secondsSinceSeen: TimeInterval
    }

    /// A network that comes up later, or a port that was busy, is picked up here.
    private static let maintenanceInterval: TimeInterval = 15

    private let queue = DispatchQueue(label: "cz.splman.shurekit.discovery", qos: .utility)
    private var listener: MulticastUDPListener?
    private var maintenanceTimer: DispatchSourceTimer?
    private var seen: [String: (advertisement: ShureAdvertisement, at: TimeInterval)] = [:]

    public init() {}

    deinit { tearDown() }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.maintenanceTimer == nil else { return }
            self.maintain()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + Self.maintenanceInterval,
                repeating: Self.maintenanceInterval
            )
            timer.setEventHandler { [weak self] in
                self?.maintain()
            }
            timer.resume()
            self.maintenanceTimer = timer
        }
    }

    public func stop() {
        queue.sync {
            tearDown()
            seen = [:]
        }
    }

    public func snapshot() -> [Receiver] {
        queue.sync {
            let now = ProcessInfo.processInfo.systemUptime
            return seen.map { address, entry in
                Receiver(
                    address: address,
                    model: entry.advertisement.model,
                    name: entry.advertisement.name,
                    secondsSinceSeen: max(0, now - entry.at)
                )
            }
        }
    }

    private func tearDown() {
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        listener?.close()
        listener = nil
    }

    private func maintain() {
        if let listener {
            listener.joinGroup()
            return
        }
        listener = MulticastUDPListener(
            group: ShureAdvertisement.multicastGroup,
            port: ShureAdvertisement.port,
            queue: queue
        ) { [weak self] datagram, sender in
            self?.handle(datagram, from: sender)
        }
    }

    private func handle(_ datagram: [UInt8], from sender: in_addr) {
        guard let advertisement = ShureAdvertisement(datagram: datagram),
              ShureReceiverModel(name: advertisement.model) != nil else { return }
        // The sender is reachable from here, unlike an address inside the
        // advertisement, which may belong to another interface of the receiver.
        seen[ConsoleUDPSocket.text(of: sender)] = (
            advertisement,
            ProcessInfo.processInfo.systemUptime
        )
    }
}

/// Looks for receivers by asking every neighbor on the command port for its
/// model. This connects to other people's devices, so it only ever runs because
/// the user asked for it, and only across the neighborhood of this Mac's own
/// addresses. Only models this library can read are reported.
public final class ShureNetworkScanner {
    public struct Snapshot: Equatable {
        public let isScanning: Bool
        public let addresses: [String]
    }

    private static let simultaneousProbes = 32
    private static let probeTimeout: TimeInterval = 1.5
    /// Keeps a scan to one /24, even on a much larger network.
    private static let widestNetmask: UInt32 = 0xFFFF_FF00

    private final class Probe {
        let address: String
        let connection: NWConnection
        var parser = ShureStreamParser()

        init(address: String, connection: NWConnection) {
            self.address = address
            self.connection = connection
        }
    }

    private let queue = DispatchQueue(label: "cz.splman.shurekit.scanner", qos: .utility)
    private var pending: ArraySlice<String> = []
    private var probes: [ObjectIdentifier: Probe] = [:]
    private var found: Set<String> = []

    public init() {}

    deinit {
        for probe in probes.values {
            probe.connection.stateUpdateHandler = nil
            probe.connection.cancel()
        }
    }

    /// Starts a new scan unless one is running. Earlier results are kept.
    public func start() {
        queue.async { [weak self] in
            guard let self, self.probes.isEmpty, self.pending.isEmpty else { return }
            var addresses: [String] = []
            for interface in ConsoleNetwork.ipv4Interfaces() {
                addresses += Self.hostsToProbe(
                    address: ConsoleUDPSocket.text(of: interface.address),
                    netmask: ConsoleUDPSocket.text(of: interface.netmask)
                )
            }
            var unique = Set<String>()
            self.pending = addresses.filter { unique.insert($0).inserted }[...]
            self.startProbes()
        }
    }

    /// Ends a running scan and forgets what it found.
    public func stop() {
        queue.sync {
            pending = []
            for probe in probes.values {
                probe.connection.stateUpdateHandler = nil
                probe.connection.cancel()
            }
            probes = [:]
            found = []
        }
    }

    public func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(
                isScanning: !probes.isEmpty || !pending.isEmpty,
                addresses: found.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            )
        }
    }

    /// The other addresses of the network, within one /24 at most.
    public static func hostsToProbe(address: String, netmask: String) -> [String] {
        guard let address = ConsoleUDPSocket.ipv4Address(address),
              let netmask = ConsoleUDPSocket.ipv4Address(netmask) else { return [] }
        let own = UInt32(bigEndian: address.s_addr)
        let mask = UInt32(bigEndian: netmask.s_addr) | widestNetmask
        let network = own & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        return ((network + 1)..<broadcast).compactMap { host in
            guard host != own else { return nil }
            return ConsoleUDPSocket.text(of: in_addr(s_addr: host.bigEndian))
        }
    }

    private func startProbes() {
        while probes.count < Self.simultaneousProbes, let address = pending.popFirst() {
            startProbe(of: address)
        }
    }

    private func startProbe(of address: String) {
        guard let port = NWEndpoint.Port(rawValue: ShureProtocol.port) else { return }
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        let connection = NWConnection(
            host: NWEndpoint.Host(address),
            port: port,
            using: NWParameters(tls: nil, tcp: options)
        )
        let probe = Probe(address: address, connection: connection)
        probes[ObjectIdentifier(probe)] = probe
        connection.stateUpdateHandler = { [weak self, weak probe] state in
            guard let self, let probe else { return }
            switch state {
            case .ready:
                connection.send(
                    content: Data(ShureProtocol.modelRequest),
                    completion: .contentProcessed { _ in }
                )
                self.receive(probe)
            case .failed:
                self.finish(probe)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.probeTimeout) { [weak self, weak probe] in
            guard let self, let probe else { return }
            self.finish(probe)
        }
    }

    private func receive(_ probe: Probe) {
        probe.connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) {
            [weak self, weak probe] data, _, isComplete, error in
            guard let self, let probe, self.probes[ObjectIdentifier(probe)] != nil else { return }
            for message in probe.parser.consume(Array(data ?? Data())) {
                if case .model(let name)? = ShureProtocol.deviceReport(from: message) {
                    if ShureReceiverModel(name: name) != nil {
                        self.found.insert(probe.address)
                    }
                    self.finish(probe)
                    return
                }
            }
            if isComplete || error != nil {
                self.finish(probe)
            } else {
                self.receive(probe)
            }
        }
    }

    private func finish(_ probe: Probe) {
        guard probes.removeValue(forKey: ObjectIdentifier(probe)) != nil else { return }
        probe.connection.stateUpdateHandler = nil
        probe.connection.cancel()
        startProbes()
    }
}
