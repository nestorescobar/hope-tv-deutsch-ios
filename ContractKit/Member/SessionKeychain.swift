import Foundation
import Security

/// Where the member session lives between launches.
protocol SessionStoring {
    func load() -> MemberSession?
    func save(_ session: MemberSession) throws
    func delete()
}

/// The member session in the tvOS Keychain (spec §7 row 5): never `UserDefaults`.
///
/// One generic-password item per App build: service = the bundle id, account =
/// `<entityId>:<appSlug>`. It is readable after the first unlock and never leaves this device
/// (no backup, no migration). The item holds the token, the expiry and the display name.
struct SessionKeychain: SessionStoring {
    let service: String
    let account: String

    static func account(for config: ContractConfig) -> String {
        "\(config.entityId):\(config.appSlug)"
    }

    struct SaveFailed: Error {
        let status: OSStatus
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> MemberSession? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(MemberSession.self, from: data)
    }

    /// Replaces the item. Delete, then add, so the accessibility class is always this one.
    func save(_ session: MemberSession) throws {
        delete()
        var item = query
        item[kSecValueData as String] = try JSONEncoder().encode(session)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw SaveFailed(status: status) }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
