import ConsoleSockets
import Foundation

/// One read-only metering session with a Behringer X32 or Midas M32 over UDP.
/// All work happens on a private queue and no method blocks. UDP has no
/// connection to lose, so the caller detects a lost console from missing meter
/// data. A client is used for one attempt only.
public final class X32Client {
    public enum State: Equatable {
        case connecting
        case connected
        case failed
    }

    public struct Snapshot {
        public let state: State
        public let address: String?
        public let model: String
        public let firmware: String
        public let secondsSinceMeterData: TimeInterval?
        /// Latest linear values of each requested meter page.
        public let meterPages: [Int: [Float]]
        public let names: [String: String]
        /// Changes whenever `names` changes.
        public let namesRevision: Int
    }

    private static let probeInterval: TimeInterval = 1
    private static let probeAttempts = 5
    /// Meter requests expire after 10 seconds, and any single datagram can be lost.
    private static let renewalInterval: TimeInterval = 3
    private static let renewalsPerNameRefresh = 10
    /// Many datagrams at once could overflow the console's receive queue.
    private static let nameBatchInterval: TimeInterval = 0.05
    private static let namesPerBatch = 8

    private let queue = DispatchQueue(label: "cz.splman.x32kit", qos: .userInitiated)
    private let configuredAddress: String?
    private let meterPages: [Int]
    private let nameAddresses: [String]
    private let nameAddressSet: Set<String>

    private var state = State.connecting
    private var console: in_addr?
    private var model = ""
    private var firmware = ""
    private var lastMeterDataAt: TimeInterval?
    private var meterValues: [Int: [Float]] = [:]
    private var names: [String: String] = [:]
    private var namesRevision = 0

    private var socket: ConsoleUDPSocket?
    private var probeTimer: DispatchSourceTimer?
    private var probesSent = 0
    private var renewalTimer: DispatchSourceTimer?
    private var renewalsSinceNameRefresh = 0
    private var nameTimer: DispatchSourceTimer?
    private var pendingNames: ArraySlice<String> = []

    /// - Parameters:
    ///   - address: The console's IPv4 address, or nil to find it by broadcast.
    ///   - meterPages: The `/meters/<page>` pages to receive.
    ///   - nameAddresses: Text parameters to read and keep current.
    public init(address: String?, meterPages: [Int], nameAddresses: [String]) {
        configuredAddress = address
        self.meterPages = meterPages
        self.nameAddresses = nameAddresses
        nameAddressSet = Set(nameAddresses)
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
                address: console.map(ConsoleUDPSocket.text(of:)) ?? configuredAddress,
                model: model,
                firmware: firmware,
                secondsSinceMeterData: lastMeterDataAt.map {
                    max(0, ProcessInfo.processInfo.systemUptime - $0)
                },
                meterPages: meterValues,
                names: names,
                namesRevision: namesRevision
            )
        }
    }

    private func begin() {
        guard state == .connecting, socket == nil else { return }
        socket = ConsoleUDPSocket(queue: queue) { [weak self] datagram, sender in
            self?.handleDatagram(datagram, from: sender)
        }
        guard socket != nil else {
            fail()
            return
        }
        sendProbe()
        probeTimer = makeTimer(interval: Self.probeInterval) { [weak self] in
            self?.sendProbe()
        }
    }

    private func fail() {
        guard state != .failed else { return }
        state = .failed
        tearDown()
    }

    private func tearDown() {
        probeTimer?.cancel()
        probeTimer = nil
        renewalTimer?.cancel()
        renewalTimer = nil
        nameTimer?.cancel()
        nameTimer = nil
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

    private func sendProbe() {
        guard probesSent < Self.probeAttempts else {
            fail()
            return
        }
        probesSent += 1
        if let configuredAddress {
            guard let destination = ConsoleUDPSocket.ipv4Address(configuredAddress) else {
                fail()
                return
            }
            socket?.send(X32Protocol.infoRequest, to: destination, port: X32Protocol.port)
        } else {
            socket?.broadcast(X32Protocol.infoRequest, port: X32Protocol.port)
        }
    }

    private func sendToConsole(_ bytes: [UInt8]) {
        guard let console else { return }
        socket?.send(bytes, to: console, port: X32Protocol.port)
    }

    private func handleDatagram(_ datagram: [UInt8], from sender: in_addr) {
        if let console, console.s_addr != sender.s_addr { return }
        guard let message = X32Message(packet: datagram) else { return }
        if console == nil {
            guard message.address == X32Protocol.infoAddress else { return }
            console = sender
            subscribe()
        }
        apply(message)
    }

    private func subscribe() {
        probeTimer?.cancel()
        probeTimer = nil
        state = .connected
        requestMeters()
        requestNames()
        renewalTimer = makeTimer(interval: Self.renewalInterval) { [weak self] in
            self?.renew()
        }
        nameTimer = makeTimer(interval: Self.nameBatchInterval) { [weak self] in
            self?.sendNameBatch()
        }
    }

    private func renew() {
        requestMeters()
        renewalsSinceNameRefresh += 1
        if renewalsSinceNameRefresh >= Self.renewalsPerNameRefresh {
            renewalsSinceNameRefresh = 0
            requestNames()
        }
    }

    private func requestMeters() {
        for page in meterPages {
            sendToConsole(X32Protocol.meterRequest(page: page))
        }
    }

    private func requestNames() {
        pendingNames = nameAddresses[...]
    }

    private func sendNameBatch() {
        for address in pendingNames.prefix(Self.namesPerBatch) {
            sendToConsole(X32Protocol.read(address))
        }
        pendingNames = pendingNames.dropFirst(Self.namesPerBatch)
    }

    private func apply(_ message: X32Message) {
        if let page = X32Protocol.meterPage(address: message.address) {
            guard case .blob(let blob)? = message.arguments.first,
                  let values = X32Protocol.meterValues(blob: blob) else { return }
            meterValues[page] = values
            lastMeterDataAt = ProcessInfo.processInfo.systemUptime
            return
        }

        let texts: [String] = message.arguments.compactMap {
            if case .string(let text) = $0 { return text }
            return nil
        }
        switch message.address {
        case X32Protocol.infoAddress:
            // version, server name, console model, console version
            if texts.count >= 4 {
                model = texts[2]
                firmware = texts[3]
            }
        default:
            if nameAddressSet.contains(message.address),
               let name = texts.first,
               names[message.address] != name {
                names[message.address] = name
                namesRevision += 1
            }
        }
    }
}
