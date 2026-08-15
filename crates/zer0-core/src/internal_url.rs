//! `zer0://` — the browser's own addresses.
//!
//! # An address space, not a page type
//!
//! Four addresses, and they do not all do the same kind of thing:
//!
//! | Address | What it does |
//! |---|---|
//! | `zer0://chat` | a page, drawn in the tab |
//! | `zer0://history` | a page, drawn in the tab |
//! | `zer0://downloads` | a page, drawn in the tab |
//! | `zer0://settings` | raises the Settings window |
//!
//! **What an address does is that address's decision, not the scheme's.**
//! Configuration is a window you keep beside your work while you change
//! something and then close; a conversation, a history and a download list are
//! things you keep, revisit, pin, search and put next to the page they are
//! about, which is a tab. Forcing one shape onto all four would mean either a
//! settings *tab* that competes with the window ⌘, already opens, or three long
//! searchable lists trapped in a window that cannot be pinned, split or
//! restored.
//!
//! So [`Effect`] is the second half of the type, and a new address has to
//! choose. There is no default.
//!
//! # WebKit is never told this scheme exists
//!
//! This is the security decision, it applies to all four addresses at once, and
//! it is why this module is in the core rather than being a
//! `WKURLSchemeHandler` in the shell.
//!
//! A registered custom scheme is reachable from web content: a page can put one
//! in an `<iframe>`, redirect to one, or fetch one as a subresource. The handler
//! that answers cannot tell any of that apart — `WKURLSchemeTask` carries a
//! request and nothing else: no frame, no initiator, no navigation type. The one
//! place that distinction exists is the navigation policy delegate, and a
//! subresource load never reaches it.
//!
//! So the scheme is not registered, and `WKWebView` cannot resolve `zer0:` at
//! all. Which means:
//!
//! - a page that navigates to one is refused, because the policy delegate
//!   refuses a scheme the browser owns before the engine ever sees it — and
//!   there would be nothing to load it with even if it did not;
//! - a page cannot frame one, for the same reason;
//! - a redirect cannot reach one;
//! - there is no origin to reason about, because an internal page is not web
//!   content. It is drawn natively, so there is no document, no script and no
//!   bridge for anything to be reached *through*.
//!
//! The cost is stated rather than dodged: an internal page cannot be built out
//! of HTML, and every one of them is written again when a second shell arrives.
//! That is the price of a page a hostile site cannot address, and for surfaces
//! holding somebody's conversations, their history and their downloads it is
//! worth paying. ADR-0054.

use crate::chat::{Conversation, ConversationId};
use crate::icons;
use crate::shortcuts::UiCommand;

/// The scheme, in one place. Compared case-insensitively, because a URL's
/// scheme is case-insensitive and somebody will type `Zer0://`.
pub const SCHEME: &str = "zer0";

/// One of the browser's own addresses.
///
/// A closed enum for the usual reason: an address nobody routed would have to
/// fall through to something, and the something is always wrong.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum InternalAddress {
    /// `zer0://chat`, or `zer0://chat?conversation=7` for a particular thread.
    ///
    /// `None` means "whichever thread this tab should show", which the reducer
    /// resolves — so the address stays meaningful typed by hand, and what the
    /// tab ends up holding is the resolved one.
    Chat {
        conversation: Option<ConversationId>,
    },
    Settings,
    History,
    Downloads,
}

/// What going to an address does.
///
/// The distinction the shell acts on, and the reason the scheme is not a page
/// type. A `Page` is drawn in the tab that navigated to it. A `Window` leaves
/// the tab exactly where it was and raises something in front of it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum Effect {
    /// Drawn in the tab, by the shell, natively.
    Page,
    /// Runs a command that opens a window. The tab that asked does not change,
    /// and a navigation never commits — going to `zer0://settings` from a page
    /// leaves you on that page with Settings in front of it, which is what
    /// pressing ⌘, does and the only behaviour that is not surprising.
    ///
    /// A [`UiCommand`] rather than a window name, because the browser already
    /// has these four commands, they already carry ADR-0053's rule about which
    /// window a command may land in, and a second vocabulary for "open
    /// Settings at History" would be a second thing to keep in step.
    Window { command: UiCommand },
}

impl InternalAddress {
    /// The address that comes back here.
    ///
    /// Round-trips through [`parse`], which is what makes a restored session
    /// return to the same thread rather than to a fresh one.
    pub fn url(&self) -> String {
        match self {
            InternalAddress::Chat { conversation: None } => format!("{SCHEME}://chat"),
            InternalAddress::Chat {
                conversation: Some(id),
            } => format!("{SCHEME}://chat?conversation={}", id.0),
            InternalAddress::Settings => format!("{SCHEME}://settings"),
            InternalAddress::History => format!("{SCHEME}://history"),
            InternalAddress::Downloads => format!("{SCHEME}://downloads"),
        }
    }

    /// What this address does.
    ///
    /// **History and downloads are pages, and the Settings panes they came
    /// from are gone.** They are long lists that want searching, scrolling and
    /// the keyboard, which is a page; they were panes only because that is
    /// where they were built first. Keeping both would have been two screens
    /// for one thing, and the one on screen is always the stale one (ADR-0063,
    /// which is what ADR-0054's "when to revisit" predicted).
    pub fn effect(&self) -> Effect {
        match self {
            InternalAddress::Chat { .. }
            | InternalAddress::History
            | InternalAddress::Downloads => Effect::Page,
            InternalAddress::Settings => Effect::Window {
                command: UiCommand::ShowSettings,
            },
        }
    }

    /// What the sidebar and the window strip call this tab, for the addresses
    /// whose name is a constant.
    ///
    /// In the core because it is the *name of a page*, exactly as a web page's
    /// title is: two shells must not disagree about what the row in the list
    /// says. How it is drawn is still the shell's.
    ///
    /// **`None` for `Chat`, and that is a guarantee rather than a gap.** This
    /// used to answer `"Chat"` for every thread, so a sidebar holding three
    /// conversations showed three different badges (ADR-0083) and three
    /// identical labels — and VoiceOver heard the word "Chat" three times,
    /// because the badge beside it is `accessibilityHidden` and correctly so.
    /// A conversation is named after what it is about, and what it is about is
    /// a fact about the *thread*, which a number in a query string cannot
    /// reach. [`conversation_title`] is the one place that answers, and a
    /// caller with no thread in hand cannot get a name out of this type by
    /// accident — the compiler makes them go and find one.
    pub fn title(&self) -> Option<String> {
        match self {
            InternalAddress::Chat { .. } => None,
            InternalAddress::Settings => Some("Settings".to_string()),
            InternalAddress::History => Some("History".to_string()),
            InternalAddress::Downloads => Some("Downloads".to_string()),
        }
    }
}

/// How much of an opening question a tab is called.
///
/// A title is read sideways in a sidebar column about two hundred points wide
/// and is truncated there anyway, so this is not about fitting: it is about
/// what gets written to the session file and ranked by the command bar. A
/// pasted three-paragraph question would otherwise become a three-paragraph
/// tab title, and the row beside it would be scored against every word of it.
const TITLE_LIMIT: usize = 56;

/// What a conversation is called.
///
/// **The one door**, asked by everything that has to name a chat tab, so the
/// sidebar, the command bar, the window strip and a restored session cannot
/// disagree about what a thread is.
///
/// Three answers, in the order the thread acquires them:
///
/// - **The first thing the person typed**, once they have typed something. It
///   is the only line in a transcript written on purpose to say what was
///   wanted, and it is already what `ThreadList` labels a thread by — so a
///   conversation is called the same thing in the sidebar as on the screen
///   that lists it. Folded to one line and clamped, because a question is
///   allowed to be a paragraph and a title is not.
/// - **The site it is about**, before anything has been asked. The thread has
///   a subject from the moment it is minted (ADR-0060) and that subject is the
///   whole reason to open this page rather than another tab on somebody's
///   website, so it is what the row says. Not the page's *title*: that is the
///   page's own claim about itself, it lives on a tab that may be closed, and
///   this is the core, where there is no such thing as "whatever is open".
/// - **"New chat"**, for a thread about no page with nothing asked — one per
///   space, started from the command bar. There is no page to name and nothing
///   has been said, so it says exactly that (ADR-0018).
///
/// `None` is the fourth case and not a failure: a tab sitting on the bare
/// `zer0://chat`, or one restored addressing a thread that no longer exists.
/// Both are a chat page with nothing in it, which is what the last answer says.
pub fn conversation_title(thread: Option<&Conversation>) -> String {
    let Some(thread) = thread else {
        return "New chat".to_string();
    };

    let asked = clamp(&one_line(thread.opening_question()));
    if !asked.is_empty() {
        return asked;
    }

    match thread
        .scope
        .page()
        .and_then(|page| site_name(page.as_str()))
    {
        Some(site) => format!("Chat about {site}"),
        None => "New chat".to_string(),
    }
}

/// The site as a person says it: the host, without the `www.` nobody reads.
///
/// `None` for an anchor with no site to name — a `file://` page is anchorable
/// (`PageAnchor`) and has no host, and there is nothing true to put in a title
/// for one.
fn site_name(page: &str) -> Option<String> {
    let host = icons::host_of(page)?;
    Some(
        host.strip_prefix("www.")
            .filter(|rest| !rest.is_empty())
            .unwrap_or(&host)
            .to_string(),
    )
}

/// A question as one line. Every run of whitespace becomes one space.
///
/// ⇧↩ puts a newline in the composer, so a question really does arrive with
/// line breaks in it, and a title carrying one is a row whose second line is
/// somebody's second paragraph.
fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Cut to [`TITLE_LIMIT`] characters, at a word boundary, with an ellipsis.
///
/// Characters rather than bytes: a question in Portuguese or Japanese is not
/// entitled to a shorter title than one in English, and slicing a `String` by
/// byte count panics in the middle of a character.
fn clamp(text: &str) -> String {
    if text.chars().count() <= TITLE_LIMIT {
        return text.to_string();
    }
    let head: String = text.chars().take(TITLE_LIMIT).collect();
    // Back up to the last space so the title ends on a word rather than in the
    // middle of one — unless there is no space to back up to, in which case one
    // long word is cut where it is.
    let cut = head.rfind(' ').map_or(head.as_str(), |at| &head[..at]);
    format!("{}…", cut.trim_end())
}

/// Read an address, or say it is not one of ours.
///
/// Deliberately strict. Everything this does not recognise exactly is `None`,
/// and `None` is never repaired into the nearest address. A repaired address is
/// an address nobody typed, and this is the one scheme whose destinations are
/// inside the browser.
pub fn parse(url: &str) -> Option<InternalAddress> {
    let rest = strip_scheme(url)?;
    // A fragment addresses a place inside a document, and these have no
    // document.
    let rest = rest.split('#').next().unwrap_or(rest);
    let (path, query) = match rest.split_once('?') {
        Some((path, query)) => (path, Some(query)),
        None => (rest, None),
    };

    // `zer0://chat` and `zer0://chat/` are one address. A trailing slash is
    // punctuation, not a different page.
    match path.trim_end_matches('/').to_ascii_lowercase().as_str() {
        "chat" => Some(InternalAddress::Chat {
            conversation: query.and_then(conversation_in),
        }),
        "settings" => Some(InternalAddress::Settings),
        "history" => Some(InternalAddress::History),
        "downloads" => Some(InternalAddress::Downloads),
        _ => None,
    }
}

/// Whether this address *claims* our scheme, whether or not it names something
/// we have.
///
/// Separate from [`is_internal`], and the difference is load-bearing:
/// `zer0://nonsense` is not an address, but it must not reach a web engine
/// either. A URL that is refused has to be refused as ours, or an engine is
/// asked to load a scheme it does not know and the failure comes back as a
/// navigation error about a site that does not exist.
pub fn claims_scheme(url: &str) -> bool {
    strip_scheme(url).is_some()
}

/// Everything after `zer0://`, or `None` when this is not that.
fn strip_scheme(url: &str) -> Option<&str> {
    let (scheme, rest) = url.split_once("://")?;
    scheme.eq_ignore_ascii_case(SCHEME).then_some(rest)
}

/// The conversation named in a query string, if one is and it is a number.
///
/// Hostile input like any other: this arrives from a session file, from a
/// hand-typed address, and eventually from somebody's bookmark. Anything that
/// is not a plain unsigned number is dropped rather than repaired, landing on
/// `None`, which means "whichever thread this tab should show". An id nobody
/// minted addresses nothing, and the reducer answers that the same way it
/// answers a missing one.
fn conversation_in(query: &str) -> Option<ConversationId> {
    query
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .find(|(key, _)| key.eq_ignore_ascii_case("conversation"))
        .and_then(|(_, value)| value.parse::<u64>().ok())
        .map(ConversationId)
}

// MARK: - Across the FFI
//
// Free functions, because a uniffi record carries no methods across. The same
// argument `chat_provider_preset` makes: a shell that recomputed any of these
// for itself would be a second opinion about what one of our addresses means,
// and the half that is wrong is always the half on screen.

/// The scheme, so no shell writes `"zer0"` out for itself.
#[cfg(feature = "ffi")]
#[uniffi::export]
pub fn internal_scheme() -> String {
    SCHEME.to_string()
}

/// Read an address. `None` is "not one of ours, or not one we have".
#[cfg(feature = "ffi")]
#[uniffi::export]
pub fn internal_address(url: String) -> Option<InternalAddress> {
    parse(&url)
}

/// Whether a URL claims our scheme at all, page or not.
#[cfg(feature = "ffi")]
#[uniffi::export]
pub fn internal_claims_scheme(url: String) -> bool {
    claims_scheme(&url)
}

/// What going to this address does.
#[cfg(feature = "ffi")]
#[uniffi::export]
pub fn internal_effect(address: InternalAddress) -> Effect {
    address.effect()
}

/// What this tab is called, for the addresses that name themselves.
///
/// `None` for a conversation, which is named after what it is about rather than
/// after its address. A shell does not have to ask: the core keeps every chat
/// tab's `title` in step with its thread (`reducer::name_our_pages`), so the
/// name is already on the row being drawn.
#[cfg(feature = "ffi")]
#[uniffi::export]
pub fn internal_title(address: InternalAddress) -> Option<String> {
    address.title()
}

/// The address that comes back here.
#[cfg(feature = "ffi")]
#[uniffi::export]
pub fn internal_address_url(address: InternalAddress) -> String {
    address.url()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::{
        ConversationScope, Message, MessageId, MessageRole, MessageState, PageAnchor,
    };
    use crate::model::SpaceId;

    #[test]
    fn every_address_round_trips_through_its_own_url() {
        for address in [
            InternalAddress::Chat { conversation: None },
            InternalAddress::Chat {
                conversation: Some(ConversationId(7)),
            },
            InternalAddress::Settings,
            InternalAddress::History,
            InternalAddress::Downloads,
        ] {
            assert_eq!(parse(&address.url()), Some(address.clone()), "{address:?}");
        }
        assert_eq!(
            InternalAddress::Chat {
                conversation: Some(ConversationId(7))
            }
            .url(),
            "zer0://chat?conversation=7"
        );
    }

    /// The whole argument of this module: the scheme does not decide the shape.
    /// A conversation, a history and a download list are tabs because you keep
    /// them; settings is a window because you close it.
    #[test]
    fn an_address_decides_its_own_shape_and_the_scheme_does_not() {
        for page in [
            InternalAddress::Chat { conversation: None },
            InternalAddress::History,
            InternalAddress::Downloads,
        ] {
            assert_eq!(page.effect(), Effect::Page, "{page:?}");
        }
        assert_eq!(
            InternalAddress::Settings.effect(),
            Effect::Window {
                command: UiCommand::ShowSettings
            }
        );
    }

    /// No address in the scheme is dead: every one either draws a page that has
    /// a name, or raises a window somebody can see arrive.
    ///
    /// A conversation's name comes from the thread rather than from the
    /// address, so the name asked for here is the one a chat tab with no thread
    /// gets — which still has to be something a person can read in a list.
    #[test]
    fn no_address_in_the_scheme_does_nothing() {
        for address in [
            InternalAddress::Chat { conversation: None },
            InternalAddress::Settings,
            InternalAddress::History,
            InternalAddress::Downloads,
        ] {
            let name = address.title().unwrap_or_else(|| conversation_title(None));
            match address.effect() {
                Effect::Page => assert!(!name.is_empty(), "{address:?} has no name"),
                Effect::Window { command } => assert!(
                    matches!(command, UiCommand::ShowSettings),
                    "{address:?} raises {command:?}"
                ),
            }
        }
    }

    #[test]
    fn the_scheme_and_the_address_are_case_insensitive_and_a_trailing_slash_is_punctuation() {
        for spelling in ["ZER0://CHAT", "Zer0://Chat/", "zer0://chat/"] {
            assert_eq!(
                parse(spelling),
                Some(InternalAddress::Chat { conversation: None }),
                "{spelling}"
            );
        }
    }

    /// The whole reason [`claims_scheme`] exists. An address of ours naming
    /// nothing we have must not be handed to a web engine: it is refused here,
    /// as ours.
    #[test]
    fn an_address_we_do_not_recognise_is_still_never_the_webs() {
        assert_eq!(parse("zer0://nonsense"), None);
        assert!(claims_scheme("zer0://nonsense"));

        assert!(!claims_scheme("https://example.com"));
        // The one that matters: a site cannot dress itself up as us.
        assert!(!claims_scheme("https://zer0.example/chat"));
        assert!(!claims_scheme("https://example.com/?u=zer0://chat"));
        assert!(!claims_scheme("zer0.example/chat"));
    }

    #[test]
    fn a_conversation_that_is_not_a_number_is_dropped_rather_than_repaired() {
        for address in [
            "zer0://chat?conversation=",
            "zer0://chat?conversation=abc",
            "zer0://chat?conversation=-1",
            "zer0://chat?conversation=1x",
            "zer0://chat?other=3",
        ] {
            assert_eq!(
                parse(address),
                Some(InternalAddress::Chat { conversation: None }),
                "{address}"
            );
        }
    }

    #[test]
    fn a_fragment_addresses_nothing_here_and_is_ignored() {
        assert_eq!(
            parse("zer0://chat?conversation=3#anything"),
            Some(InternalAddress::Chat {
                conversation: Some(ConversationId(3))
            })
        );
    }

    /// The addresses whose name is a constant say it here, and a conversation
    /// deliberately does not: an address is a number in a query string, and two
    /// threads addressed `?conversation=1` and `?conversation=2` are not two
    /// different things to this type.
    #[test]
    fn a_page_names_itself_so_two_shells_cannot_disagree() {
        assert_eq!(InternalAddress::History.title().as_deref(), Some("History"));
        assert_eq!(
            InternalAddress::Downloads.title().as_deref(),
            Some("Downloads")
        );
        assert_eq!(
            InternalAddress::Chat { conversation: None }.title(),
            None,
            "an address cannot name a conversation and must not pretend to"
        );
    }

    // MARK: - What a conversation is called

    fn thread(scope: ConversationScope, asked: &[&str]) -> Conversation {
        Conversation {
            id: ConversationId(1),
            scope,
            messages: asked
                .iter()
                .enumerate()
                .map(|(at, text)| Message {
                    id: MessageId(at as u64),
                    role: MessageRole::User,
                    text: (*text).to_string(),
                    page: None,
                    state: MessageState::Complete,
                    tool_calls: Vec::new(),
                    answers: None,
                    model: None,
                    created_at_ms: 0,
                })
                .collect(),
            error: None,
            awaiting_page: false,
            created_at_ms: 0,
        }
    }

    fn about(page: &str) -> ConversationScope {
        ConversationScope::Page {
            space: SpaceId(1),
            page: PageAnchor::of(page).expect("anchorable"),
        }
    }

    /// The defect this replaced: every thread was called "Chat", so a sidebar
    /// holding three of them said the same word three times — and said it to
    /// VoiceOver three times too, because the badge that now differs is
    /// `accessibilityHidden`.
    #[test]
    fn a_conversation_is_called_what_was_asked_and_never_the_word_chat() {
        let named = conversation_title(Some(&thread(
            about("https://github.com/avelino/zer0/pull/412"),
            &["does the migration in here roll back cleanly"],
        )));
        assert_eq!(named, "does the migration in here roll back cleanly");

        // The *first* question, not the last: a thread is about what it was
        // opened for, and a name that changed with every turn would be a row
        // that moves under the hand reaching for it.
        let named = conversation_title(Some(&thread(
            about("https://github.com/avelino/zer0/pull/412"),
            &["what changed here", "and the cost?"],
        )));
        assert_eq!(named, "what changed here");
    }

    /// Three threads about three pages are three different names, before a word
    /// has been typed in any of them. The badge half of this is ADR-0083's
    /// `threeConversationsAreThreeDifferentBadges`; this is the other half, and
    /// it is the half VoiceOver hears.
    #[test]
    fn three_conversations_about_three_pages_are_three_different_names() {
        let names: Vec<String> = [
            "https://github.com/avelino/zer0",
            "https://news.ycombinator.com/item?id=1",
            "https://www.rust-lang.org/learn",
        ]
        .into_iter()
        .map(|page| conversation_title(Some(&thread(about(page), &[]))))
        .collect();

        assert_eq!(
            names,
            [
                "Chat about github.com",
                "Chat about news.ycombinator.com",
                // `www.` is punctuation in a name nobody reads it in.
                "Chat about rust-lang.org",
            ]
        );
    }

    /// A thread about no page has no site to name, and nothing has been asked,
    /// so it says that and invents neither (ADR-0018). Same for a chat tab
    /// addressing no thread at all — a bare `zer0://chat`, or one restored
    /// pointing at a conversation that did not survive the load.
    #[test]
    fn a_conversation_about_no_page_with_nothing_asked_says_so() {
        assert_eq!(
            conversation_title(Some(&thread(
                ConversationScope::Space { space: SpaceId(1) },
                &[]
            ))),
            "New chat"
        );
        assert_eq!(conversation_title(None), "New chat");

        // And it stops being new the moment somebody says something.
        assert_eq!(
            conversation_title(Some(&thread(
                ConversationScope::Space { space: SpaceId(1) },
                &["what is a WAL checkpoint"]
            ))),
            "what is a WAL checkpoint"
        );
    }

    /// A question is allowed to be a paragraph. A title is not: it goes into
    /// the session file and is ranked by the command bar against every word of
    /// it.
    #[test]
    fn a_long_question_is_cut_to_a_title_at_a_word_boundary() {
        let asked = "why does the reducer stay pure when the engine is right \
                     there and could just be called directly from it";
        let named = conversation_title(Some(&thread(
            ConversationScope::Space { space: SpaceId(1) },
            &[asked],
        )));

        assert!(named.ends_with('…'), "{named}");
        assert!(named.chars().count() <= TITLE_LIMIT + 1, "{named}");
        assert!(asked.starts_with(named.trim_end_matches('…')), "{named}");
        assert!(
            !named.trim_end_matches('…').ends_with(' '),
            "cut in the middle of a word: {named}"
        );

        // Counted in characters, so a question in Portuguese is not entitled to
        // a shorter title than the same question in English. Byte slicing here
        // would panic rather than truncate.
        let acented = "á".repeat(TITLE_LIMIT * 2);
        let named = conversation_title(Some(&thread(
            ConversationScope::Space { space: SpaceId(1) },
            &[&acented],
        )));
        assert!(named.chars().count() <= TITLE_LIMIT + 1, "{named}");
    }

    /// ⇧↩ is a new line in the composer, so a question really does arrive with
    /// line breaks in it.
    #[test]
    fn a_question_typed_over_several_lines_is_still_one_line_of_title() {
        let named = conversation_title(Some(&thread(
            ConversationScope::Space { space: SpaceId(1) },
            &["  what does\n\nWAL mode\tbuy us  "],
        )));
        assert_eq!(named, "what does WAL mode buy us");
    }

    /// A `file://` page is anchorable and has no site to name. Nothing true is
    /// left, so nothing is invented.
    #[test]
    fn a_page_with_no_site_to_name_falls_back_rather_than_inventing_one() {
        assert_eq!(
            conversation_title(Some(&thread(about("file:///Users/a/notes.md"), &[]))),
            "New chat"
        );
    }
}
