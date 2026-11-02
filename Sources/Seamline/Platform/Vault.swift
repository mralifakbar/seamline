import CryptoKit
import Foundation
import SeamlineCore

struct TrustedPeer: Codable, Equatable {
    var id: UUID
    var name: String
    var key: Data
}

/// This Mac's identity and the Macs it has paired with, stored in Application Support with owner-only access.
final class Vault {
    private let directory: URL
    let identity: Identity
    private(set) var trusted: [TrustedPeer]

    init() {
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG
        if let home = ProcessInfo.processInfo.environment["SEAMLINE_HOME"] { base = URL(fileURLWithPath: home) }
        #endif
        directory = base.appendingPathComponent("Seamline", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        identity = Self.loadIdentity(in: directory)
        trusted = (try? JSONDecoder().decode([TrustedPeer].self, from: Data(contentsOf: directory.appendingPathComponent("trusted.json")))) ?? []
    }

    func isTrusted(_ id: UUID, key: Data) -> Bool {
        trusted.contains { $0.id == id && $0.key == key }
    }

    func trust(_ peer: TrustedPeer) {
        trusted.removeAll { $0.id == peer.id }
        trusted.append(peer)
        save()
    }

    func forget(_ id: UUID) {
        trusted.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(trusted) else { return }
        write(data, to: "trusted.json")
    }

    private func write(_ data: Data, to name: String) {
        let url = directory.appendingPathComponent(name)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private struct StoredIdentity: Codable {
        var id: UUID
        var key: Data
    }

    private static func loadIdentity(in directory: URL) -> Identity {
        let url = directory.appendingPathComponent("identity.json")
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored.key) {
            return Identity(id: stored.id, name: SystemInfo.computerName, key: key)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let stored = StoredIdentity(id: UUID(), key: key.rawRepresentation)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return Identity(id: stored.id, name: SystemInfo.computerName, key: key)
    }
}
