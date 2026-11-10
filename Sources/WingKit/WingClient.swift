import ConsoleSockets
import Foundation
import Network
import os

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
    private static let log = Logger(subsystem: "cz.splman.wingkit", category: "session")
    /// A group the console does not have may never report. Also how long after
    /// measuring reports of the last measured collection may still arrive.
    private static let measurementTimeout: TimeInterval = 0.5
    /// A real console kept sending only one of several simultaneous reports, and
    /// there is no way to cancel one, so measuring and streaming use a single
    /// report, like the single request of the wapi library.
    private static let combinedReportID: UInt32 = 1

    private let queue = DispatchQueue(label: "cz.splman.wingkit", qos: .userInitiated)
    private let meterGroups: [WingMeterGroup]
    private let nameNodes: [Int32]
    private let nameNodeSet: Set<Int32>

    private var state = State.connecting
    private var address: String?
    private var console: WingConsoleInfo?
    private var filter = WingConsoleFilter(address: nil)
    private var measurement: WingGroupMeasurement
    private var lastMeterDataAt: TimeInterval?
    private var reports: [[Int16]]
    private var names: [Int32: String] = [:]
    private var namesRevision = 0

    private var socket: ConsoleUDPSocket?
    private var connection: NWConnection?
    private var parser = WingStreamParser()
    private var discoveryTimer: DispatchSourceTimer?
    private var discoveriesSent = 0
    private var renewalTimer: DispatchSourceTimer?
    private var renewalsSinceNameRefresh = 0
    private var measurementTimer: DispatchSourceTimer?
    /// Values per group, in group order, as far as they are known.
    private var groupLengths: [Int] = []
    private var connectedAt: TimeInterval?
    private var reportsReceived = 0
    private var ignoredDatagrams = 0

    /// - Parameters:
    ///   - address: The console's address, or nil to find it by broadcast.
    ///   - meterGroups: The values of each group are kept apart in `Snapshot.reports`.
    ///   - nameNodes: Text parameters to read and keep current.
    public init(address: String?, meterGroups: [WingMeterGroup], nameNodes: [Int32]) {
        self.address = address
        self.meterGroups = meterGroups
        self.nameNodes = nameNodes
        nameNodeSet = Set(nameNodes)
        reports = Array(repeating: [], count: meterGroups.count)
        measurement = WingGroupMeasurement(groups: meterGroups)
    }

    deinit { tearDown() }

    public func start() {
        queue.async { [weak self] in
            self?.begin()
        }
    }

    public func stop() {
        queue.sync {
            if connection != nil { logSessionEnd("stopped by the application") }
            tearDown()
        }
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
        guard state == .connecting, connection == nil, socket == nil else { return }
        socket = ConsoleUDPSocket(queue: queue) { [weak self] datagram, sender in
            self?.handleDatagram(datagram, from: sender)
        }
        guard let socket else {
            fail("no UDP socket")
            return
        }
        filter = WingConsoleFilter(address: address)
        if let address {
            // The reply only names the console; the connection does not wait for it.
            if let destination = ConsoleUDPSocket.ipv4Address(address) {
                socket.send(WingProtocol.discoveryRequest, to: destination, port: WingProtocol.port)
            }
            openConnection(to: address)
        } else {
            sendDiscovery()
            discoveryTimer = makeTimer(interval: Self.discoveryInterval) { [weak self] in
                self?.sendDiscovery()
            }
        }
    }

    private func fail(_ reason: String) {
        guard state != .failed else { return }
        state = .failed
        logSessionEnd(reason)
        tearDown()
    }

    /// The application retries silently, so this is the only record of why a
    /// session ended and whether the console was still sending each report.
    private func logSessionEnd(_ reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let connected = connectedAt.map { String(format: "%.1f s", now - $0) } ?? "never"
        let silence = lastMeterDataAt.map { String(format: "%.1f s", now - $0) } ?? "no data"
        let summary = "connected: \(connected), meter silence: \(silence), "
            + "group lengths: \(groupLengths), reports: \(reportsReceived), ignored: \(ignoredDatagrams)"
        Self.log.notice("Session ended: \(reason, privacy: .public); \(summary, privacy: .public)")
    }

    private func tearDown() {
        discoveryTimer?.cancel()
        discoveryTimer = nil
        measurementTimer?.cancel()
        measurementTimer = nil
        renewalTimer?.cancel()
        renewalTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        socket?.close()
        socket = nil
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

    private func sendDiscovery() {
        guard connection == nil else {
            discoveryTimer?.cancel()
            discoveryTimer = nil
            return
        }
        guard discoveriesSent < Self.discoveryAttempts else {
            fail("no discovery reply")
            return
        }
        discoveriesSent += 1
        socket?.broadcast(WingProtocol.discoveryRequest, port: WingProtocol.port)
    }

    private func handleDatagram(_ datagram: [UInt8], from sender: in_addr) {
        let senderText = ConsoleUDPSocket.text(of: sender)
        if datagram.starts(with: WingProtocol.discoveryReplyPrefix) {
            guard let info = WingConsoleInfo(
                discoveryReply: String(decoding: datagram, as: UTF8.self)
            ) else { return }
            if connection == nil, address == nil {
                console = info
                address = info.ip
                filter = WingConsoleFilter(address: info.ip)
                discoveryTimer?.cancel()
                discoveryTimer = nil
                openConnection(to: info.ip)
            } else if filter.acceptsConsoleInfo(info, from: senderText) {
                console = info
            }
            return
        }
        guard filter.acceptsMeters(from: senderText),
              let report = WingMeterReport(packet: datagram) else {
            ignoredDatagrams += 1
            return
        }
        if state == .connected, report.reportID == Self.combinedReportID {
            applyCombined(report)
        } else if measurementTimer != nil, report.reportID == Self.combinedReportID {
            if let step = measurement.receive(length: report.words.count) {
                perform(step)
            }
        } else {
            ignoredDatagrams += 1
        }
    }

    private func applyCombined(_ report: WingMeterReport) {
        guard let groups = WingProtocol.split(report.words, lengths: groupLengths) else {
            if let connectedAt,
               ProcessInfo.processInfo.systemUptime - connectedAt < Self.measurementTimeout {
                // The console may still send the last measured collection.
                ignoredDatagrams += 1
                return
            }
            // For example a card was exchanged. Reconnecting measures again, and
            // values must not be shown on the wrong strips until then.
            fail("report of \(report.words.count) values does not match the groups")
            return
        }
        reports = groups
        reportsReceived += 1
        lastMeterDataAt = ProcessInfo.processInfo.systemUptime
    }

    // MARK: - TCP

    private func openConnection(to address: String) {
        guard let port = NWEndpoint.Port(rawValue: WingProtocol.port) else {
            fail("invalid TCP port")
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
            filter = WingConsoleFilter(address: remoteIPv4Address() ?? address)
            subscribe()
        case .failed(let error):
            fail("connection failed: \(error)")
        case .waiting(let error):
            // The system retries when the network or the local network permission
            // changes. The caller limits the total time.
            let description = "\(error)"
            Self.log.notice("Connection waiting: \(description, privacy: .public)")
        default:
            break
        }
    }

    private func subscribe() {
        guard let meterPort = socket?.port else {
            fail("no UDP socket")
            return
        }
        transmit(
            WingProtocol.selectControlChannel + WingProtocol.meterPort(meterPort) + nameRequests()
        )
        receiveStream()
        perform(measurement.start())
    }

    /// The address the connection reached, which a host name does not tell.
    private func remoteIPv4Address() -> String? {
        guard case .hostPort(host: .ipv4(let ip), port: _)? = connection?.currentPath?.remoteEndpoint
        else { return nil }
        return ip.rawValue.map { String($0) }.joined(separator: ".")
    }

    /// Carries out a step of measuring how many values each group reports; see
    /// `WingGroupMeasurement`. A report's collection is replaced by each request,
    /// so measuring needs no report of its own.
    private func perform(_ step: WingGroupMeasurement.Step) {
        measurementTimer?.cancel()
        measurementTimer = nil
        groupLengths = measurement.lengths
        switch step {
        case .request(let meters):
            transmit(WingProtocol.meterRequest(reportID: Self.combinedReportID, meters: meters))
            measurementTimer = makeTimer(interval: Self.measurementTimeout) { [weak self] in
                guard let self else { return }
                self.perform(self.measurement.timeout())
            }
        case .finished(let lengths):
            groupLengths = lengths
            startStreaming()
        case .failed(let reason):
            fail(reason)
        }
    }

    private func startStreaming() {
        let meters: [WingMeter] = zip(meterGroups, groupLengths).flatMap { group, length in
            length > 0 ? group.meters : []
        }
        transmit(WingProtocol.meterRequest(reportID: Self.combinedReportID, meters: meters))
        renewalTimer = makeTimer(interval: Self.renewalInterval) { [weak self] in
            self?.renewMeters()
        }
        connectedAt = ProcessInfo.processInfo.systemUptime
        state = .connected
        let lengths = groupLengths.description
        Self.log.notice("Connected: group lengths \(lengths, privacy: .public)")
    }

    private func renewMeters() {
        var message = WingProtocol.meterRenewal(reportID: Self.combinedReportID)
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
            // Sends still pending when the session is stopped report an error too.
            guard let self, let error, self.connection != nil else { return }
            self.fail("send failed: \(error)")
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
            if let error {
                self.fail("receive failed: \(error)")
            } else if isComplete {
                self.fail("console closed the connection")
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
