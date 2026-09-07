import DayreedCore
import Foundation
import Security

public protocol ProviderCredentialStore: Sendable {
    func read(for providerID: UUID) throws -> String?
    func write(_ value: String?, for providerID: UUID) throws
}

public struct KeychainCredentialStore: ProviderCredentialStore {
    public static let service = "YunaBuild.Dayreed.providers"
    public init() {}
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }
    public func read(for providerID: UUID) throws -> String? {
        var request = query(providerID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw AnalysisError.credentials }
        return value
    }
    public func write(_ value: String?, for providerID: UUID) throws {
        let query = query(providerID)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AnalysisError.credentials }
            return
        }
        guard !value.isEmpty, value.utf8.count <= 16_384,
              !value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw AnalysisError.credentials }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AnalysisError.credentials }
        } else if status != errSecSuccess { throw AnalysisError.credentials }
    }
}

public struct ProviderSettingsService: Sendable {
    private let store: DayreedStore
    private let credentials: any ProviderCredentialStore
    public init(store: DayreedStore, credentials: any ProviderCredentialStore = KeychainCredentialStore()) {
        self.store = store; self.credentials = credentials
    }
    public func configurations() throws -> [ProviderConfiguration] { try store.providerConfigurations() }
    public func save(_ configuration: ProviderConfiguration) throws { try store.saveProviderConfiguration(configuration) }
    public func select(id: UUID?) throws { try store.selectProvider(id: id) }
    public func remove(id: UUID) throws {
        // Keep the configuration available for retry if Keychain refuses deletion. Removing the
        // database row first would hide an orphaned credential from the Settings interface.
        try store.invalidatePendingAnalysis()
        try credentials.write(nil, for: id)
        try store.removeProviderConfiguration(id: id)
    }
    /// Call only for a key explicitly supplied in Dayreed Settings. Never probes environment keys.
    public func setAPIKey(_ value: String?, for id: UUID) throws {
        guard try store.providerConfigurations().contains(where: { $0.id == id }) else { throw AnalysisError.notFound }
        try store.invalidatePendingAnalysis()
        try credentials.write(value, for: id)
    }
}
