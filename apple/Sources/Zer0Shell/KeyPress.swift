import AppKit
import Carbon
import Zer0Core

/// What physical key this is, independent of what it happens to type.
///
/// A key press reports the glyph the layout produced, and for punctuation that
/// glyph moves under Shift: the key the keymap calls `\` reports `|` when Shift
/// is down, and the key the keymap calls `+` never reports anything else
/// without it. Resolving a chord on the reported glyph alone therefore loses
/// ⇧⌘\ in one direction and ⌘+ in the other.
enum KeyboardLayout {
    /// The glyph this physical key types with no modifiers at all.
    ///
    /// Read from the live ASCII-capable layout rather than assumed, because
    /// "the key to the right of P" is a different glyph on a different layout
    /// and the whole point of asking the system is not to guess.
    static func baseCharacter(for keyCode: UInt16) -> String? {
        // A virtual key code is a byte. Anything above that is not a key, and
        // handing it to UCKeyTranslate is asking it to index off the end of a
        // table it will not bounds-check for us.
        guard keyCode <= 0x7F else { return nil }

        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
            .takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let base = buffer.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)

            var deadState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadState, characters.count, &length, &characters
            )
            guard status == noErr, length == 1 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

/// Turning a real key press into the chords the core's keymap can answer.
///
/// This exists because the menu cannot be the only door. `Keymap::chord_for`
/// returns the **first** binding of a command, so a command with two chords got
/// one of them wired into AppKit and the other did nothing at all — `Back` has
/// ⌘← and ⌘[, and only ⌘← ever arrived. Worse, a command with no menu item had
/// no chord anywhere, however carefully the core bound it.
///
/// The keymap is the dispatcher now. The menu keeps its label and its advertised
/// chord, and stops being the thing that decides what a key press means — which
/// is what ADR-0012 says the shell must not do.
enum KeyPress {
    /// Physical Escape. Named because `BrowserModel` has to recognise it before
    /// it decides whether the keymap may have it.
    static let escapeKeyCode: UInt16 = 53

    /// The chords this press could mean, best first.
    ///
    /// More than one because of Shift, which means two different things. On a
    /// letter it is a modifier the person added: ⇧⌘T is not ⌘T. On punctuation
    /// it is usually just *how the glyph is typed*, and the keymap and the
    /// keyboard disagree about which glyph to name:
    ///
    /// - the keymap says `⇧⌘\`, the keyboard reports `|`;
    /// - the keymap says `⌘+`, the keyboard reports `+` **with Shift held**,
    ///   because no keyboard has an unshifted `+`.
    ///
    /// So a press offers what it typed, what its key types unshifted, and what
    /// it typed with the Shift discounted. Whichever the keymap recognises wins.
    static func chords(
        keyCode: UInt16,
        characters: String,
        baseCharacter: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> [Chord] {
        let mods = Modifiers(
            primary: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
            alt: modifiers.contains(.option),
            control: modifiers.contains(.control)
        )

        // Named keys come from the key code, not the character. The character
        // is a mess — Tab is "\t" but Shift-Tab is a different control code
        // entirely, and an arrow is a private-use scalar — while the code is
        // the physical key and says the same thing on every layout.
        if let named = namedKey(for: keyCode) {
            return [Chord(key: named, modifiers: mods)]
        }

        var out: [Chord] = []
        func offer(_ value: String, shift: Bool) {
            let lowered = value.lowercased()
            guard lowered.count == 1, let scalar = lowered.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar)
            else { return }
            let chord = Chord(
                key: .char(value: lowered),
                modifiers: Modifiers(
                    primary: mods.primary, shift: shift, alt: mods.alt, control: mods.control
                )
            )
            if !out.contains(chord) { out.append(chord) }
        }

        // What it typed. Letters and unshifted punctuation are already done.
        offer(characters, shift: mods.shift)

        if mods.shift {
            // What the same key types unshifted, keeping Shift as a modifier.
            // This is ⇧⌘\ arriving as "|".
            if let baseCharacter { offer(baseCharacter, shift: true) }

            // And the glyph as typed with the Shift discounted, for a chord
            // written as the shifted glyph. This is ⌘+ arriving as ⇧⌘=.
            if let scalar = characters.lowercased().unicodeScalars.first,
               !CharacterSet.alphanumerics.contains(scalar) {
                offer(characters, shift: false)
            }
        }
        return out
    }

    /// Whether the keymap is even allowed to claim this press.
    ///
    /// Without this, every letter typed into a page or a text field would be
    /// looked up in the keymap. A browser that eats typing is worse than one
    /// missing a shortcut, so the bar is a real modifier: Command or Control.
    ///
    /// Escape is deliberately not here. It is bound to `StopLoading`, but it is
    /// also how the command bar, the find bar and a rename field are dismissed,
    /// and arbitrating that is a focus decision (ADR-0013) rather than a keymap
    /// one. `BrowserModel` handles it with the focus it can see.
    static func couldBeAShortcut(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.command) || modifiers.contains(.control)
    }

    private static func namedKey(for keyCode: UInt16) -> Key? {
        switch keyCode {
        case 36: .enter
        case 48: .tab
        case 49: .space
        case 51: .backspace
        case escapeKeyCode: .escape
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
    }
}
