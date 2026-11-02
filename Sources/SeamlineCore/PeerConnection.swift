import Foundation
import Network

public struct SessionInfo: Sendable {
    public let peerID: UUID
    public let peerName: String
    public let peerKey: Data
    public let pairingCode: String
}

/// Callbacks arrive on the connection's own queue so input can be injected without a main-thread hop.
/// Events arrive exactly once and in order, whichever path carried them.
public protocol PeerConnectionDelegate: AnyObject {
    func peerConnection(_ connection: PeerConnection, didEstablish session: SessionInfo)
    func peerConnection(_ connection: PeerConnection, didReceive message: Message)
    func peerConnection(_ connection: PeerConnection, didCloseWith error: Error?)
}

protocol DatagramRegistrar: AnyObject {
    func register(_ connection: PeerConnection, tag: Data)
    func unregister(tag: Data)
}

@inline(__always) func monotonicNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// One encrypted session with another Mac, over two paths:
///   stream (TCP): handshake, pairing, clipboard, and a reliable copy of every input event.
///   datagram (UDP): pointer motion (newest wins) and a fast copy of every input event.
/// A lost Wi-Fi frame stalls TCP for a retransmit timeout; the datagram copy routes around that stall.
public final class PeerConnection: @unchecked Sendable {
    public static let serviceType = "_seamline._tcp"
    public static let defaultPort: UInt16 = 47321

    /// 250 Hz: above any display refresh rate, below the airtime a 1000 Hz mouse would burn on Wi-Fi.
    static let motionInterval: UInt64 = 4_000_000
    /// Recent events ride along in every datagram for this long, so one lost packet is repaired by the next.
    static let redundancyWindow: UInt64 = 150_000_000
    static let maxRedundant = 8
    static let datagramTimeout: UInt64 = 2_500_000_000
    static let hotProbeInterval: DispatchTimeInterval = .milliseconds(20)
    static let coldProbeInterval: DispatchTimeInterval = .seconds(1)

    public let queue: DispatchQueue
    public weak var delegate: PeerConnectionDelegate?
    public private(set) var session: SessionInfo?
    public let endpoint: NWEndpoint
    /// Set before `start()`. Off forces everything onto the stream, for comparison and for networks that block UDP.
    public var datagramsEnabled = true
    /// Test hook: fraction of outgoing datagrams to drop.
    var datagramLoss = 0.0

    private let nw: NWConnection
    private let role: Handshake.Role
    private let handshake: Handshake
    private var channel: SecureChannel?
    private var reader = FrameReader(maxFrame: 4096)
    private var closed = false
    weak var registrar: DatagramRegistrar?

    // Receive side, confined to `queue`.
    private var sequencer = EventSequencer()
    private var lastMotionSeq: UInt32 = 0

    // Shared with the event tap thread; guarded by `lock`.
    private let lock = NSLock()
    private var outbox = Outbox()
    private var inFlight = false
    private var flushScheduled = false
    private var established = false
    private var datagram: DatagramCrypto?
    private var udp: NWConnection?
    private var lastDatagramReply: UInt64 = 0
    private var eventSeq: UInt32 = 0
    private var motionSeq: UInt32 = 0
    private var recent: [(at: UInt64, message: Message)] = []
    private var pendingMove: Message?
    private var lastMotionSent: UInt64 = 0
    private var motionScheduled = false
    private var hot = false
    private var warmUntil: UInt64 = 0
    private var timerIsHot = false
    private var probeID: UInt32 = 0
    private var datagramRTT = LatencyStats()
    private var streamRTT = LatencyStats()
    private var stats = LinkStats()
    private var kind: LinkKind?
    private var probeTimer: DispatchSourceTimer?

    public convenience init(to endpoint: NWEndpoint, identity: Identity, interface: NWInterface? = nil) {
        let params = Self.parameters()
        if let interface { params.requiredInterface = interface }
        self.init(NWConnection(to: endpoint, using: params), role: .initiator, identity: identity)
    }

    public init(_ connection: NWConnection, role: Handshake.Role, identity: Identity, queue: DispatchQueue? = nil) {
        nw = connection
        endpoint = connection.endpoint
        self.role = role
        handshake = Handshake(role: role, identity: identity)
        self.queue = queue ?? DispatchQueue(label: "seamline.peer", qos: .userInteractive)
    }

    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 6
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        // Wi-Fi voice queue: input packets skip ahead of bulk traffic on the same access point.
        params.serviceClass = .interactiveVoice
        return params
    }

    static func datagramParameters() -> NWParameters {
        let params = NWParameters.udp
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVoice
        return params
    }

    // MARK: Public state

    public var linkKind: LinkKind? { lock.withLock { kind } }
    public var usesDatagrams: Bool { lock.withLock { datagramReadyLocked(monotonicNanos()) } }
    /// Smoothed round trip in milliseconds over the path input actually takes.
    public var latency: Double? {
        lock.withLock { datagramReadyLocked(monotonicNanos()) ? datagramRTT.smoothed : streamRTT.smoothed }
    }
    public var latencyReport: (datagram: LatencyStats, stream: LatencyStats) { lock.withLock { (datagramRTT, streamRTT) } }
    public var statistics: LinkStats { lock.withLock { stats } }

    public func resetMeasurements() {
        lock.withLock { datagramRTT.reset(); streamRTT.reset(); stats = LinkStats() }
    }

    /// Keeps both radios awake with a probe every 20 ms. On while the pointer is on this peer.
    public func setHot(_ on: Bool) {
        lock.withLock { hot = on }
        retuneProbes()
    }

    /// Short burst of warmth, e.g. while the pointer approaches the edge toward this peer.
    public func prewarm() {
        let needsRetune = lock.withLock { () -> Bool in
            warmUntil = monotonicNanos() + 1_500_000_000
            return !timerIsHot
        }
        if needsRetune { retuneProbes() }
    }

    // MARK: Lifecycle

    public func start() {
        nw.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let kind = Self.classify(self.nw.currentPath)
                self.lock.withLock { self.kind = kind }
                for frame in self.handshake.start() { self.write(frame) }
                self.receive()
            case .waiting(let error), .failed(let error):
                self.fail(error)
            case .cancelled:
                self.fail(nil)
            default:
                break
            }
        }
        nw.start(queue: queue)
    }

    public func close() {
        queue.async { self.fail(nil) }
    }

    // MARK: Sending

    public func send(_ message: Message) {
        let now = monotonicNanos()
        var packet: Data?
        var flushNow = false
        var motionDelay: UInt64?

        lock.lock()
        switch message {
        case let .move(_, x, y, dx, dy):
            motionSeq &+= 1
            if case let .move(_, _, _, pdx, pdy)? = pendingMove {
                pendingMove = .move(seq: motionSeq, x: x, y: y, dx: pdx + dx, dy: pdy + dy)
            } else {
                pendingMove = .move(seq: motionSeq, x: x, y: y, dx: dx, dy: dy)
            }
            if datagramReadyLocked(now) {
                if !motionScheduled {
                    let elapsed = now &- lastMotionSent
                    if elapsed >= Self.motionInterval {
                        packet = sealLocked(takeMoveLocked(now) + redundantLocked(now))
                    } else {
                        motionScheduled = true
                        motionDelay = Self.motionInterval - elapsed
                    }
                }
            } else {
                outbox.push(pendingMove!)
                pendingMove = nil
                flushNow = claimFlushLocked()
            }

        case _ where message.isEvent:
            eventSeq &+= 1
            var event = message
            if case let .enter(x, y, flags, _) = message {
                event = .enter(x: x, y: y, flags: flags, motionSeq: motionSeq)
                pendingMove = nil
            }
            let wrapped = Message.sequenced(seq: eventSeq, message: event)
            outbox.push(wrapped)
            flushNow = claimFlushLocked()
            recent.append((now, wrapped))
            if recent.count > Self.maxRedundant { recent.removeFirst(recent.count - Self.maxRedundant) }
            if datagramReadyLocked(now) {
                packet = sealLocked(takeMoveLocked(now) + redundantLocked(now))
            }

        default:
            outbox.push(message)
            flushNow = claimFlushLocked()
        }
        let udp = self.udp
        lock.unlock()

        if let packet { udp?.send(content: packet, completion: .idempotent) }
        if flushNow { queue.async { self.flush() } }
        if let motionDelay {
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(motionDelay))) { self.flushMotion() }
        }
    }

    public func send(_ messages: [Message]) {
        for m in messages { send(m) }
    }

    private func datagramReadyLocked(_ now: UInt64) -> Bool {
        datagramsEnabled && udp != nil && lastDatagramReply != 0 && now &- lastDatagramReply < Self.datagramTimeout
    }

    private func claimFlushLocked() -> Bool {
        guard established, !inFlight, !flushScheduled else { return false }
        flushScheduled = true
        return true
    }

    private func takeMoveLocked(_ now: UInt64) -> [Message] {
        guard let move = pendingMove else { return [] }
        pendingMove = nil
        lastMotionSent = now
        return [move]
    }

    private func redundantLocked(_ now: UInt64) -> [Message] {
        recent.filter { now &- $0.at < Self.redundancyWindow }.map(\.message)
    }

    private func sealLocked(_ batch: [Message]) -> Data? {
        guard !batch.isEmpty, var crypto = datagram else { return nil }
        let sealed = try? crypto.seal(Message.encodeBatch(batch))
        datagram = crypto
        stats.datagramsOut += 1
        if case .move = batch.first { stats.movesSent += 1 }
        if datagramLoss > 0, Double.random(in: 0..<1) < datagramLoss { return nil }
        return sealed
    }

    private func flushMotion() {
        let now = monotonicNanos()
        var packet: Data?
        var flushNow = false
        lock.lock()
        motionScheduled = false
        if let move = pendingMove {
            if datagramReadyLocked(now) {
                packet = sealLocked(takeMoveLocked(now) + redundantLocked(now))
            } else {
                outbox.push(move)
                pendingMove = nil
                flushNow = claimFlushLocked()
            }
        }
        let udp = self.udp
        lock.unlock()
        if let packet { udp?.send(content: packet, completion: .idempotent) }
        if flushNow { flush() }
    }

    private func flush() {
        lock.lock()
        flushScheduled = false
        guard established, !inFlight, !closed, !outbox.isEmpty else { lock.unlock(); return }
        let batch = outbox.drain()
        inFlight = true
        lock.unlock()

        do {
            let sealed = try channel!.seal(Message.encodeBatch(batch))
            nw.send(content: FrameReader.frame(sealed), completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error { self.fail(error); return }
                self.lock.withLock { self.inFlight = false }
                self.flush()
            })
        } catch {
            fail(error)
        }
    }

    private func write(_ frame: Data) {
        nw.send(content: FrameReader.frame(frame), completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(error) }
        })
    }

    // MARK: Receiving

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.reader.append(data)
                do {
                    while !self.closed, let frame = try self.reader.next() { try self.handle(frame) }
                } catch {
                    self.fail(error)
                    return
                }
            }
            if let error { self.fail(error); return }
            if isComplete { self.fail(nil); return }
            self.receive()
        }
    }

    private func handle(_ frame: Data) throws {
        if var channel {
            let plain = try channel.open(frame)
            self.channel = channel
            for message in try Message.decodeBatch(plain) { process(message, viaDatagram: false) }
            return
        }
        let (replies, keys) = try handshake.receive(frame)
        for r in replies { write(r) }
        guard let keys else { return }
        channel = keys.channel
        lock.withLock {
            datagram = keys.datagram
            established = true
        }
        reader.maxFrame = 2 << 20
        let info = SessionInfo(peerID: keys.peerID, peerName: keys.peerName, peerKey: keys.peerKey, pairingCode: keys.pairingCode)
        session = info
        registrar?.register(self, tag: keys.datagram.tag)
        if role == .initiator {
            if datagramsEnabled { openDatagramPath() }
            retuneProbes()
        }
        delegate?.peerConnection(self, didEstablish: info)
        flush()
    }

    /// The datagram path targets the same host and port the stream reached; the listener serves both.
    private func openDatagramPath() {
        guard case let .hostPort(host, port)? = nw.currentPath?.remoteEndpoint else { return }
        let params = Self.datagramParameters()
        if let interface = nw.currentPath?.availableInterfaces.first { params.requiredInterface = interface }
        let udp = NWConnection(host: host, port: port, using: params)
        udp.stateUpdateHandler = { [weak self, weak udp] state in
            if case .failed = state, let self, let udp { self.lock.withLock { if self.udp === udp { self.udp = nil } } }
        }
        udp.start(queue: queue)
        lock.withLock { self.udp = udp }
        receiveDatagrams(on: udp)
    }

    private func receiveDatagrams(on udp: NWConnection) {
        udp.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if let data { self.handleDatagram(data, from: udp) }
            if error == nil { self.receiveDatagrams(on: udp) }
        }
    }

    /// Runs on `queue`. The responder learns its return path from whichever socket the host used.
    func handleDatagram(_ packet: Data, from udp: NWConnection) {
        guard !closed else { return }
        let crypto = lock.withLock { datagram }
        guard let plain = crypto?.open(packet), let messages = try? Message.decodeBatch(plain) else {
            lock.withLock { stats.datagramsRejected += 1 }
            return
        }
        lock.withLock {
            stats.datagramsIn += 1
            if role == .responder, self.udp !== udp { self.udp = udp }
        }
        for message in messages { process(message, viaDatagram: true) }
    }

    private func process(_ message: Message, viaDatagram: Bool) {
        switch message {
        case let .sequenced(seq, inner):
            let delivered = sequencer.accept(seq, inner)
            lock.withLock {
                if delivered.isEmpty, seq < sequencer.next { stats.redundantCopies += 1 }
                stats.eventsDelivered += delivered.count
                if viaDatagram { stats.eventsFirstByDatagram += delivered.count } else { stats.eventsFirstByStream += delivered.count }
            }
            for event in delivered {
                if case let .enter(_, _, _, start) = event { lastMotionSeq = max(lastMotionSeq, start) }
                delegate?.peerConnection(self, didReceive: event)
            }

        case let .move(seq, _, _, _, _):
            guard seq > lastMotionSeq else { lock.withLock { stats.movesStale += 1 }; return }
            lastMotionSeq = seq
            lock.withLock { stats.movesDelivered += 1 }
            delegate?.peerConnection(self, didReceive: message)

        case let .probe(id, nanos):
            reply(.probeReply(id: id, nanos: nanos), viaDatagram: viaDatagram)

        case let .probeReply(_, nanos):
            let now = monotonicNanos()
            let ms = Double(now &- nanos) / 1_000_000
            lock.withLock {
                if viaDatagram {
                    datagramRTT.add(ms)
                    lastDatagramReply = now
                } else {
                    streamRTT.add(ms)
                }
            }

        default:
            delegate?.peerConnection(self, didReceive: message)
        }
    }

    private func reply(_ message: Message, viaDatagram: Bool) {
        guard viaDatagram else { send(message); return }
        let (packet, udp) = lock.withLock { (sealLocked([message]), self.udp) }
        if let packet { udp?.send(content: packet, completion: .idempotent) }
    }

    // MARK: Probes

    private func retuneProbes() {
        queue.async { [weak self] in
            guard let self, !self.closed, self.role == .initiator, self.session != nil else { return }
            let now = monotonicNanos()
            let wantHot = self.lock.withLock { self.hot || now < self.warmUntil }
            if self.probeTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.setEventHandler { [weak self] in self?.probeTick() }
                self.probeTimer = timer
                timer.resume()
            } else if self.lock.withLock({ self.timerIsHot }) == wantHot {
                return
            }
            self.lock.withLock { self.timerIsHot = wantHot }
            self.probeTimer?.schedule(deadline: .now(), repeating: wantHot ? Self.hotProbeInterval : Self.coldProbeInterval,
                                      leeway: wantHot ? .milliseconds(2) : .milliseconds(100))
        }
    }

    private func probeTick() {
        let now = monotonicNanos()
        let (id, packet, udp, stillHot, timerHot) = lock.withLock { () -> (UInt32, Data?, NWConnection?, Bool, Bool) in
            probeID &+= 1
            let packet = datagramsEnabled ? sealLocked([.probe(id: probeID, nanos: now)]) : nil
            return (probeID, packet, self.udp, hot || now < warmUntil, timerIsHot)
        }
        if let packet { udp?.send(content: packet, completion: .idempotent) }
        send(.probe(id: id, nanos: now))
        if stillHot != timerHot { retuneProbes() }
    }

    // MARK: Teardown

    private func fail(_ error: Error?) {
        guard !closed else { return }
        closed = true
        probeTimer?.cancel()
        probeTimer = nil
        nw.stateUpdateHandler = nil
        nw.cancel()
        let (udp, tag) = lock.withLock { () -> (NWConnection?, Data?) in
            defer { self.udp = nil }
            return (self.udp, datagram?.tag)
        }
        if role == .initiator { udp?.cancel() }
        if let tag { registrar?.unregister(tag: tag) }
        delegate?.peerConnection(self, didCloseWith: error)
    }

    static func classify(_ path: NWPath?) -> LinkKind? {
        guard let interface = path?.availableInterfaces.first else { return nil }
        if interface.name.hasPrefix("awdl") || interface.name.hasPrefix("llw") { return .peerToPeer }
        switch interface.type {
        case .wiredEthernet: return .ethernet
        case .wifi: return .wifi
        case .loopback: return .loopback
        case .other: return interface.name.hasPrefix("utun") ? .vpn : .other
        default: return .other
        }
    }
}

// MARK: - Discovery

/// A Seamline peer seen through Bonjour.
public struct DiscoveredPeer: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: MachineKind
    public let endpoint: NWEndpoint
    /// The fastest interface the advertisement was seen on, so the connection can be pinned to it.
    public let interface: NWInterface?
    /// Every interface it was seen on, fastest first.
    public let interfaces: [NWInterface]

    public init(id: UUID, name: String, kind: MachineKind, endpoint: NWEndpoint, interfaces: [NWInterface] = []) {
        self.id = id; self.name = name; self.kind = kind; self.endpoint = endpoint
        self.interfaces = interfaces
        interface = interfaces.first
    }
}

public enum DiscoveryProblem: Equatable, Sendable {
    case localNetworkDenied
    case unavailable(String)
}

/// Bonjour browsing for Macs that are ready to be controlled.
public final class PeerBrowser: @unchecked Sendable {
    private let browser: NWBrowser
    private let ownID: UUID
    public var onChange: (([DiscoveredPeer]) -> Void)?
    public var onProblem: ((DiscoveryProblem?) -> Void)?

    public init(ownID: UUID) {
        self.ownID = ownID
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: PeerConnection.serviceType, domain: nil), using: PeerConnection.parameters())
    }

    /// Lower is better. Peer-to-peer Wi-Fi time-shares the radio with the access point, so it is the last resort.
    static func rank(_ interface: NWInterface?) -> Int {
        guard let interface else { return 3 }
        if interface.name.hasPrefix("awdl") || interface.name.hasPrefix("llw") { return 4 }
        switch interface.type {
        case .wiredEthernet: return 0
        case .wifi: return 1
        case .other: return 2
        default: return 3
        }
    }

    /// Whether an endpoint already chosen for a Mac beats a newly seen one. A Mac seen first over
    /// peer-to-peer Wi-Fi has nothing to keep yet, so the new endpoint always wins then.
    static func keepsExisting(newRank: Int, existingRank: Int?) -> Bool {
        guard let existingRank else { return false }
        return existingRank < newRank
    }

    public func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var peers: [UUID: DiscoveredPeer] = [:]
            var seen: [UUID: [NWInterface]] = [:]
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint,
                      case let .bonjour(txt) = result.metadata,
                      let idString = txt["id"], let id = UUID(uuidString: idString), id != self.ownID
                else { continue }
                let kind = txt["k"].flatMap(UInt8.init).flatMap(MachineKind.init(rawValue:)) ?? .desktop
                // The same Mac can appear once per interface; connect through the fastest one.
                var interfaces = (seen[id] ?? []) + result.interfaces
                interfaces.sort { Self.rank($0) < Self.rank($1) }
                seen[id] = interfaces
                let existing = peers[id]
                let keep = Self.keepsExisting(newRank: Self.rank(result.interfaces.first), existingRank: existing.map { Self.rank($0.interface) })
                let endpoint = keep ? existing!.endpoint : result.endpoint
                peers[id] = DiscoveredPeer(id: id, name: name, kind: kind, endpoint: endpoint, interfaces: interfaces)
            }
            self.onChange?(peers.values.sorted { $0.name < $1.name })
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onProblem?(nil)
            case .waiting(let error), .failed(let error): self?.onProblem?(Self.problem(from: error))
            default: break
            }
        }
        browser.start(queue: .main)
    }

    public func cancel() { browser.cancel() }

    static func problem(from error: NWError) -> DiscoveryProblem {
        if case let .dns(code) = error, code == -65570 { return .localNetworkDenied }
        return .unavailable(error.localizedDescription)
    }
}

/// TCP and UDP listeners on one port, plus Bonjour advertising, for the Mac being controlled.
public final class PeerListener: @unchecked Sendable, DatagramRegistrar {
    private var listener: NWListener?
    private var datagramListener: NWListener?
    private let identity: Identity
    private let kind: MachineKind
    private let preferredPort: NWEndpoint.Port
    private let advertise: Bool
    private let datagramQueue = DispatchQueue(label: "seamline.datagrams", qos: .userInteractive)
    private let lock = NSLock()
    private var routes: [Data: Weak] = [:]
    public var onConnection: ((PeerConnection) -> Void)?
    public var onProblem: ((DiscoveryProblem?) -> Void)?
    public var onReady: ((NWEndpoint.Port) -> Void)?
    public private(set) var port: NWEndpoint.Port?

    private struct Weak { weak var connection: PeerConnection? }

    public init(identity: Identity, kind: MachineKind,
                port: NWEndpoint.Port = NWEndpoint.Port(rawValue: PeerConnection.defaultPort)!, advertise: Bool = true) {
        self.identity = identity
        self.kind = kind
        preferredPort = port
        self.advertise = advertise
    }

    public func start() throws {
        try listen(on: preferredPort)
    }

    private func listen(on port: NWEndpoint.Port) throws {
        let listener = try NWListener(using: PeerConnection.parameters(), on: port)
        if advertise {
            listener.service = NWListener.Service(name: identity.name, type: PeerConnection.serviceType, domain: nil,
                                                  txtRecord: NWTXTRecord(["id": identity.id.uuidString, "v": "1", "k": String(kind.rawValue)]))
        }
        listener.newConnectionHandler = { [weak self] nw in
            guard let self else { nw.cancel(); return }
            // Sharing the datagram queue lets datagrams be handled where they land, with no queue hop.
            let connection = PeerConnection(nw, role: .responder, identity: self.identity, queue: self.datagramQueue)
            connection.registrar = self
            self.onConnection?(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                self.onProblem?(nil)
                if let port = listener.port { self.startDatagrams(on: port) }
            case .failed where port != .any:
                // The fixed port is taken, most likely by another copy of Seamline: take any free port instead.
                listener.cancel()
                try? self.listen(on: .any)
            case .waiting(let error), .failed(let error):
                self.onProblem?(PeerBrowser.problem(from: error))
            default:
                break
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func startDatagrams(on port: NWEndpoint.Port) {
        guard self.port != port else { return }
        self.port = port
        datagramListener?.cancel()
        if let udp = try? NWListener(using: PeerConnection.datagramParameters(), on: port) {
            udp.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.datagramQueue)
                self.receive(on: connection)
            }
            udp.start(queue: datagramQueue)
            datagramListener = udp
        }
        onReady?(port)
    }

    private func receive(on udp: NWConnection) {
        udp.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let tag = DatagramCrypto.sessionTag(of: data),
               let target = self.lock.withLock({ self.routes[tag]?.connection }) {
                if target.queue === self.datagramQueue {
                    target.handleDatagram(data, from: udp)
                } else {
                    target.queue.async { target.handleDatagram(data, from: udp) }
                }
            }
            if error == nil { self.receive(on: udp) } else { udp.cancel() }
        }
    }

    func register(_ connection: PeerConnection, tag: Data) {
        lock.withLock { routes[tag] = Weak(connection: connection) }
    }

    func unregister(tag: Data) {
        lock.withLock { routes[tag] = nil }
    }

    public func cancel() {
        listener?.cancel()
        datagramListener?.cancel()
        listener = nil
        datagramListener = nil
        port = nil
    }
}
