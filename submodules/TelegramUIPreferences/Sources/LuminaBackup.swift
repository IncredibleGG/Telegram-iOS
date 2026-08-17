import Foundation
import CryptoKit

// LuminaGram: encrypted local backup (.lgbak) - the iOS twin of Android's
// LuminaConfig.exportAll/importAll and desktop's equivalent. iOS has no single prefs blob
// like Android SharedPreferences.getAll(), so "export everything" is just serializing the
// LuminaSettings struct itself (it already holds every Lumina field - see
// LuminaSettings.swift) rather than enumerating individual keys.
//
// Format: [salt(16 bytes)][AES-256-GCM combined (12-byte nonce + ciphertext + 16-byte tag)].
// The key is derived from the user's passphrase via HKDF-SHA256 (CryptoKit does not expose
// PBKDF2/Argon2 on iOS without dropping to CommonCrypto, which needs a bridging header this
// fork doesn't have yet). This is weaker than a real password-hashing KDF against an
// attacker who can brute-force the passphrase against a stolen file - acceptable for a
// "protect a file that leaked" threat model, same class of guarantee Android's version
// gives, but worth strengthening in a follow-up if a CommonCrypto/Argon2 dependency gets
// added later.
public enum LuminaBackupError: Error {
    case emptyPassphrase
    case randomGenerationFailed
    case corruptData
    case wrongPassphraseOrCorruptData
}

public enum LuminaBackup {
    private static let saltLength = 16
    private static let hkdfInfo = Data("LuminaGram.backup.v1".utf8)

    public static func export<T: Encodable>(_ value: T, passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else {
            throw LuminaBackupError.emptyPassphrase
        }
        let plaintext = try JSONEncoder().encode(value)

        var salt = Data(count: self.saltLength)
        let saltStatus = salt.withUnsafeMutableBytes { pointer -> Int32 in
            guard let baseAddress = pointer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, self.saltLength, baseAddress)
        }
        guard saltStatus == errSecSuccess else {
            throw LuminaBackupError.randomGenerationFailed
        }

        let key = self.deriveKey(passphrase: passphrase, salt: salt)
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw LuminaBackupError.randomGenerationFailed
        }
        return salt + combined
    }

    public static func importData<T: Decodable>(_ type: T.Type, data: Data, passphrase: String) throws -> T {
        guard !passphrase.isEmpty else {
            throw LuminaBackupError.emptyPassphrase
        }
        guard data.count > self.saltLength else {
            throw LuminaBackupError.corruptData
        }
        let salt = Data(data.prefix(self.saltLength))
        let combined = Data(data.suffix(from: data.index(data.startIndex, offsetBy: self.saltLength)))

        let key = self.deriveKey(passphrase: passphrase, salt: salt)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            return try JSONDecoder().decode(type, from: plaintext)
        } catch {
            // AES.GCM authentication failure and JSON decode failure both surface here as
            // generic Swift errors - collapse both into one user-facing case ("wrong
            // passphrase, or the file is damaged") since GCM's whole point is that a wrong
            // key can't be distinguished from tampered ciphertext.
            throw LuminaBackupError.wrongPassphraseOrCorruptData
        }
    }

    private static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        let passphraseKey = SymmetricKey(data: Data(passphrase.utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: passphraseKey, salt: salt, info: self.hkdfInfo, outputByteCount: 32)
    }
}
