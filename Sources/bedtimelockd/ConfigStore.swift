import Foundation
import CryptoKit
import Security
import DeadlockShared

final class ConfigStore {
    private let fm = FileManager.default
    private var keyData: Data
    private(set) var state: PersistedState

    init() throws {
        try fm.createDirectory(atPath: DeadlockPaths.support, withIntermediateDirectories: true)
        keyData = try ConfigStore.loadOrCreateKey()
        state = PersistedState()
        if let loaded = try? loadVerified(path: DeadlockPaths.state, signaturePath: DeadlockPaths.stateSignature) {
            state = loaded
        } else if let backup = try? loadVerified(path: DeadlockPaths.backupState, signaturePath: DeadlockPaths.backupSignature) {
            state = backup
            try persist()
        } else {
            state = PersistedState()
            try persist()
        }
    }

    private static func loadOrCreateKey() throws -> Data {
        let fm = FileManager.default
        if let d = fm.contents(atPath: DeadlockPaths.key), d.count == 32 { return d }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: "deadlock", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not generate HMAC key"])
        }
        let d = Data(bytes)
        try d.write(to: URL(fileURLWithPath: DeadlockPaths.key), options: .atomic)
        _ = chmod(DeadlockPaths.key, 0o600)
        return d
    }

    private func canonical(_ state: PersistedState) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(state)
    }

    private func signature(for data: Data) -> Data {
        let key = SymmetricKey(data: keyData)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private func loadVerified(path: String, signaturePath: String) throws -> PersistedState {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let expected = try Data(contentsOf: URL(fileURLWithPath: signaturePath))
        guard signature(for: data) == expected else {
            throw NSError(domain: "deadlock", code: 2, userInfo: [NSLocalizedDescriptionKey: "Config signature mismatch"])
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode(PersistedState.self, from: data)
    }

    func persist() throws {
        let data = try canonical(state)
        let sig = signature(for: data)
        if fm.fileExists(atPath: DeadlockPaths.state), fm.fileExists(atPath: DeadlockPaths.stateSignature) {
            try? fm.removeItem(atPath: DeadlockPaths.backupState)
            try? fm.removeItem(atPath: DeadlockPaths.backupSignature)
            try fm.copyItem(atPath: DeadlockPaths.state, toPath: DeadlockPaths.backupState)
            try fm.copyItem(atPath: DeadlockPaths.stateSignature, toPath: DeadlockPaths.backupSignature)
        }
        try data.write(to: URL(fileURLWithPath: DeadlockPaths.state), options: .atomic)
        try sig.write(to: URL(fileURLWithPath: DeadlockPaths.stateSignature), options: .atomic)
        for p in [DeadlockPaths.state, DeadlockPaths.stateSignature, DeadlockPaths.backupState, DeadlockPaths.backupSignature] where fm.fileExists(atPath: p) {
            _ = chmod(p, 0o600)
        }
    }

    func mutate(_ body: (inout PersistedState) -> Void) throws {
        body(&state)
        state.updatedAt = Date()
        try persist()
    }

    func reloadIfValid() {
        if let loaded = try? loadVerified(path: DeadlockPaths.state, signaturePath: DeadlockPaths.stateSignature) {
            state = loaded
            return
        }
        if let backup = try? loadVerified(path: DeadlockPaths.backupState, signaturePath: DeadlockPaths.backupSignature) {
            state = backup
            try? persist()
        }
    }
}
