import Foundation
import Security
import CryptoKit

final class PassphraseManager {
    private static let keychainService = "com.turboproductions.turboremote"
    private static let keychainAccount = "connection-passphrase"

    private static let wordList = [
        "alpha", "anchor", "arrow", "basin", "blade", "bloom", "brass", "breeze",
        "bridge", "canyon", "cedar", "cipher", "cloud", "cobalt", "coral", "crane",
        "creek", "crown", "crystal", "delta", "drift", "eagle", "echo", "ember",
        "falcon", "flame", "flint", "forge", "frost", "glacier", "grove", "harbor",
        "hawk", "haze", "iron", "ivory", "jade", "lance", "maple", "mesa",
        "mist", "north", "oak", "onyx", "orbit", "peak", "pine", "prism",
        "pulse", "quartz", "raven", "reef", "ridge", "river", "sage", "shadow",
        "sierra", "silver", "slate", "solar", "spark", "steel", "storm", "summit",
    ]

    static func getOrCreatePassphrase() -> String {
        if let existing = loadPassphrase() { return existing }
        let phrase = generatePassphrase()
        savePassphrase(phrase)
        return phrase
    }

    static func verify(_ input: String, against stored: String) -> Bool {
        input.lowercased().trimmingCharacters(in: .whitespaces) ==
            stored.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Hash passphrase for network transmission (don't send plaintext)
    static func hash(_ passphrase: String) -> Data {
        let normalized = passphrase.lowercased().trimmingCharacters(in: .whitespaces)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return Data(digest)
    }

    // MARK: - Private

    private static func generatePassphrase() -> String {
        var words = [String]()
        for _ in 0..<4 {
            let index = Int.random(in: 0..<wordList.count)
            words.append(wordList[index])
        }
        return words.joined(separator: "-")
    }

    private static func loadPassphrase() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
        ]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func savePassphrase(_ passphrase: String) {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: passphrase.data(using: .utf8)!,
        ]
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ] as CFDictionary)
        SecItemAdd(attrs as CFDictionary, nil)
    }
}
