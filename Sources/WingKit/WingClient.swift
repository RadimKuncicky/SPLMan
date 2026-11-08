import Darwin
import Foundation
import Network

/// One read-only metering session with a Behringer WING: optional discovery,
/// the TCP control connection and the UDP meter stream. All work happens on a
/// private queue and no method blocks. A client is used for one attempt only;
/// after a failure, create a new one to try again.
public final class WingClient {
    public enum State: Equatable {
        case connecting
        case connected
        case failed
    }

    public struct Snapshot {
        public let state: State
        public let address: String?
        public let console: WingConsoleInfo?
        public let secondsSinceMeterData: TimeInterval?
        /// Latest values of each meter group, empty before its first report.
        public let reports: [[Int16]]
        public let names: [Int32: String]
        /// Changes whenever `names` changes.
        public let namesRevision: Int
    }

    private static let discoveryInterval: TimeInterval = 1
    private static let discoveryAttempts = 5
    /// Reports expire after 5 seconds, so a late renewal must not lose them.
    private static let renewalInterval: TimeInterval = 3
    /// Requesting names regularly also keeps linked names current.
    private static let renewalsPerNameRefresh = 10
    private static let connectionTimeoutSeconds = 5
    private static let receiveBufferBytes: Int32 = 256 * 1_024

    private let queue = DispatchQueue(label: "cz.splman.wingkit", qos: .userInitiated)
    private let meterGroups: [[WingMeter]]
    private let nameNodes: [Int32]
    private let nameNodeSet: Set<Int32>

    private var state = State.connecting
    private var address: String?
    private var console: WingConsoleInfo?
    private var lastMeterDataAt: TimeInterval?
    private var reports: [[Int16]]
    private var names: [Int32: String] = [:]
    private var namesRevision = 0

    private var socketDescriptor: Int32 = -1
    private var meterPort: UInt16 = 0
    private var socketSource: DispatchSourceRead?
    private var connection: NWConnection?
    private var parser = WingStreamParser()
    private var discoveryTimer: DispatchSourceTimer?
    private var discoveriesSent = 0
    private var renewalTimer: DispatchSourceTimer?
    private var renewalsSinceNameRefresh = 0

    /// - Parameters:
    ///   - address: The console's address, or nil to find it by broadcast.
    ///   - meterGroups: Each group arrives as its own report.
    ///   - nameNodes: Text parameters to read and keep current.
    public init(address: String?, meterGroups: [[WingMeter]], nameNodes: [Int32]) {
        self.address = address
        self.meterGroups = meterGroups
        self.nameNodes = nameNodes
        nameNodeSet = Set(nameNodes)
        reports = Array(repeating: [], count: meterGroups.count)
    }

    deinit { tearDown() }

    public func start() {
        queue.async { [weak self] in
            self?.begin()
        }
    }

    public func stop() {
        queue.sync { tearDown() }
    }

    public func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(
                state: state,
                address: console?.ip ?? address,
                console: console,
                secondsSinceMeterData: lastMeterDataAt.map {
                    max(0, ProcessInfo.processInfo.systemUptime - $0)
                },
                reports: reports,
                names: names,
                namesRevision: namesRevision
            )
        }
    }

    // MARK: - Session

    private func begin() {
        guard state == .connecting, connection == nil, socketSource == nil else { return }
        guard openSocket() else {
            fail()
            return
        }
        if let address {
            // The reply only names the console; the connection does not wait for it.
            var destination = in_addr()
            if inet_pton(AF_INET, address, &destination) == 1 {
                sendDatagram(WingProtocol.discoveryRequest, to: destination)
            }
            openConnection(to: address)
        } else {
            sendDiscovery()
            discoveryTimer = makeTimer(interval: Self.discoveryInterval) { [weak self] in
                self?.sendDiscovery()
            }
        }
    }

    private func fail() {
        guard state != .failed else { return }
        state = .failed
        tearDown()
    }

    private func tearDown() {
        discoveryTimer?.cancel()
        discoveryTimer = nil
        renewalTimer?.cancel()
        renewalTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        socketSource?.cancel()
        socketSource = nil
        socketDescriptor = -1
    }

    private func makeTimer(
        interval: TimeInterval,
        handler: @escaping () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    // MARK: - UDP

    private func openSocket() -> Bool {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return false }

        var enabled: Int32 = 1
        var bufferBytes = Self.receiveBufferBytes
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, optionSize)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &bufferBytes, optionSize)

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr = in_addr(s_addr: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let isBound = withUnsafeMutablePointer(to: &local) { pointer -> Bool in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address -> Bool in
                guard Darwin.bind(descriptor, address, length) == 0 else { return false }
                return getsockname(descriptor, address, &length) == 0
            }
        }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard isBound, flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            return false
        }
        meterPort = UInt16(bigEndian: local.sin_port)
        socketDescriptor = descriptor

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readDatagrams()
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        source.resume()
        socketSource = source
        return true
    }

    /// A Mac on Wi-Fi and Ethernet routes 255.255.255.255 through one of them, so
    /// the request also goes to the broadcast address of every network.
    private func sendDiscovery() {
        guard connection == nil else {
            discoveryTimer?.cancel()
            discoveryTimer = nil
            return
        }
        guard discoveriesSent < Self.discoveryAttempts else {
            fail()
            return
        }
        discoveriesSent += 1
        sendDatagram(WingProtocol.discoveryRequest, to: in_addr(s_addr: UInt32.max))
        for destination in Self.interfaceBroadcastAddresses() {
            sendDatagram(WingProtocol.discoveryRequest, to: destination)
        }
    }

    private static func interfaceBroadcastAddresses() -> [in_addr] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [] }
        defer { freeifaddrs(start) }

        var addresses: [in_addr] = []
        for interface in sequence(first: start, next: { $0.pointee.ifa_next }) {
            let flags = Int32(bitPattern: interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_BROADCAST != 0,
                  flags & IFF_LOOPBACK == 0,
                  let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  let broadcast = interface.pointee.ifa_dstaddr else { continue }
            addresses.append(UnsafeRawPointer(broadcast).load(as: sockaddr_in.self).sin_addr)
        }
        return addresses
    }

    private func sendDatagram(_ bytes: [UInt8], to destination: in_addr) {
        guard socketDescriptor >= 0 else { return }
        let descriptor = socketDescriptor
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = WingProtocol.port.bigEndian
        remote.sin_addr = destination
        // A refused send is not final: local network access may still be pending,
        // and discovery repeats while the connection attempt runs.
        _ = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &remote) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(
                        descriptor,
                        buffer.baseAddress,
                        buffer.count,
                        0,
                        address,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
    }

    private func readDatagrams() {
        let descriptor = socketDescriptor
        guard descriptor >= 0 else { return }
        let capacity = 8_192
        var buffer = [UInt8](repeating: 0, count: capacity)
        while true {
            let count = recv(descriptor, &buffer, capacity, 0)
            guard count > 0 else { return }
            handleDatagram(Array(buffer[0..<count]))
        }
    }

    private func handleDatagram(_ datagram: [UInt8]) {
        if datagram.starts(with: WingProtocol.discoveryReplyPrefix) {
            guard let info = WingConsoleInfo(
                discoveryReply: String(decoding: datagram, as: UTF8.self)
            ) else { return }
            console = info
            if connection == nil, address == nil {
                address = info.ip
                discoveryTimer?.cancel()
                discoveryTimer = nil
                openConnection(to: info.ip)
            }
            return
        }
        guard let report = WingMeterReport(packet: datagram),
              report.reportID >= 1,
              report.reportID <= UInt32(reports.count) else { return }
        reports[Int(report.reportID) - 1] = report.words
        lastMeterDataAt = ProcessInfo.processInfo.systemUptime
    }

    // MARK: - TCP

    private func openConnection(to address: String) {
        guard let port = NWEndpoint.Port(rawValue: WingProtocol.port) else {
            fail()
            return
        }
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        options.connectionTimeout = Self.connectionTimeoutSeconds
        let connection = NWConnection(
            host: NWEndpoint.Host(address),
            port: port,
            using: NWParameters(tls: nil, tcp: options)
        )
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    private func handle(_ connectionState: NWConnection.State) {
        switch connectionState {
        case .ready:
            subscribe()
        case .failed:
            fail()
        default:
            // While waiting, the system retries when the network or the local
            // network permission changes. The caller limits the total time.
            break
        }
    }

    private func subscribe() {
        var message = WingProtocol.selectControlChannel + WingProtocol.meterPort(meterPort)
        for (index, meters) in meterGroups.enumerated() {
            message += WingProtocol.meterRequest(reportID: UInt32(index + 1), meters: meters)
        }
        transmit(message + nameRequests())
        receiveStream()
        renewalTimer = makeTimer(interval: Self.renewalInterval) { [weak self] in
            self?.renewMeters()
        }
        state = .connected
    }

    private func renewMeters() {
        var message = (0..<meterGroups.count).flatMap {
            WingProtocol.meterRenewal(reportID: UInt32($0 + 1))
        }
        renewalsSinceNameRefresh += 1
        if renewalsSinceNameRefresh >= Self.renewalsPerNameRefresh {
            renewalsSinceNameRefresh = 0
            message += nameRequests()
        }
        transmit(message)
    }

    private func nameRequests() -> [UInt8] {
        nameNodes.flatMap { WingProtocol.nodeDataRequest(node: $0) }
    }

    private func transmit(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        connection?.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.fail() }
        })
    }

    /// Also drains the console's unsolicited change messages.
    private func receiveStream() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
            [weak self] data, _, isComplete, error in
            guard let self, self.connection != nil else { return }
            if let data, !data.isEmpty {
                self.applyNames(self.parser.consume([UInt8](data)))
            }
            if isComplete || error != nil {
                self.fail()
            } else {
                self.receiveStream()
            }
        }
    }

    private func applyNames(_ values: [WingNodeText]) {
        for value in values where nameNodeSet.contains(value.node) && names[value.node] != value.text {
            names[value.node] = value.text
            namesRevision += 1
        }
    }
}
