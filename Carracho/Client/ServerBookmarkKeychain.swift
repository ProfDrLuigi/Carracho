import Foundation
import Security

enum ServerBookmarkKeychainError: LocalizedError {
    case invalidPasswordEncoding
    case invalidVaultEncoding
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidPasswordEncoding:
            return L("The bookmark password could not be encoded as UTF-8.")
        case .invalidVaultEncoding:
            return L("The bookmark password vault in Keychain is invalid.")
        case let .keychain(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return LF("Keychain error: %@ (%@)", message, String(status))
            }
            return LF("Keychain error %@.", String(status))
        }
    }
}

protocol ServerBookmarkPasswordStore {
    func password(for bookmarkID: UUID) throws -> String?
    func setPassword(_ password: String, for bookmarkID: UUID) throws
    func removePassword(for bookmarkID: UUID) throws
}

struct ServerBookmarkKeychainItem {
    var account: String
    var data: Data
}

protocol ServerBookmarkKeychainStorage {
    func data(service: String, account: String) throws -> Data?
    func setData(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
    func allItems(service: String) throws -> [ServerBookmarkKeychainItem]
}

struct SecurityServerBookmarkKeychainStorage: ServerBookmarkKeychainStorage {
    func data(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ServerBookmarkKeychainError.keychain(status) }
        guard let data = result as? Data else { throw ServerBookmarkKeychainError.invalidPasswordEncoding }
        return data
    }

    func setData(_ data: Data, service: String, account: String) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw ServerBookmarkKeychainError.keychain(updateStatus) }

        var add = key
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw ServerBookmarkKeychainError.keychain(addStatus) }
    }

    func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ServerBookmarkKeychainError.keychain(status)
        }
    }

    func allItems(service: String) throws -> [ServerBookmarkKeychainItem] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw ServerBookmarkKeychainError.keychain(status) }

        let rawItems: [[String: Any]]
        if let values = result as? [[String: Any]] { rawItems = values }
        else if let value = result as? [String: Any] { rawItems = [value] }
        else { throw ServerBookmarkKeychainError.invalidVaultEncoding }

        return try rawItems.map { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else {
                throw ServerBookmarkKeychainError.invalidVaultEncoding
            }
            return ServerBookmarkKeychainItem(account: account, data: data)
        }
    }
}

/// Stores every bookmark password in one Keychain generic-password item.
///
/// Older Carracho builds stored one Keychain item per bookmark UUID. That meant a
/// changed app signature could make macOS ask for Keychain access once per bookmark.
/// The current format keeps a UUID -> password dictionary in one item, so there is
/// only one Keychain ACL/item for all server bookmarks.
struct ServerBookmarkKeychain: ServerBookmarkPasswordStore {
    static let defaultService = "luigi.com.carracho.server-bookmarks"
    static let vaultAccount = "carracho-bookmark-password-vault.v1"

    private struct PasswordVault: Codable {
        static let currentVersion = 1
        var version: Int = currentVersion
        var passwords: [String: String] = [:]
    }

    private static let lock = NSLock()
    private static var vaultCache: [String: PasswordVault] = [:]
    private static var missingVaultServices: Set<String> = []

    var service: String
    private let storage: any ServerBookmarkKeychainStorage

    init(service: String = Self.defaultService,
         storage: any ServerBookmarkKeychainStorage = SecurityServerBookmarkKeychainStorage()) {
        self.service = service
        self.storage = storage
    }

    func password(for bookmarkID: UUID) throws -> String? {
        try withLock {
            let bookmarkKey = account(for: bookmarkID)
            var vault = try loadVault() ?? PasswordVault()
            if let password = vault.passwords[bookmarkKey] { return password }

            // Lazy compatibility fallback in case startup migration was cancelled or
            // an old per-bookmark item appears after a Keychain restore.
            guard let legacyData = try storage.data(service: service, account: bookmarkKey) else { return nil }
            guard let legacyPassword = String(data: legacyData, encoding: .utf8) else {
                throw ServerBookmarkKeychainError.invalidPasswordEncoding
            }
            vault.passwords[bookmarkKey] = legacyPassword
            try saveVault(vault)
            try storage.delete(service: service, account: bookmarkKey)
            return legacyPassword
        }
    }

    func setPassword(_ password: String, for bookmarkID: UUID) throws {
        guard password.data(using: .utf8) != nil else { throw ServerBookmarkKeychainError.invalidPasswordEncoding }
        if password.isEmpty {
            try removePassword(for: bookmarkID)
            return
        }

        try withLock {
            let bookmarkKey = account(for: bookmarkID)
            var vault = try loadVault() ?? PasswordVault()
            vault.passwords[bookmarkKey] = password
            try saveVault(vault)
            // Remove a legacy duplicate only after the shared vault is safely updated.
            try storage.delete(service: service, account: bookmarkKey)
        }
    }

    func removePassword(for bookmarkID: UUID) throws {
        try withLock {
            let bookmarkKey = account(for: bookmarkID)
            if var vault = try loadVault() {
                vault.passwords.removeValue(forKey: bookmarkKey)
                try saveVault(vault)
            }
            try storage.delete(service: service, account: bookmarkKey)
        }
    }

    /// Consolidates all legacy per-bookmark items for the supplied bookmarks into
    /// the shared vault. The production storage uses one match-all Keychain query so
    /// the old collection is fetched in one migration pass. Existing shared values
    /// win over stale legacy duplicates.
    func migrateLegacyPasswords(for bookmarkIDs: [UUID]) throws {
        guard !bookmarkIDs.isEmpty else { return }
        try withLock {
            let wanted = Set(bookmarkIDs.map(account(for:)))
            let items = try storage.allItems(service: service)
            let storedVault = try vault(from: items)
            var vault = Self.vaultCache[service] ?? storedVault ?? PasswordVault()
            if let storedVault {
                Self.vaultCache[service] = storedVault
                Self.missingVaultServices.remove(service)
            } else if items.isEmpty {
                Self.missingVaultServices.insert(service)
            }
            var migratedAccounts: [String] = []

            for item in items {
                guard item.account != Self.vaultAccount, wanted.contains(item.account) else { continue }
                if vault.passwords[item.account] == nil {
                    guard let password = String(data: item.data, encoding: .utf8) else {
                        throw ServerBookmarkKeychainError.invalidPasswordEncoding
                    }
                    vault.passwords[item.account] = password
                }
                migratedAccounts.append(item.account)
            }

            guard !migratedAccounts.isEmpty else { return }
            try saveVault(vault)
            // Shared data is committed first. A failed cleanup leaves a harmless
            // duplicate and never destroys the migrated password.
            for account in migratedAccounts { try storage.delete(service: service, account: account) }
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try body()
    }

    private func account(for bookmarkID: UUID) -> String {
        bookmarkID.uuidString.lowercased()
    }

    private func loadVault() throws -> PasswordVault? {
        if let cached = Self.vaultCache[service] { return cached }
        if Self.missingVaultServices.contains(service) { return nil }
        guard let data = try storage.data(service: service, account: Self.vaultAccount) else {
            Self.missingVaultServices.insert(service)
            return nil
        }
        let vault = try decodeVault(data)
        Self.vaultCache[service] = vault
        Self.missingVaultServices.remove(service)
        return vault
    }

    private func vault(from items: [ServerBookmarkKeychainItem]) throws -> PasswordVault? {
        guard let item = items.first(where: { $0.account == Self.vaultAccount }) else { return nil }
        return try decodeVault(item.data)
    }

    private func decodeVault(_ data: Data) throws -> PasswordVault {
        guard let vault = try? JSONDecoder().decode(PasswordVault.self, from: data),
              vault.version == PasswordVault.currentVersion else {
            throw ServerBookmarkKeychainError.invalidVaultEncoding
        }
        return vault
    }

    private func saveVault(_ vault: PasswordVault) throws {
        if vault.passwords.isEmpty {
            try storage.delete(service: service, account: Self.vaultAccount)
            Self.vaultCache.removeValue(forKey: service)
            Self.missingVaultServices.insert(service)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(vault)
        try storage.setData(data, service: service, account: Self.vaultAccount)
        Self.vaultCache[service] = vault
        Self.missingVaultServices.remove(service)
    }
}
