import Foundation
import Security

enum APIKeyStore {
    private static let service = "com.danbarclay.onair.openai"
    private static let account = "OPENAI_API_KEY"

    static func load() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let value = String(data: data, encoding: .utf8), value.hasPrefix("sk-") { return value }
        guard status == errSecItemNotFound else { throw TranscriptionError.credentials }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".env")
        guard let contents = try? String(contentsOf: path, encoding: .utf8), let key = parse(contents) else {
            throw TranscriptionError.credentials
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(key.utf8),
        ]
        let saved = SecItemAdd(item as CFDictionary, nil)
        guard saved == errSecSuccess || saved == errSecDuplicateItem else { throw TranscriptionError.credentials }
        return key
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
