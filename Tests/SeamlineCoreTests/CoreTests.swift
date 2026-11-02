import CryptoKit
import Foundation
import Network
import XCTest
@testable import SeamlineCore

final class WireTests: XCTestCase {
    func testEveryMessageRoundTrips() throws {
        let messages: [Message] = [
            .introduction(Introduction(kind: .laptop, displays: [Rect(x: 0, y: 0, width: 1512, height: 982)], trustsPeer: true)),
            .displays([Rect(x: -1920, y: 0, width: 1920, height: 1080), Rect(x: 0, y: 0, width: 1512, height: 982)]),
            .pairAccept, .pairDecline,
            .enter(x: 10.5, y: 20.25, flags: 0x100000, motionSeq: 9),
            .leave,
            .move(seq: 3, x: 1, y: 2, dx: -3.5, dy: 4.25),
            .button(index: 2, down: true, clicks: 3, flags: 0, x: 4, y: 5),
            .scroll(Scroll(lineY: -1, lineX: 0, pointY: -12, pointX: 3, fixedY: -1.5, fixedX: 0.25, continuous: true, phase: 1, momentumPhase: 0)),
            .key(code: 36, down: false, isRepeat: true, flags: 0x20000, keyboardType: 40),
            .modifiers(code: 56, flags: 0x20102),
            .systemKey(subtype: 8, data1: 0x000A_0A00, data2: -1),
            .clipboardChunk(transfer: 7, index: 0, count: 1, bytes: Data([1, 2, 3])),
            .sequenced(seq: 41, message: .key(code: 1, down: true, isRepeat: false, flags: 0, keyboardType: 0)),
            .probe(id: 5, nanos: 123_456_789),
            .probeReply(id: 5, nanos: 123_456_789),
        ]
        XCTAssertEqual(try Message.decodeBatch(Message.encodeBatch(messages)), messages)
    }

    func testPointerMoveIsCompact() {
        XCTAssertEqual(Message.encodeBatch([.move(seq: 1, x: 1, y: 2, dx: 3, dy: 4)]).count, 22)
    }

    func testVarintBoundaries() throws {
        for v: UInt64 in [0, 127, 128, 16_383, 16_384, .max] {
            var w = ByteWriter()
            w.varint(v)
            var r = ByteReader(w.data)
            XCTAssertEqual(try r.varint(), v)
        }
    }

    func testFrameReaderHandlesSplitAndCoalescedReads() throws {
        let a = FrameReader.frame(Data([1, 2, 3]))
        let b = FrameReader.frame(Data(repeating: 9, count: 300))
        let stream = a + b
        var reader = FrameReader(maxFrame: 1024)
        var frames: [Data] = []
        for byte in stream {
            reader.append(Data([byte]))
            while let f = try reader.next() { frames.append(f) }
        }
        XCTAssertEqual(frames, [Data([1, 2, 3]), Data(repeating: 9, count: 300)])
    }

    func testFrameReaderRejectsOversizedFrame() {
        var reader = FrameReader(maxFrame: 10)
        reader.append(FrameReader.frame(Data(count: 11)))
        XCTAssertThrowsError(try reader.next())
    }

    func testTruncatedInputThrows() {
        var r = ByteReader(Data([0x12, 0, 0]))
        XCTAssertThrowsError(try Message.decode(from: &r))
    }
}

final class OutboxTests: XCTestCase {
    func testConsecutiveMovesCollapseAndSumDeltas() {
        var box = Outbox()
        box.push(.move(seq: 1, x: 1, y: 1, dx: 1, dy: 1))
        box.push(.move(seq: 2, x: 3, y: 4, dx: 2, dy: 3))
        XCTAssertEqual(box.drain(), [.move(seq: 2, x: 3, y: 4, dx: 3, dy: 4)])
    }

    func testButtonKeepsMovesOrdered() {
        var box = Outbox()
        box.push(.move(seq: 1, x: 1, y: 1, dx: 1, dy: 1))
        box.push(.button(index: 0, down: true, clicks: 1, flags: 0, x: 1, y: 1))
        box.push(.move(seq: 2, x: 2, y: 2, dx: 1, dy: 1))
        XCTAssertEqual(box.drain().count, 3)
    }

    func testBulkNeverDelaysInput() {
        var box = Outbox()
        for i in 0..<3 { box.push(.clipboardChunk(transfer: 1, index: UInt32(i), count: 3, bytes: Data())) }
        box.push(.key(code: 0, down: true, isRepeat: false, flags: 0, keyboardType: 0))
        let first = box.drain()
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.first, .key(code: 0, down: true, isRepeat: false, flags: 0, keyboardType: 0))
        XCTAssertEqual(box.drain().count, 1)
        XCTAssertEqual(box.drain().count, 1)
        XCTAssertTrue(box.isEmpty)
    }
}

final class ClipboardTests: XCTestCase {
    func testLargeTextCompressesAndReassembles() throws {
        let text = Data(String(repeating: "Seamline shares one keyboard. ", count: 20_000).utf8)
        let payload = ClipboardPayload(items: [.init(type: "public.utf8-plain-text", data: text),
                                               .init(type: "public.png", data: Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))])
        let chunks = payload.chunks(transfer: 42)
        var assembler = ClipboardAssembler()
        var result: ClipboardPayload?
        for case let .clipboardChunk(t, i, c, bytes) in chunks {
            result = try assembler.add(transfer: t, index: i, count: c, bytes: bytes)
        }
        XCTAssertEqual(result, payload)
    }

    func testOutOfOrderChunkIsRejected() {
        var assembler = ClipboardAssembler()
        XCTAssertThrowsError(try assembler.add(transfer: 1, index: 1, count: 2, bytes: Data()))
    }
}

final class HandshakeTests: XCTestCase {
    private func identity(_ name: String) -> Identity {
        Identity(id: UUID(), name: name, key: Curve25519.KeyAgreement.PrivateKey())
    }

    private func run(_ i: Handshake, _ r: Handshake) throws -> (SessionKeys, SessionKeys) {
        let commit = i.start()[0]
        let helloR = try r.receive(commit).send[0]
        let (toR, keysI) = try i.receive(helloR)
        let (_, keysR) = try r.receive(toR[0])
        return (keysI!, keysR!)
    }

    func testBothSidesAgreeOnCodeAndChannel() throws {
        let host = identity("Studio"), guest = identity("Air")
        let (ki, kr) = try run(Handshake(role: .initiator, identity: host), Handshake(role: .responder, identity: guest))
        XCTAssertEqual(ki.pairingCode, kr.pairingCode)
        XCTAssertEqual(ki.pairingCode.count, 6)
        XCTAssertEqual(ki.peerKey, guest.publicKey)
        XCTAssertEqual(kr.peerKey, host.publicKey)
        XCTAssertEqual(kr.peerName, "Studio")

        var send = ki.channel, receive = kr.channel
        for n in 0..<5 {
            let msg = Data("frame \(n)".utf8)
            XCTAssertEqual(try receive.open(send.seal(msg)), msg)
        }
        var back = kr.channel, front = ki.channel
        XCTAssertEqual(try front.open(back.seal(Data("reply".utf8))), Data("reply".utf8))
    }

    func testTamperedFrameFails() throws {
        let (ki, kr) = try run(Handshake(role: .initiator, identity: identity("A")), Handshake(role: .responder, identity: identity("B")))
        var send = ki.channel, receive = kr.channel
        var sealed = try send.seal(Data("click".utf8))
        sealed[sealed.startIndex] ^= 1
        XCTAssertThrowsError(try receive.open(sealed))
    }

    func testReplayedFrameFails() throws {
        let (ki, kr) = try run(Handshake(role: .initiator, identity: identity("A")), Handshake(role: .responder, identity: identity("B")))
        var send = ki.channel, receive = kr.channel
        let sealed = try send.seal(Data("click".utf8))
        _ = try receive.open(sealed)
        XCTAssertThrowsError(try receive.open(sealed))
    }

    func testInitiatorCannotSwapHelloAfterCommitting() throws {
        let i = Handshake(role: .initiator, identity: identity("A"))
        let swapped = Handshake(role: .initiator, identity: identity("M"))
        let r = Handshake(role: .responder, identity: identity("B"))
        let helloR = try r.receive(i.start()[0]).send[0]
        _ = swapped.start()
        let (forged, _) = try swapped.receive(helloR)
        XCTAssertThrowsError(try r.receive(forged[0])) { XCTAssertEqual($0 as? HandshakeError, .commitmentMismatch) }
    }

    func testFreshSessionsProduceDifferentCodes() throws {
        let a = identity("A"), b = identity("B")
        let codes = try (0..<4).map { _ in try run(Handshake(role: .initiator, identity: a), Handshake(role: .responder, identity: b)).0.pairingCode }
        XCTAssertGreaterThan(Set(codes).count, 1)
    }
}

final class GeometryTests: XCTestCase {
    // A laptop with a taller external display to its left, tops aligned.
    let space = ScreenSpace(displays: [Rect(x: 0, y: 0, width: 1512, height: 982), Rect(x: -2560, y: 0, width: 2560, height: 1440)])

    func testOuterEdgeIgnoresSeamBetweenDisplays() {
        XCTAssertNil(space.pushedEdge(at: Point(x: 0, y: 500), delta: Point(x: -3, y: 0), cornerGuard: 8))
        XCTAssertEqual(space.pushedEdge(at: Point(x: -2560, y: 500), delta: Point(x: -3, y: 0), cornerGuard: 8), .left)
        XCTAssertEqual(space.pushedEdge(at: Point(x: 1511, y: 500), delta: Point(x: 2, y: 0), cornerGuard: 8), .right)
    }

    func testBottomOfShortDisplayIsOuterButCornerGuardHolds() {
        XCTAssertEqual(space.pushedEdge(at: Point(x: 700, y: 981), delta: Point(x: 0, y: 1), cornerGuard: 8), .bottom)
        XCTAssertNil(space.pushedEdge(at: Point(x: 1508, y: 981), delta: Point(x: 0, y: 1), cornerGuard: 8))
        XCTAssertNil(space.pushedEdge(at: Point(x: 700, y: 500), delta: Point(x: 0, y: 1), cornerGuard: 8))
    }

    func testEntryPointLandsOnOuterDisplay() {
        XCTAssertEqual(space.entryPoint(through: .left, fraction: 0.5).x, -2560)
        let right = space.entryPoint(through: .right, fraction: 0.2)
        XCTAssertEqual(right.x, 1511)
        // Below the laptop's height only the external display exists, so a right entry there clamps onto it.
        XCTAssertEqual(space.entryPoint(through: .right, fraction: 0.95).x, -1)
    }

    func testVirtualCursorCrossesSeamAndExitsWithResistance() {
        var cursor = VirtualCursor(space: space, position: Point(x: 10, y: 100), resistance: 20)
        XCTAssertEqual(cursor.move(dx: -30, dy: 0, allowExit: true), .moved(Point(x: -20, y: 100)))
        _ = cursor.move(dx: -3000, dy: 0, allowExit: true)
        XCTAssertEqual(cursor.position.x, -2560)
        XCTAssertEqual(cursor.move(dx: -10, dy: 0, allowExit: true), .moved(Point(x: -2560, y: 100)))
        guard case .exited(.left, let f) = cursor.move(dx: -15, dy: 0, allowExit: true) else { return XCTFail("expected exit") }
        XCTAssertEqual(f, 100.0 / 1440.0, accuracy: 0.0001)
    }

    func testDragNeverExits() {
        var cursor = VirtualCursor(space: space, position: Point(x: 1500, y: 100), resistance: 0)
        XCTAssertEqual(cursor.move(dx: 500, dy: 0, allowExit: false), .moved(Point(x: 1511, y: 100)))
    }

    func testSlidingAlongStepFollowsTheDisplay() {
        var cursor = VirtualCursor(space: space, position: Point(x: 5, y: 970), resistance: 0)
        // Diagonal move whose target sits below the laptop but whose x lands on the external display.
        XCTAssertEqual(cursor.move(dx: -10, dy: 30, allowExit: true), .moved(Point(x: -5, y: 1000)))
    }
}

final class LayoutTests: XCTestCase {
    func testNeighborsAndSwap() {
        var layout = Layout()
        layout.place("host", at: Cell(x: 0, y: 0))
        layout.place("air", at: Cell(x: 1, y: 0))
        layout.place("mini", at: Cell(x: 0, y: -1))
        XCTAssertEqual(layout.neighbor(of: "host", toward: .right), "air")
        XCTAssertEqual(layout.neighbor(of: "air", toward: .left), "host")
        XCTAssertEqual(layout.neighbor(of: "host", toward: .top), "mini")
        XCTAssertNil(layout.neighbor(of: "air", toward: .top))
        layout.place("mini", at: Cell(x: 1, y: 0))
        XCTAssertEqual(layout.cell(of: "air"), Cell(x: 0, y: -1))
        layout.normalize()
        XCTAssertEqual(layout.cell(of: "host"), Cell(x: 0, y: 1))
    }

    func testDropTargetsTouchTheArrangement() {
        var layout = Layout()
        layout.place("host", at: Cell(x: 0, y: 0))
        let targets = layout.dropTargets(for: "air")
        XCTAssertEqual(targets.count, 5)
        XCTAssertFalse(targets.contains(Cell(x: 2, y: 0)))
    }
}

final class ReliabilityTests: XCTestCase {
    private func key(_ code: UInt16) -> Message { .key(code: code, down: true, isRepeat: false, flags: 0, keyboardType: 0) }

    func testSequencerDeliversInOrderExactlyOnce() {
        var seq = EventSequencer()
        XCTAssertEqual(seq.accept(2, key(2)), [])
        XCTAssertEqual(seq.accept(3, key(3)), [])
        XCTAssertEqual(seq.accept(1, key(1)), [key(1), key(2), key(3)])
        XCTAssertEqual(seq.accept(2, key(2)), [], "late duplicate from the other path")
        XCTAssertEqual(seq.accept(4, key(4)), [key(4)])
        XCTAssertEqual(seq.buffered, 0)
    }

    func testSequencerResyncsAfterHugeGap() {
        var seq = EventSequencer()
        XCTAssertEqual(seq.accept(100_000, key(9)), [key(9)])
        XCTAssertEqual(seq.next, 100_001)
    }

    func testDatagramCryptoRoundTripAndRejection() throws {
        let k1 = SymmetricKey(size: .bits256), k2 = SymmetricKey(size: .bits256)
        let tag = Data(repeating: 7, count: 8)
        var a = DatagramCrypto(tag: tag, sendKey: k1, receiveKey: k2)
        let b = DatagramCrypto(tag: tag, sendKey: k2, receiveKey: k1)
        let first = try a.seal(Data("one".utf8))
        let second = try a.seal(Data("two".utf8))
        XCTAssertEqual(b.open(second), Data("two".utf8), "datagrams open in any order")
        XCTAssertEqual(b.open(first), Data("one".utf8))
        var tampered = first
        tampered[tampered.endIndex - 1] ^= 1
        XCTAssertNil(b.open(tampered))
        let stranger = DatagramCrypto(tag: Data(repeating: 9, count: 8), sendKey: k2, receiveKey: k1)
        XCTAssertNil(stranger.open(first), "wrong session tag")
        XCTAssertEqual(DatagramCrypto.sessionTag(of: first), tag)
    }

    func testLatencyPercentiles() {
        var stats = LatencyStats()
        for ms in 1...100 { stats.add(Double(ms)) }
        XCTAssertEqual(stats.percentile(50) ?? 0, 50, accuracy: 1)
        XCTAssertEqual(stats.percentile(99) ?? 0, 99, accuracy: 1)
        XCTAssertNotNil(stats.smoothed)
    }
}

final class LoopbackTests: XCTestCase, @unchecked Sendable {
    private struct Rig {
        let listener: PeerListener
        let client: PeerConnection
        let collector: Collector
        var server: PeerConnection? { collector.server }
    }

    /// Real sockets on localhost: TCP and UDP listener on one port, the same code paths the app uses.
    private func makeRig(datagrams: Bool = true) throws -> Rig {
        let host = Identity(id: UUID(), name: "Host", key: .init())
        let guest = Identity(id: UUID(), name: "Guest", key: .init())
        let collector = Collector()
        let listener = PeerListener(identity: guest, kind: .laptop, port: .any, advertise: false)
        listener.onConnection = { connection in
            connection.delegate = collector
            collector.server = connection
            connection.start()
        }
        let ready = expectation(description: "listening")
        listener.onReady = { _ in ready.fulfill() }
        try listener.start()
        wait(for: [ready], timeout: 5)

        let client = PeerConnection(to: .hostPort(host: "127.0.0.1", port: listener.port!), identity: host)
        client.datagramsEnabled = datagrams
        client.delegate = collector
        client.start()
        let deadline = Date().addingTimeInterval(5)
        while collector.codes.count < 2, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(collector.codes.count, 2)
        XCTAssertEqual(Set(collector.codes).count, 1)
        return Rig(listener: listener, client: client, collector: collector)
    }

    private func waitForDatagrams(_ client: PeerConnection) {
        let deadline = Date().addingTimeInterval(5)
        while !client.usesDatagrams, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(client.usesDatagrams, "datagram path should come up within a probe or two")
    }

    private func waitFor(_ count: Int, in collector: Collector) {
        let deadline = Date().addingTimeInterval(8)
        while collector.events.count < count, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func keyCodes(_ messages: [Message]) -> [UInt16] {
        messages.compactMap { if case let .key(code, _, _, _, _) = $0 { return code }; return nil }
    }

    func testEventsTakeTheDatagramPath() throws {
        let rig = try makeRig()
        waitForDatagrams(rig.client)
        for i in 0..<200 { rig.client.send(.key(code: UInt16(i), down: true, isRepeat: false, flags: 0, keyboardType: 0)) }
        rig.client.send(.leave)
        waitFor(201, in: rig.collector)
        XCTAssertEqual(keyCodes(rig.collector.events), (0..<200).map(UInt16.init))
        XCTAssertEqual(rig.collector.events.last, .leave)
        XCTAssertGreaterThan(rig.server!.statistics.eventsFirstByDatagram, 0)
        XCTAssertNotNil(rig.client.latency)
        rig.client.close(); rig.listener.cancel()
    }

    func testHeavyDatagramLossStillDeliversExactlyOnceInOrder() throws {
        let rig = try makeRig()
        waitForDatagrams(rig.client)
        rig.client.datagramLoss = 0.6
        for i in 0..<300 {
            rig.client.send(.move(seq: 0, x: Float(i), y: 1, dx: 1, dy: 0))
            rig.client.send(.key(code: UInt16(i), down: i % 2 == 0, isRepeat: false, flags: 0, keyboardType: 0))
        }
        waitFor(300, in: rig.collector)
        XCTAssertEqual(keyCodes(rig.collector.events), (0..<300).map(UInt16.init))
        let stats = rig.server!.statistics
        XCTAssertEqual(stats.eventsDelivered, 300)
        XCTAssertGreaterThan(stats.eventsFirstByDatagram, 0)
        XCTAssertGreaterThan(stats.eventsFirstByStream, 0, "the stream fills the holes the lossy datagrams leave")
        rig.client.close(); rig.listener.cancel()
    }

    func testStaleMovesNeverOverwriteNewerOnes() throws {
        let rig = try makeRig()
        waitForDatagrams(rig.client)
        for i in 1...50 { rig.client.send(.move(seq: 0, x: Float(i), y: 0, dx: 1, dy: 0)) }
        let deadline = Date().addingTimeInterval(3)
        while rig.collector.lastMoveX != 50, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(rig.collector.lastMoveX, 50)
        XCTAssertTrue(rig.collector.moveXs == rig.collector.moveXs.sorted(), "positions only ever move forward")
        rig.client.close(); rig.listener.cancel()
    }

    func testStreamOnlyFallback() throws {
        let rig = try makeRig(datagrams: false)
        for i in 0..<100 { rig.client.send(.key(code: UInt16(i), down: true, isRepeat: false, flags: 0, keyboardType: 0)) }
        waitFor(100, in: rig.collector)
        XCTAssertEqual(keyCodes(rig.collector.events), (0..<100).map(UInt16.init))
        XCTAssertFalse(rig.client.usesDatagrams)
        rig.client.close(); rig.listener.cancel()
    }
}

private final class Collector: PeerConnectionDelegate, @unchecked Sendable {
    let lock = NSLock()
    var codes: [String] = []
    private var _events: [Message] = []
    private var _moveXs: [Float] = []
    var server: PeerConnection?

    var events: [Message] { lock.withLock { _events } }
    var moveXs: [Float] { lock.withLock { _moveXs } }
    var lastMoveX: Float? { moveXs.last }

    func peerConnection(_ connection: PeerConnection, didEstablish session: SessionInfo) {
        lock.withLock { codes.append(session.pairingCode) }
    }

    func peerConnection(_ connection: PeerConnection, didReceive message: Message) {
        lock.withLock {
            if case let .move(_, x, _, _, _) = message { _moveXs.append(x) } else { _events.append(message) }
        }
    }

    func peerConnection(_ connection: PeerConnection, didCloseWith error: Error?) {}
}

final class DiscoveryTests: XCTestCase {
    /// Regression: a Mac seen first over peer-to-peer Wi-Fi (rank 4) crashed the browser by unwrapping an endpoint it never had.
    func testFirstSightingOverPeerToPeerTakesTheNewEndpoint() {
        XCTAssertFalse(PeerBrowser.keepsExisting(newRank: 4, existingRank: nil))
        XCTAssertFalse(PeerBrowser.keepsExisting(newRank: 0, existingRank: nil))
    }

    func testFasterInterfaceWins() {
        XCTAssertTrue(PeerBrowser.keepsExisting(newRank: 4, existingRank: 1), "Wi-Fi beats peer-to-peer")
        XCTAssertFalse(PeerBrowser.keepsExisting(newRank: 0, existingRank: 1), "Ethernet beats Wi-Fi")
        XCTAssertFalse(PeerBrowser.keepsExisting(newRank: 1, existingRank: 1), "a tie takes the newest result")
    }
}
