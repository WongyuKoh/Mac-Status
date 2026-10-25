import Foundation
import Security
import LocalAuthentication

enum KeychainStore {
    private static let service = "com.macstatus.metric-secrets"

    static func read(id: UUID) -> String? {
        var query = baseQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Automatic polling must not repeatedly present a Keychain permission dialog.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, id: UUID) throws {
        try TemplateEngine.validateCredential(value)
        guard let data = value.data(using: .utf8), !value.isEmpty else {
            throw StatusError.message("저장할 보안 키를 입력하세요.")
        }
        let query = baseQuery(id: id)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(create as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw StatusError.message("macOS 키체인에 보안 키를 저장하지 못했습니다. (\(status))")
        }
    }

    @discardableResult
    static func delete(id: UUID) -> Bool {
        let status = SecItemDelete(baseQuery(id: id) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
    }
}
