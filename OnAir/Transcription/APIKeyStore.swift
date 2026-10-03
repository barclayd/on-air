import Foundation
import Security

enum APIKeyStore {
    private static let service = "com.danbarclay.onair.openai"
    private static let account = "OPENAI_API_KEY"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
    }
    private static let managedKey = "credentialsManagedInSettings"

    static func load() throws -> String {
        do {
            guard let value = try read() else { throw TranscriptionError.credentials }
            return value
        } catch { throw TranscriptionError.credentials }
    }

    static func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let value = String(data: data, encoding: .utf8), value.hasPrefix("sk-") { return value }
        guard status == errSecItemNotFound else { throw CredentialStoreError.unavailable }
        // Preserve existing developer installs, but never resurrect a key removed in Settings.
        guard !UserDefaults.standard.bool(forKey: managedKey) else { return nil }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".env")
        guard let contents = try? String(contentsOf: path, encoding: .utf8), let key = parse(contents) else {
            return nil
        }
        try save(key)
        return key
    }

    static func save(_ key: String) throws {
        let value = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(value) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStoreError.unavailable }
        UserDefaults.standard.set(true, forKey: managedKey)
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.unavailable }
        UserDefaults.standard.set(true, forKey: managedKey)
    }

    /// Parse a literal dotenv assignment; never source or execute the user's file.
    static func parse(_ contents: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline) {
            var entry = line.trimmingCharacters(in: .whitespaces)
            if entry.hasPrefix("export ") { entry = String(entry.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = entry.firstIndex(of: "="), entry[..<equals].trimmingCharacters(in: .whitespaces) == account else { continue }
            var value = String(entry[entry.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                guard let end = value.dropFirst().firstIndex(of: quote) else { return nil }
                value = String(value[value.index(after: value.startIndex)..<end])
            } else {
                value = String(value.split(whereSeparator: { $0.isWhitespace || $0 == "#" }).first ?? "")
            }
            return value.hasPrefix("sk-") && value.count > 10 ? value : nil
        }
        return nil
    }
}

@MainActor
protocol CredentialStoring {
    func read() throws -> String?
    func save(_ key: String) throws
    func remove() throws
}

struct KeychainCredentials: CredentialStoring {
    func read() throws -> String? { try APIKeyStore.read() }
    func save(_ key: String) throws { try APIKeyStore.save(key) }
    func remove() throws { try APIKeyStore.remove() }
}

enum CredentialStoreError: Error {
    case unavailable
}
