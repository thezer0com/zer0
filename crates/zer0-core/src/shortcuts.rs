//! Keyboard shortcuts.
//!
//! These live in the core for the same reason command-bar ranking does: a
//! shortcut defined in the macOS shell is a shortcut the Linux shell will get
//! subtly wrong. One keymap, one set of defaults, every platform.
//!
//! The only thing that varies per platform is which physical key counts as
//! [`Modifiers::primary`]: Command on Apple, Control everywhere else. Bindings
//! are written in terms of "primary" so ⌘T and Ctrl+T are the same binding
//! rather than two that have to be kept in step.

/// Something the user can ask the browser to do, independent of how it was
/// asked. Menus, shortcuts and the command bar all resolve to these.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum UiCommand {
    NewTab,
    CloseTab,
    ReopenClosedTab,
    OpenLocation,
    Back,
    Forward,
    Reload,
    ReloadIgnoringCache,
    CopyCurrentUrl,
    NextTab,
    PreviousTab,
    /// 1-based, as printed on the keyboard. 9 means "the last one".
    SelectTab {
        index: u8,
    },
    /// Press the nth extension button without reaching for the pointer.
    ///
    /// 1-based, indexing the pinned row in the order the core keeps it. Chrome
    /// has no answer here at all — its extension buttons are pointer-only —
    /// and the reason to have one is that a password manager is a thing you
    /// reach for mid-typing, which is the worst possible moment to be sent to
    /// the mouse.
    ///
    /// Deliberately shaped like [`UiCommand::SelectTab`] and bound one Shift
    /// away from it: ⌘n is the nth tab, ⇧⌘n is the nth extension. That is one
    /// sentence to learn rather than nine chords to memorise, and it is the
    /// only reason this is a numbered family rather than something invented.
    ///
    /// An index past the end of the row does nothing, and does it silently.
    /// There is no failure to report — the row is on screen and visibly has
    /// fewer things in it than the number that was pressed.
    RunPinnedExtension {
        index: u8,
    },
    /// Keep the page you are on, without keeping a tab open on it.
    ///
    /// ⌘D, which is what it is in Chrome. It has never removed anything: a
    /// second press on a page already kept says so and offers to rename it.
    AddBookmark,
    /// Show or hide the shelf the kept pages live on.
    ToggleBookmarks,
    TogglePinTab,
    ToggleMuteTab,
    /// Turn content blocking off — or back on — for the site in front of you.
    ///
    /// A command rather than a control parked over the page, because the moment
    /// it is wanted is the moment a site is visibly broken, and a permanent
    /// shield badge is the thing ADR-0010 exists to refuse. This is the door
    /// that is open from where the person already is.
    ToggleBlockingHere,
    /// Ask about the page you are on.
    OpenChat,
    /// ⌘N. Another window onto the space you are already in, with one new tab.
    NewWindow,
    /// ⇧⌘W. Close the window, as distinct from ⌘W closing a tab.
    CloseWindow,
    /// ⇧⌘N. The private window every browser puts on this chord.
    ///
    /// It is a window onto a fresh ephemeral space rather than a second notion
    /// of privacy, because an ephemeral space already is this browser's private
    /// mode: its own cookie jar, no history, nothing on disk (ADR-0007,
    /// ADR-0023). Two mechanisms would be two sets of promises to keep.
    NewPrivateWindow,
    NewSpace,
    NextSpace,
    PreviousSpace,
    /// Go straight to a space, rather than stepping past the ones in between.
    ///
    /// 1-based, over the chips in the order the sidebar draws them. It
    /// completes the numeric row: ⌘n is the nth tab, ⇧⌘n is the nth extension
    /// (ADR-0068), ⌃n is the nth space — the same digits, one modifier apart,
    /// for the three things a number means in this browser.
    ///
    /// Unlike [`UiCommand::SelectTab`], the ninth slot is the ninth space and
    /// not "the last one". That rule is Chrome's about tabs and arrives in the
    /// finger already; nobody's browser has a chord for a space, so there is
    /// nothing to honour and inventing it would land somebody somewhere they
    /// did not name. An index past the end does nothing, silently.
    SelectSpace {
        index: u8,
    },
    /// Two pages side by side, or back to one.
    ToggleSplitView,
    /// Move the keyboard across a split, without reaching for the mouse.
    FocusOtherPane,
    ToggleSidebar,
    SavePage,
    PrintPage,
    ViewSource,
    ToggleDevTools,
    StopLoading,
    FindInPage,
    FindNext,
    FindPrevious,
    ShowHistory,
    ShowDownloads,
    ShowSettings,
    ShowExtensions,
    ZoomIn,
    ZoomOut,
    ZoomReset,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum Key {
    /// A printable key, stored lowercase so Shift is expressed by the modifier
    /// rather than by the character.
    Char {
        value: String,
    },
    Enter,
    Escape,
    Tab,
    Space,
    Backspace,
    Left,
    Right,
    Up,
    Down,
}

impl Key {
    pub fn character(value: &str) -> Self {
        Key::Char {
            value: value.to_lowercase(),
        }
    }
}

/// `primary` is Command on Apple platforms and Control elsewhere. `control` is
/// the literal Control key, which on Apple is a different thing entirely.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Modifiers {
    pub primary: bool,
    pub shift: bool,
    pub alt: bool,
    pub control: bool,
}

impl Modifiers {
    pub const NONE: Self = Self {
        primary: false,
        shift: false,
        alt: false,
        control: false,
    };

    pub const fn primary() -> Self {
        Self {
            primary: true,
            ..Self::NONE
        }
    }

    pub const fn primary_shift() -> Self {
        Self {
            primary: true,
            shift: true,
            ..Self::NONE
        }
    }

    pub const fn primary_alt() -> Self {
        Self {
            primary: true,
            alt: true,
            ..Self::NONE
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Chord {
    pub key: Key,
    pub modifiers: Modifiers,
}

impl Chord {
    pub fn new(key: Key, modifiers: Modifiers) -> Self {
        Self { key, modifiers }
    }

    /// A shorthand for the common case of primary plus a letter.
    pub fn primary(character: &str) -> Self {
        Self::new(Key::character(character), Modifiers::primary())
    }

    pub fn primary_shift(character: &str) -> Self {
        Self::new(Key::character(character), Modifiers::primary_shift())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
// Exposed as `ShortcutBinding` because SwiftUI owns the name `Binding`, and an
// ambiguous type lookup there is a miserable thing to debug.
#[cfg_attr(
    feature = "ffi",
    derive(uniffi::Record),
    uniffi(name = "ShortcutBinding")
)]
pub struct Binding {
    pub chord: Chord,
    pub command: UiCommand,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Keymap {
    bindings: Vec<Binding>,
}

impl Default for Keymap {
    fn default() -> Self {
        Self::with_defaults()
    }
}

impl Keymap {
    /// The shipped bindings.
    ///
    /// Deliberately close to what Safari and Chrome already do. A browser that
    /// invents its own shortcuts for going back is a browser people fight.
    pub fn with_defaults() -> Self {
        use Modifiers as M;
        use UiCommand::*;

        let mut bindings = vec![
            // Tabs
            Binding {
                chord: Chord::primary("t"),
                command: NewTab,
            },
            Binding {
                chord: Chord::primary("w"),
                command: CloseTab,
            },
            Binding {
                chord: Chord::primary_shift("t"),
                command: ReopenClosedTab,
            },
            Binding {
                chord: Chord::new(
                    Key::Tab,
                    M {
                        control: true,
                        ..M::NONE
                    },
                ),
                command: NextTab,
            },
            Binding {
                chord: Chord::new(
                    Key::Tab,
                    M {
                        control: true,
                        shift: true,
                        ..M::NONE
                    },
                ),
                command: PreviousTab,
            },
            Binding {
                chord: Chord::new(Key::Right, M::primary_alt()),
                command: NextTab,
            },
            Binding {
                chord: Chord::new(Key::Left, M::primary_alt()),
                command: PreviousTab,
            },
            Binding {
                // Safari's tab switcher. A switcher coming from Safari rather
                // than Chrome reaches for these, and they cost us nothing:
                // ⌘[ and ⌘] are Back and Forward, ⇧⌘[ and ⇧⌘] were free.
                chord: Chord::primary_shift("]"),
                command: NextTab,
            },
            Binding {
                chord: Chord::primary_shift("["),
                command: PreviousTab,
            },
            // Navigation
            Binding {
                chord: Chord::primary("l"),
                command: OpenLocation,
            },
            Binding {
                chord: Chord::new(Key::Left, M::primary()),
                command: Back,
            },
            Binding {
                chord: Chord::new(Key::Right, M::primary()),
                command: Forward,
            },
            Binding {
                chord: Chord::primary("["),
                command: Back,
            },
            Binding {
                chord: Chord::primary("]"),
                command: Forward,
            },
            Binding {
                chord: Chord::primary("r"),
                command: Reload,
            },
            Binding {
                chord: Chord::primary_shift("r"),
                command: ReloadIgnoringCache,
            },
            Binding {
                chord: Chord::new(Key::Escape, M::NONE),
                command: StopLoading,
            },
            Binding {
                // Firefox publishes ⌘. for Stop on macOS, and it is the older
                // Mac convention for "stop what you are doing" besides. Escape
                // is the one everybody knows; this is the one that still works
                // when something else on screen has claimed Escape.
                chord: Chord::primary("."),
                command: StopLoading,
            },
            // The page
            Binding {
                chord: Chord::primary("s"),
                command: SavePage,
            },
            Binding {
                chord: Chord::primary("p"),
                command: PrintPage,
            },
            Binding {
                chord: Chord::primary("f"),
                command: FindInPage,
            },
            Binding {
                chord: Chord::primary("g"),
                command: FindNext,
            },
            Binding {
                chord: Chord::primary_shift("g"),
                command: FindPrevious,
            },
            Binding {
                // What ⌘D is in Chrome, and now what it is here. It used to be
                // TogglePinTab, on the argument that pinning was "keep this
                // page" in the model this browser actually had; ADR-0059 gave
                // it a bookmark, so the argument expired and ADR-0061 moved the
                // chord back to what Chrome means by it.
                chord: Chord::primary("d"),
                command: AddBookmark,
            },
            Binding {
                // Pinning has no Chrome analogue, so by the rule this list runs
                // on it takes an invented chord rather than a borrowed one.
                // Shift for "the other one", the pattern ⌘G/⇧⌘G, ⌘R/⇧⌘R and
                // ⌘\/⇧⌘\ already set here. ⇧⌘D is Bookmark All Tabs in Chrome,
                // which is not a command this browser has.
                chord: Chord::primary_shift("d"),
                command: TogglePinTab,
            },
            Binding {
                // ⇧⌘B is Chrome's show/hide bookmarks bar, and this is the
                // shelf that answers to the same question. ⌘B is already the
                // sidebar; Shift makes it the shelf inside it.
                chord: Chord::primary_shift("b"),
                command: ToggleBookmarks,
            },
            Binding {
                chord: Chord::primary_shift("m"),
                command: ToggleMuteTab,
            },
            Binding {
                // Nobody's browser has a chord for this — Safari, Chrome,
                // Firefox and Edge all bury per-site blocking behind the lock
                // icon — so there is no memory to honour and the criterion
                // becomes the other one this list uses: take something that
                // costs nobody anything. ⇧⌘K is unspent in all four for any
                // command this browser has, and it survives the collapse to
                // Control, so the Linux shell needs no second binding.
                //
                // It has a chord at all because of *when* it is wanted: a site
                // is visibly broken and the page is what the hand is on.
                // Sending someone to the menu bar for that is the trip this
                // command exists to remove.
                chord: Chord::primary_shift("k"),
                command: ToggleBlockingHere,
            },
            Binding {
                chord: Chord::primary_shift("c"),
                command: CopyCurrentUrl,
            },
            Binding {
                // Chrome spends ⌘E on "Use Selection for Find", a command this
                // browser does not have, so the chord is free and E is the
                // letter people reach for. It survives the collapse to Control
                // — Ctrl+E is a shell editing key, not a browser one — so it
                // needs no second binding to exist off Apple.
                chord: Chord::primary("e"),
                command: OpenChat,
            },
            // Zoom
            Binding {
                chord: Chord::primary("+"),
                command: ZoomIn,
            },
            Binding {
                // The key people actually press, and the one every browser
                // binds. `+` and `=` are the same physical key, and on every
                // layout that key types `=` unshifted — so ⌘+ is really ⇧⌘=,
                // and somebody pressing ⌘ and the key next to backspace
                // without reaching for Shift got nothing at all.
                //
                // Both are bound rather than one being rewritten, because the
                // press arrives as whichever glyph the layout produced and
                // `KeyPress::chords` offers both spellings; binding the pair
                // is what makes either press land without the shell having to
                // decide which one the person meant.
                chord: Chord::primary("="),
                command: ZoomIn,
            },
            Binding {
                chord: Chord::primary("-"),
                command: ZoomOut,
            },
            Binding {
                chord: Chord::primary("0"),
                command: ZoomReset,
            },
            // Windows and panels
            Binding {
                // Chrome has no vertical tab strip, so this one is ours. ⌃S on
                // Apple, where Control is its own key.
                chord: Chord::new(
                    Key::character("s"),
                    M {
                        control: true,
                        ..M::NONE
                    },
                ),
                command: ToggleSidebar,
            },
            Binding {
                // Off Apple, Control *is* primary, so ⌃S would collide with
                // Save. This is the binding that works everywhere.
                chord: Chord::primary("b"),
                command: ToggleSidebar,
            },
            Binding {
                // Chrome has no split, so this one is ours and we are free to
                // choose — which means choosing something a finger already
                // knows rather than something free. ⌘\ is Split Editor in VS
                // Code, and Ctrl+\ is the same there on Linux, so the chord
                // survives the collapse to Control without a second binding.
                chord: Chord::primary("\\"),
                command: ToggleSplitView,
            },
            Binding {
                // Same key, Shift for "the other one" — the pattern ⌘G/⇧⌘G and
                // ⌘R/⇧⌘R already set in this list.
                chord: Chord::primary_shift("\\"),
                command: FocusOtherPane,
            },
            Binding {
                // The three window chords every browser already has, spelled
                // the way every browser spells them. ⇧⌘N used to open a space
                // here; it is the private-window chord in Chrome, Safari,
                // Firefox and Edge, and a browser that answered it with
                // something else would be lying to fingers that already know.
                chord: Chord::primary("n"),
                command: NewWindow,
            },
            Binding {
                chord: Chord::primary_shift("w"),
                command: CloseWindow,
            },
            Binding {
                chord: Chord::primary_shift("n"),
                command: NewPrivateWindow,
            },
            Binding {
                // Spaces move to ⌥⌘N, which is where this keymap already keeps
                // the things Chrome has no name for (⌥⌘I, ⌥⌘U, ⌥⌘L).
                chord: Chord::new(Key::character("n"), M::primary_alt()),
                command: NewSpace,
            },
            Binding {
                // Chrome has no spaces. Horizontal arrows are already its tab
                // switcher, so spaces take the vertical ones: tabs move across,
                // spaces move up and down, which matches the sidebar anyway.
                chord: Chord::new(Key::Down, M::primary_alt()),
                command: NextSpace,
            },
            Binding {
                chord: Chord::new(Key::Up, M::primary_alt()),
                command: PreviousSpace,
            },
            Binding {
                chord: Chord::primary("y"),
                command: ShowHistory,
            },
            Binding {
                // ⇧⌘J, which is where Chrome puts downloads on a Mac.
                chord: Chord::primary_shift("j"),
                command: ShowDownloads,
            },
            Binding {
                // And ⌥⌘L, which is where Edge puts them on a Mac. Downloads is
                // the pane the four browsers disagree about most — Chrome ⇧⌘J,
                // Edge ⌥⌘L, Firefox ⌘J — so it is the clearest case for taking
                // two chords instead of picking a loser.
                chord: Chord::new(Key::character("l"), M::primary_alt()),
                command: ShowDownloads,
            },
            Binding {
                chord: Chord::primary(","),
                command: ShowSettings,
            },
            Binding {
                chord: Chord::primary_shift(","),
                command: ShowExtensions,
            },
            // Developer
            Binding {
                chord: Chord::new(Key::character("i"), M::primary_alt()),
                command: ToggleDevTools,
            },
            Binding {
                // And ⇧⌘I, for the same reason Downloads takes two chords: the
                // browsers disagree, so taking both beats picking a loser.
                // ⌥⌘I is Chrome-on-Mac's and Safari's, so it is listed first
                // and is what the menu prints. ⇧⌘I is what Chrome prints
                // everywhere that is not a Mac — and it is the only one of the
                // two that survives the collapse to Control, where it lands on
                // Ctrl+Shift+I exactly as Chrome on Linux spells it. ⌥⌘I
                // collapses to Ctrl+Alt+I, which is nobody's.
                chord: Chord::primary_shift("i"),
                command: ToggleDevTools,
            },
            Binding {
                chord: Chord::new(Key::character("u"), M::primary_alt()),
                command: ViewSource,
            },
            Binding {
                // And ⌘U, on exactly the argument the inspector's second chord
                // runs on. ⌥⌘U is Chrome-on-Mac's and Safari's, so it stays
                // first and is what the menu prints; Ctrl+U is what Chrome,
                // Firefox and Edge publish everywhere that is not a Mac, and
                // ⌘U is the only spelling of this command that collapses onto
                // it. ⌥⌘U collapses to Ctrl+Alt+U, which is nobody's — so
                // without this row, View Source is a Mac-only command that
                // passes every reachability test by winning a chord no Linux
                // finger will ever press. ⌘U is unspent on a Mac.
                chord: Chord::primary("u"),
                command: ViewSource,
            },
        ];

        // The numeric row has three tenants, one modifier apart, and the order
        // they are pushed in is the tie-break (ADR-0087).
        //
        // ⌘1..⌘8 select a tab and ⌘9 jumps to the last, exactly as Chrome does.
        // ⇧⌘1..⇧⌘9 press the extension button in the same position, which is
        // the same sentence with one more key in it. ⌃1..⌃9 go to a space,
        // which is the division above both.
        //
        // ⌃n and ⌘n are the *same physical chord* off Apple, so one of them has
        // to lose it. **Tabs win**, for the reason Save wins ⌃S (ADR-0012):
        // Ctrl+1..Ctrl+9 is Chrome's tab selection on Linux and Windows and it
        // is in the finger already, where nobody has ever pressed a key to
        // reach a space. Spaces get ⌥⌘n, which collapses to Ctrl+Alt+n and
        // belongs to nothing — the same shape as ⌘B under ⌃S.
        //
        // `SelectTab` is pushed first *within each digit*, because
        // `command_for_collapsed` gives the collapsed chord to the first
        // binding that claims it. Reordering these four pushes silently decides
        // who owns Ctrl+n off Apple, and changes nothing at all on a Mac.
        for index in 1..=9u8 {
            let digit = index.to_string();
            bindings.push(Binding {
                chord: Chord::primary(&digit),
                command: SelectTab { index },
            });
            bindings.push(Binding {
                chord: Chord::primary_shift(&digit),
                command: RunPinnedExtension { index },
            });
            bindings.push(Binding {
                // What the Mac menu and the chip tooltips print: on Apple,
                // Control is its own key and this is the chord that was asked
                // for.
                chord: Chord::new(
                    Key::character(&digit),
                    M {
                        control: true,
                        ..M::NONE
                    },
                ),
                command: SelectSpace { index },
            });
            bindings.push(Binding {
                // And the one that survives the collapse. ⌥⌘ is already where
                // this keymap keeps what Chrome has no name for, and spaces
                // already live there: ⌥⌘N makes one, ⌥⌘↑/↓ step between them.
                // Going straight to one is the same family, not a new one.
                chord: Chord::new(Key::character(&digit), M::primary_alt()),
                command: SelectSpace { index },
            });
        }

        Self { bindings }
    }

    pub fn bindings(&self) -> &[Binding] {
        &self.bindings
    }

    /// What this key press means, if anything.
    pub fn command_for(&self, chord: &Chord) -> Option<UiCommand> {
        self.bindings
            .iter()
            .find(|b| &b.chord == chord)
            .map(|b| b.command.clone())
    }

    /// The chord to print next to a menu item.
    ///
    /// Returns the first binding, so when a command has several the default
    /// list decides which one is advertised.
    pub fn chord_for(&self, command: &UiCommand) -> Option<Chord> {
        self.bindings
            .iter()
            .find(|b| &b.command == command)
            .map(|b| b.chord.clone())
    }

    /// Bind a chord, taking it from whatever held it before.
    ///
    /// Two commands on one chord would make behaviour depend on list order,
    /// so the previous owner loses it.
    pub fn bind(&mut self, chord: Chord, command: UiCommand) {
        self.bindings.retain(|b| b.chord != chord);
        self.bindings.push(Binding { chord, command });
    }

    /// Make `chord` the only way to reach `command`.
    ///
    /// Distinct from [`bind`](Self::bind), which adds a chord alongside any
    /// the command already had. Changing "New Tab" to ⌘J should stop ⌘T doing
    /// it; adding a second chord for Back should not remove the first.
    pub fn rebind(&mut self, command: UiCommand, chord: Chord) {
        self.bindings
            .retain(|b| b.command != command && b.chord != chord);
        self.bindings.push(Binding { chord, command });
    }

    pub fn unbind(&mut self, chord: &Chord) -> bool {
        let before = self.bindings.len();
        self.bindings.retain(|b| &b.chord != chord);
        before != self.bindings.len()
    }

    pub fn reset(&mut self) {
        *self = Self::with_defaults();
    }

    /// What this key press does on a platform where Control is the primary
    /// modifier, which is everywhere except Apple.
    ///
    /// There, ⌃S and ⌘S are the same physical chord, so the first binding in
    /// the list wins and the second is unreachable.
    pub fn command_for_collapsed(&self, chord: &Chord) -> Option<UiCommand> {
        self.bindings
            .iter()
            .find(|b| collapsed(&b.chord) == collapsed(chord))
            .map(|b| b.command.clone())
    }

    /// Commands with no way to reach them once Control and primary collapse
    /// into one key.
    ///
    /// A command listed here works on macOS and silently does nothing on
    /// Linux, which is exactly the drift the shared keymap exists to prevent.
    pub fn unreachable_when_control_is_primary(&self) -> Vec<UiCommand> {
        let mut stranded = Vec::new();

        for binding in &self.bindings {
            if stranded.contains(&binding.command) {
                continue;
            }
            // Reachable if any of this command's chords wins its collapsed form.
            let reachable = self
                .bindings
                .iter()
                .filter(|b| b.command == binding.command)
                .any(|b| self.command_for_collapsed(&b.chord).as_ref() == Some(&b.command));

            if !reachable {
                stranded.push(binding.command.clone());
            }
        }
        stranded
    }

    /// Bindings that differ from the defaults, which is all that needs saving.
    pub fn customisations(&self) -> Vec<Binding> {
        let defaults = Self::with_defaults();
        self.bindings
            .iter()
            .filter(|b| defaults.command_for(&b.chord).as_ref() != Some(&b.command))
            .cloned()
            .collect()
    }

    /// Rebuild from defaults plus saved customisations.
    pub fn load(customisations: Vec<Binding>) -> Self {
        let mut map = Self::with_defaults();
        for binding in customisations {
            map.bind(binding.chord, binding.command);
        }
        map
    }
}

/// A chord as it exists on a platform where Control is the primary modifier.
fn collapsed(chord: &Chord) -> (Key, bool, bool, bool) {
    (
        chord.key.clone(),
        chord.modifiers.primary || chord.modifiers.control,
        chord.modifiers.shift,
        chord.modifiers.alt,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_default_chord_is_bound_twice() {
        // Two commands on one chord makes behaviour depend on list order, and
        // the bug shows up as "sometimes the wrong thing happens".
        let map = Keymap::with_defaults();
        let mut seen: Vec<&Chord> = Vec::new();

        for binding in map.bindings() {
            assert!(
                !seen.contains(&&binding.chord),
                "{:?} is bound twice, second time to {:?}",
                binding.chord,
                binding.command
            );
            seen.push(&binding.chord);
        }
    }

    #[test]
    fn every_command_is_still_reachable_where_control_is_primary() {
        // Off Apple there is no separate Command key, so ⌃S and ⌘S are one
        // chord. Anything stranded by that works on macOS and quietly does
        // nothing on Linux.
        let map = Keymap::with_defaults();

        let stranded = map.unreachable_when_control_is_primary();

        assert!(stranded.is_empty(), "no way to reach: {stranded:?}");
    }

    #[test]
    fn save_wins_the_collision_and_the_sidebar_keeps_its_own_way_in() {
        let map = Keymap::with_defaults();

        // Ctrl+S on Linux is Save, because that is what a Linux user expects.
        let control_s = Chord::new(
            Key::character("s"),
            Modifiers {
                control: true,
                ..Modifiers::NONE
            },
        );
        assert_eq!(
            map.command_for_collapsed(&control_s),
            Some(UiCommand::SavePage)
        );

        // And the sidebar is still reachable, through the binding that does
        // not collide.
        assert_eq!(
            map.command_for_collapsed(&Chord::primary("b")),
            Some(UiCommand::ToggleSidebar)
        );
    }

    #[test]
    fn on_apple_control_and_command_stay_different_keys() {
        let map = Keymap::with_defaults();
        let control_s = Chord::new(
            Key::character("s"),
            Modifiers {
                control: true,
                ..Modifiers::NONE
            },
        );

        assert_eq!(map.command_for(&control_s), Some(UiCommand::ToggleSidebar));
        assert_eq!(
            map.command_for(&Chord::primary("s")),
            Some(UiCommand::SavePage)
        );
    }

    #[test]
    fn the_chrome_shortcuts_our_users_already_know_are_all_there() {
        let map = Keymap::with_defaults();

        let expected = [
            (Chord::primary("t"), UiCommand::NewTab),
            (Chord::primary("w"), UiCommand::CloseTab),
            (Chord::primary_shift("t"), UiCommand::ReopenClosedTab),
            (Chord::primary("l"), UiCommand::OpenLocation),
            (Chord::primary("r"), UiCommand::Reload),
            (Chord::primary_shift("r"), UiCommand::ReloadIgnoringCache),
            (Chord::primary("s"), UiCommand::SavePage),
            (Chord::primary("p"), UiCommand::PrintPage),
            (Chord::primary("f"), UiCommand::FindInPage),
            (Chord::primary("g"), UiCommand::FindNext),
            (Chord::primary_shift("g"), UiCommand::FindPrevious),
            (Chord::primary("y"), UiCommand::ShowHistory),
            (Chord::primary_shift("j"), UiCommand::ShowDownloads),
            (Chord::primary(","), UiCommand::ShowSettings),
            (Chord::primary("0"), UiCommand::ZoomReset),
            (Chord::primary("d"), UiCommand::AddBookmark),
        ];

        for (chord, command) in expected {
            assert_eq!(
                map.command_for(&chord),
                Some(command.clone()),
                "{chord:?} should be {command:?}"
            );
        }
    }

    #[test]
    fn command_d_keeps_the_page_and_shift_command_d_keeps_the_tab() {
        // ADR-0061. ⌘D is the most-pressed bookmark chord there is and this
        // browser's audience presses it without looking. It used to move the
        // tab into another sidebar group instead, which is the one divergence
        // ADR-0011 accepted knowingly and named as its likeliest surprise.
        let map = Keymap::with_defaults();

        assert_eq!(
            map.command_for(&Chord::primary("d")),
            Some(UiCommand::AddBookmark)
        );
        assert_eq!(
            map.command_for(&Chord::primary_shift("d")),
            Some(UiCommand::TogglePinTab),
            "pinning has to keep a chord of its own, not lose one"
        );

        // And both survive the collapse to Control, so the Linux shell needs no
        // bindings of its own for either.
        assert_eq!(
            map.command_for_collapsed(&Chord::primary("d")),
            Some(UiCommand::AddBookmark)
        );
        assert_eq!(
            map.command_for_collapsed(&Chord::primary_shift("d")),
            Some(UiCommand::TogglePinTab)
        );
    }

    #[test]
    fn the_shelf_of_kept_pages_has_a_way_in_from_the_keyboard() {
        // ⇧⌘B is Chrome's, and ⌘B — the sidebar the shelf lives in — keeps its
        // own.
        let map = Keymap::with_defaults();

        assert_eq!(
            map.command_for(&Chord::primary_shift("b")),
            Some(UiCommand::ToggleBookmarks)
        );
        assert_eq!(
            map.command_for(&Chord::primary("b")),
            Some(UiCommand::ToggleSidebar)
        );
    }

    #[test]
    fn the_split_bindings_are_ours_and_step_on_nobody() {
        // Chrome has no split, so nothing had to be given up for these. ⌘\ is
        // Split Editor in VS Code, and Shift is "the other one" the way ⌘G and
        // ⇧⌘G already are here.
        let map = Keymap::with_defaults();

        assert_eq!(
            map.command_for(&Chord::primary("\\")),
            Some(UiCommand::ToggleSplitView)
        );
        assert_eq!(
            map.command_for(&Chord::primary_shift("\\")),
            Some(UiCommand::FocusOtherPane)
        );

        // And both survive the collapse to Control, so neither needs a second
        // binding to exist off Apple.
        assert_eq!(
            map.command_for_collapsed(&Chord::primary("\\")),
            Some(UiCommand::ToggleSplitView)
        );
        assert_eq!(
            map.command_for_collapsed(&Chord::primary_shift("\\")),
            Some(UiCommand::FocusOtherPane)
        );
    }

    #[test]
    fn asking_about_the_page_has_a_chord_that_costs_nobody_anything() {
        let map = Keymap::with_defaults();

        assert_eq!(
            map.command_for(&Chord::primary("e")),
            Some(UiCommand::OpenChat)
        );
        // And it is still there once Command and Control are one key, so the
        // Linux shell does not need a binding of its own.
        assert_eq!(
            map.command_for_collapsed(&Chord::primary("e")),
            Some(UiCommand::OpenChat)
        );
    }

    /// The command exists so a broken site can be fixed without leaving the
    /// page. A chord that only works on a Mac would make that true on a Mac
    /// and false everywhere else.
    #[test]
    fn turning_blocking_off_here_has_a_chord_that_survives_linux() {
        let map = Keymap::with_defaults();

        assert_eq!(
            map.command_for(&Chord::primary_shift("k")),
            Some(UiCommand::ToggleBlockingHere)
        );
        assert_eq!(
            map.command_for_collapsed(&Chord::primary_shift("k")),
            Some(UiCommand::ToggleBlockingHere)
        );
    }

    #[test]
    fn escape_stops_a_load_the_way_it_does_in_chrome() {
        let map = Keymap::with_defaults();
        assert_eq!(
            map.command_for(&Chord::new(Key::Escape, Modifiers::NONE)),
            Some(UiCommand::StopLoading)
        );
    }

    #[test]
    fn the_shortcuts_people_already_know_are_there() {
        let map = Keymap::with_defaults();

        assert_eq!(
            map.command_for(&Chord::primary("t")),
            Some(UiCommand::NewTab)
        );
        assert_eq!(
            map.command_for(&Chord::primary("w")),
            Some(UiCommand::CloseTab)
        );
        assert_eq!(
            map.command_for(&Chord::primary("l")),
            Some(UiCommand::OpenLocation)
        );
        assert_eq!(
            map.command_for(&Chord::primary("r")),
            Some(UiCommand::Reload)
        );
    }

    #[test]
    fn a_command_can_have_more_than_one_chord() {
        let map = Keymap::with_defaults();

        // Both are muscle memory for different people.
        assert_eq!(map.command_for(&Chord::primary("[")), Some(UiCommand::Back));
        assert_eq!(
            map.command_for(&Chord::new(Key::Left, Modifiers::primary())),
            Some(UiCommand::Back)
        );
    }

    #[test]
    fn both_inspector_chords_arrive_and_shift_is_the_one_linux_keeps() {
        let map = Keymap::with_defaults();

        // ⌥⌘I is Chrome-on-Mac's and Safari's; ⇧⌘I is Chrome's everywhere
        // else. Fingers arrive from both, so both land.
        assert_eq!(
            map.command_for(&Chord::new(Key::character("i"), Modifiers::primary_alt())),
            Some(UiCommand::ToggleDevTools)
        );
        assert_eq!(
            map.command_for(&Chord::primary_shift("i")),
            Some(UiCommand::ToggleDevTools)
        );

        // ⌥⌘I is listed first, so it is the one the menu prints.
        assert_eq!(
            map.chord_for(&UiCommand::ToggleDevTools),
            Some(Chord::new(Key::character("i"), Modifiers::primary_alt()))
        );

        // And off Apple, where there is no separate Command key, Ctrl+Shift+I
        // is the chord Chrome publishes. ⌥⌘I collapses to Ctrl+Alt+I, which is
        // nobody's, so ⇧⌘I is what keeps the inspector reachable there.
        assert_eq!(
            map.command_for_collapsed(&Chord::primary_shift("i")),
            Some(UiCommand::ToggleDevTools)
        );
    }

    #[test]
    fn every_digit_selects_a_tab() {
        let map = Keymap::with_defaults();

        for index in 1..=9u8 {
            assert_eq!(
                map.command_for(&Chord::primary(&index.to_string())),
                Some(UiCommand::SelectTab { index })
            );
        }
    }

    /// A space is the browser's top-level division and until now the only way
    /// into one was pointing at a chip. ⌃n completes the numeric row.
    #[test]
    fn every_digit_switches_to_a_space() {
        let map = Keymap::with_defaults();

        for index in 1..=9u8 {
            let control_digit = Chord::new(
                Key::character(&index.to_string()),
                Modifiers {
                    control: true,
                    ..Modifiers::NONE
                },
            );
            assert_eq!(
                map.command_for(&control_digit),
                Some(UiCommand::SelectSpace { index })
            );
            // And the chord that survives off Apple, where ⌃n is ⌘n.
            assert_eq!(
                map.command_for(&Chord::new(
                    Key::character(&index.to_string()),
                    Modifiers::primary_alt()
                )),
                Some(UiCommand::SelectSpace { index })
            );
        }

        // ⌃n is listed first, so it is what the Mac menu and the space chips
        // print. Reversing the two rows would advertise ⌥⌘1 on a Mac and hide
        // the chord this exists for.
        assert_eq!(
            map.chord_for(&UiCommand::SelectSpace { index: 1 }),
            Some(Chord::new(
                Key::character("1"),
                Modifiers {
                    control: true,
                    ..Modifiers::NONE
                }
            ))
        );
    }

    /// The ⌃S/⌘S collision, one row of the keyboard along. Off Apple `primary`
    /// *is* Control, so ⌃1 and ⌘1 are one physical chord and one of the two
    /// commands has to lose it.
    #[test]
    fn tabs_win_the_collapsed_digit_and_spaces_keep_their_own_way_in() {
        let map = Keymap::with_defaults();

        for index in 1..=9u8 {
            let control_digit = Chord::new(
                Key::character(&index.to_string()),
                Modifiers {
                    control: true,
                    ..Modifiers::NONE
                },
            );
            // Ctrl+n on Linux selects a tab, because that is what Chrome has
            // taught every finger there.
            assert_eq!(
                map.command_for_collapsed(&control_digit),
                Some(UiCommand::SelectTab { index }),
                "Ctrl+{index} has to stay the nth tab off Apple"
            );
            // And the space is still reachable, through the chord that does
            // not collide. Delete this binding and
            // `every_command_is_still_reachable_where_control_is_primary`
            // names SelectSpace in its orphan list.
            assert_eq!(
                map.command_for_collapsed(&Chord::new(
                    Key::character(&index.to_string()),
                    Modifiers::primary_alt()
                )),
                Some(UiCommand::SelectSpace { index })
            );
            // The extension row is untouched by the collapse either way.
            assert_eq!(
                map.command_for_collapsed(&Chord::primary_shift(&index.to_string())),
                Some(UiCommand::RunPinnedExtension { index })
            );
        }
    }

    /// ⌥⌘U is Chrome-on-Mac's and Safari's; Ctrl+U is what every browser
    /// publishes everywhere else, and ⌥⌘U collapses to Ctrl+Alt+U, which is
    /// nobody's. Without a second chord this is a Mac-only command that passes
    /// every reachability test.
    #[test]
    fn viewing_source_keeps_the_chord_the_rest_of_the_world_presses() {
        let map = Keymap::with_defaults();

        assert_eq!(
            map.command_for(&Chord::new(Key::character("u"), Modifiers::primary_alt())),
            Some(UiCommand::ViewSource)
        );
        assert_eq!(
            map.command_for(&Chord::primary("u")),
            Some(UiCommand::ViewSource)
        );

        // ⌥⌘U stays first, so the Mac menu prints the chord Safari and Chrome
        // print on a Mac.
        assert_eq!(
            map.chord_for(&UiCommand::ViewSource),
            Some(Chord::new(Key::character("u"), Modifiers::primary_alt()))
        );

        // And off Apple it lands on Ctrl+U exactly as Chrome spells it.
        assert_eq!(
            map.command_for_collapsed(&Chord::primary("u")),
            Some(UiCommand::ViewSource)
        );
    }

    #[test]
    fn an_unbound_chord_means_nothing() {
        let map = Keymap::with_defaults();
        assert_eq!(map.command_for(&Chord::primary("q")), None);
    }

    #[test]
    fn modifiers_are_part_of_the_match() {
        let map = Keymap::with_defaults();

        assert_eq!(
            map.command_for(&Chord::primary("r")),
            Some(UiCommand::Reload)
        );
        assert_eq!(
            map.command_for(&Chord::primary_shift("r")),
            Some(UiCommand::ReloadIgnoringCache)
        );
        // Without the primary modifier, "r" is just typing.
        assert_eq!(
            map.command_for(&Chord::new(Key::character("r"), Modifiers::NONE)),
            None
        );
    }

    #[test]
    fn character_keys_ignore_case() {
        let map = Keymap::with_defaults();
        assert_eq!(
            map.command_for(&Chord::new(Key::character("T"), Modifiers::primary())),
            Some(UiCommand::NewTab)
        );
    }

    #[test]
    fn primary_and_control_are_not_the_same_modifier() {
        // On a Mac these are Command and Control, and confusing them makes
        // ⌃Tab do nothing.
        let map = Keymap::with_defaults();
        let control_tab = Chord::new(
            Key::Tab,
            Modifiers {
                control: true,
                ..Modifiers::NONE
            },
        );
        let primary_tab = Chord::new(Key::Tab, Modifiers::primary());

        assert_eq!(map.command_for(&control_tab), Some(UiCommand::NextTab));
        assert_eq!(map.command_for(&primary_tab), None);
    }

    #[test]
    fn rebinding_takes_the_chord_from_its_previous_owner() {
        let mut map = Keymap::with_defaults();

        map.bind(Chord::primary("t"), UiCommand::NewSpace);

        assert_eq!(
            map.command_for(&Chord::primary("t")),
            Some(UiCommand::NewSpace)
        );
        assert_eq!(
            map.bindings()
                .iter()
                .filter(|b| b.chord == Chord::primary("t"))
                .count(),
            1
        );
    }

    #[test]
    fn rebinding_replaces_every_chord_a_command_had() {
        let mut map = Keymap::with_defaults();
        // Back ships with two chords.
        assert!(
            map.bindings()
                .iter()
                .filter(|b| b.command == UiCommand::Back)
                .count()
                > 1
        );

        map.rebind(UiCommand::Back, Chord::primary("b"));

        assert_eq!(
            map.bindings()
                .iter()
                .filter(|b| b.command == UiCommand::Back)
                .count(),
            1
        );
        assert_eq!(map.command_for(&Chord::primary("b")), Some(UiCommand::Back));
        assert_eq!(map.command_for(&Chord::primary("[")), None);
    }

    #[test]
    fn rebinding_also_takes_the_chord_from_whoever_held_it() {
        let mut map = Keymap::with_defaults();

        map.rebind(UiCommand::NewSpace, Chord::primary("t"));

        assert_eq!(
            map.command_for(&Chord::primary("t")),
            Some(UiCommand::NewSpace)
        );
        assert_eq!(map.chord_for(&UiCommand::NewTab), None);
    }

    #[test]
    fn adding_a_chord_leaves_the_existing_ones_alone() {
        let mut map = Keymap::with_defaults();

        map.bind(Chord::primary("j"), UiCommand::NewTab);

        // Both work now, which is the point of bind over rebind.
        assert_eq!(
            map.command_for(&Chord::primary("j")),
            Some(UiCommand::NewTab)
        );
        assert_eq!(
            map.command_for(&Chord::primary("t")),
            Some(UiCommand::NewTab)
        );
    }

    #[test]
    fn unbinding_reports_whether_anything_happened() {
        let mut map = Keymap::with_defaults();

        assert!(map.unbind(&Chord::primary("t")));
        assert_eq!(map.command_for(&Chord::primary("t")), None);
        assert!(!map.unbind(&Chord::primary("t")));
    }

    #[test]
    fn only_the_changes_are_worth_saving() {
        let mut map = Keymap::with_defaults();
        assert!(map.customisations().is_empty());

        map.bind(Chord::primary("j"), UiCommand::NextTab);

        let saved = map.customisations();
        assert_eq!(saved.len(), 1);
        assert_eq!(saved[0].command, UiCommand::NextTab);
    }

    #[test]
    fn saved_changes_survive_a_reload() {
        let mut map = Keymap::with_defaults();
        map.bind(Chord::primary("j"), UiCommand::NextTab);
        map.bind(Chord::primary("t"), UiCommand::NewSpace);

        let restored = Keymap::load(map.customisations());

        assert_eq!(
            restored.command_for(&Chord::primary("j")),
            Some(UiCommand::NextTab)
        );
        assert_eq!(
            restored.command_for(&Chord::primary("t")),
            Some(UiCommand::NewSpace)
        );
        // Defaults nobody touched are still there.
        assert_eq!(
            restored.command_for(&Chord::primary("w")),
            Some(UiCommand::CloseTab)
        );
    }

    #[test]
    fn resetting_puts_everything_back() {
        let mut map = Keymap::with_defaults();
        map.bind(Chord::primary("t"), UiCommand::NewSpace);
        map.unbind(&Chord::primary("w"));

        map.reset();

        assert_eq!(map, Keymap::with_defaults());
    }

    #[test]
    fn menus_can_ask_what_to_print_next_to_a_command() {
        let map = Keymap::with_defaults();

        assert_eq!(map.chord_for(&UiCommand::NewTab), Some(Chord::primary("t")));
        assert_eq!(
            map.chord_for(&UiCommand::ReopenClosedTab),
            Some(Chord::primary_shift("t"))
        );
    }
}
