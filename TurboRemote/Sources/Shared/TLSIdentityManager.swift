import Foundation
import Security
import CryptoKit

final class TLSIdentityManager {
    private static let keychainLabel = "TurboRemote Server"
    private static let keychainTag = "com.turboproductions.turboremote.server".data(using: .utf8)!

    static func getOrCreateIdentity() -> SecIdentity? {
        if let existing = queryIdentity() {
            print("[TLS] Using existing identity")
            return existing
        }
        print("[TLS] Generating new self-signed identity...")
        return generateIdentity()
    }

    // MARK: - Identity Generation

    private static func generateIdentity() -> SecIdentity? {
        deleteExisting()

        // 1. Generate EC P-256 key pair with CryptoKit
        let privateKey = P256.Signing.PrivateKey()
        let publicKeyX963 = privateKey.publicKey.x963Representation

        // 2. Build self-signed X.509 certificate
        guard let certDER = buildCertificate(publicKeyX963: publicKeyX963, signingKey: privateKey) else {
            print("[TLS] Failed to build certificate DER")
            return nil
        }

        guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
            print("[TLS] Failed to create SecCertificate from DER")
            return nil
        }

        // 3. Import private key into Keychain
        let privKeyData = privateKey.x963Representation
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(privKeyData as CFData, keyAttrs as CFDictionary, &error) else {
            print("[TLS] Failed to create SecKey: \(error?.takeRetainedValue() as Any)")
            return nil
        }

        let addKeyAttrs: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: secKey,
            kSecAttrApplicationTag as String: keychainTag,
            kSecAttrLabel as String: keychainLabel,
            kSecAttrIsPermanent as String: true,
        ]
        SecItemDelete(addKeyAttrs as CFDictionary)
        let keyStatus = SecItemAdd(addKeyAttrs as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            print("[TLS] Failed to add key to Keychain: \(keyStatus)")
            return nil
        }

        // 4. Add certificate to Keychain
        let addCertAttrs: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: keychainLabel,
        ]
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: keychainLabel] as CFDictionary)
        let certStatus = SecItemAdd(addCertAttrs as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            print("[TLS] Failed to add certificate to Keychain: \(certStatus)")
            return nil
        }

        // 5. Query for identity
        if let identity = queryIdentity() {
            print("[TLS] Identity created successfully")
            return identity
        }

        print("[TLS] Failed to query identity after creation")
        return nil
    }

    private static func queryIdentity() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: keychainLabel,
            kSecReturnRef as String: true,
        ]
        var ref: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        return status == errSecSuccess ? (ref as! SecIdentity) : nil
    }

    private static func deleteExisting() {
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keychainTag,
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: keychainLabel,
        ] as CFDictionary)
    }

    // MARK: - X.509 Certificate Builder

    private static func buildCertificate(publicKeyX963: Data, signingKey: P256.Signing.PrivateKey) -> Data? {
        let tbsCert = buildTBSCertificate(publicKeyX963: publicKeyX963)

        // Sign TBS certificate
        guard let signature = try? signingKey.signature(for: tbsCert) else {
            print("[TLS] Failed to sign TBS certificate")
            return nil
        }
        let sigDER = Data(signature.derRepresentation)

        // Final Certificate SEQUENCE
        let sigAlg = DER.sequence(DER.oid(OID.sha256WithECDSA))
        let sigBitString = DER.bitString(sigDER)
        return DER.sequence(tbsCert + sigAlg + sigBitString)
    }

    private static func buildTBSCertificate(publicKeyX963: Data) -> Data {
        var tbs = Data()

        // Version: [0] EXPLICIT INTEGER 2 (v3)
        tbs.append(DER.explicit(0, DER.integer(2)))

        // Serial number (random 8 bytes, positive)
        var serialBytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &serialBytes)
        serialBytes[0] &= 0x7F
        tbs.append(DER.integer(Data(serialBytes)))

        // Signature algorithm: sha256WithECDSA
        tbs.append(DER.sequence(DER.oid(OID.sha256WithECDSA)))

        // Issuer: CN=TurboRemote
        let cn = DER.sequence(DER.oid(OID.commonName) + DER.utf8String("TurboRemote"))
        let rdnSet = DER.set(cn)
        let name = DER.sequence(rdnSet)
        tbs.append(name)

        // Validity: now to 10 years from now
        let now = Date()
        let expiry = now.addingTimeInterval(10 * 365.25 * 24 * 3600)
        tbs.append(DER.sequence(DER.utcTime(now) + DER.utcTime(expiry)))

        // Subject: same as issuer (self-signed)
        tbs.append(name)

        // SubjectPublicKeyInfo
        let algId = DER.sequence(DER.oid(OID.ecPublicKey) + DER.oid(OID.secp256r1))
        let spki = DER.sequence(algId + DER.bitString(publicKeyX963))
        tbs.append(spki)

        return DER.sequence(tbs)
    }

    // MARK: - OIDs

    private enum OID {
        static let sha256WithECDSA: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
        static let ecPublicKey: [UInt8]     = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        static let secp256r1: [UInt8]       = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
        static let commonName: [UInt8]      = [0x55, 0x04, 0x03]
    }

    // MARK: - DER Encoding Helpers

    private enum DER {
        static func tagged(_ tag: UInt8, _ content: Data) -> Data {
            var result = Data([tag])
            result.append(contentsOf: lengthBytes(content.count))
            result.append(content)
            return result
        }

        static func sequence(_ content: Data) -> Data { tagged(0x30, content) }
        static func set(_ content: Data) -> Data { tagged(0x31, content) }

        static func integer(_ value: Int) -> Data {
            if value <= 0x7F {
                return Data([0x02, 0x01, UInt8(value)])
            }
            var bytes = [UInt8]()
            var v = value
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            if bytes.first! >= 0x80 { bytes.insert(0x00, at: 0) }
            return tagged(0x02, Data(bytes))
        }

        static func integer(_ data: Data) -> Data {
            var content = data
            if (content.first ?? 0) >= 0x80 { content.insert(0x00, at: 0) }
            return tagged(0x02, content)
        }

        static func oid(_ bytes: [UInt8]) -> Data { tagged(0x06, Data(bytes)) }
        static func utf8String(_ string: String) -> Data { tagged(0x0C, string.data(using: .utf8)!) }

        static func bitString(_ data: Data) -> Data {
            var content = Data([0x00])
            content.append(data)
            return tagged(0x03, content)
        }

        static func utcTime(_ date: Date) -> Data {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyMMddHHmmss'Z'"
            fmt.timeZone = TimeZone(identifier: "UTC")
            return tagged(0x17, fmt.string(from: date).data(using: .ascii)!)
        }

        static func explicit(_ tag: Int, _ content: Data) -> Data {
            tagged(0xA0 | UInt8(tag), content)
        }

        private static func lengthBytes(_ length: Int) -> [UInt8] {
            if length < 128 { return [UInt8(length)] }
            if length < 256 { return [0x81, UInt8(length)] }
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        }
    }
}
