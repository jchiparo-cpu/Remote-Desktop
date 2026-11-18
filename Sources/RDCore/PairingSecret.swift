import CryptoKit
import Foundation
import Security

/// A 256-bit random secret shared once between host and client.
///
/// Both sides derive the TLS pre-shared key from it, so only a client that
/// holds the secret can complete the TLS handshake. It is deliberately long
/// (not a short PIN): a short PIN used as a TLS-PSK could be brute-forced
/// offline from a recorded handshake.
public struct PairingSecret: Equatable {
    public static let byteCount = 32
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    public static func generate() -> PairingSecret {
        var raw = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &raw)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return PairingSecret(bytes: Data(raw))!
    }

    /// Parses the display form. Dashes, spaces and case are ignored.
    public init?(string: String) {
        let hex = string.lowercased().filter { $0.isHexDigit }
        let stripped = string.filter { !$0.isWhitespace && $0 != "-" }
        guard hex.count == Self.byteCount * 2, stripped.count == hex.count else { return nil }
        var out = Data(capacity: Self.byteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self.bytes = out
    }

    /// Hex in groups of 8, e.g. `3f9a01c2-...`, easy to copy between machines.
    public var displayString: String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        var groups: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 8)
            groups.append(String(hex[index..<next]))
            index = next
        }
        return groups.joined(separator: "-")
    }

    /// Key material handed to TLS. Derived rather than used raw so the
    /// stored secret is never put on the wire format directly.
    public func derivedPSK() -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: bytes),
            info: Data("remote-desktop tls-psk v1".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

/// Stores the pairing secret in the login Keychain.
public enum SecretStore {
    private static let service = "RemoteDesktop.pairing"

    public enum Role: String {
        case host
        case client
    }

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { "Keychain error \(status)" }
    }

    public static func save(_ secret: PairingSecret, role: Role) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: role.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = secret.bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public static func load(role: Role) -> PairingSecret? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: role.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return PairingSecret(bytes: data)
    }
}
