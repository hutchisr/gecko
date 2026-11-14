import Foundation
import Security

/// Account passwords in the Keychain, readable after the first unlock so the
/// app can reconnect in the background, and shared through the App Group with
/// the notification extension, which signs in to fetch what a push announced.
struct KeychainPasswords: PasswordKeeper {
    private static let service = "me.anemoneya.gecko.xmpp"
#if targetEnvironment(macCatalyst)
    // The local Mac build has no App Group, and no extension to share with.
    private static let group: String? = nil
#else
    private static let group: String? = "group.me.anemoneya.gecko"
#endif

    /// Without `group`, a lookup searches every group the app may read.
    private func query(_ jid: String, group: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: jid]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    private func find(_ query: [String: Any]) -> (password: String, group: String?)? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecReturnAttributes as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return (password, item[kSecAttrAccessGroup as String] as? String)
    }

    func password(for jid: String) -> String? {
        if let shared = find(query(jid, group: Self.group)) { return shared.password }
        if let local = LocalPasswords.password(for: jid) { return local }
        // Saved before passwords were shared: move it into the group, deleting
        // the old copy only once the shared one is written.
        guard let group = Self.group, let old = find(query(jid, group: nil)), old.group != group else { return nil }
        if add(old.password, for: jid, group: group) == errSecSuccess, let oldGroup = old.group {
            SecItemDelete(query(jid, group: oldGroup) as CFDictionary)
        }
        return old.password
    }

    func setPassword(_ password: String?, for jid: String) {
        SecItemDelete(query(jid, group: nil) as CFDictionary)
        LocalPasswords.set(nil, for: jid)
        guard let password else { return }
        let status = add(password, for: jid, group: Self.group)
        if status == errSecMissingEntitlement {
            // An unsigned local build may not use the Keychain at all.
            LocalPasswords.set(password, for: jid)
        } else if status != errSecSuccess, Self.group != nil {
            // Not shareable (no App Group entitlement): kept for the app alone
            // rather than lost.
            add(password, for: jid, group: nil)
        }
    }

    @discardableResult
    private func add(_ password: String, for jid: String, group: String?) -> OSStatus {
        var item = query(jid, group: group)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { NSLog("gecko-core: Keychain write failed (%d)", status) }
        return status
    }
}

/// Where passwords go when the Keychain refuses an unsigned local build: a
/// file only this user can read, beside the app's data.
/// ponytail: plain text, as the Dino-based Gecko kept them in `dino.db`;
/// properly signed builds never get here.
private enum LocalPasswords {
    private static var file: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xdg-data/gecko/passwords.plist")
    }

    private static func all() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let passwords = try? PropertyListDecoder().decode([String: String].self, from: data) else { return [:] }
        return passwords
    }

    static func password(for jid: String) -> String? { all()[jid] }

    static func set(_ password: String?, for jid: String) {
        var passwords = all()
        guard passwords[jid] != password else { return }
        passwords[jid] = password
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? PropertyListEncoder().encode(passwords) else { return }
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
