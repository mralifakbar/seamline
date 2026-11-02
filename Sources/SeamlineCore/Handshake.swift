import CryptoKit
import Foundation

public enum HandshakeError: Error, Equatable {
    case unexpectedMessage
    case commitmentMismatch
    case versionMismatch(UInt8)
    case invalidKey
}

/// A Mac's long-term identity. The public half is what a pairing pins.
public struct Identity {
    public let id: UUID
    public let name: String
    public let key: Curve25519.KeyAgreement.PrivateKey

    public init(id: UUID, name: String, key: Curve25519.KeyAgreement.PrivateKey) {
        self.id = id; self.name = name; self.key = key
    }

    public var publicKey: Data { key.publicKey.rawRepresentation }
}

public struct HandshakeHello: Equatable {
    public static let version: UInt8 = 1

    public var version: UInt8
    public var id: UUID
    public var name: String
    public var staticKey: Data
    public var ephemeralKey: Data

    func encoded() -> Data {
        var w = ByteWriter(capacity: 128)
        w.u8(version)
        withUnsafeBytes(of: id.uuid) { w.raw(Data($0)) }
        w.raw(staticKey)
        w.raw(ephemeralKey)
        w.string(name)
        return w.data
    }

    static func decode(_ data: Data) throws -> HandshakeHello {
        var r = ByteReader(data)
        let version = try r.u8()
        guard version == Self.version else { throw HandshakeError.versionMismatch(version) }
        let idBytes = try r.raw(16)
        let uuid = idBytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        let staticKey = try r.raw(32)
        let ephemeralKey = try r.raw(32)
        let name = try r.string()
        return HandshakeHello(version: version, id: UUID(uuid: uuid), name: name,
                              staticKey: staticKey, ephemeralKey: ephemeralKey)
    }
}

public struct SessionKeys {
    public let channel: SecureChannel
    public let datagram: DatagramCrypto
    /// Six digits both screens show during pairing. Matching codes prove there is no one in the middle.
    public let pairingCode: String
    public let peerID: UUID
    public let peerName: String
    public let peerKey: Data
}

/// Three-message key exchange over the raw TCP stream:
///   1. initiator -> responder: SHA-256 commitment to the initiator's hello
///   2. responder -> initiator: responder hello
///   3. initiator -> responder: initiator hello (checked against the commitment)
/// The commitment stops a man in the middle from choosing keys after seeing both sides,
/// which is what makes a 6-digit comparison code safe (one guess in a million per attempt).
/// Keys mix ee, es and se Diffie-Hellman results, so a pinned static key also authenticates every later session.
public final class Handshake {
    public enum Role { case initiator, responder }

    public let role: Role
    private let identity: Identity
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private var myHello: Data
    private var peerCommitment: Data?
    private var done = false

    public init(role: Role, identity: Identity) {
        self.role = role
        self.identity = identity
        myHello = HandshakeHello(version: HandshakeHello.version, id: identity.id, name: identity.name,
                                 staticKey: identity.publicKey, ephemeralKey: ephemeral.publicKey.rawRepresentation).encoded()
    }

    /// Frames to send right after connecting.
    public func start() -> [Data] {
        role == .initiator ? [Data([0x01]) + Data(SHA256.hash(data: myHello))] : []
    }

    /// Feeds one handshake frame. Returns frames to send and, once finished, the session keys.
    public func receive(_ frame: Data) throws -> (send: [Data], keys: SessionKeys?) {
        guard !done, let kind = frame.first else { throw HandshakeError.unexpectedMessage }
        let body = frame.dropFirst()
        switch (role, kind) {
        case (.responder, 0x01) where peerCommitment == nil:
            guard body.count == 32 else { throw HandshakeError.unexpectedMessage }
            peerCommitment = Data(body)
            return ([Data([0x02]) + myHello], nil)

        case (.initiator, 0x02):
            let peer = try HandshakeHello.decode(Data(body))
            let keys = try derive(peerHello: peer, responderHello: Data(body), initiatorHello: myHello)
            done = true
            return ([Data([0x02]) + myHello], keys)

        case (.responder, 0x02):
            guard let commitment = peerCommitment else { throw HandshakeError.unexpectedMessage }
            guard Data(SHA256.hash(data: body)) == commitment else { throw HandshakeError.commitmentMismatch }
            let peer = try HandshakeHello.decode(Data(body))
            let keys = try derive(peerHello: peer, responderHello: myHello, initiatorHello: Data(body))
            done = true
            return ([], keys)

        default:
            throw HandshakeError.unexpectedMessage
        }
    }

    private func derive(peerHello: HandshakeHello, responderHello: Data, initiatorHello: Data) throws -> SessionKeys {
        guard let peerStatic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerHello.staticKey),
              let peerEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerHello.ephemeralKey)
        else { throw HandshakeError.invalidKey }

        let ee = try ephemeral.sharedSecretFromKeyAgreement(with: peerEphemeral)
        // Order the mixed secrets by role so both ends feed HKDF identical bytes.
        let mine = try ephemeral.sharedSecretFromKeyAgreement(with: peerStatic)
        let theirs = try identity.key.sharedSecretFromKeyAgreement(with: peerEphemeral)
        let (initEphRespStatic, initStaticRespEph) = role == .initiator ? (mine, theirs) : (theirs, mine)

        var material = Data()
        for secret in [ee, initEphRespStatic, initStaticRespEph] {
            let bytes = secret.withUnsafeBytes { Data($0) }
            guard bytes.contains(where: { $0 != 0 }) else { throw HandshakeError.invalidKey }
            material.append(bytes)
        }

        let transcript = Data(SHA256.hash(data: responderHello + initiatorHello))
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: transcript,
                                         info: Data("seamline/1 session".utf8), outputByteCount: 136)
        let bytes = okm.withUnsafeBytes { Data($0) }
        let toResponder = SymmetricKey(data: bytes[0..<32])
        let toInitiator = SymmetricKey(data: bytes[32..<64])
        let codeValue = bytes[64..<72].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
        let datagramToResponder = SymmetricKey(data: bytes[72..<104])
        let datagramToInitiator = SymmetricKey(data: bytes[104..<136])
        let tag = Data(transcript.prefix(8))

        let channel = role == .initiator
            ? SecureChannel(sendKey: toResponder, receiveKey: toInitiator)
            : SecureChannel(sendKey: toInitiator, receiveKey: toResponder)
        let datagram = role == .initiator
            ? DatagramCrypto(tag: tag, sendKey: datagramToResponder, receiveKey: datagramToInitiator)
            : DatagramCrypto(tag: tag, sendKey: datagramToInitiator, receiveKey: datagramToResponder)
        return SessionKeys(channel: channel, datagram: datagram, pairingCode: String(format: "%06llu", codeValue),
                           peerID: peerHello.id, peerName: peerHello.name, peerKey: peerHello.staticKey)
    }
}

public enum ChannelError: Error { case authenticationFailed }

/// ChaCha20-Poly1305 with a per-direction counter nonce. TCP delivers in order, so the counters never skip.
public struct SecureChannel {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    public init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey; self.receiveKey = receiveKey
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sendCounter))
        sendCounter += 1
        return box.ciphertext + box.tag
    }

    public mutating func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw ChannelError.authenticationFailed }
        let split = sealed.endIndex - 16
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(receiveCounter), ciphertext: sealed[..<split], tag: sealed[split...])
            let plain = try ChaChaPoly.open(box, using: receiveKey)
            receiveCounter += 1
            return plain
        } catch {
            throw ChannelError.authenticationFailed
        }
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}
