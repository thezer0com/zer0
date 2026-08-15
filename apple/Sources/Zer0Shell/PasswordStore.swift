import Foundation
import Security
import Zer0Core

/// A saved login, on its way into a page.
///
/// The only type in the shell that holds a password, and it exists for the
/// length of one fill. It is not `Codable`, not `CustomStringConvertible` and
/// not `Equatable` on purpose: every one of those is a way for a value to reach
/// a log line, a crash report or a test failure message, and this is the value
/// that must not.
struct SavedPassword {
    let username: String
    let password: String
}

/// Where saved logins live: the same Keychain `SecretStore` already owns, in
/// the class meant for them.
///
/// # Why this is a second protocol beside `SecretStore` rather than more cases
/// on it
///
/// `SecretStore` is keyed by a *name* — `anthropic` — because that is what a
/// config file refers to. A login is keyed by an origin and an account, which
/// is what `kSecClassInternetPassword` is already keyed by. Forcing one into
/// the other would mean inventing a name format, and a name format is an index
/// this design does not want to own (see `passwords.rs`).
///
/// It is the same seam in the sense that matters: one place in the app that
/// talks to the Keychain, a protocol so a Linux host can have its own, and a
/// test double so the suite never touches the machine's real keychain.
@MainActor
protocol PasswordStore {
    /// Which accounts exist for this origin, in this space. **Never a password.**
    ///
    /// Asked whenever a login page opens, so it is the query that must not put
    /// every password on the machine into memory to answer. Attributes only —
    /// which is also the branch that cannot raise a Keychain dialog.
    func logins(for origin: String, scope: String) throws -> [SavedLogin]

    /// The password behind one account, read at the moment it is filled and not
    /// before.
    func password(for origin: String, scope: String, username: String) throws -> String

    func save(_ credential: SavedPassword, for origin: String, scope: String) throws
    func forget(_ username: String, for origin: String, scope: String) throws

    /// Everything saved in one space, for the settings pane. Attributes only.
    func allLogins(scope: String) throws -> [SavedLogin]

    /// Drop every login in a space, for when the space is closed.
    ///
    /// ADR-0007 says closing a Space deletes its store because leaving the jar
    /// on disk would be a privacy leak with no way to reach it from the
    /// interface. A Keychain item outliving the space it belonged to is the
    /// same leak, in a place even further from the interface.
    func forgetEverything(scope: String) throws
}

/// The macOS Keychain, in the internet-password class.
///
/// # Why the item looks like this
///
/// | Keychain Access | attribute | value |
/// | --- | --- | --- |
/// | Name | `kSecAttrLabel` | `github.com (zer0 — Work)` |
/// | Kind | `kSecAttrDescription` | `zer0 saved login` |
/// | Where | `kSecAttrServer` + port + protocol | the origin |
/// | Account | `kSecAttrAccount` | the username |
/// | — | `kSecAttrSecurityDomain` | which Space |
///
/// **`kSecAttrSecurityDomain` is what makes two Spaces two logins.** It is part
/// of an internet-password item's identity on macOS, so `github.com` in Work
/// and `github.com` in Personal cannot collide — not because this file is
/// careful, but because the platform's own uniqueness rule says they are
/// different items. That is the product's premise (ADR-0007: a Space is a
/// cookie jar, and a cookie jar is an identity) enforced one level below us.
///
/// `kSecUseDataProtectionKeychain` is off, for the reason `SecretStore.swift`
/// already records and which was measured again for this feature: an unsigned
/// binary asking for the data-protection keychain gets `errSecMissingEntitlement`
/// (-34018) and can store nothing at all. zer0 is built and run unsigned every
/// day. This flips the day there is a signing identity; the tests do not care.
@MainActor
final class KeychainPasswords: PasswordStore {
    /// Written into every item so a person can find zer0's logins in Keychain
    /// Access, and so a stray one two years from now can be traced.
    static let description = "zer0 saved login"

    /// Names the space in the label, so the Keychain Access row says which
    /// identity the login belongs to rather than showing the same host twice
    /// with nothing to tell them apart.
    ///
    /// A closure rather than a stored name because a space can be renamed and
    /// the browser outlives the rename. Read at the moment an item is written,
    /// which is the only moment it is used.
    let spaceName: @MainActor () -> String

    init(spaceName: @escaping @MainActor () -> String) {
        self.spaceName = spaceName
    }

    func logins(for origin: String, scope: String) throws -> [SavedLogin] {
        guard let fields = passwordKeychainFields(origin: origin) else { return [] }
        var query = Self.identity(fields: fields, scope: scope)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        return try Self.accounts(matching: query, origin: origin)
    }

    func allLogins(scope: String) throws -> [SavedLogin] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: scope,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Keychain.error(status, name: "") }

        return (result as? [[String: Any]] ?? []).compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let server = item[kSecAttrServer as String] as? String
            else { return nil }
            let https = (item[kSecAttrProtocol as String] as? String)
                == (kSecAttrProtocolHTTPS as String)
            let scheme = https ? "https" : "http"
            let port = item[kSecAttrPort as String] as? Int ?? 0
            let bare = (https && port == 443) || (!https && port == 80) || port == 0
            let origin = bare ? "\(scheme)://\(server)" : "\(scheme)://\(server):\(port)"
            return SavedLogin(origin: origin, username: account)
        }
        .sorted { ($0.origin, $0.username) < ($1.origin, $1.username) }
    }

    func password(for origin: String, scope: String, username: String) throws -> String {
        guard let fields = passwordKeychainFields(origin: origin) else {
            throw SecretStoreError.notFound(name: username)
        }
        var query = Self.identity(fields: fields, scope: scope, username: username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw Keychain.error(status, name: username) }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.failed(
                name: username,
                status: errSecDecode,
                message: "the stored value is not text"
            )
        }
        return secret
    }

    func save(_ credential: SavedPassword, for origin: String, scope: String) throws {
        guard let fields = passwordKeychainFields(origin: origin) else {
            throw SecretStoreError.failed(
                name: credential.username,
                status: errSecParam,
                message: "\(origin) is not an origin a login can be saved for"
            )
        }
        let data = Data(credential.password.utf8)
        var attributes = Self.identity(fields: fields, scope: scope, username: credential.username)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "\(fields.host) (zer0 — \(spaceName()))"
        attributes[kSecAttrDescription as String] = Self.description

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // No upsert exists. The update takes only real attributes — no
            // class, no return keys — so the value goes on its own, against the
            // same identity the add used. If the two disagreed, an update would
            // quietly create a second item, which is the bug `SecretStore.swift`
            // already records once.
            let update = [kSecValueData as String: data]
            let updated = SecItemUpdate(
                Self.identity(fields: fields, scope: scope, username: credential.username)
                    as CFDictionary,
                update as CFDictionary
            )
            guard updated == errSecSuccess else {
                throw Keychain.error(updated, name: credential.username)
            }
            return
        }
        guard status == errSecSuccess else { throw Keychain.error(status, name: credential.username) }
    }

    func forget(_ username: String, for origin: String, scope: String) throws {
        guard let fields = passwordKeychainFields(origin: origin) else { return }
        let status = SecItemDelete(
            Self.identity(fields: fields, scope: scope, username: username) as CFDictionary
        )
        // Already gone is the outcome that was asked for.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Keychain.error(status, name: username)
        }
    }

    func forgetEverything(scope: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: scope,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Keychain.error(status, name: "")
        }
    }

    /// What makes an item unique, written once so a query, an add and an update
    /// can never disagree about which item they mean.
    ///
    /// Every attribute here is part of the Keychain's primary key for an
    /// internet password. `username` is left out for the query that lists
    /// accounts and put in for the ones that name a single login.
    private static func identity(
        fields: KeychainFields,
        scope: String,
        username: String? = nil
    ) -> [String: Any] {
        var identity: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: fields.host,
            kSecAttrPort as String: Int(fields.port),
            kSecAttrProtocol as String: fields.scheme == "https"
                ? kSecAttrProtocolHTTPS
                : kSecAttrProtocolHTTP,
            // The Space. Part of the primary key, which is what makes two
            // Spaces two logins rather than one overwriting the other.
            kSecAttrSecurityDomain as String: scope,
        ]
        if let username { identity[kSecAttrAccount as String] = username }
        return identity
    }

    private static func accounts(
        matching query: [String: Any],
        origin: String
    ) throws -> [SavedLogin] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // Nothing saved yet is the state of every machine before anybody logs
        // in anywhere, so it is an empty list rather than a failure.
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Keychain.error(status, name: "") }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { item in
            (item[kSecAttrAccount as String] as? String)
                .map { SavedLogin(origin: origin, username: $0) }
        }
    }
}

/// A password store that keeps nothing, for tests.
///
/// Exists for the same reason `InMemorySecrets` does: the tests that matter
/// most here are about what is *refused*, and they have to be able to hold a
/// real-looking password without a signing identity and without leaving
/// anything on the machine running the suite.
@MainActor
final class InMemoryPasswords: PasswordStore {
    /// Keyed the way the Keychain keys it, so a test that gets the scoping
    /// wrong fails here rather than passing against a laxer double.
    private struct Key: Hashable {
        let scope: String
        let origin: String
        let username: String
    }

    private var stored: [Key: String] = [:]

    /// Names and verbs, never values. A double that let a test read a password
    /// back out would be a double that proves the leak it exists to rule out.
    private(set) var crossings: [String] = []

    init() {}

    func logins(for origin: String, scope: String) throws -> [SavedLogin] {
        stored.keys
            .filter { $0.scope == scope && $0.origin == origin }
            .map { SavedLogin(origin: $0.origin, username: $0.username) }
            .sorted { $0.username < $1.username }
    }

    func allLogins(scope: String) throws -> [SavedLogin] {
        stored.keys
            .filter { $0.scope == scope }
            .map { SavedLogin(origin: $0.origin, username: $0.username) }
            .sorted { ($0.origin, $0.username) < ($1.origin, $1.username) }
    }

    func password(for origin: String, scope: String, username: String) throws -> String {
        guard let value = stored[Key(scope: scope, origin: origin, username: username)] else {
            throw SecretStoreError.notFound(name: username)
        }
        crossings.append("read(\(origin), \(username))")
        return value
    }

    func save(_ credential: SavedPassword, for origin: String, scope: String) throws {
        stored[Key(scope: scope, origin: origin, username: credential.username)] =
            credential.password
        crossings.append("save(\(origin), \(credential.username))")
    }

    func forget(_ username: String, for origin: String, scope: String) throws {
        stored.removeValue(forKey: Key(scope: scope, origin: origin, username: username))
        crossings.append("forget(\(origin), \(username))")
    }

    func forgetEverything(scope: String) throws {
        stored = stored.filter { $0.key.scope != scope }
        crossings.append("forgetEverything(\(scope))")
    }
}
