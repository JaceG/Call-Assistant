import Foundation
import Security

/// The Claude API key, kept in the login Keychain. Jace adds it himself with
/// `security add-generic-password` (see the README); the app only reads it.
/// The first read makes macOS ask whether Call Assistant may use it.
public enum APIKeyStore {
    public static let service = "com.jaceg.callassistant"
    public static let account = "anthropic-api-key"

    public static func read(service: String = service, account: String = account) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty
            else { throw AnswerError.noKey }
            return key
        case errSecItemNotFound:
            throw AnswerError.noKey
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw AnswerError.keychainDenied
        default:
            throw AnswerError.keychain(status: status)
        }
    }
}
