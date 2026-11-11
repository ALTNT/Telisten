import Foundation
import Security

final class KeychainStore: @unchecked Sendable {
    private static let defaultService = "ad.neko.player"
    private static let accessGroupPrefixInfoKey = "TelistenKeychainAccessGroupPrefix"

    private let service: String
    private let accessGroupPrefix: String?
    private let lock = NSLock()

    init(
        service: String = KeychainStore.defaultService,
        accessGroupPrefix: String? = nil
    ) {
        self.service = service
        let configuredPrefix = accessGroupPrefix
            ?? Bundle.main.object(forInfoDictionaryKey: Self.accessGroupPrefixInfoKey) as? String
        self.accessGroupPrefix = configuredPrefix.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
            return trimmed.hasSuffix(".") ? trimmed : "\(trimmed)."
        }
    }

    private enum AccountKey {
        static let searchBots = "search-bots.v1"
        static let accountRegistry = "telegram.accounts.v1"
        static func tdlibDatabaseKey(accountID: String) -> String {
            "tdlib.database-key.\(accountID)"
        }
    }

    private struct StoredAccountRegistry: Codable {
        var accounts: [TelegramAccount]
        var activeAccountID: String?
    }

    private struct SyncedValue: Codable {
        var payload: Data
        var modifiedAt: Date
    }

    private struct DecodedSyncedValue {
        var payload: Data
        var modifiedAt: Date
        var encoded: Data
    }

    func availableSessionAccountIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: "tdlib.authorizedAccountIDs") ?? []
    }

    @discardableResult
    func setTDLibAccount(_ accountID: String, authorized: Bool) -> Bool {
        withLock {
            var accountIDs = Set(UserDefaults.standard.stringArray(forKey: "tdlib.authorizedAccountIDs") ?? [])
            if authorized {
                accountIDs.insert(accountID)
            } else {
                accountIDs.remove(accountID)
            }
            UserDefaults.standard.set(accountIDs.sorted(), forKey: "tdlib.authorizedAccountIDs")
            return true
        }
    }

    func loadOrCreateTDLibDatabaseKey(accountID: String) -> Data? {
        withLock {
            let account = AccountKey.tdlibDatabaseKey(accountID: accountID)
            if let data = loadDeviceLocal(account: account), data.count == 32 { return data }
            let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            return saveDeviceLocal(data, account: account) ? data : nil
        }
    }

    func copyTDLibDatabaseKey(from sourceAccountID: String, to destinationAccountID: String) -> Bool {
        guard sourceAccountID != destinationAccountID else { return true }
        return withLock {
            guard let data = loadDeviceLocal(account: AccountKey.tdlibDatabaseKey(accountID: sourceAccountID)),
                  data.count == 32 else { return false }
            return saveDeviceLocal(data, account: AccountKey.tdlibDatabaseKey(accountID: destinationAccountID))
        }
    }

    @discardableResult
    func saveSearchBotConfigs(_ configs: [SearchBotConfig]) -> Bool {
        guard let data = try? JSONEncoder().encode(configs) else { return false }
        return withLock {
            saveSynced(data, account: AccountKey.searchBots)
        }
    }

    /// Returns `nil` when no configuration has ever been stored. An empty array is a
    /// deliberate user choice and is preserved across devices.
    func loadSearchBotConfigs() -> [SearchBotConfig]? {
        withLock {
            guard let data = loadSynced(account: AccountKey.searchBots) else { return nil }
            return try? JSONDecoder().decode([SearchBotConfig].self, from: data)
        }
    }

    @discardableResult
    func saveAccountRegistry(accounts: [TelegramAccount], activeAccountID: String?) -> Bool {
        guard let data = try? JSONEncoder().encode(
            StoredAccountRegistry(accounts: accounts, activeAccountID: activeAccountID)
        ) else { return false }
        return withLock {
            saveSynced(data, account: AccountKey.accountRegistry)
        }
    }

    func loadAccountRegistry() -> (accounts: [TelegramAccount], activeAccountID: String?)? {
        withLock {
            guard let data = loadSynced(account: AccountKey.accountRegistry),
                  let registry = try? JSONDecoder().decode(StoredAccountRegistry.self, from: data) else {
                return nil
            }
            return (registry.accounts, registry.activeAccountID)
        }
    }

    /// Account descriptors and user configuration may follow the user through
    /// iCloud Keychain. TDLib's database encryption key remains device-local.
    @discardableResult
    private func saveSynced(_ data: Data, account: String) -> Bool {
        guard let encoded = try? JSONEncoder().encode(
            SyncedValue(payload: data, modifiedAt: Date())
        ) else { return false }
        do {
            try save(encoded, account: account, synchronizable: true)
            delete(account: account, synchronizable: false)
            return true
        } catch {
            do {
                try save(encoded, account: account, synchronizable: false)
                return true
            } catch {
                return false
            }
        }
    }

    private func loadSynced(account: String) -> Data? {
        let local = decodedSyncedValue(load(account: account, synchronizable: false, service: service))
        let cloud = decodedSyncedValue(load(account: account, synchronizable: true, service: service))
        let selected: DecodedSyncedValue
        switch (local, cloud) {
        case let (local?, cloud?):
            selected = local.modifiedAt > cloud.modifiedAt ? local : cloud
        case let (local?, nil):
            selected = local
        case let (nil, cloud?):
            selected = cloud
        case (nil, nil):
            return nil
        }

        if let local, selected.modifiedAt == local.modifiedAt,
           (cloud == nil || local.modifiedAt > cloud!.modifiedAt) {
            do {
                try save(selected.encoded, account: account, synchronizable: true, service: service)
                delete(account: account, synchronizable: false, service: service)
            } catch {
                // Keep the newer local fallback and retry when iCloud Keychain is available.
            }
        } else if cloud != nil {
            delete(account: account, synchronizable: false, service: service)
        }
        return selected.payload
    }

    private func decodedSyncedValue(_ data: Data?) -> DecodedSyncedValue? {
        guard let data else { return nil }
        if let value = try? JSONDecoder().decode(SyncedValue.self, from: data) {
            return DecodedSyncedValue(
                payload: value.payload,
                modifiedAt: value.modifiedAt,
                encoded: data
            )
        }
        // Values written by an earlier build of the current app remain readable.
        return DecodedSyncedValue(payload: data, modifiedAt: .distantPast, encoded: data)
    }

    @discardableResult
    private func saveDeviceLocal(_ data: Data, account: String) -> Bool {
        do {
            try save(data, account: account, synchronizable: false)
            return true
        } catch {
            return false
        }
    }

    private func loadDeviceLocal(account: String) -> Data? {
        load(account: account, synchronizable: false, service: service)
    }

    private func save(
        _ data: Data,
        account: String,
        synchronizable: Bool,
        service itemService: String? = nil
    ) throws {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: itemService ?? service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
        ]
        addAccessOptions(to: &query, service: itemService ?? service)
        let values: [CFString: Any] = [
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }

        let status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func load(
        account: String,
        synchronizable: Bool,
        service itemService: String? = nil
    ) -> Data? {
        try? loadThrowing(
            account: account,
            synchronizable: synchronizable,
            service: itemService
        )
    }

    private func loadThrowing(
        account: String,
        synchronizable: Bool,
        service itemService: String? = nil
    ) throws -> Data? {
        var result: CFTypeRef?
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: itemService ?? service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        addAccessOptions(to: &query, service: itemService ?? service)
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return data
    }

    private func delete(
        account: String,
        synchronizable: Bool,
        service itemService: String? = nil
    ) {
        try? deleteThrowing(
            account: account,
            synchronizable: synchronizable,
            service: itemService
        )
    }

    private func deleteThrowing(
        account: String,
        synchronizable: Bool,
        service itemService: String? = nil
    ) throws {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: itemService ?? service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
        ]
        addAccessOptions(to: &query, service: itemService ?? service)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func addAccessOptions(to query: inout [CFString: Any], service itemService: String) {
        if let accessGroupPrefix {
            query[kSecAttrAccessGroup] = "\(accessGroupPrefix)\(itemService)"
        }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain] = true
        #endif
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
