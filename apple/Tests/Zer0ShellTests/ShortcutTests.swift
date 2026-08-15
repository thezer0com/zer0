import Testing
import SwiftUI
import Zer0Core

@testable import Zer0Shell

/// The keymap comes from the core, and the shell only renders it. These check
/// both halves: that commands actually do something, and that a chord survives
/// the trip into AppKit.
@MainActor
struct ShortcutTests {
    private func model() -> BrowserModel { BrowserModel(storagePath: nil) }

    @Test("every command in the keymap is wired to something")
    func everyBoundCommandIsHandled() async throws {
        let m = model()

        // perform() has no default case, so this failing means a command was
        // added to the core and never given behaviour here.
        for binding in m.keymap {
            m.perform(binding.command)
        }

        #expect(!m.keymap.isEmpty)
    }

    @Test("the shortcuts people already know do what they should")
    func familiarShortcutsWork() async throws {
        let m = model()
        let before = m.snapshot.tabs.count

        m.perform(.newTab)
        // ⌘T opens the command bar rather than a blank page.
        #expect(m.commandBarOpen)

        m.commandBarOpen = false
        m.send(.openTab(space: nil, url: nil, parent: nil))
        #expect(m.snapshot.tabs.count == before + 1)

        m.perform(.closeTab)
        #expect(m.snapshot.tabs.count == before)
    }

    @Test("cycling tabs moves focus and wraps")
    func cyclingWorks() async throws {
        let m = model()
        let first = try #require(m.snapshot.activeTab)
        m.send(.openTab(space: nil, url: nil, parent: nil))
        let second = try #require(m.snapshot.activeTab)

        m.perform(.nextTab)
        #expect(m.snapshot.activeTab == first, "wraps past the end")

        m.perform(.previousTab)
        #expect(m.snapshot.activeTab == second)
    }

    @Test("selecting a tab by number is one-based")
    func selectByNumber() async throws {
        let m = model()
        let first = try #require(m.snapshot.activeTab)
        m.send(.openTab(space: nil, url: nil, parent: nil))

        m.perform(.selectTab(index: 1))

        #expect(m.snapshot.activeTab == first)
    }

    /// A press, all the way through to the space actually changing. The keymap
    /// tests say ⌃3 means `selectSpace(3)`; this says the browser moves.
    @Test("a digit goes straight to the space in that position")
    func selectSpaceByNumber() async throws {
        let m = model()
        let first = m.snapshot.activeSpace
        m.createSpace(named: "Work")
        let second = m.snapshot.activeSpace
        #expect(second != first)

        m.perform(.selectSpace(index: 1))
        #expect(m.snapshot.activeSpace == first)

        m.perform(.selectSpace(index: 2))
        #expect(m.snapshot.activeSpace == second)

        // Past the end is silence, not a clamp onto the last one: ⌘9 means
        // "the last tab" because Chrome taught it, and nobody has taught
        // anything about a space.
        m.perform(.selectSpace(index: 9))
        #expect(m.snapshot.activeSpace == second)
    }

    @Test("zoom moves in steps and resets to exactly one")
    func zoomWorks() async throws {
        let m = model()

        m.perform(.zoomIn)
        #expect((m.activeTab?.zoomFactor ?? 0) > 1.0)

        m.perform(.zoomReset)
        #expect(m.activeTab?.zoomFactor == 1.0)
    }

    @Test("toggling the sidebar is a shell concern and stays one")
    func sidebarToggles() async throws {
        let m = model()
        #expect(m.sidebarVisible)

        m.perform(.toggleSidebar)

        #expect(!m.sidebarVisible)
    }

    @Test("a chord survives the trip into a SwiftUI shortcut")
    func chordsConvert() async throws {
        let m = model()
        let newTab = try #require(m.chord(for: .newTab))

        let shortcut = try #require(newTab.keyboardShortcut)

        #expect(shortcut.key == KeyEquivalent("t"))
        #expect(shortcut.modifiers.contains(.command))
        #expect(!shortcut.modifiers.contains(.shift))
    }

    @Test("primary maps to Command here, and Control stays Control")
    func modifiersAreNotConfused() async throws {
        let m = model()
        // ⌃Tab is Next Tab. Reading "primary" as Control would make it ⌘Tab,
        // which macOS owns.
        let nextTab = try #require(m.chord(for: .nextTab))
        let shortcut = try #require(nextTab.keyboardShortcut)

        #expect(shortcut.modifiers.contains(.control))
        #expect(!shortcut.modifiers.contains(.command))
    }

    @Test("an arrow-key chord converts too")
    func arrowKeysConvert() async throws {
        // No model: converting a chord to a `KeyboardShortcut` is a pure
        // function of the chord, and building one here only made this test look
        // as though it depended on a browser.
        let back = Chord(key: .left, modifiers: Modifiers(
            primary: true, shift: false, alt: false, control: false
        ))

        let shortcut = try #require(back.keyboardShortcut)

        #expect(shortcut.key == KeyEquivalent.leftArrow)
    }

    @Test("adding a chord keeps the one that was already there")
    func bindingAddsRatherThanReplaces() async throws {
        let m = model()
        let extra = Chord(key: .char(value: "j"), modifiers: Modifiers(
            primary: true, shift: false, alt: false, control: false
        ))

        m.bind(extra, to: .newTab)

        // The default still works; the new one works too.
        #expect(m.keymap.contains { $0.chord == extra && $0.command == .newTab })
        #expect(m.keymap.contains {
            $0.chord.key == .char(value: "t") && $0.command == .newTab
        })
    }

    @Test("rebinding a shortcut changes what the menu shows")
    func rebindingUpdatesTheMenu() async throws {
        let m = model()
        let replacement = Chord(key: .char(value: "j"), modifiers: Modifiers(
            primary: true, shift: false, alt: false, control: false
        ))

        m.rebind(.newTab, to: replacement)

        #expect(m.chord(for: .newTab) == replacement)
    }

    @Test("resetting puts the defaults back")
    func resettingRestoresDefaults() async throws {
        let m = model()
        let original = try #require(m.chord(for: .newTab))
        m.rebind(
            .newTab,
            to: Chord(key: .char(value: "j"), modifiers: Modifiers(
                primary: true, shift: false, alt: false, control: false
            ))
        )

        m.resetKeymap()

        #expect(m.chord(for: .newTab) == original)
    }
}

/// The trip from a physical key press to a command.
///
/// Everything else in this file exercises the keymap, and the keymap was never
/// the problem: ⌘[ and ⌘] were bound to Back and Forward, covered by a passing
/// test, and did nothing in the hand. The menu was the only door, a menu item
/// carries one chord, and `chord(for: .back)` hands it ⌘←. These cover the
/// boundary that lied.
@MainActor
struct KeyPressTests {
    private func model() -> BrowserModel { BrowserModel(storagePath: nil) }

    /// A key code that is not one of the named keys, for the letter chords —
    /// those resolve on the character the press reported, never on the code.
    private static let notANamedKey: UInt16 = 0xFFFF

    /// The punctuation keys the keymap uses: ANSI key code, the glyph the key
    /// types, and the glyph it types with Shift held.
    ///
    /// Measured on this machine with `UCKeyTranslate` against both the US and
    /// the Brazilian (ABNT2) layouts, which agree on every row: `[`, `]`, `\`,
    /// `,`, `.`, `-` and `=` are unshifted on both, and `+` is Shift and `=`.
    ///
    /// The table is the point of these tests. A press reports the glyph that
    /// came out, so `⇧⌘\` arrives as `|` and `⌘+` arrives as `+` with Shift
    /// held — and a helper that just echoed the chord back would agree with the
    /// keymap and prove nothing.
    private static let punctuation: [(code: UInt16, plain: String, shifted: String)] = [
        (33, "[", "{"), (30, "]", "}"), (42, "\\", "|"),
        (43, ",", "<"), (47, ".", ">"), (27, "-", "_"), (24, "=", "+"),
    ]

    /// The press a person actually makes to produce this chord.
    private func press(_ chord: Chord) -> (UInt16, String, NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if chord.modifiers.primary { flags.insert(.command) }
        if chord.modifiers.shift { flags.insert(.shift) }
        if chord.modifiers.alt { flags.insert(.option) }
        if chord.modifiers.control { flags.insert(.control) }

        switch chord.key {
        case let .char(value):
            if let key = Self.punctuation.first(where: { $0.plain == value }) {
                // Shift moves the glyph: the `\` key reports `|`.
                let typed = chord.modifiers.shift ? key.shifted : key.plain
                return (key.code, typed, flags)
            }
            if let key = Self.punctuation.first(where: { $0.shifted == value }) {
                // A glyph that only exists shifted. The press carries Shift
                // whether or not the chord admits to it, which is the whole
                // story of ⌘+.
                flags.insert(.shift)
                return (key.code, key.shifted, flags)
            }
            // A letter or a digit, reported as typed — uppercase under Shift,
            // the way `charactersIgnoringModifiers` gives it.
            return (
                Self.notANamedKey,
                chord.modifiers.shift ? value.uppercased() : value,
                flags
            )
        case .enter: return (36, "", flags)
        case .tab: return (48, "", flags)
        case .space: return (49, "", flags)
        case .backspace: return (51, "", flags)
        case .escape: return (53, "", flags)
        case .left: return (123, "", flags)
        case .right: return (124, "", flags)
        case .up: return (126, "", flags)
        case .down: return (125, "", flags)
        }
    }

    @Test("every chord in the keymap reaches its command from a real key press")
    func everyDefaultChordIsReachable() async throws {
        let m = model()
        // Escape is the one binding the keymap does not get unconditionally:
        // it is also how the command bar and the find bar are dismissed, so it
        // is claimed only while a page is loading. Covered separately below.
        let bindings = m.keymap.filter { $0.chord.key != .escape }
        #expect(!bindings.isEmpty)

        for binding in bindings {
            let (code, characters, flags) = press(binding.chord)
            let resolved = m.command(
                forKeyCode: code, characters: characters, modifiers: flags
            )
            #expect(
                resolved == binding.command,
                "\(binding.chord) should reach \(binding.command), got \(String(describing: resolved))"
            )
        }
    }

    @Test("⌘[ goes back and ⌘] goes forward, not only ⌘← and ⌘→")
    func bracketsNavigate() async throws {
        let m = model()

        // Real ANSI key codes, so this goes through the live keyboard layout
        // the way the reported defect did.
        #expect(m.command(forKeyCode: 33, characters: "[", modifiers: [.command]) == .back)
        #expect(m.command(forKeyCode: 30, characters: "]", modifiers: [.command]) == .forward)

        // The chords the menu advertises still work; this is an addition, not
        // a swap.
        #expect(m.command(forKeyCode: 123, characters: "", modifiers: [.command]) == .back)
        #expect(m.command(forKeyCode: 124, characters: "", modifiers: [.command]) == .forward)
    }

    @Test("a chord written with a shifted glyph answers to the press that types it")
    func shiftedGlyphsResolve() async throws {
        let m = model()

        // ⌘+ is what Chrome, Safari, Firefox and Edge all publish, and no
        // keyboard can produce a "+" without Shift. Key code 24 is the `=` key.
        #expect(m.command(
            forKeyCode: 24, characters: "+", modifiers: [.command, .shift]
        ) == .zoomIn)

        // And the other direction: Shift moves punctuation to a *different*
        // glyph, so ⇧⌘\ reaches the keyboard as "|". Reading the reported glyph
        // alone loses this one, which is how it was lost the first time.
        #expect(m.command(
            forKeyCode: 42, characters: "|", modifiers: [.command, .shift]
        ) == .focusOtherPane)
        #expect(m.command(
            forKeyCode: 42, characters: "\\", modifiers: [.command]
        ) == .toggleSplitView)
    }

    @Test("Shift stays a modifier on a letter")
    func shiftIsNotSwallowedOnLetters() async throws {
        let m = model()

        // charactersIgnoringModifiers reports "T" for ⇧⌘T, and the core stores
        // the key lowercased with Shift held in the modifier.
        #expect(m.command(
            forKeyCode: Self.notANamedKey, characters: "T", modifiers: [.command, .shift]
        ) == .reopenClosedTab)
        #expect(m.command(
            forKeyCode: Self.notANamedKey, characters: "t", modifiers: [.command]
        ) == .newTab)
    }

    /// The numeric row's three tenants, proved one press at a time (ADR-0087).
    ///
    /// `everyDefaultChordIsReachable` sweeps all four of these already. This
    /// one exists because the sweep would stay green if two of them swapped:
    /// it checks each chord reaches *its* command, and a keymap where ⌃1 ran an
    /// extension and ⇧⌘1 opened a space would satisfy it perfectly.
    @Test("one digit, three modifiers, three different things")
    func theNumericRowHasThreeTenants() async throws {
        let m = model()
        let digit = Self.notANamedKey

        #expect(m.command(
            forKeyCode: digit, characters: "1", modifiers: [.command]
        ) == .selectTab(index: 1))
        #expect(m.command(
            forKeyCode: digit, characters: "1", modifiers: [.command, .shift]
        ) == .runPinnedExtension(index: 1))
        #expect(m.command(
            forKeyCode: digit, characters: "1", modifiers: [.control]
        ) == .selectSpace(index: 1))
        // The chord that survives where Control *is* the primary modifier. It
        // is the only way into a space on Linux, so a press has to arrive here
        // too or the second binding is decoration.
        #expect(m.command(
            forKeyCode: digit, characters: "3", modifiers: [.command, .option]
        ) == .selectSpace(index: 3))
    }

    @Test("⌃Tab and ⌃⇧Tab survive, and ⌘Tab is left to the system")
    func tabCyclingResolves() async throws {
        let m = model()

        #expect(m.command(forKeyCode: 48, characters: "", modifiers: [.control]) == .nextTab)
        #expect(m.command(
            forKeyCode: 48, characters: "", modifiers: [.control, .shift]
        ) == .previousTab)
        #expect(m.command(forKeyCode: 48, characters: "", modifiers: [.command]) == nil)
    }

    @Test("typing is never mistaken for a shortcut")
    func plainTypingIsLeftAlone() async throws {
        let m = model()

        // No Command and no Control means it is text, whatever it spells.
        for character in ["t", "w", "[", "9", "+"] {
            #expect(m.command(
                forKeyCode: Self.notANamedKey, characters: character, modifiers: []
            ) == nil, "\(character) alone must reach the page")
        }
        // And a chord we do not bind is not ours to swallow.
        #expect(m.command(
            forKeyCode: Self.notANamedKey, characters: "c", modifiers: [.command]
        ) == nil)
    }

    @Test("Escape stops a load only when there is one, and never steals a dismissal")
    func escapeIsClaimedCarefully() async throws {
        let m = model()
        let escape: (UInt16, String, NSEvent.ModifierFlags) = (53, "", [])

        // Nothing loading: Escape belongs to whatever is on screen.
        #expect(m.command(
            forKeyCode: escape.0, characters: escape.1, modifiers: escape.2
        ) == nil)

        let tab = try #require(m.snapshot.activeTab)
        m.send(.navigationStarted(tab: tab, url: "https://avelino.run/"))
        #expect(m.command(
            forKeyCode: escape.0, characters: escape.1, modifiers: escape.2
        ) == .stopLoading)

        // The command bar wants Escape more than the loader does.
        m.commandBarOpen = true
        #expect(m.command(
            forKeyCode: escape.0, characters: escape.1, modifiers: escape.2
        ) == nil)
    }

    @Test("the door is actually installed")
    func lifecycleRoutesKeys() async throws {
        let lifecycle = SessionLifecycle()
        #expect(!lifecycle.isRoutingKeys)

        lifecycle.attach(to: model())

        // Without this the keymap is complete, correct and unreachable, which
        // is exactly the state this whole file exists to prevent.
        #expect(lifecycle.isRoutingKeys)
    }

    // MARK: - Which window the press came from

    // `everyDefaultChordIsReachable` asks what a press *means*. These ask
    // *where it is allowed to land* — the half that was missing while the
    // monitor listened to the whole application and treated Settings as if it
    // were the browser. That test passed the whole time ⌘W was closing a tab
    // behind the Settings window, because it never asked where the press came
    // from.

    @Test("no chord in the keymap runs a browser command from another window")
    func browserCommandsStayWithTheBrowser() async throws {
        let m = model()
        // Somewhere for the browser state to be disturbed *from*, so "nothing
        // moved" is a real claim rather than a claim about an empty browser.
        m.send(.openTab(space: nil, url: nil, parent: nil))

        for binding in m.keymap {
            // Read before each press rather than once at the end. ⌘N and ⇧⌘N
            // are `opensItsOwnWindow` and *do* change the browser — that is
            // what they are for — so a single comparison afterwards could no
            // longer tell "the crossing ones worked" from "a refused one got
            // through" (ADR-0065).
            let tabs = m.snapshot.tabs.count
            let active = m.snapshot.activeTab
            let sidebar = m.sidebarVisible
            let zoom = m.activeTab?.zoomFactor
            let windows = m.snapshot.windows.count

            let (code, characters, flags) = press(binding.chord)
            let disposition = m.handleKeyDown(
                keyCode: code, characters: characters, modifiers: flags, from: .auxiliary
            )

            if binding.command.scope == .opensItsOwnWindow {
                #expect(
                    disposition == .handled,
                    "\(binding.chord) opens a window of its own and should still work"
                )
                continue
            }

            #expect(
                disposition != .handled,
                "\(binding.chord) reached \(binding.command) from a window that is not the browser"
            )
            // The disposition is what the shell acts on; this is what the
            // person sees. Nothing behind the window moved.
            #expect(
                m.snapshot.tabs.count == tabs,
                "\(binding.chord) opened or closed a tab behind the window"
            )
            #expect(m.snapshot.activeTab == active, "\(binding.chord) moved the active tab")
            #expect(
                m.snapshot.windows.count == windows,
                "\(binding.chord) opened or closed a window"
            )
            #expect(m.sidebarVisible == sidebar)
            #expect(m.activeTab?.zoomFactor == zoom)
            #expect(!m.commandBarOpen, "the command bar opened over a window nobody is looking at")
            #expect(!m.finder.isOpen)
        }
    }

    @Test("⌘W closes the window it was pressed over, and a tab only in the browser")
    func closeTabIsAboutWhatIsInFront() async throws {
        let m = model()
        m.send(.openTab(space: nil, url: nil, parent: nil))
        let tabs = m.snapshot.tabs.count
        let (code, characters, flags) = press(try #require(m.chord(for: .closeTab)))

        #expect(m.handleKeyDown(
            keyCode: code, characters: characters, modifiers: flags, from: .auxiliary
        ) == .closesTheWindow)
        #expect(m.snapshot.tabs.count == tabs, "the reported defect: a tab behind the window")

        #expect(m.handleKeyDown(
            keyCode: code, characters: characters, modifiers: flags, from: .browser(m.snapshot.keyWindow)
        ) == .handled)
        #expect(m.snapshot.tabs.count == tabs - 1)
    }

    @Test("the panes that open a window of their own still answer from anywhere")
    func settingsCrossesOver() async throws {
        let m = model()
        m.showingSettings = false

        let (code, characters, flags) = press(try #require(m.chord(for: .showSettings)))
        #expect(m.handleKeyDown(
            keyCode: code, characters: characters, modifiers: flags, from: .auxiliary
        ) == .handled)

        // ⌘, from About puts Settings in front of you, which is the whole
        // argument for letting it across.
        #expect(m.showingSettings)
        #expect(m.settingsSection == .general)
    }

    @Test("Escape belongs to the window in front, even while a page is loading")
    func escapeIsNotTakenFromAnotherWindow() async throws {
        let m = model()
        let tab = try #require(m.snapshot.activeTab)
        m.send(.navigationStarted(tab: tab, url: "https://avelino.run/"))
        let escape: (UInt16, String, NSEvent.ModifierFlags) = (KeyPress.escapeKeyCode, "", [])

        // Passed on rather than swallowed: About closes on Escape, and a sheet
        // in Settings is dismissed with it. Stopping a load nobody can see is
        // not worth either of those.
        #expect(m.handleKeyDown(
            keyCode: escape.0, characters: escape.1, modifiers: escape.2, from: .auxiliary
        ) == .passOn)

        // In the browser it still stops the load, which is what it is bound to.
        #expect(m.handleKeyDown(
            keyCode: escape.0, characters: escape.1, modifiers: escape.2, from: .browser(m.snapshot.keyWindow)
        ) == .handled)
    }

    @Test("the keys a text field lives on are never taken, from any window")
    func editingKeysSurvive() async throws {
        let m = model()

        // The Air Traffic rule editor and the extension install field are
        // ordinary text fields in the Settings window. A monitor that swallowed
        // these would be a worse defect than the one it was written to fix.
        for character in ["a", "c", "v", "x", "z"] {
            for role in [WindowRole.auxiliary, .browser(m.snapshot.keyWindow)] {
                #expect(m.handleKeyDown(
                    keyCode: Self.notANamedKey, characters: character,
                    modifiers: [.command], from: role
                ) == .passOn, "⌘\(character.uppercased()) must reach the field")
            }
        }
    }

    @Test("a menu item never advertises a bare key")
    func menusDoNotClaimBareKeys() async throws {
        let m = model()

        // A menu item's key equivalent is matched against the whole
        // application, whichever window is in front. Escape on the Stop item is
        // Escape taken from every window in the app — including About, which is
        // documented as closing on it.
        #expect(
            m.keymap.contains { $0.command == .stopLoading && $0.chord.key == .escape },
            "the keymap still binds bare Escape; only the menu may not print it"
        )
        let stop = try #require(CommandMenuItem.advertisedChord(for: .stopLoading, in: m))
        #expect(stop.modifiers.anyHeld)
        #expect(stop.key == .char(value: "."), "⌘. is the chord a menu can carry")

        // And nothing else lost its chord on the way: every command with a
        // modified binding still prints one.
        for binding in m.keymap where binding.chord.modifiers.anyHeld {
            #expect(
                CommandMenuItem.advertisedChord(for: binding.command, in: m) != nil,
                "\(binding.command) has \(binding.chord) and the menu shows nothing"
            )
        }
    }
}

/// Telling the windows apart.
///
/// By identity, never by title: a title is copy, and the day "Settings" is
/// "Ajustes" a check against the string stops working without failing.
@MainActor
struct WindowRoleTests {
    @Test("a window is the browser only if it says so")
    func auxiliaryIsTheDefault() async throws {
        // The registry is one table for the whole application, so a test that
        // does not clear it inherits whatever the last one queued.
        BrowserWindows.forgetEverything()
        let window = testWindow(.zero)

        // The safe direction. A window added next year, by someone who never
        // reads this file, gets standard macOS behaviour rather than the
        // browser's whole keymap.
        #expect(WindowRole(of: window) == .auxiliary)
        #expect(WindowRole(of: nil) == .auxiliary)

        BrowserWindows.hold(window, fallback: WindowId(7))
        #expect(WindowRole(of: window) == .browser(WindowId(7)))

        BrowserWindows.release(window)
        #expect(WindowRole(of: window) == .auxiliary)
    }

    @Test("the marker claims the window it lands in, and lets go of it")
    func theMarkerFollowsItsWindow() async throws {
        BrowserWindows.forgetEverything()
        let window = testWindow(NSRect(x: 0, y: 0, width: 400, height: 300))
        let m = BrowserModel(storagePath: nil)
        let marker = BrowserWindowTag(model: m)

        window.contentView?.addSubview(marker)
        #expect(WindowRole(of: window) == .browser(m.snapshot.keyWindow))

        // A window the browser has left is not the browser. Without this the
        // registry would answer for a view that moved on.
        marker.removeFromSuperview()
        #expect(WindowRole(of: window) == .auxiliary)

        // And it is a tag, not a surface: a marker that answered a hit test
        // would be a transparent sheet over the whole page.
        #expect(marker.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    @Test("every command says where it is allowed to land")
    func scopesAreDecided() async throws {
        let m = BrowserModel(storagePath: nil)

        // `scope` has no `default:`, so a command added to the core cannot
        // compile without a decision. This checks the decisions themselves.
        for binding in m.keymap {
            switch binding.command.scope {
            case .opensItsOwnWindow:
                #expect(binding.command.reaches(.auxiliary))
            case .browserWindow, .frontmost:
                #expect(!binding.command.reaches(.auxiliary))
            }
            #expect(
                binding.command.reaches(.browser(m.snapshot.keyWindow)),
                "the browser runs all of them"
            )
        }
    }
}

/// The sidebar toggle, which is ⌘S and has to survive the trip through
/// NavigationSplitView's visibility enum.
@MainActor
struct SidebarToggleTests {
    @Test("⌃S toggles the sidebar, leaving ⌘S to Save as Chrome has it")
    func shortcutIsBound() async throws {
        let m = BrowserModel(storagePath: nil)
        let chord = try #require(m.chord(for: .toggleSidebar))

        #expect(chord.key == .char(value: "s"))
        #expect(chord.modifiers.control)
        #expect(!chord.modifiers.primary)
        #expect(!chord.modifiers.shift)
    }

    @Test("hiding and showing round-trips through the split view's visibility")
    func visibilityRoundTrips() async throws {
        // .all is a three-column value and does nothing in a two-column split,
        // so showing the sidebar again would silently fail.
        #expect(NavigationSplitViewVisibility.showingSidebar(true) == .doubleColumn)
        #expect(NavigationSplitViewVisibility.showingSidebar(false) == .detailOnly)

        #expect(NavigationSplitViewVisibility.showingSidebar(true).showsSidebar)
        #expect(!NavigationSplitViewVisibility.showingSidebar(false).showsSidebar)
    }

    @Test("toggling twice returns to where it started")
    func togglingIsReversible() async throws {
        let m = BrowserModel(storagePath: nil)
        let initial = m.sidebarVisible

        m.perform(.toggleSidebar)
        #expect(m.sidebarVisible != initial)

        m.perform(.toggleSidebar)
        #expect(m.sidebarVisible == initial)
    }
}

/// We target Chrome users, so the bindings are Chrome's.
@MainActor
struct ChromeParityTests {
    private func newModel() -> BrowserModel { BrowserModel(storagePath: nil) }

    @Test("the Chrome shortcuts a switcher already has in their fingers")
    func chromeBindings() async throws {
        let m = newModel()

        let expected: [(UiCommand, String, Bool)] = [
            (.newTab, "t", false),
            (.closeTab, "w", false),
            (.reopenClosedTab, "t", true),
            (.openLocation, "l", false),
            (.reload, "r", false),
            (.reloadIgnoringCache, "r", true),
            (.savePage, "s", false),
            (.printPage, "p", false),
            (.findInPage, "f", false),
            (.findNext, "g", false),
            (.findPrevious, "g", true),
            (.showHistory, "y", false),
            (.showDownloads, "j", true),
            (.showSettings, ",", false),
            // ⌘D is Chrome's bookmark chord and it is ours (ADR-0061). It used
            // to be `.togglePinTab` on the argument that pinning was "keep this
            // page" in the model this browser had; ADR-0059 gave it a bookmark,
            // so the argument expired and this row moved *towards* Chrome
            // rather than away from it.
            (.addBookmark, "d", false),
            // And pinning, which Chrome has no concept of, took an invented
            // chord instead of a borrowed one. It has to be asserted here too:
            // "⌘D bookmarks" is only half the decision, and the half that goes
            // silently wrong is the other one disappearing.
            (.togglePinTab, "d", true),
            (.toggleBookmarks, "b", true),
        ]

        for (command, key, shift) in expected {
            let chord = try #require(m.chord(for: command), "\(command) has no shortcut")
            #expect(chord.key == .char(value: key), "\(command) is on the wrong key")
            #expect(chord.modifiers.primary, "\(command) is missing ⌘")
            #expect(chord.modifiers.shift == shift, "\(command) has the wrong shift")
        }
    }

    @Test("⌘S saves the page and does not touch the sidebar")
    func saveOwnsCommandS() async throws {
        let m = newModel()

        let save = try #require(m.chord(for: .savePage))
        #expect(save.key == .char(value: "s"))
        #expect(save.modifiers.primary)

        // The sidebar moved to ⌃S, which on a Mac is a different key.
        let sidebar = try #require(m.chord(for: .toggleSidebar))
        #expect(sidebar.modifiers.control)
        #expect(!sidebar.modifiers.primary)
    }

    @Test("every page action is wired, not just bound")
    func pageActionsAreHandled() async throws {
        let m = newModel()

        // perform() has no default case, so a command with no behaviour would
        // not compile. This checks none of them blow up at runtime either.
        for command in [UiCommand.stopLoading, .findInPage, .findNext, .findPrevious] {
            m.perform(command)
        }
        #expect(m.finder.isOpen, "⌘F must actually open the find bar")
    }

    @Test("find remembers the query so ⌘G can repeat it")
    func findRemembersTheQuery() async throws {
        let m = newModel()
        m.perform(.findInPage)

        m.setFindQuery("webkit")

        #expect(m.finder.query == "webkit")
        m.perform(.findNext)
        #expect(m.finder.query == "webkit", "repeating must not clear the query")
    }

    @Test("closing find puts the bar away")
    func findCloses() async throws {
        let m = newModel()
        m.perform(.findInPage)
        #expect(m.finder.isOpen)

        m.closeFind()

        #expect(!m.finder.isOpen)
    }

    @Test("a saved page gets a filename you would not be embarrassed by")
    func filenamesAreSane() async throws {
        #expect(EngineHost.filename(from: "Hello World") == "Hello World.html")
        // Slashes in a title would otherwise become directories.
        #expect(EngineHost.filename(from: "a/b:c?d") == "a-b-c-d.html")
        #expect(EngineHost.filename(from: "") == "Page.html")
        #expect(EngineHost.filename(from: "   ") == "Page.html")

        let long = String(repeating: "x", count: 300)
        #expect(EngineHost.filename(from: long).count <= 85)
    }
}

/// More than one browser window (ADR-0065).
///
/// `KeyPressTests` sweeps the keymap from a window that is *not* the browser.
/// These sweep it from a browser window that is not the one in front, which is
/// the case ADR-0053 could not distinguish: `WindowRole` answered "browser" for
/// both, so the command ran against whichever window the core was pointing at.
@MainActor
struct SeveralWindowTests {
    private func model() -> BrowserModel { BrowserModel(storagePath: nil) }

    /// The identity of a second window, made the way ⌘N makes one.
    private func secondWindow(_ m: BrowserModel) -> WindowId {
        m.send(.openWindow(onto: .currentSpace))
        return m.snapshot.keyWindow
    }

    @Test("a command acts on the window it was pressed in, not the one in front")
    func commandsFollowThePress() async throws {
        let m = model()
        let first = m.snapshot.keyWindow
        let behind = try #require(m.snapshot.activeTab)
        let second = secondWindow(m)
        let inFront = try #require(m.snapshot.activeTab)
        #expect(second != first)
        #expect(behind != inFront)

        // ⌘W pressed over the *first* window, while the second is the one the
        // core has in front. Before this, the press would have closed the tab
        // in the second — a page disappearing in a window nobody touched.
        let (code, characters, flags) = press(try #require(m.chord(for: .closeTab)))
        #expect(m.handleKeyDown(
            keyCode: code, characters: characters, modifiers: flags,
            from: .browser(first)
        ) == .handled)

        #expect(m.snapshot.tabs.contains { $0.id == inFront }, "a tab closed in the other window")
        #expect(!m.snapshot.tabs.contains { $0.id == behind })
        #expect(m.snapshot.keyWindow == first, "the press moved the front to where it came from")
    }

    /// The sweep, two windows wide. Every chord in the keymap, pressed over the
    /// window that is not in front, must leave the other window's page, zoom and
    /// tab exactly where they were.
    @Test("no chord in the keymap reaches into the window behind the one pressed")
    func theSweepHoldsForTwoWindows() async throws {
        let m = model()
        var pressedIn = m.snapshot.keyWindow
        var behind = secondWindow(m)

        for binding in m.keymap {
            // ⇧⌘W closed the window the last press came from, so there is one
            // again. Rebuilt rather than skipped: a sweep that steps over a
            // chord is a sweep with a hole in it, and the hole is always the
            // chord somebody was in a hurry about.
            if !m.snapshot.windows.contains(where: { $0.id == pressedIn }) {
                pressedIn = behind
                behind = secondWindow(m)
            }
            m.focusWindow(behind)

            // Read fresh each time: the press below is aimed at `pressedIn` and
            // is allowed to change that window as much as it likes.
            let theirTab = m.activeTab(in: behind)
            let theirTabs = m.todayTabs(in: behind).map(\.id)
            let theirZoom = theirTab.flatMap { id in
                m.snapshot.tabs.first { $0.id == id }?.zoomFactor
            }

            let (code, characters, flags) = press(binding.chord)
            m.handleKeyDown(
                keyCode: code, characters: characters, modifiers: flags,
                from: .browser(pressedIn)
            )

            // ⇧⌘W closes the window the press came from and ⌘N/⇧⌘N open one.
            // Both move the front on purpose; what none of them may do is
            // disturb the window that was already there.
            guard m.snapshot.windows.contains(where: { $0.id == behind }) else { continue }
            #expect(
                m.activeTab(in: behind) == theirTab,
                "\(binding.chord) moved the active tab in the window behind it"
            )
            #expect(
                m.todayTabs(in: behind).map(\.id) == theirTabs,
                "\(binding.chord) opened or closed a tab in the window behind it"
            )
            let zoomNow = m.activeTab(in: behind).flatMap { id in
                m.snapshot.tabs.first { $0.id == id }?.zoomFactor
            }
            #expect(zoomNow == theirZoom, "\(binding.chord) zoomed the window behind it")
        }
    }

    /// A chord that does nothing is worse than one that does the ordinary
    /// thing. The core refuses to close the last window; the press has to go
    /// somewhere, and `performClose:` is where every other Mac window closes.
    @Test("⇧⌘W on the last window falls through to the platform's own close")
    func theLastWindowFallsThroughToTheSystem() async throws {
        let m = model()
        #expect(m.snapshot.windows.count == 1)
        let (code, characters, flags) = press(try #require(m.chord(for: .closeWindow)))

        #expect(m.handleKeyDown(
            keyCode: code, characters: characters, modifiers: flags,
            from: .browser(m.snapshot.keyWindow)
        ) == .closesTheWindow)
        #expect(m.snapshot.windows.count == 1, "the core kept somewhere to draw a page")

        // With two, it is the core's to close and the platform is not asked.
        let second = secondWindow(m)
        #expect(m.handleKeyDown(
            keyCode: code, characters: characters, modifiers: flags,
            from: .browser(second)
        ) == .handled)
        #expect(!m.snapshot.windows.contains { $0.id == second })
    }

    /// The whole-window version of ADR-0023's promise. A private space writes
    /// nothing down; this asks the same question about the window it is in, and
    /// asks it of the file rather than of the projection — the Rust suite
    /// already covers the projection, and this is the path the app runs.
    @Test("a private window writes nothing down, not even that it existed")
    func aPrivateWindowPersistsNothing() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-private-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }

        let priv: WindowId
        let secret: TabId
        do {
            let m = BrowserModel(storagePath: path.path)
            let ordinary = m.snapshot.keyWindow

            m.perform(.newPrivateWindow)
            priv = m.snapshot.keyWindow
            #expect(priv != ordinary)
            let space = try #require(m.snapshot.spaces.first { $0.id == m.activeSpace(in: priv) })
            #expect(
                space.profile.ephemeral,
                "⇧⌘N must open onto an ephemeral space, or it is not private at all"
            )

            secret = try #require(m.activeTab(in: priv))
            m.send(.navigationCommitted(tab: secret, url: "https://secret.example/"))
            m.send(.titleChanged(tab: secret, title: "Secret"))
            m.saveNow(reason: .quitting)
        }

        let after = BrowserModel(storagePath: path.path)

        #expect(
            !after.snapshot.windows.contains { $0.id == priv },
            "the private window came back, which is a record that somebody opened one"
        )
        #expect(after.snapshot.keyWindow != priv)
        #expect(!after.snapshot.tabs.contains { $0.id == secret }, "a private page came back")
        #expect(!after.snapshot.tabs.contains { $0.url == "https://secret.example/" })
        #expect(
            after.searchHistory("secret.example").isEmpty,
            "a private page reached history"
        )
        #expect(after.recentHistory(limit: 50).allSatisfy { $0.url != "https://secret.example/" })
    }

    @Test("a relaunch puts the tabs back in the windows they were in")
    func sessionRestoreKeepsWindows() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-windows-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }

        let stayed: TabId
        let moved: TabId
        let second: WindowId
        do {
            let m = BrowserModel(storagePath: path.path)
            stayed = try #require(m.snapshot.activeTab)
            m.send(.openWindow(onto: .currentSpace))
            second = m.snapshot.keyWindow
            moved = try #require(m.snapshot.activeTab)
            m.send(.navigationCommitted(tab: moved, url: "https://avelino.run/"))
            m.saveNow(reason: .quitting)
        }

        let after = BrowserModel(storagePath: path.path)

        #expect(after.snapshot.windows.count == 2, "the second window did not come back")
        #expect(after.snapshot.keyWindow == second, "the window in front came back behind")
        #expect(after.snapshot.tabs.first { $0.id == moved }?.window == second)
        #expect(after.snapshot.tabs.first { $0.id == stayed }?.window != second)
    }

    /// Copied from `KeyPressTests`, which owns the real table. Only the chords
    /// these tests press are needed, and all of them carry a modifier.
    private func press(_ chord: Chord) -> (UInt16, String, NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if chord.modifiers.primary { flags.insert(.command) }
        if chord.modifiers.shift { flags.insert(.shift) }
        if chord.modifiers.alt { flags.insert(.option) }
        if chord.modifiers.control { flags.insert(.control) }

        switch chord.key {
        case let .char(value):
            let punctuation: [(code: UInt16, plain: String, shifted: String)] = [
                (33, "[", "{"), (30, "]", "}"), (42, "\\", "|"),
                (43, ",", "<"), (47, ".", ">"), (27, "-", "_"), (24, "=", "+"),
            ]
            if let key = punctuation.first(where: { $0.plain == value }) {
                return (key.code, chord.modifiers.shift ? key.shifted : key.plain, flags)
            }
            if let key = punctuation.first(where: { $0.shifted == value }) {
                flags.insert(.shift)
                return (key.code, key.shifted, flags)
            }
            return (0xFFFF, chord.modifiers.shift ? value.uppercased() : value, flags)
        case .enter: return (36, "", flags)
        case .tab: return (48, "", flags)
        case .space: return (49, "", flags)
        case .backspace: return (51, "", flags)
        case .escape: return (53, "", flags)
        case .left: return (123, "", flags)
        case .right: return (124, "", flags)
        case .up: return (126, "", flags)
        case .down: return (125, "", flags)
        }
    }
}
