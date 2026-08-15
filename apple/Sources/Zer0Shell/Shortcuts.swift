import SwiftUI
import Zer0Core

/// Translating the core's keymap into what AppKit and SwiftUI want.
///
/// This file knows about Command keys and `KeyEquivalent`. It does not know
/// which shortcut does what: that comes from `zer0-core`, so the Linux shell
/// will read the same bindings out of the same place.
public extension Chord {
    /// The Apple rendering of a chord, or nil if the key has no SwiftUI
    /// equivalent.
    var keyboardShortcut: KeyboardShortcut? {
        guard let equivalent = keyEquivalent else { return nil }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }

    private var keyEquivalent: KeyEquivalent? {
        switch key {
        case let .char(value):
            guard let character = value.first, value.count == 1 else { return nil }
            return KeyEquivalent(character)
        case .enter: return .return
        case .escape: return .escape
        case .tab: return .tab
        case .space: return .space
        case .backspace: return .delete
        case .left: return .leftArrow
        case .right: return .rightArrow
        case .up: return .upArrow
        case .down: return .downArrow
        }
    }

    /// How the chord is written next to a menu item, using the glyphs people
    /// already read on a Mac keyboard.
    var displayString: String {
        var out = ""
        if modifiers.control { out += "⌃" }
        if modifiers.alt { out += "⌥" }
        if modifiers.shift { out += "⇧" }
        if modifiers.primary { out += "⌘" }
        out += keyGlyph
        return out
    }

    private var keyGlyph: String {
        switch key {
        case let .char(value): value.uppercased()
        case .enter: "↩"
        case .escape: "⎋"
        case .tab: "⇥"
        case .space: "Space"
        case .backspace: "⌫"
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        }
    }

    /// `primary` is Command here. On Linux the same binding will read as
    /// Control, which is the whole point of the core not naming a physical key.
    private var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.primary { result.insert(.command) }
        if modifiers.shift { result.insert(.shift) }
        if modifiers.alt { result.insert(.option) }
        if modifiers.control { result.insert(.control) }
        return result
    }
}

public extension UiCommand {
    /// The menu label. Kept here rather than in the core because it is copy,
    /// and copy gets localised per platform.
    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .closeTab: "Close Tab"
        case .reopenClosedTab: "Reopen Closed Tab"
        case .openLocation: "Open Location…"
        case .back: "Back"
        case .forward: "Forward"
        case .reload: "Reload"
        case .reloadIgnoringCache: "Reload Ignoring Cache"
        case .copyCurrentUrl: "Copy Current URL"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case let .selectTab(index): "Select Tab \(index)"
        case let .runPinnedExtension(index): "Extension \(index)"
        case .addBookmark: "Keep This Page"
        case .toggleBookmarks: "Kept Pages"
        case .togglePinTab: "Pin Tab"
        case .toggleMuteTab: "Mute Tab"
        // What the item says when there is no page to name. The live item names
        // the site and says which way it is about to go — see
        // `BrowserModel.blockingMenuTitle`.
        case .toggleBlockingHere: "Turn Off Blocking on This Site"
        case .openChat: "Ask About This Page"
        case .newWindow: "New Window"
        // "New Private Window" is what Chrome, Firefox and Edge print, and what
        // somebody scanning the File menu is looking for. The mechanism behind
        // it is an ephemeral space (ADR-0065); the menu is not the place to
        // teach that.
        case .newPrivateWindow: "New Private Window"
        case .closeWindow: "Close Window"
        case .newSpace: "New Space"
        case .nextSpace: "Next Space"
        case .previousSpace: "Previous Space"
        case let .selectSpace(index): "Select Space \(index)"
        case .toggleSplitView: "Split View"
        case .focusOtherPane: "Other Pane"
        case .toggleSidebar: "Toggle Sidebar"
        case .savePage: "Save Page As…"
        case .printPage: "Print…"
        case .viewSource: "View Source"
        case .toggleDevTools: "Web Inspector"
        case .stopLoading: "Stop"
        case .findInPage: "Find…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .showHistory: "History"
        case .showDownloads: "Downloads"
        case .showSettings: "Settings…"
        case .showExtensions: "Extensions…"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .zoomReset: "Actual Size"
        }
    }
}

/// A menu item wired to a command, wearing whatever chord the keymap gives it.
///
/// Built from the keymap rather than hard-coded, so rebinding a shortcut
/// updates the menu without anyone having to remember to.
public struct CommandMenuItem: View {
    @Environment(BrowserModel.self) private var model
    let command: UiCommand

    public init(command: UiCommand) {
        self.command = command
    }

    public var body: some View {
        let button = Button(title) { model.perform(command) }
            // A menu item that takes the click and does nothing is a lie of
            // affordance (ADR-0018). There is no host to file an exception
            // against on a blank tab or a `data:` URL, so the item says so by
            // going grey rather than by beeping after the fact.
            .disabled(command == .toggleBlockingHere && model.blockingHost == nil)

        if let shortcut = Self.advertisedChord(for: command, in: model)?.keyboardShortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }

    /// The label, which for one command depends on the page in front of you.
    ///
    /// Not a switch, deliberately: a switch here would be a second copy of the
    /// vocabulary that has to stay exhaustive, and every other command's title
    /// is a constant that belongs on the command itself.
    private var title: String {
        command == .toggleBlockingHere ? model.blockingMenuTitle : command.title
    }

    /// The chord this item wears: the first one the keymap gives the command
    /// that carries a modifier.
    ///
    /// **A menu item's key equivalent is matched against the whole
    /// application**, whichever window is in front, so a bare key on a menu item
    /// is a key taken away from every other window in the app. `StopLoading` is
    /// bound to Escape and to ⌘. — advertising the Escape put a global Escape in
    /// the menu bar, where a press in Settings reached the browser's
    /// stop-loading path instead of the window in front of you.
    ///
    /// Nothing is lost: bare keys still reach their command through the key
    /// monitor, which can see what has focus and arbitrate (ADR-0013). What
    /// changes is only what the menu prints — Stop now shows ⌘., which is the
    /// chord you can actually put on a menu.
    static func advertisedChord(for command: UiCommand, in model: BrowserModel) -> Chord? {
        model.keymap.first { $0.command == command && $0.chord.modifiers.anyHeld }?.chord
    }
}

extension Modifiers {
    /// Whether this chord asks for any modifier at all.
    var anyHeld: Bool { primary || shift || alt || control }
}
