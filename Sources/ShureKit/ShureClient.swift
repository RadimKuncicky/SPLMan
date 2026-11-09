import Foundation
import Network

/// One read-only session with a Shure receiver over its command port. All work
/// happens on a private queue and no method blocks. A client is used for one
/// attempt only; after a failure, create a new one to try again.
public final class ShureClient {
    public enum State: Equatable {
        case connecting
        case connected
        /// The device answered, but it is not a receiver this library can read.
        case unsupported
        case failed
    }

    public struct Channel: Equatable {
        public let number: Int
        public var name = ""
        public var audioLevelDBFS: Double?
        public var rfLevelDBm: Double?
        public var batteryBars: Int?
        public var batteryMinutes: Int?
        public var transmitterModel: String?
    }

    public struct Snapshot {
        public let state: State
        public let address: String
        public let modelName: String
        public let deviceID: String
        public let firmware: String
        public let secondsSinceData: TimeInterval?
        public let channels: [Channel]
    }

    private static let connectionTimeoutSeconds = 5
    private static let modelReplyTimeout: TimeInterval = 5
    private static let meterInterval: TimeInterval = 0.125
    private static let ticksPerRFRequest = 4
    /// The receiver reports these by itself when they change, so asking again is
    /// only a safeguard against a missed report.
    private static let ticksPerStatusRequest = 80

    private let queue = DispatchQueue(label: "cz.splman.shurekit", qos: .userInitiated)
    private let address: String

    private var state = State.connecting
    private var model: ShureReceiverModel?
    private var modelName = ""
    private var deviceID = ""
    private var firmware = ""
    private var lastDataAt: TimeInterval?
    private var channels: [Channel] = []
    private var rfLevels: [Int: [Int: Double]] = [:]

    private var connection: NWConnection?
    private var parser = ShureStreamParser()
    private var modelTimer: DispatchSourceTimer?
    private var meterTimer: DispatchSourceTimer?
    private var ticks = 0

    public init(address: String) {
        self.address = address
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
                address: address,
                modelName: modelName,
                deviceID: deviceID,
                firmware: firmware,
                secondsSinceData: lastDataAt.map {
                    max(0, ProcessInfo.processInfo.systemUptime - $0)
                },
                channels: channels
            )
        }
    }

    private func begin() {
        guard state == .connecting, connection == nil,
              let port = NWEndpoint.Port(rawValue: ShureProtocol.port) else { return }
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
            send(ShureProtocol.modelRequest)
            receive()
            modelTimer = makeTimer(interval: Self.modelReplyTimeout) { [weak self] in
                self?.fail()
            }
        case .failed:
            fail()
        default:
            // While waiting, the system retries when the network or the local
            // network permission changes; the caller's timeout bounds the wait.
            break
        }
    }

    private func fail() {
        guard state == .connecting || state == .connected else { return }
        state = .failed
        tearDown()
    }

    private func tearDown() {
        modelTimer?.cancel()
        modelTimer = nil
        meterTimer?.cancel()
        meterTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
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

    private func send(_ bytes: [UInt8]) {
        connection?.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.fail() }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
            [weak self] data, _, isComplete, error in
            guard let self, self.connection != nil else { return }
            if let data, !data.isEmpty {
                for message in self.parser.consume(Array(data)) {
                    self.handle(message)
                }
            }
            if isComplete || error != nil {
                self.fail()
            } else {
                self.receive()
            }
        }
    }

    private func handle(_ message: ShureMessage) {
        lastDataAt = ProcessInfo.processInfo.systemUptime
        guard let model else {
            if case .model(let name)? = ShureProtocol.deviceReport(from: message) {
                identify(name)
            }
            return
        }
        guard let report = ShureProtocol.report(from: message, dialect: model.dialect) else {
            return
        }
        apply(report)
    }

    private func identify(_ name: String) {
        modelTimer?.cancel()
        modelTimer = nil
        modelName = name
        guard let model = ShureReceiverModel(name: name) else {
            state = .unsupported
            tearDown()
            return
        }
        self.model = model
        channels = (1...model.channelCount).map { Channel(number: $0) }
        state = .connected
        for request in ShureProtocol.deviceRequests {
            send(request)
        }
        requestMeters(model)
        requestRF(model)
        requestStatus(model)
        meterTimer = makeTimer(interval: Self.meterInterval) { [weak self] in
            self?.tick()
        }
    }

    private func tick() {
        guard let model else { return }
        ticks += 1
        requestMeters(model)
        if ticks % Self.ticksPerRFRequest == 0 { requestRF(model) }
        if ticks % Self.ticksPerStatusRequest == 0 { requestStatus(model) }
    }

    private func requestMeters(_ model: ShureReceiverModel) {
        for channel in channels {
            ShureProtocol.meterRequests(model.dialect, channel: channel.number).forEach(send)
        }
    }

    private func requestRF(_ model: ShureReceiverModel) {
        for channel in channels {
            ShureProtocol.rfRequests(model.dialect, channel: channel.number).forEach(send)
        }
    }

    private func requestStatus(_ model: ShureReceiverModel) {
        for channel in channels {
            ShureProtocol.statusRequests(model.dialect, channel: channel.number).forEach(send)
        }
    }

    private func apply(_ report: ShureReport) {
        switch report {
        case .model:
            break
        case .deviceID(let id):
            deviceID = id
        case .firmware(let version):
            firmware = version
        case .channelName(let channel, let name):
            update(channel) { $0.name = name }
        case .audioLevel(let channel, let level):
            update(channel) { $0.audioLevelDBFS = level }
        case .rfLevel(let channel, let antenna, let level):
            rfLevels[channel, default: [:]][antenna] = level
            // The stronger antenna is the one that carries the signal.
            let strongest = rfLevels[channel]?.values.max()
            update(channel) { $0.rfLevelDBm = strongest }
        case .batteryBars(let channel, let bars):
            update(channel) { $0.batteryBars = bars }
        case .batteryMinutes(let channel, let minutes):
            update(channel) { $0.batteryMinutes = minutes }
        case .transmitter(let channel, let model):
            update(channel) { $0.transmitterModel = model }
        }
    }

    private func update(_ number: Int, _ change: (inout Channel) -> Void) {
        guard let index = channels.firstIndex(where: { $0.number == number }) else { return }
        change(&channels[index])
    }
}
