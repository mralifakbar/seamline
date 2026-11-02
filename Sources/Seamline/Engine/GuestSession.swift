import AppKit
import SeamlineCore

/// Thread-safe switch that keeps input from an unpaired Mac from ever reaching the injector.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    var isOpen: Bool { lock.withLock { open } }
    func set(_ value: Bool) { lock.withLock { open = value } }
}

@MainActor
final class GuestSession {
    private unowned let model: AppModel
    private let listener: PeerListener
    private var links: [ObjectIdentifier: Link] = [:]
    private var gates: [ObjectIdentifier: Gate] = [:]
    private let injector = InputInjector()
    private let injectLock = NSLock()
    private var active: ObjectIdentifier?
    private var lastChangeCount = Pasteboard.changeCount
    private var transfer: UInt32 = 0

    init(model: AppModel) {
        self.model = model
        listener = PeerListener(identity: model.identity, kind: SystemInfo.kind)
    }

    func start() {
        listener.onConnection = { [weak self] connection in
            MainActor.runOnMain { self?.accept(connection) }
        }
        listener.onProblem = { [weak self] problem in
            MainActor.runOnMain { self?.model.discoveryProblem = problem }
        }
        listener.onReady = { [weak self] port in
            MainActor.runOnMain {
                let suffix = port.rawValue == PeerConnection.defaultPort ? "" : ":\(port.rawValue)"
                self?.model.listenAddresses = SystemInfo.addresses().map { "\($0.address)\(suffix)\($0.vpn ? " (VPN)" : "")" }
            }
        }
        do {
            try listener.start()
        } catch {
            model.discoveryProblem = .unavailable(error.localizedDescription)
        }
        publish()
        #if DEBUG
        if ProcessInfo.processInfo.environment["SEAMLINE_AUTOPAIR"] == "1" {
            debugTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.runOnMain {
                    guard let self else { return }
                    for link in self.links.values where link.ready {
                        let s = link.connection.statistics
                        print("[guest] link: datagrams in \(s.datagramsIn), events \(s.eventsDelivered) (first by UDP \(s.eventsFirstByDatagram), by TCP \(s.eventsFirstByStream)), redundant copies \(s.redundantCopies), moves \(s.movesDelivered), stale \(s.movesStale)")
                    }
                    fflush(stdout)
                }
            }
        }
        #endif
    }

    #if DEBUG
    private var debugTimer: Timer?
    #endif

    func stop() {
        listener.cancel()
        for link in links.values { link.connection.close() }
        injectLock.withLock { injector.releaseAll() }
        links = [:]
        gates = [:]
    }

    private func accept(_ connection: PeerConnection) {
        let link = Link(connection)
        let key = ObjectIdentifier(link)
        let gate = Gate()
        links[key] = link
        gates[key] = gate

        // Input is injected straight from the connection queue: no main-thread hop on the hot path.
        let injector = self.injector, lock = injectLock
        link.relay.immediate = { message in
            switch message {
            case .move, .button, .scroll, .key, .modifiers, .systemKey:
                if gate.isOpen { lock.withLock { injector.handle(message) } }
                return true
            case .enter, .leave:
                if gate.isOpen { lock.withLock { injector.handle(message) } }
                return false
            default:
                return false
            }
        }
        link.relay.established = { [weak self] session in self?.established(key, session) }
        link.relay.message = { [weak self] message in self?.received(message, key) }
        link.relay.closed = { [weak self] _ in self?.closed(key) }
        connection.start()
    }

    private func established(_ key: ObjectIdentifier, _ session: SessionInfo) {
        guard let link = links[key] else { return }
        link.session = session
        link.trustedLocally = model.vault.isTrusted(session.peerID, key: session.peerKey)
        link.connection.send(.introduction(Introduction(kind: SystemInfo.kind, displays: SystemInfo.displays(), trustsPeer: link.trustedLocally)))
        evaluate(key)
    }

    private func received(_ message: Message, _ key: ObjectIdentifier) {
        guard let link = links[key] else { return }
        switch message {
        case .introduction(let intro):
            link.intro = intro
            evaluate(key)
        case .pairAccept:
            link.acceptedRemotely = true
            evaluate(key)
        case .pairDecline:
            model.notice = "\(link.session?.peerName ?? "The other Mac") cancelled pairing."
            link.connection.close()
        case .enter:
            guard link.ready else { return }
            active = key
            model.controller = link.session?.peerName
        case .leave:
            guard link.ready else { return }
            if active == key { active = nil; model.controller = nil }
            returnClipboard(over: link)
        case let .clipboardChunk(transferID, index, count, bytes):
            guard link.ready, model.clipboardSync else { return }
            do {
                if let payload = try link.assembler.add(transfer: transferID, index: index, count: count, bytes: bytes) {
                    lastChangeCount = Pasteboard.write(payload)
                }
            } catch {
                link.assembler = ClipboardAssembler()
            }
        default:
            break
        }
    }

    /// Sends this Mac's clipboard back as the pointer leaves, but only if something new was copied here.
    private func returnClipboard(over link: Link) {
        guard model.clipboardSync else { return }
        let count = Pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard let payload = Pasteboard.read() else { return }
        transfer &+= 1
        link.connection.send(payload.chunks(transfer: transfer))
    }

    private func evaluate(_ key: ObjectIdentifier) {
        guard let link = links[key], let session = link.session else { return }
        if link.needsPrompt, model.pairing?.id != session.peerID {
            model.pairing = PairingPrompt(id: session.peerID, name: session.peerName, code: session.pairingCode, waiting: false)
            NSApp.activate(ignoringOtherApps: true)
        }
        guard !link.ready, link.localOK, link.remoteOK, link.intro != nil else { publish(); return }
        link.ready = true
        if !link.trustedLocally {
            model.vault.trust(TrustedPeer(id: session.peerID, name: session.peerName, key: session.peerKey))
            link.trustedLocally = true
        }
        if model.pairing?.id == session.peerID { model.pairing = nil }
        gates[key]?.set(true)
        publish()
    }

    private func link(for peer: UUID) -> Link? {
        links.values.first { $0.session?.peerID == peer }
    }

    func acceptPairing() {
        guard let prompt = model.pairing, let link = link(for: prompt.id) else { return }
        link.acceptedLocally = true
        link.connection.send(.pairAccept)
        model.pairing?.waiting = true
        if let key = links.first(where: { $0.value === link })?.key { evaluate(key) }
    }

    func declinePairing() {
        guard let prompt = model.pairing else { return }
        model.pairing = nil
        if let link = link(for: prompt.id) {
            link.connection.send(.pairDecline)
            link.connection.close()
        }
    }

    func forget(_ id: UUID) {
        link(for: id)?.connection.close()
        publish()
    }

    func broadcastDisplays() {
        let displays = SystemInfo.displays()
        for link in links.values where link.ready { link.connection.send(.displays(displays)) }
    }

    private func closed(_ key: ObjectIdentifier) {
        gates[key]?.set(false)
        if active == key {
            active = nil
            model.controller = nil
            injectLock.withLock { injector.releaseAll() }
        }
        if let peer = links[key]?.session?.peerID, model.pairing?.id == peer { model.pairing = nil }
        links[key] = nil
        gates[key] = nil
        publish()
    }

    private func publish() {
        var result: [UUID: Machine] = [:]
        for peer in model.vault.trusted {
            result[peer.id] = Machine(id: peer.id, name: peer.name, kind: .desktop, displays: [], status: .offline, isPaired: true)
        }
        for link in links.values {
            guard let session = link.session else { continue }
            var m = result[session.peerID] ?? Machine(id: session.peerID, name: session.peerName, kind: .desktop, displays: [], status: .connecting, isPaired: false)
            if let intro = link.intro { m.kind = intro.kind; m.displays = intro.displays }
            m.status = link.status
            result[session.peerID] = m
        }
        model.machines = result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
