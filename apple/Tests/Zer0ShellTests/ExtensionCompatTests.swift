import Foundation
import JavaScriptCore
import Testing
import Zer0Core

@testable import Zer0Shell

/// The compatibility file zer0 adds to a package, held to what it claims.
///
/// **Run as JavaScript, not read as text.** The claims this file makes are
/// behavioural — *nothing is installed over something that exists*, *a member
/// this file does not list stays undefined*, *managed storage is empty and
/// refuses writes* — and a scan for a substring cannot see any of them. These
/// are the same bytes the core compiles in with `include_str!` and writes into
/// every package it installs; `ext::compat::tests` holds that end of it.
///
/// What this cannot see is WebKit. Whether the worker then starts is measured by
/// loading real packages into a real `WKWebExtensionController`, which is not
/// something a suite can do in under a second — ADR-0100 carries the numbers.
@Suite struct ExtensionCompatTests {
    /// The shipped file, read from where the core reads it.
    static var source: String {
        get throws {
            let path = SourceScan.repoRoot.appending(path: "crates/zer0-core/src/ext/compat.js")
            return try String(contentsOf: path, encoding: .utf8)
        }
    }

    /// A worker's global scope, near enough: a `chrome` carrying whatever the
    /// caller says WebKit installs, and nothing else.
    static func context(chrome: String) throws -> JSContext {
        let context = JSContext()!
        var thrown: String?
        context.exceptionHandler = { _, value in thrown = value?.toString() }
        context.evaluateScript("var chrome = \(chrome);")
        context.evaluateScript(try source)
        #expect(thrown == nil, "the compatibility file threw: \(thrown ?? "")")
        return context
    }

    private func string(_ context: JSContext, _ expression: String) -> String {
        context.evaluateScript(expression)?.toString() ?? "<nil>"
    }

    // MARK: - The two rules that keep it honest

    /// The one that matters most, and the one to break on purpose: drop the
    /// guard in `define` and this goes red on every line.
    ///
    /// WebKit ships one of these one day. If our stand-in wins, an API that
    /// works is shadowed by an enum that is merely plausible and an event that
    /// never fires — a silent failure, which is the single outcome worse than
    /// the loud one this file replaces (ADR-0077).
    @Test func nothingIsInstalledOverSomethingThatAlreadyExists() throws {
        let context = try Self.context(chrome: """
        {
          scripting: { ExecutionWorld: { ISOLATED: 'real-isolated' } },
          webNavigation: { onHistoryStateUpdated: { addListener() { return 'real'; } } },
          storage: { managed: { get() { return 'real-managed'; } } },
          notifications: { onClicked: { addListener() { return 'real'; } }, create() {} }
        }
        """)

        #expect(string(context, "chrome.scripting.ExecutionWorld.ISOLATED") == "real-isolated")
        #expect(string(context, "chrome.webNavigation.onHistoryStateUpdated.addListener()") == "real")
        #expect(string(context, "chrome.storage.managed.get()") == "real-managed")
        #expect(string(context, "chrome.notifications.onClicked.addListener()") == "real")
        #expect(
            string(context, "typeof chrome.notifications.create") == "function",
            "a real namespace must not be replaced by ours"
        )
    }

    /// A member this file does not list stays `undefined`, and that is
    /// deliberate rather than an omission.
    ///
    /// A stub that throws when called reads as friendlier and would defeat
    /// `if (chrome.notifications.create)` — the extension's own way of finding
    /// out and taking another path — while asserting a method exists that does
    /// not. Somebody will one day "improve" this into a Proxy that answers
    /// everything; this is what says no.
    @Test func nothingIsInventedBeyondWhatIsListed() throws {
        let context = try Self.context(chrome: "{ runtime: {}, scripting: {}, storage: {} }")

        // The namespace it does create carries three events and no methods.
        #expect(string(context, "typeof chrome.notifications") == "object")
        #expect(string(context, "typeof chrome.notifications.onClicked") == "object")
        #expect(
            string(context, "typeof chrome.notifications.create") == "undefined",
            "a method that resolves without delivering a notification is the lie ADR-0077 forbids"
        )
        #expect(string(context, "typeof chrome.notifications.getPermissionLevel") == "undefined")

        // And no other namespace is conjured up. `chrome.bookmarks` absent is
        // WebKit's statement about itself and stays that way (ADR-0084).
        //
        // `downloads`, `idle` and `management` left this list in ADR-0103, and
        // they left it by being *built* rather than by being relaxed: each one
        // reaches the browser over `ExtensionApiHost` and does the thing. What
        // is asserted about them below is the same thing asserted here — that
        // nothing exists which does not act.
        for absent in ["bookmarks", "history", "offscreen", "topSites", "sessions"] {
            #expect(
                string(context, "typeof chrome.\(absent)") == "undefined",
                "\(absent) was created"
            )
        }

        // What zer0 answers, it answers all of. What it does not, stays absent
        // — so `if (chrome.downloads.setShelfEnabled)` is still an honest
        // question with an honest answer.
        for missing in [
            "downloads.setShelfEnabled",
            "downloads.setUiOptions",
            "downloads.acceptDanger",
            "downloads.getFileIcon",
            "idle.setDetectionInterval",
            "idle.getAutoLockDelay",
            "management.getAll",
            "management.setEnabled",
            "management.uninstall",
            "management.uninstallSelf",
        ] {
            #expect(
                string(context, "typeof chrome.\(missing)") == "undefined",
                "\(missing) was invented"
            )
        }

        // Including where a member was asked for on a namespace that is not
        // there: no `webNavigation` means no `webNavigation`.
        #expect(string(context, "typeof chrome.webNavigation") == "undefined")
        #expect(string(context, "typeof chrome.declarativeNetRequest") == "undefined")
    }

    // MARK: - What it does install

    /// React Developer Tools dies on `chrome.scripting.ExecutionWorld.ISOLATED`
    /// and Privacy Badger's content injection dies on `.MAIN`. Two strings.
    @Test func anEnumIsItsValueAndCarriesEveryMemberChromeDocuments() throws {
        let context = try Self.context(chrome: """
        { scripting: {}, runtime: {}, webRequest: {}, declarativeNetRequest: {} }
        """)

        #expect(string(context, "chrome.scripting.ExecutionWorld.ISOLATED") == "ISOLATED")
        #expect(string(context, "chrome.scripting.ExecutionWorld.MAIN") == "MAIN")
        // DuckDuckGo's.
        #expect(string(context, "chrome.webRequest.OnHeadersReceivedOptions.EXTRA_HEADERS") == "extraHeaders")
        #expect(string(context, "chrome.webRequest.OnBeforeSendHeadersOptions.REQUEST_HEADERS") == "requestHeaders")
        #expect(string(context, "chrome.runtime.OnInstalledReason.INSTALL") == "install")
        #expect(string(context, "chrome.runtime.ContextType.BACKGROUND") == "BACKGROUND")
        #expect(string(context, "chrome.declarativeNetRequest.ResourceType.MAIN_FRAME") == "main_frame")
        #expect(string(context, "chrome.declarativeNetRequest.DYNAMIC_RULESET_ID") == "_dynamic")
    }

    /// Vimium's whole extension is one `webNavigation.onHistoryStateUpdated`
    /// listener registered while its worker starts.
    ///
    /// The event never fires, and the object says so honestly: `hasListener`
    /// answers about registration, which happened, and nothing anywhere claims
    /// the event arrived.
    @Test func anEventObjectRegistersAndSaysOnlyThatItRegistered() throws {
        let context = try Self.context(chrome: "{ webNavigation: {}, runtime: {}, storage: {} }")
        context.evaluateScript("""
        var fired = false;
        var listener = function () { fired = true; };
        chrome.webNavigation.onHistoryStateUpdated.addListener(listener);
        """)

        #expect(string(context, "chrome.webNavigation.onHistoryStateUpdated.hasListener(listener)") == "true")
        #expect(string(context, "fired") == "false", "nothing may pretend the event happened")

        context.evaluateScript("chrome.webNavigation.onHistoryStateUpdated.removeListener(listener)")
        #expect(string(context, "chrome.webNavigation.onHistoryStateUpdated.hasListener(listener)") == "false")
    }

    /// Twelve of 59 packages read `storage.managed`, LanguageTool fatally.
    ///
    /// Empty is the correct answer and not a stand-in for one: managed storage
    /// holds what an enterprise policy put there, and zer0 has no mechanism by
    /// which a policy could put anything there. Writing to it rejects, which is
    /// what Chrome does too — this is not zer0 refusing something.
    @Test func managedStorageIsEmptyAndRefusesToBeWrittenTo() throws {
        let context = try Self.context(chrome: "{ storage: { local: {} }, runtime: {} }")

        // The callback form, which is what an MV2-era package uses.
        context.evaluateScript("""
        var read = null;
        chrome.storage.managed.get({ policyValue: 'default' }, function (v) { read = v; });
        var bare = null;
        chrome.storage.managed.get('anything', function (v) { bare = v; });
        """)
        #expect(
            string(context, "read.policyValue") == "default",
            "Chrome answers a defaults object with its defaults, since nothing is ever set"
        )
        #expect(string(context, "JSON.stringify(bare)") == "{}")

        // The promise form, which is what MV3 uses.
        #expect(string(context, "chrome.storage.managed.get('x') instanceof Promise") == "true")

        context.evaluateScript("""
        var rejected = null;
        chrome.storage.managed.set({ a: 1 }).catch(function (e) { rejected = e.message; });
        var threw = null;
        try { chrome.storage.managed.clear(function () {}); } catch (e) { threw = e.message; }
        """)
        // A `.catch` is a microtask; anything evaluated after it has run.
        context.evaluateScript(";")
        #expect(string(context, "rejected").contains("read-only"))
        #expect(string(context, "threw").contains("read-only"))

        // And the storage the person actually granted is untouched.
        #expect(string(context, "typeof chrome.storage.local") == "object")
    }

    /// A permission the person withheld leaves the whole namespace `undefined`
    /// (ADR-0077). Handing the extension a storage it was refused would undo a
    /// decision somebody made on the consent sheet.
    @Test func aWithheldNamespaceIsNotHandedBackByTheCompatibilityFile() throws {
        let context = try Self.context(chrome: "{ runtime: {} }")
        #expect(string(context, "typeof chrome.storage") == "undefined")
    }

    /// `browser` is the other spelling, and Violentmonkey dies on
    /// `browser.notifications.onClicked` rather than on `chrome`'s.
    @Test func theOtherSpellingOfTheNamespaceRootIsCoveredToo() throws {
        let context = JSContext()!
        context.evaluateScript("var chrome = { runtime: {} }; var browser = { runtime: {} };")
        context.evaluateScript(try Self.source)

        #expect(string(context, "typeof browser.notifications.onClicked") == "object")
        #expect(string(context, "browser.runtime.OnInstalledReason.UPDATE") == "update")
    }

    // MARK: - Saying so on the screen

    /// The browser modified somebody else's package, and the person has to be
    /// able to see that without a hex editor: the file that was added, and
    /// where the extension's own code still begins.
    ///
    /// Delete the line from the row and this is what goes red. It is a sentence
    /// test on purpose — the fact is not in doubt, only whether it is said.
    @Test func aModifiedPackageSaysSoAndNamesBothHalves() throws {
        let one = try #require(extensionModificationLine(manifest(compat: CompatNotice(
            addedFiles: ["zer0-compat.js"],
            originalEntryPoint: "build/background.js"
        ))))
        #expect(one.contains("zer0-compat.js"), "the added file is not named")
        #expect(one.contains("build/background.js"), "the entry point it runs before is not named")
        #expect(one.contains("added"))

        // A module worker needs a second file, and the line has to name that
        // one too: "one file was added" over a package with two in it is the
        // same untrue sentence as saying nothing.
        let two = try #require(extensionModificationLine(manifest(compat: CompatNotice(
            addedFiles: ["zer0-compat.js", "zer0-compat-api.js"],
            originalEntryPoint: "sw.js"
        ))))
        #expect(two.contains("zer0-compat.js"))
        #expect(two.contains("zer0-compat-api.js"))
        #expect(two.contains("which run "), "two files do not run, singular")
    }

    /// Most packages are not modified — no background, or an HTML background
    /// page — and a browser that told everybody it had changed their extension
    /// would be making the notice worthless for the ones it did change.
    @Test func aPackageNobodyTouchedSaysNothing() {
        #expect(extensionModificationLine(manifest(compat: nil)) == nil)
    }

    private func manifest(compat: CompatNotice?) -> ExtensionManifest {
        ExtensionManifest(
            name: "Test",
            version: "1.0",
            description: nil,
            manifestVersion: 3,
            permissions: [],
            hostPermissions: [],
            hasAction: true,
            compat: compat
        )
    }
}
