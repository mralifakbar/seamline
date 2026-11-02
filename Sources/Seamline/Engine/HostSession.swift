import AppKit
import Network
import SeamlineCore

/// Bridges a connection's queue callbacks onto the main actor.
final class Relay: PeerConnectionDelegate {
    var established: (@MainActor (SessionInfo) -> Void)?
    var message: (@MainActor (Message) -> Void)?
    var closed: (@MainActor (Error?) -> Void)?
    /// Optional fast path that runs on the connection queue. Return true when the message was fully handled there.
    var immediate: ((Message) -> Bool)?

    // DispatchQueue.main keeps strict FIFO order, which clipboard slices rely on.
    func peerConnection(_ connection: PeerConnection, didEstablish session: SessionInfo) {
        DispatchQueue.main.async { self.established?(session) }
    }

    func peerConnection(_ connection: PeerConnection, didReceive message: Message) {
        if immediate?(message) == true { return }
        DispatchQueue.main.async { self.message?(message) }
    }

    func peerConnection(_ connection: PeerConnection, didCloseWith error: Error?) {
        DispatchQueue.main.async { self.closed?(error) }
    }
}

/// Pairing state for one connection. Both sides must trust each other before any input flows.
@MainActor
final class Link {
    /// Bonjour or saved-address ID at first; replaced by the peer's real ID once the handshake proves it.
    var id: UUID
    /// Set when the link was opened by address rather than discovered, so the address can be remembered.
    let address: String?
    let connection: PeerConnection
    let relay = Relay()
    var session: SessionInfo?
    var intro: Introduction?
    var trustedLocally = false
    var acceptedLocally = false
    var acceptedRemotely = false
    var ready = false
    var assembler = ClipboardAssembler()

    init(_ connection: PeerConnection, id: UUID = UUID(), address: String? = nil) {
        self.id = id
        self.address = address
        self.connection = connection
        connection.delegate = relay
    }

    var localOK: Bool { trustedLocally || acceptedLocally }
    var remoteOK: Bool { (intro?.trustsPeer ?? false) || acceptedRemotely }
    var needsPrompt: Bool { session != nil && !trustedLocally && !acceptedLocally }

    /// "Pairing" only while a person has something to confirm; a trusted reconnect reads as connecting.
    var status: Machine.Status {
        if ready { return .connected }
        if needsPrompt || (intro != nil && !remoteOK) { return .pairing }
        return .connecting
    }
}

@MainActor
final class HostSession {
    private unowned let model: AppModel
    let engine: HostEngine
    private lazy var tap = EventTap { [engine] type, event in engine.handle(type, event) }
    private let browser: PeerBrowser
    private var discovered: [UUID: DiscoveredPeer] = [:]
    private var links: [UUID: Link] = [:]
    private var retry: Timer?
    private var meter: Timer?
    private var secureInputTimer: Timer?
    private var paused = false

    // A clipboard generation increases on every new copy, wherever it came from.
    private var generation = 0
    private var peerGeneration: [UUID: Int] = [:]
    private var lastChangeCount = Pasteboard.changeCount
    private var transfer: UInt32 = 0

    init(model: AppModel) {
        self.model = model
        engine = HostEngine(selfID: model.identity.id)
        browser = PeerBrowser(ownID: model.identity.id)
    }

    func start() {
        engine.setLayout(model.layout)
        engine.setResistance(model.resistance.distance)
        engine.onFocusChange = { [weak self] focus in
            MainActor.runOnMain { self?.focusChanged(focus) }
        }
        browser.onChange = { [weak self] peers in
            MainActor.runOnMain { self?.discoveredChanged(peers) }
        }
        browser.onProblem = { [weak self] problem in
            MainActor.runOnMain { self?.model.discoveryProblem = problem }
        }
        browser.start()
        retry = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.runOnMain { self?.connectTrusted() }
        }
        // Latency on screen is measured, so refresh it while there is something to measure.
        meter = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.runOnMain { self?.refreshLatency() }
        }
        #if DEBUG
        if let address = ProcessInfo.processInfo.environment["SEAMLINE_CONNECT"] { _ = connect(address: address) }
        #endif
        connectTrusted()
        publish()
    }

    func stop() {
        retry?.invalidate()
        meter?.invalidate()
        secureInputTimer?.invalidate()
        engine.returnHome()
        tap.stop()
        browser.cancel()
        for link in links.values { link.connection.close() }
        links = [:]
    }

    func setPaused(_ value: Bool) {
        paused = value
        if value { engine.returnHome(); tap.stop() } else { updateTap() }
    }

    func reconnectAll() {
        engine.localDisplaysChanged()
        connectTrusted()
    }

    // MARK: Discovery and connection

    private var savedAddresses: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "addresses") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "addresses") }
    }

    private func discoveredChanged(_ peers: [DiscoveredPeer]) {
        discovered = Dictionary(uniqueKeysWithValues: peers.map { ($0.id, $0) })
        connectTrusted()
        publish()
    }

    /// Trusted Macs reconnect by themselves: through Bonjour when they are on this network, by saved address otherwise (VPN, Tailscale).
    private func connectTrusted() {
        for peer in model.vault.trusted where links[peer.id] == nil {
            if let found = discovered[peer.id] {
                connect(found)
            } else if let address = savedAddresses[peer.id.uuidString], let endpoint = Self.endpoint(from: address) {
                open(Link(PeerConnection(to: endpoint, identity: model.identity), id: peer.id, address: address))
            }
        }
    }

    func pair(_ id: UUID) {
        guard links[id] == nil, let peer = discovered[id] else { return }
        connect(peer)
    }

    private func connect(_ peer: DiscoveredPeer) {
        var interface = peer.interface
        #if DEBUG
        if ProcessInfo.processInfo.environment["SEAMLINE_PREFER_P2P"] == "1",
           let p2p = peer.interfaces.first(where: { $0.name.hasPrefix("awdl") || $0.name.hasPrefix("llw") }) {
            interface = p2p
        }
        #endif
        open(Link(PeerConnection(to: peer.endpoint, identity: model.identity, interface: interface), id: peer.id))
    }

    /// Connects to "host", "host:port" or "[v6]:port". Returns a message for the person when the text is not an address.
    func connect(address text: String) -> String? {
        guard let endpoint = Self.endpoint(from: text) else {
            return "Enter a name or IP address, like 192.168.1.20 or macbook.tailnet.ts.net."
        }
        open(Link(PeerConnection(to: endpoint, identity: model.identity), address: text.trimmingCharacters(in: .whitespaces)))
        return nil
    }

    static func endpoint(from text: String) -> NWEndpoint? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(" ") else { return nil }
        var host = value
        var port = PeerConnection.defaultPort
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            if rest.hasPrefix(":") {
                guard let p = UInt16(rest.dropFirst()) else { return nil }
                port = p
            }
        } else if value.filter({ $0 == ":" }).count == 1, let colon = value.firstIndex(of: ":") {
            host = String(value[..<colon])
            guard let p = UInt16(value[value.index(after: colon)...]) else { return nil }
            port = p
        }
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
    }

    private func open(_ link: Link) {
        links[link.id] = link
        link.relay.established = { [weak self, weak link] session in
            guard let self, let link else { return }
            self.established(link, session)
        }
        link.relay.message = { [weak self, weak link] message in
            guard let self, let link else { return }
            self.received(message, on: link)
        }
        link.relay.closed = { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.closed(link)
        }
        link.connection.start()
        publish()
    }

    private func established(_ link: Link, _ session: SessionInfo) {
        guard links[link.id] === link else { return }
        if link.id != session.peerID {
            // Opened by address: now the peer's real identity is known.
            if let existing = links[session.peerID], existing !== link {
                link.connection.close()
                return
            }
            links[link.id] = nil
            link.id = session.peerID
            links[link.id] = link
        }
        if let address = link.address { savedAddresses[session.peerID.uuidString] = address }
        link.session = session
        link.trustedLocally = model.vault.isTrusted(session.peerID, key: session.peerKey)
        link.connection.send(.introduction(Introduction(kind: SystemInfo.kind, displays: SystemInfo.displays(), trustsPeer: link.trustedLocally)))
        evaluate(link.id)
    }

    private func received(_ message: Message, on link: Link) {
        let id = link.id
        guard links[id] === link else { return }
        switch message {
        case .introduction(let intro):
            link.intro = intro
            evaluate(id)
        case .displays(let rects):
            link.intro?.displays = rects
            if link.ready { engine.updateDisplays(rects, for: id) }
            publish()
        case .pairAccept:
            link.acceptedRemotely = true
            evaluate(id)
        case .pairDecline:
            model.notice = "\(link.session?.peerName ?? "The other Mac") declined to pair."
            link.connection.close()
        case let .clipboardChunk(transferID, index, count, bytes):
            guard link.ready else { return }
            do {
                if let payload = try link.assembler.add(transfer: transferID, index: index, count: count, bytes: bytes) {
                    clipboardArrived(payload, from: id)
                }
            } catch {
                link.assembler = ClipboardAssembler()
            }
        default:
            break
        }
    }

    private func evaluate(_ id: UUID) {
        guard let link = links[id], let session = link.session else { return }
        if link.needsPrompt, model.pairing?.id != id {
            model.pairing = PairingPrompt(id: id, name: session.peerName, code: session.pairingCode, waiting: false)
        }
        guard !link.ready, link.localOK, link.remoteOK, let intro = link.intro else { publish(); return }
        link.ready = true
        if !link.trustedLocally {
            model.vault.trust(TrustedPeer(id: session.peerID, name: session.peerName, key: session.peerKey))
            link.trustedLocally = true
        }
        if model.pairing?.id == id { model.pairing = nil }
        if model.layout.cell(of: id.uuidString) == nil { placeBesideHost(id) }
        engine.add(link.connection, id: id, displays: intro.displays)
        updateTap()
        publish()
        #if DEBUG
        Bench.runIfRequested(link.connection, name: session.peerName)
        #endif
    }

    func acceptPairing() {
        guard let prompt = model.pairing, let link = links[prompt.id] else { return }
        link.acceptedLocally = true
        link.connection.send(.pairAccept)
        model.pairing?.waiting = true
        evaluate(prompt.id)
    }

    func declinePairing() {
        guard let prompt = model.pairing else { return }
        model.pairing = nil
        if let link = links[prompt.id] {
            link.connection.send(.pairDecline)
            link.connection.close()
        }
    }

    func forget(_ id: UUID) {
        savedAddresses[id.uuidString] = nil
        links[id]?.connection.close()
        engine.remove(id)
        publish()
    }

    private func closed(_ link: Link) {
        let id = link.id
        guard links[id] === link else { return }
        links[id] = nil
        engine.remove(id)
        if model.pairing?.id == id { model.pairing = nil }
        updateTap()
        publish()
    }

    private func placeBesideHost(_ id: UUID) {
        let hostCell = model.layout.cell(of: model.identity.id.uuidString) ?? Cell(x: 0, y: 0)
        let free = [Edge.right, .left, .top, .bottom].map { hostCell.step($0) }.first { model.layout.machine(at: $0) == nil }
        let maxX = model.layout.cells.values.map(\.x).max() ?? 0
        model.move(id, to: free ?? Cell(x: maxX + 1, y: hostCell.y))
    }

    private func updateTap() {
        let wanted = !paused && engine.hasPeers
        if wanted, !tap.isRunning {
            model.tapFailed = !tap.start()
        } else if !wanted, tap.isRunning {
            tap.stop()
        }
    }

    // MARK: Focus and clipboard

    private func focusChanged(_ focus: Focus) {
        model.focus = focus
        secureInputTimer?.invalidate()
        secureInputTimer = nil
        model.secureInputApp = nil
        guard case .remote(let id) = focus else { return }
        pushClipboard(to: id)
        checkSecureInput()
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.runOnMain { self?.checkSecureInput() }
        }
    }

    /// Secure Input hides keystrokes from the tap, so typing lands on this Mac instead. Say so while it lasts.
    private func checkSecureInput() {
        let owner = SecureInput.owner()
        if model.secureInputApp != owner { model.secureInputApp = owner }
    }

    private func pushClipboard(to id: UUID) {
        guard model.clipboardSync, let link = links[id], link.ready else { return }
        let count = Pasteboard.changeCount
        if count != lastChangeCount {
            lastChangeCount = count
            generation += 1
        }
        guard peerGeneration[id] != generation else { return }
        peerGeneration[id] = generation
        guard let payload = Pasteboard.read() else { return }
        transfer &+= 1
        link.connection.send(payload.chunks(transfer: transfer))
    }

    private func clipboardArrived(_ payload: ClipboardPayload, from id: UUID) {
        guard model.clipboardSync else { return }
        lastChangeCount = Pasteboard.write(payload)
        generation += 1
        peerGeneration[id] = generation
        // Moving straight from one guest to another: hand the copy on.
        if case .remote(let current) = model.focus, current != id { pushClipboard(to: current) }
    }

    // MARK: Publishing

    private func refreshLatency() {
        var changed = false
        var machines = model.machines
        for i in machines.indices {
            guard let link = links[machines[i].id], link.ready else { continue }
            let latency = link.connection.latency.map { ($0 * 10).rounded() / 10 }
            if machines[i].latency != latency || machines[i].link != link.connection.linkKind {
                machines[i].latency = latency
                machines[i].link = link.connection.linkKind
                changed = true
            }
        }
        if changed { model.machines = machines }
    }

    private func publish() {
        var result: [UUID: Machine] = [:]
        for peer in model.vault.trusted {
            result[peer.id] = Machine(id: peer.id, name: peer.name, kind: .desktop, displays: [], status: .offline, isPaired: true)
        }
        for peer in discovered.values {
            var m = result[peer.id] ?? Machine(id: peer.id, name: peer.name, kind: peer.kind, displays: [], status: .nearby, isPaired: false)
            m.name = peer.name
            m.kind = peer.kind
            if m.isPaired { m.status = .connecting }
            result[peer.id] = m
        }
        for (id, link) in links {
            var m = result[id] ?? Machine(id: id, name: link.session?.peerName ?? link.address ?? "Mac", kind: .desktop,
                                          displays: [], status: .connecting, isPaired: false)
            if let intro = link.intro { m.kind = intro.kind; m.displays = intro.displays }
            m.status = link.status
            m.isPaired = link.ready || m.isPaired
            if link.ready {
                m.latency = link.connection.latency
                m.link = link.connection.linkKind
            }
            result[id] = m
        }
        model.machines = result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension MainActor {
    /// Hops a Network or Timer callback onto the main actor.
    static func runOnMain(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { body() }
    }
}
