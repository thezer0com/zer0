import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// The shell half of ADR-0064.
///
/// The core suite (`crates/zer0-core/src/passwords_tests.rs`) holds the
/// decisions — which origin matches, which field is real, which space writes
/// nothing down. What is left for here is the seam: that a password goes from
/// the Keychain into a page and nowhere else, that two Spaces are two logins,
/// and that the channel a page can reach has no verb for "fill me".
@MainActor
struct PasswordTests {
    private func anOrdinaryField() -> ReportedField {
        ReportedField(
            width: 240,
            height: 32,
            opacity: 1,
            x: 40,
            y: 200,
            viewportWidth: 1200,
            viewportHeight: 800,
            disabled: false,
            readonly: false,
            topmost: true
        )
    }

    private func aLoginForm(on host: String) -> ReportedForm {
        let origin = ReportedOrigin(scheme: "https", host: host, port: 0)
        return ReportedForm(
            page: origin,
            form: origin,
            username: anOrdinaryField(),
            password: anOrdinaryField()
        )
    }

    private func aHost(
        store: InMemoryPasswords,
        scope: String? = "zer0.space.WORK"
    ) -> PasswordHost {
        PasswordHost(
            store: store,
            scope: { _ in scope },
            saveVerdict: { _, form in
                // Stands in for the core's space lookup, which needs a session.
                // The decision itself is the core's and is tested there.
                zer0Save(form)
            }
        )
    }

    private let tab = TabId(1)

    // MARK: - The page cannot ask

    @Test("a page has no way to ask to be filled")
    func aPageCannotAskToBeFilled() {
        // The whole design rests on this. If a message named "fill" were ever
        // accepted here, every other defence in the feature would be decoration:
        // a page could ask on a form it drew itself and read the answer back.
        for verb in ["fill", "read", "password", "get", "credentials", "autofill"] {
            #expect(
                PasswordChannel.message(named: verb) == nil,
                "\"\(verb)\" must not be a verb a page can post on this channel"
            )
        }
        // What it may say is only ever a report.
        #expect(PasswordChannel.message(named: "caret") != nil)
        #expect(PasswordChannel.message(named: "submitted") != nil)
    }

    @Test("the channel is not reachable from the page's own world")
    func theChannelIsNotInThePageWorld() {
        // `window.webkit.messageHandlers` in the page world is visible to every
        // script a site loads. In a named world the DOM is shared and the
        // globals are not, which is the split this needs.
        #expect(PasswordScript.world != WKContentWorld.page)
        #expect(PasswordScript.world == WKContentWorld.world(name: "zer0.passwords"))
    }

    // MARK: - Two Spaces are two logins

    @Test("the same site in two spaces holds two different logins")
    func twoSpacesHoldTwoLogins() throws {
        // ADR-0007's premise, at the level a password lives. Getting this wrong
        // means logging into Work and showing up as Work in Personal — the
        // failure that looks like it works until somebody notices.
        let store = InMemoryPasswords()
        try store.save(
            SavedPassword(username: "work@example.com", password: "w"),
            for: "https://github.com",
            scope: "zer0.space.WORK"
        )
        try store.save(
            SavedPassword(username: "me@personal.com", password: "p"),
            for: "https://github.com",
            scope: "zer0.space.PERSONAL"
        )

        let work = try store.logins(for: "https://github.com", scope: "zer0.space.WORK")
        let personal = try store.logins(for: "https://github.com", scope: "zer0.space.PERSONAL")

        #expect(work.map(\.username) == ["work@example.com"])
        #expect(personal.map(\.username) == ["me@personal.com"])
    }

    @Test("a space cannot read another space's login")
    func aSpaceCannotReadAnothersLogin() throws {
        let store = InMemoryPasswords()
        try store.save(
            SavedPassword(username: "work@example.com", password: "w"),
            for: "https://github.com",
            scope: "zer0.space.WORK"
        )
        #expect(throws: SecretStoreError.notFound(name: "work@example.com")) {
            try store.password(
                for: "https://github.com",
                scope: "zer0.space.PERSONAL",
                username: "work@example.com"
            )
        }
    }

    @Test("closing a space takes its logins with it")
    func closingASpaceTakesItsLogins() throws {
        // ADR-0007 deletes the cookie jar when a Space closes, because leaving
        // it on disk is a privacy leak with no way to reach it from the
        // interface. A Keychain item outliving its space is the same leak,
        // somewhere even further from the interface.
        let store = InMemoryPasswords()
        try store.save(
            SavedPassword(username: "a", password: "1"),
            for: "https://github.com",
            scope: "zer0.space.WORK"
        )
        try store.save(
            SavedPassword(username: "b", password: "2"),
            for: "https://gitlab.com",
            scope: "zer0.space.WORK"
        )
        try store.save(
            SavedPassword(username: "c", password: "3"),
            for: "https://github.com",
            scope: "zer0.space.PERSONAL"
        )

        try store.forgetEverything(scope: "zer0.space.WORK")

        #expect(try store.allLogins(scope: "zer0.space.WORK").isEmpty)
        #expect(try store.allLogins(scope: "zer0.space.PERSONAL").count == 1)
    }

    // MARK: - Nothing is offered where nothing may be

    @Test("a lookalike origin is offered nothing that was saved for the real one")
    func aLookalikeIsOfferedNothing() throws {
        let store = InMemoryPasswords()
        try store.save(
            SavedPassword(username: "avelino", password: "hunter2"),
            for: "https://github.com",
            scope: "zer0.space.WORK"
        )
        let host = aHost(store: store)

        #expect(host.offer(for: aLoginForm(on: "github.com"), tab: tab) != nil)
        for impostor in ["github.com.evil.tld", "githubb.com", "gist.github.com"] {
            #expect(
                host.offer(for: aLoginForm(on: impostor), tab: tab) == nil,
                "\(impostor) must be shown an empty list, not github.com's login"
            )
        }
    }

    @Test("a field nobody can see is offered nothing")
    func aHiddenFieldIsOfferedNothing() throws {
        let store = InMemoryPasswords()
        try store.save(
            SavedPassword(username: "avelino", password: "hunter2"),
            for: "https://github.com",
            scope: "zer0.space.WORK"
        )
        let host = aHost(store: store)

        var hidden = aLoginForm(on: "github.com")
        hidden.password.height = 1
        #expect(host.offer(for: hidden, tab: tab) == nil)

        var covered = aLoginForm(on: "github.com")
        covered.password.topmost = false
        #expect(host.offer(for: covered, tab: tab) == nil)
    }

    @Test("an ephemeral space has no scope, so nothing is offered and nothing is read")
    func anEphemeralSpaceReadsNothing() throws {
        // `password_keychain_scope` returns nil for a space that records
        // nothing, and without it there is no Keychain query to build. The
        // store is never reached — which is what `crossings` proves.
        let store = InMemoryPasswords()
        try store.save(
            SavedPassword(username: "avelino", password: "hunter2"),
            for: "https://github.com",
            scope: "zer0.space.WORK"
        )
        let before = store.crossings.count
        let host = aHost(store: store, scope: nil)

        #expect(host.offer(for: aLoginForm(on: "github.com"), tab: tab) == nil)
        #expect(
            store.crossings.count == before,
            "a private space must not even ask the store a question"
        )
    }

    // MARK: - What the source may not contain

    @Test("no password is ever interpolated into JavaScript source")
    func noPasswordIsInterpolatedIntoScriptSource() throws {
        // A password built into a string of JavaScript is one that has to be
        // escaped correctly forever, and one that lands in anything recording
        // what was evaluated. `callAsyncJavaScript` passes it as an argument
        // instead, and the argument never becomes source.
        let source = try sourceOf("PasswordHost.swift")
        #expect(
            source.contains("callAsyncJavaScript"),
            "the fill has to pass the value as an argument, not build it into source"
        )
        #expect(
            !source.contains("\\(password)"),
            "a password interpolated into a string is a password in a log"
        )
        #expect(!source.contains("evaluateJavaScript"))
    }

    @Test("what was typed is pulled out of the page, never pushed in by it")
    func submittedValuesArePulledNotPushed() throws {
        // If the values rode in on the message, a page could post a `submitted`
        // it invented — with an account name and a value of its choosing — and
        // get zer0 to offer to overwrite a real saved login for its own origin.
        // The message says only *that* a form was submitted; the values are
        // read out of the DOM by this side.
        let source = try sourceOf("PasswordHost.swift")
        // Matched as it is written rather than as it evaluates: the call site
        // spells the entry point as a Swift interpolation, so the value never
        // appears in the file.
        #expect(
            source.contains("?.read() ?? null"),
            "the save path has to read the DOM itself"
        )
        for pushed in ["body[\"password\"] as? String", "body[\"username\"] as? String"] {
            #expect(
                !source.contains(pushed),
                "\(pushed) would let a page hand zer0 a login it made up"
            )
        }
    }

    @Test("the origins come from WebKit and never from the message body")
    func theOriginsComeFromWebKit() throws {
        // A page that could name its own origin could name somebody else's,
        // which is the whole of the attack. The frame's origin comes from
        // `frameInfo.securityOrigin` and the page's from the view's committed
        // URL; neither is ever read out of `body`.
        let source = try sourceOf("PasswordHost.swift")
        #expect(source.contains("message.frameInfo.securityOrigin"))
        #expect(source.contains("message.webView?.url"))
        for spoofable in ["body[\"origin\"]", "body[\"host\"]", "body[\"scheme\"]", "body[\"url\"]"] {
            #expect(
                !source.contains(spoofable),
                "\(spoofable) would let a page name the origin it is filled for"
            )
        }
    }

    @Test("a malformed report refuses rather than fills")
    func aMalformedReportRefuses() throws {
        // Everything a page sends is coerced, and every missing value defaults
        // to the answer that refuses: disabled and readonly default to `true`,
        // topmost to `false`. A report that arrives half-built is a refusal
        // instead of a fill against a field nobody measured.
        let source = try sourceOf("PasswordHost.swift")
        #expect(source.contains("d[\"disabled\"] as? Bool ?? true"))
        #expect(source.contains("d[\"readonly\"] as? Bool ?? true"))
        #expect(source.contains("d[\"topmost\"] as? Bool ?? false"))
    }

    @Test("the data-protection keychain stays off while the build is unsigned")
    func theDataProtectionKeychainStaysOff() throws {
        // Measured, not assumed: an unsigned binary asking for the
        // data-protection keychain gets errSecMissingEntitlement (-34018) and
        // can store nothing at all. `SecretStore.swift` records the same
        // finding for API keys. This flips the day there is a signing identity.
        let source = try sourceOf("PasswordStore.swift")
        // `as String` is what makes it a query key. The bare name appears in the
        // comment explaining why it is off, and a test that could not tell those
        // apart would be a test that forces the reason to go undocumented.
        #expect(!source.contains("kSecUseDataProtectionKeychain as String"))
        // The Space is part of the item's identity, which is what makes two
        // Spaces two logins at the level the platform enforces.
        #expect(source.contains("kSecAttrSecurityDomain"))
    }

    private func sourceOf(_ name: String) throws -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Zer0Shell/\(name)")
        return try String(contentsOf: path, encoding: .utf8)
    }
}

/// The save decision, without a session to look a space up in.
///
/// Every test here uses a space that records to disk; the ephemeral half of the
/// decision is held in the core suite, where a real `Browser` exists to ask.
private func zer0Save(_ form: ReportedForm) -> SaveVerdict {
    switch passwordFillVerdict(form: form) {
    case let .fill(origin): .save(origin: origin)
    case let .refuse(because): .refuse(because: because)
    }
}
