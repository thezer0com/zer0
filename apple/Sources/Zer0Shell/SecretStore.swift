import Foundation
import Security
import Zer0Core

/// Where the values behind the config file's credential names actually live.
///
/// The config file says `credential = "anthropic"`. This is the other half:
/// given that name, the key. Deliberately the only thing in the app that can
/// produce one — the Rust core has no type that can hold a secret, no call that
/// accepts one and no call that returns one, so "a key cannot reach the config
/// file" is a property of the seam rather than a rule somebody has to keep.
///
/// A protocol rather than the Keychain directly, for two reasons. The Keychain
/// is a platform API and a Linux host will have a different one. And the test
/// that matters most in this feature — that a secret never reaches the file —
/// has to be able to put a real-looking key somewhere without a signed binary
/// and without leaving anything behind on the machine running it.
@MainActor
protocol SecretStore {
    /// Which credentials exist, by name, without reading a single value.
    ///
    /// This is the whole question asked at launch, and it is asked in this
    /// shape on purpose: reading the values would mean holding every API key
    /// the person has in memory from the moment the browser opens, to answer a
    /// question that is only about presence.
    func names() throws -> [String]

    /// The value behind a name.
    ///
    /// Called at the moment it is used — before a request, before spawning an
    /// MCP server — and not before.
    func secret(named name: String) throws -> String

    func store(_ secret: String, named name: String) throws
    func remove(named name: String) throws
}

/// Why a credential could not be read or written, in the shapes a person can
/// act on.
///
/// `notFound` is the one that matters and it is deliberately not an error state
/// in the interface: five minutes after cloning a dotfiles repository it is
/// true of every credential in the file, and that is a to-do list rather than a
/// fault. It carries the name so the interface can say which key to add.
enum SecretStoreError: LocalizedError, Equatable {
    /// The config file names this credential and nothing here has it.
    case notFound(name: String)
    /// Somebody clicked Deny, or dismissed the dialog.
    case denied(name: String)
    /// Something wanted to ask and could not — a locked keychain, a login
    /// session with no UI.
    case cannotAsk(name: String)
    /// Anything else, with the system's own words kept for the log.
    case failed(name: String, status: OSStatus, message: String)

    var errorDescription: String? {
        switch self {
        case let .notFound(name):
            "There is no key named “\(name)” in your Keychain yet."
        case let .denied(name):
            "zer0 was not allowed to read the key named “\(name)”."
        case let .cannotAsk(name):
            "Your Keychain is locked, so the key named “\(name)” could not be read."
        case let .failed(name, status, message):
            "The key named “\(name)” could not be read: \(message) (\(status))."
        }
    }

    /// What to do about it, said in one sentence. Shown under the message,
    /// because an error that does not say what to do next is a dead end.
    var recoverySuggestion: String? {
        switch self {
        case let .notFound(name):
            "Add it in Settings, or in Keychain Access as a password named “\(name)” under “\(Keychain.service)”."
        case .denied:
            "Open Keychain Access, find the entry under “\(Keychain.service)”, and allow zer0 to use it."
        case .cannotAsk:
            "Unlock your login keychain and try again."
        case .failed:
            "Try again. If it keeps happening, remove the entry in Keychain Access and add the key again."
        }
    }
}

/// The macOS Keychain.
///
/// # Where an item shows up
///
/// One generic password per credential, under a single service so that
/// everything zer0 holds is one search away in **Keychain Access**. The
/// service is the channel's bundle id rather than a literal (ADR-0112), so
/// stable and canary each see only their own jar — a query built here cannot
/// spell the other channel's service. The attributes are chosen for what that
/// window shows:
///
/// | Keychain Access | attribute | value |
/// | --- | --- | --- |
/// | Name | `kSecAttrLabel` | `zer0 — anthropic` |
/// | Kind | `kSecAttrDescription` | `zer0 credential` |
/// | Where | `kSecAttrService` | the bundle id (`com.thezer0.browser`) |
/// | Account | `kSecAttrAccount` | `anthropic` |
/// | Comments | `kSecAttrComment` | which config file names it |
///
/// The comment is the one that pays for itself: somebody finding a stray entry
/// two years from now gets told which file refers to it and under what name.
/// Only service and account are part of the item's identity — the rest are
/// there to be read by a person.
///
/// # Why the data-protection keychain is not switched on
///
/// `kSecUseDataProtectionKeychain` is the modern answer and it is the wrong one
/// here *for now*: it derives access from the app's `application-identifier`
/// entitlement, so an unsigned or ad-hoc-signed binary gets
/// `errSecMissingEntitlement` and cannot store anything at all. `zer0` is built
/// and run unsigned every day. The file-based keychain trusts the app that
/// created an item and prompts when the signature changes, which is an
/// annoyance during development and a recoverable one — a person clicks Always
/// Allow. Failing outright is not recoverable. This flips the day there is a
/// signing identity in the build; it is one constant and the tests do not care.
/// A class rather than a struct only so it can satisfy `ChatCredentialStore`,
/// which is `AnyObject`. It holds no mutable state.
@MainActor
final class Keychain: SecretStore {
    /// The bundle id stable ships as. Written once because two rules read it:
    /// the fallback for a process with no bundle id of its own, and the one
    /// service allowed to inherit the legacy jar. A canary id, or a future
    /// third channel, must not quietly become an heir by matching a prefix.
    nonisolated static let stableBundleId = "com.thezer0.browser"

    /// The "Where" column, and what to search for in Keychain Access.
    ///
    /// `nonisolated` because the error messages name it, and an error is
    /// rendered wherever it is caught.
    nonisolated static let service = service(
        forBundleId: Bundle.main.bundleIdentifier ?? stableBundleId
    )

    /// The rule behind `service`. A function of the bundle id, in the shape
    /// `BrowserModel.storageDir(forBundleId:)` set for the profile directory:
    /// pure, so the isolation is testable against the rule rather than
    /// against the test runner's own bundle id. It reads as the identity
    /// today; if the service ever needs a suffix or a prefix, this is the one
    /// place it changes.
    nonisolated static func service(forBundleId bundleId: String) -> String {
        bundleId
    }

    /// Where every credential lived before the channels split (ADR-0112).
    /// Kept as a constant because the carry-over reads it, and because
    /// `"zer0"` is a fact about the past rather than a service this app will
    /// ever write again.
    nonisolated static let legacyService = "zer0"

    /// Named in the comment on every item, so a stray entry can be traced back
    /// to the file that refers to it.
    let configPath: String

    init(configPath: String = defaultConfigPath()) {
        self.configPath = configPath
        // In init rather than at first access so that a launch either carries
        // the legacy jar across before anybody reads, or visibly does not —
        // there is no window where Settings lists an empty service while the
        // copy has yet to run.
        migrateLegacyCredentials()
    }

    func names() throws -> [String] {
        try Self.names(service: Self.service)
    }

    /// The accounts under one service. Split out of the instance method so
    /// the carry-over can ask the same question of the legacy jar — the
    /// instance path answers with this channel's service and only that one.
    static func names(service: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Attributes, never data: this is the branch that cannot prompt,
            // which is what makes asking at launch free.
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        // No entries at all is reported as "not found" rather than an empty
        // list. It is the state of every machine before anybody adds a key, so
        // treating it as a failure would make a first launch look broken.
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw Self.error(status, name: "")
        }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    func secret(named name: String) throws -> String {
        try Self.secret(named: name, service: Self.service)
    }

    /// The value behind a name, under an explicit service. Static so the
    /// carry-over can read the legacy jar through the same code the config
    /// reads this channel's jar with.
    static func secret(named name: String, service: String) throws -> String {
        var query = Self.identity(of: name, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw Self.error(status, name: name) }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.failed(
                name: name,
                status: errSecDecode,
                message: "the stored value is not text"
            )
        }
        return secret
    }

    func store(_ secret: String, named name: String) throws {
        try Self.store(secret, named: name, service: Self.service, configPath: configPath)
    }

    static func store(
        _ secret: String,
        named name: String,
        service: String,
        configPath: String
    ) throws {
        let data = Data(secret.utf8)
        var attributes = Self.identity(of: name, service: service)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "zer0 — \(name)"
        attributes[kSecAttrDescription as String] = "zer0 credential"
        attributes[kSecAttrComment as String] =
            "Used by zer0. Referred to in \(configPath) as credential = \"\(name)\"."

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // There is no upsert. Updating takes only real attributes — no
            // class, no return keys — so the value goes on its own.
            let update = [kSecValueData as String: data]
            let updated = SecItemUpdate(
                Self.identity(of: name, service: service) as CFDictionary,
                update as CFDictionary
            )
            guard updated == errSecSuccess else { throw Self.error(updated, name: name) }
            return
        }
        guard status == errSecSuccess else { throw Self.error(status, name: name) }
    }

    func remove(named name: String) throws {
        let status = SecItemDelete(Self.identity(of: name, service: Self.service) as CFDictionary)
        // Already gone is the outcome that was asked for.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(status, name: name)
        }
    }

    /// Service plus account, which is what makes an item unique. Written once
    /// so a query and an update can never disagree about which item they mean —
    /// and they must not, or an update quietly creates a second entry.
    private static func identity(of name: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
    }

    /// The one-shot carry-over from the era when every channel shared one
    /// service (ADR-0112): stable copies the legacy jar into its own service
    /// the first time it finds its own empty, and never deletes the original —
    /// the legacy jar is the rollback.
    ///
    /// Best-effort on purpose. This runs in `init`, at boot, where a failure
    /// must cost a missing copy — retried next launch while the new service is
    /// still empty — rather than a browser that will not start.
    private func migrateLegacyCredentials() {
        // A Keychain that will not answer reads as "nothing to do"; the next
        // launch asks again.
        guard let legacy = try? Self.names(service: Self.legacyService),
              let fresh = try? Self.names(service: Self.service),
              Self.shouldMigrate(
                  legacyCount: legacy.count,
                  newCount: fresh.count,
                  service: Self.service
              )
        else { return }
        for name in legacy {
            // Item by item, not all-or-nothing: one entry the Keychain
            // refuses to hand over (a Deny on the access prompt) must not
            // strand the rest, and an entry that fails to cross is not lost —
            // the legacy jar is never deleted.
            guard let secret = try? Self.secret(named: name, service: Self.legacyService)
            else { continue }
            try? Self.store(secret, named: name, service: Self.service, configPath: configPath)
        }
    }

    /// Whether the carry-over runs, as a pure function of the two counts and
    /// the service asking, so the decision is testable without a keychain.
    ///
    /// Stable only, decided by the service itself rather than by a flag at the
    /// call site: canary is a new bundle id and inherits nothing, and the
    /// check living here is what makes "canary starts clean" structural
    /// instead of a rule somebody has to keep at the door. And one-shot: any
    /// entry already present means the carry-over already ran — a merge that
    /// tops up the missing names would be a repair that guesses.
    nonisolated static func shouldMigrate(
        legacyCount: Int,
        newCount: Int,
        service: String
    ) -> Bool {
        service == stableBundleId && legacyCount > 0 && newCount == 0
    }

    /// An `OSStatus` as something the interface can act on.
    ///
    /// Split out and made `static` so the mapping can be tested without a
    /// keychain, which is the only way it gets tested at all: the codes that
    /// matter are the ones that are awkward to provoke on purpose.
    static func error(_ status: OSStatus, name: String) -> SecretStoreError {
        switch status {
        case errSecItemNotFound:
            .notFound(name: name)
        // Cancelling the dialog and clicking Deny arrive as different codes,
        // and both mean the same thing to the person: they said no.
        case errSecUserCanceled, errSecAuthFailed:
            .denied(name: name)
        // Something needed to ask and could not: a locked keychain, a session
        // with no UI, dark wake.
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecNotAvailable:
            .cannotAsk(name: name)
        default:
            .failed(
                name: name,
                status: status,
                message: SecCopyErrorMessageString(status, nil) as String?
                    ?? "OSStatus \(status)"
            )
        }
    }
}

/// The narrower view the settings panes were written against.
///
/// Kept as the seam the panes reach through, and deliberately kept narrow: a
/// pane only ever needs to know *whether* there is a value under a name, and
/// `has` returning `Bool` is what makes reading one impossible from there.
///
/// What it no longer has is a Keychain implementation of its own. There were
/// briefly two, under different service names, which meant a key saved in
/// Settings went in under one and was looked for under the other — stored
/// successfully and never found again. `Keychain` below is the only one.
///
/// New code should prefer `SecretStore`: `has` cannot tell "no such key" from
/// "the Keychain would not answer", and that difference is the whole of
/// `ConfigHost.credentialStoreError`.
@MainActor
protocol ChatCredentialStore: AnyObject {
    /// Whether there is a value under this name. Never the value.
    func has(_ name: String) -> Bool
    /// Write, replacing whatever was there.
    func store(_ secret: String, as name: String) throws
    func forget(_ name: String)
}

extension Keychain: ChatCredentialStore {
    /// Answered from the attribute query, never by reading the value.
    ///
    /// Asking for the data is the branch that can put a dialog on screen, and a
    /// settings pane drawing a list of providers must not make the Keychain ask
    /// about each one in turn.
    func has(_ name: String) -> Bool {
        ((try? names()) ?? []).contains(name)
    }

    func store(_ secret: String, as name: String) throws {
        try store(secret, named: name)
    }

    func forget(_ name: String) {
        try? remove(named: name)
    }
}

/// A secret store that keeps nothing, for tests.
///
/// It exists so the test that proves a key never reaches the config file can
/// hold a real-looking key without a signing identity and without writing to
/// the machine running the suite.
@MainActor
final class InMemorySecrets: SecretStore {
    private var secrets: [String: String]

    init(_ secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    func names() throws -> [String] { secrets.keys.sorted() }

    func secret(named name: String) throws -> String {
        guard let secret = secrets[name] else {
            throw SecretStoreError.notFound(name: name)
        }
        return secret
    }

    func store(_ secret: String, named name: String) throws { secrets[name] = secret }

    func remove(named name: String) throws { secrets.removeValue(forKey: name) }
}

/// The settings panes' test double, which records that a crossing happened
/// without recording what crossed.
///
/// `crossings` holds `store(anthropic)` and `forget(anthropic)` — names and
/// verbs, never values. A double that let a test read a secret back out would
/// be a double that proves the leak it is supposed to rule out.
@MainActor
final class InMemoryCredentials: ChatCredentialStore {
    private var values: [String: String] = [:]
    private(set) var crossings: [String] = []

    init(existing: [String] = []) {
        for name in existing { values[name] = "already-there" }
    }

    func has(_ name: String) -> Bool { values[name] != nil }

    func store(_ secret: String, as name: String) throws {
        values[name] = secret
        crossings.append("store(\(name))")
    }

    func forget(_ name: String) {
        values.removeValue(forKey: name)
        crossings.append("forget(\(name))")
    }
}
