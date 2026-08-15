import Foundation
import Testing
import Zer0Core

@testable import Zer0Shell

/// Settings that actually take effect, and survive.
@MainActor
struct SettingsTests {
    private func newModel() -> BrowserModel { BrowserModel(storagePath: nil) }

    @Test("⌘, opens settings, the way every Mac app does")
    func settingsShortcut() async throws {
        let m = newModel()
        let chord = try #require(m.chord(for: .showSettings))

        #expect(chord.key == .char(value: ","))
        #expect(chord.modifiers.primary)
        #expect(!chord.modifiers.shift)

        m.perform(.showSettings)
        #expect(m.showingSettings)
    }

    @Test("changing the search engine changes what a search resolves to")
    func searchEngineTakesEffect() async throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)

        m.setSearchTemplate("https://duckduckgo.com/?q={}")
        #expect(m.currentSearchEngineName == "DuckDuckGo")

        m.send(.navigateTo(tab: tab, input: "webkit"))

        let pending = try #require(m.snapshot.tabs.first { $0.id == tab }?.pendingUrl)
        #expect(pending == "https://duckduckgo.com/?q=webkit")
    }

    @Test("every offered engine is selectable and complete")
    func enginesAreUsable() async throws {
        let m = newModel()
        #expect(!m.searchEngines.isEmpty)

        for engine in m.searchEngines {
            // An engine without a placeholder would search for nothing.
            #expect(engine.template.contains("{}"), "\(engine.name) has no placeholder")
            m.setSearchTemplate(engine.template)
            #expect(m.currentSearchEngineName == engine.name)
        }
    }

    @Test("a preference change is visible immediately")
    func preferencesRoundTrip() async throws {
        let m = newModel()
        #expect(m.preferences.blockContent, "blocking must ship on")

        m.updatePreferences { $0.blockContent = false }
        #expect(!m.preferences.blockContent)

        m.updatePreferences { $0.theme = .dark }
        #expect(m.preferences.theme == .dark)
    }

    @Test("archive timing reaches the core")
    func archiveTiming() async throws {
        let m = newModel()
        m.setArchiveAfter(60 * 60 * 1000)
        #expect(m.archiveAfterMs == 60 * 60 * 1000)
    }

    @Test("a site can be excepted from blocking without turning it off everywhere")
    func perSiteBlocking() async throws {
        let m = newModel()

        m.setBlocking(host: "broken-site.com", blocking: false)

        #expect(m.preferences.blockingExceptions.contains("broken-site.com"))
        #expect(m.preferences.blockContent, "an exception must not turn blocking off everywhere")
    }

    @Test("settings survive a restart")
    func settingsPersist() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.sqlite").path

        do {
            let first = BrowserModel(storagePath: path)
            first.setSearchTemplate("https://kagi.com/search?q={}")
            first.setArchiveAfter(60 * 60 * 1000)
            first.updatePreferences {
                $0.theme = .dark
                $0.blockContent = false
                $0.confirmCloseOver = 12
            }
            first.setBlocking(host: "example.com", blocking: false)
            first.save()
        }

        let second = BrowserModel(storagePath: path)

        #expect(second.currentSearchEngineName == "Kagi")
        #expect(second.archiveAfterMs == 60 * 60 * 1000)
        #expect(second.preferences.theme == .dark)
        #expect(!second.preferences.blockContent)
        #expect(second.preferences.confirmCloseOver == 12)
        #expect(second.preferences.blockingExceptions.contains("example.com"))
    }
}

/// Offering to install from a store listing.
@MainActor
struct InstallOfferTests {
    private let realId = "cjpalhdlnbpafiamejdnhcphjbkeiagm"

    @Test("a store listing offers its extension")
    func listingIsRecognised() async throws {
        let m = BrowserModel(storagePath: nil)
        let tab = try #require(m.snapshot.activeTab)

        m.send(.navigationCommitted(
            tab: tab,
            url: "https://chromewebstore.google.com/detail/ublock-origin/\(realId)"
        ))

        #expect(m.offeredExtensionId == realId)
    }

    @Test("an ordinary page offers nothing")
    func ordinaryPagesAreQuiet() async throws {
        let m = BrowserModel(storagePath: nil)
        let tab = try #require(m.snapshot.activeTab)

        m.send(.navigationCommitted(tab: tab, url: "https://avelino.run/"))

        #expect(m.offeredExtensionId == nil)
    }

    @Test("a lookalike host cannot get itself offered")
    func lookalikeHostsAreRefused() async throws {
        let m = BrowserModel(storagePath: nil)
        let tab = try #require(m.snapshot.activeTab)

        // Offering from a lookalike is a straight path to installing whatever
        // an attacker wants.
        m.send(.navigationCommitted(
            tab: tab,
            url: "https://chromewebstore.google.com.evil.io/detail/x/\(realId)"
        ))

        #expect(m.offeredExtensionId == nil)
    }

    @Test("the settings field takes a full store URL, not just an ID")
    func urlIsAcceptedInSettings() async throws {
        let m = BrowserModel(storagePath: nil)

        let url = "https://chromewebstore.google.com/detail/ublock-origin/\(realId)?hl=pt"
        #expect(m.extensionId(inURL: url) == realId)
        #expect(m.extensionId(inURL: "https://avelino.run/") == nil)
    }
}

/// Session persistence: the thing that was silently losing everything on quit.
@MainActor
struct SessionPersistenceTests {
    private func tempPath() throws -> (String, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("session.sqlite").path, dir)
    }

    @Test("a structural change is written without waiting for the timer")
    func structuralChangesSaveThemselves() async throws {
        let (path, dir) = try tempPath()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tabCount: Int
        let whatWroteFirst: SaveReason?
        do {
            let first = BrowserModel(storagePath: path)
            first.send(.openTab(space: nil, url: nil, parent: nil))
            first.send(.openTab(space: nil, url: nil, parent: nil))
            tabCount = first.snapshot.tabs.count

            // No save() call and no quit: the debounce must land on its own.
            //
            // What is waited for is the *event*, and the discriminator is
            // `firstSaveWritten` rather than a clock. This used to poll the
            // file under a fifteen second ceiling, chosen to sit below the
            // twenty second periodic saver so that a periodic rescue could not
            // be mistaken for the debounce — which made passing a fact about
            // how busy the machine was. It failed seven runs in eight under a
            // full suite, and every one of those failures was a save that had
            // happened correctly and arrived late: measured, the debounce's
            // `Task.sleep(for: .seconds(2))` resumed twenty-four seconds after
            // it was scheduled, because swift-testing puts several hundred
            // main-actor tests in flight at once and the main actor is one lane.
            //
            // Asking which save wrote first cannot be starved into the wrong
            // answer. A debounce that never fires now reads as `.periodic` —
            // the rescue names itself, however late anyone gets to look — which
            // leaves `eventually`'s deadline doing nothing but turning a hang
            // into a readable failure.
            _ = await eventually { first.firstSaveWritten != nil }
            whatWroteFirst = first.firstSaveWritten

            // `first` has to still be alive for all of that. Its debounced save
            // holds only a weak reference, so a model that died early would
            // never write at all — and the assertion below would then be about
            // the wrong thing entirely.
            withExtendedLifetime(first) {}
        }
        #expect(
            whatWroteFirst == .structuralChange,
            """
            the first thing to write this session down was \
            \(whatWroteFirst?.rawValue ?? "nothing at all"). Opening a tab has to write \
            itself down; leaving it to the twenty second periodic saver loses every tab \
            opened in the nineteen seconds before a crash.
            """
        )

        let second = BrowserModel(storagePath: path)
        #expect(
            second.snapshot.tabs.count == tabCount,
            "tabs opened before quitting must survive without an explicit save"
        )
    }

    @Test("quitting writes everything, including what happened a second ago")
    func quittingSavesImmediately() async throws {
        let (path, dir) = try tempPath()
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let first = BrowserModel(storagePath: path)
            first.createSpace(named: "Work")
            let tab = try #require(first.snapshot.activeTab)
            first.send(.navigationCommitted(tab: tab, url: "https://avelino.run/"))

            // This is what the app delegate does on ⌘Q.
            first.saveNow(reason: .quitting)
        }

        let second = BrowserModel(storagePath: path)
        #expect(second.snapshot.spaces.count == 2)
        #expect(second.snapshot.tabs.contains { $0.url == "https://avelino.run/" })
    }

    @Test("a clean quit is remembered; a crash is not")
    func cleanShutdownIsRecorded() async throws {
        let (path, dir) = try tempPath()
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let first = BrowserModel(storagePath: path)
            first.saveNow(reason: .quitting)
        }
        let afterCleanQuit = BrowserModel(storagePath: path)
        #expect(afterCleanQuit.lastRunEndedCleanly)

        // Now a run that never quits properly.
        do {
            let crashed = BrowserModel(storagePath: path)
            crashed.saveNow(reason: .periodic)
        }
        let afterCrash = BrowserModel(storagePath: path)
        #expect(!afterCrash.lastRunEndedCleanly, "a run with no quit is not a clean one")
    }

    @Test("a crash still restores the session")
    func crashDoesNotCostTheSession() async throws {
        let (path, dir) = try tempPath()
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let first = BrowserModel(storagePath: path)
            first.send(.openTab(space: nil, url: nil, parent: nil))
            let tab = try #require(first.snapshot.activeTab)
            first.send(.navigationCommitted(tab: tab, url: "https://avelino.run/"))
            first.saveNow(reason: .periodic)
            // No clean-shutdown mark: the process died here.
        }

        let second = BrowserModel(storagePath: path)

        #expect(!second.lastRunEndedCleanly)
        #expect(
            second.snapshot.tabs.contains { $0.url == "https://avelino.run/" },
            "losing the marker must not lose the session"
        )
    }

    @Test("a session that could not be read says so on screen")
    func unreadableSessionWarnsInTheUI() async throws {
        // Whether saving stays off is the core's business and is tested there.
        // What matters here is that the news crosses the border at all: nothing
        // is being saved, and the only way to find that out before losing a
        // day's work is the banner.
        let (path, dir) = try tempPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("zer0 session, allegedly".utf8).write(to: URL(fileURLWithPath: path))

        let m = BrowserModel(storagePath: path)

        #expect(m.loadError != nil)
        #expect(m.showsSessionWarning, "silence here means finding out at the next launch")

        m.sessionWarningDismissed = true
        #expect(!m.showsSessionWarning, "knowing once is enough")
    }

    @Test("a session that reads fine says nothing")
    func healthySessionIsQuiet() async throws {
        let (path, dir) = try tempPath()
        defer { try? FileManager.default.removeItem(at: dir) }

        BrowserModel(storagePath: path).saveNow(reason: .quitting)
        let m = BrowserModel(storagePath: path)

        #expect(m.loadError == nil)
        #expect(!m.showsSessionWarning, "a warning that is always up is not a warning")
    }

    @Test("noisy actions do not each trigger a write")
    func noiseDoesNotSave() async throws {
        // Titles and progress fire constantly; treating each as a save would
        // mean rewriting the whole database dozens of times a minute.
        #expect(!BrowserModel.isStructural(.titleChanged(tab: 1, title: "x")))
        #expect(!BrowserModel.isStructural(.navigationStarted(tab: 1, url: "x")))
        #expect(!BrowserModel.isStructural(.tick(nowMs: 0)))

        #expect(BrowserModel.isStructural(.openTab(space: nil, url: nil, parent: nil)))
        #expect(BrowserModel.isStructural(.closeTab(tab: 1)))
        #expect(BrowserModel.isStructural(.navigationCommitted(tab: 1, url: "x")))
    }
}

/// The site badge, which stands in for a favicon everywhere in the UI.
@MainActor
struct SiteBadgeTests {
    /// WCAG AA for text this size. Below it the letter is a smudge.
    private let minimumContrast = 4.5

    @Test("every site colour keeps its letter readable")
    func everyHueIsReadable() async throws {
        // The badge derives its colour from a hash, so any of the 256 hues can
        // turn up. One unlucky site with an unreadable badge is still a bug.
        var worst = (contrast: Double.infinity, hue: 0)

        for step in 0 ..< 256 {
            let hue = Double(step) / 255.0
            let contrast = SiteBadge.contrastAtWorst(hue: hue)
            if contrast < worst.contrast {
                worst = (contrast, step)
            }
        }

        #expect(
            worst.contrast >= minimumContrast,
            "hue \(worst.hue) gives \(worst.contrast):1, below \(minimumContrast):1"
        )
    }

    @Test("the same site always gets the same colour")
    func coloursAreStable() async throws {
        // A badge that changes between sessions is worse than no badge: the
        // whole point is recognising a site without reading it.
        let first = SiteBadge.palette(for: "github.com")
        let second = SiteBadge.palette(for: "github.com")
        #expect(first.base == second.base)

        // And subdomains of one site read as that site.
        #expect(SiteBadge.palette(for: "gist.github.com").base == first.base)
        #expect(SiteBadge.palette(for: "www.github.com").base == first.base)
    }

    @Test("different sites get different colours")
    func coloursDiffer() async throws {
        #expect(SiteBadge.palette(for: "github.com").base
            != SiteBadge.palette(for: "avelino.run").base)
    }

    @Test("a host with nothing to show does not crash")
    func emptyHostsAreSafe() async throws {
        _ = SiteBadge.palette(for: nil)
        _ = SiteBadge.palette(for: "")
        _ = SiteBadge.significantPart(of: "localhost")
        #expect(SiteBadge.significantPart(of: nil) == nil)
    }
}
