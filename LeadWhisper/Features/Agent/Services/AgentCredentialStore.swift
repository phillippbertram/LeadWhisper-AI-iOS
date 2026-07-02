import Foundation
import Security

final class AgentCredentialStore {
    private enum Constants {
        static let service = "LeadWhisper.Agent.OpenAI"
        static let openAIAccount = "OpenAIAPIKey"
    }

    func openAIAPIKey() throws -> String? {
        var query = baseQuery(account: Constants.openAIAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AgentCredentialError.keychain(status)
        }
        guard let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?.nilIfBlank else {
            return nil
        }
        return key
    }

    func hasOpenAIAPIKey() -> Bool {
        (try? openAIAPIKey()) != nil
    }

    func saveOpenAIAPIKey(_ key: String) throws {
        guard let trimmed = key.nilIfBlank else {
            throw AgentCredentialError.emptyKey
        }
        let data = Data(trimmed.utf8)
        var query = baseQuery(account: Constants.openAIAccount)

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AgentCredentialError.keychain(addStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw AgentCredentialError.keychain(status)
        }
    }

    func deleteOpenAIAPIKey() throws {
        let status = SecItemDelete(baseQuery(account: Constants.openAIAccount) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentCredentialError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.service,
            kSecAttrAccount as String: account
        ]
    }
}

enum AgentCredentialError: LocalizedError {
    case emptyKey
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            "Enter an OpenAI API key before saving."
        case .keychain(let status):
            "Could not update the secure credential store. Keychain status \(status)."
        }
    }
}
