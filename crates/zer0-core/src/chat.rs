//! Conversations: what was said, what the model asked to do, and what was
//! allowed.
//!
//! A conversation outlives the panel that draws it — you can close the panel,
//! switch space and come back while a reply is still arriving — so it is
//! state, and state lives here.
//!
//! Three things in this file are not bookkeeping.
//!
//! **Scope is isolation.** A conversation belongs to exactly one space, and it
//! is reached either through the page it is about or through the space itself.
//! Everything a conversation holds — what you typed, what page you were
//! reading — is the same material [ADR-0007] gives every space its own cookie
//! jar for. A conversation that crossed that line would carry a work page into
//! a personal thread, and nothing in the interface would say so.
//!
//! **A thread is anchored to the page, not to the view of it** (ADR-0060).
//! [`PageAnchor`] is the one spelling that decides whether two are the same page,
//! and it is the only way a URL enters a conversation's identity. Closing the
//! tab does not end the thread; opening the page again brings it back.
//!
//! **A tool call is an action taken on your behalf.** The model chooses the
//! tool and it chooses the arguments; nobody approved either at the moment it
//! decided. So [`ToolConsent`] is a ledger in the same shape as the extension
//! one (ADR-0028): a refusal is written down rather than inferred from
//! absence, a grant is per tool rather than per server, and a tool the browser
//! cannot name is never offered for approval at all.
//!
//! **Everything a model says is hostile input.** Text, tool names, arguments
//! and results all arrive from somewhere across a network, and every one of
//! them is bounded here rather than wherever it is first drawn.

use crate::model::SpaceId;

/// How many conversations are worth keeping. Deep enough to leave a thread on
/// a pinned tab and come back to it tomorrow, shallow enough not to be a
/// second history.
pub const MAX_CONVERSATIONS: usize = 200;

/// How many messages one conversation keeps. Past this the oldest go, because
/// a thread that grows without bound is one that eventually costs more to send
/// than it is worth and then stops working entirely.
pub const MAX_MESSAGES: usize = 500;

/// The longest single message the core will hold, in bytes.
///
/// A provider streaming without end, or a page that is mostly minified
/// JavaScript, must not be able to grow the session until the machine gives
/// up. Truncation is visible: the message is marked and the interface says so
/// rather than pretending the text is whole.
pub const MAX_MESSAGE_BYTES: usize = 256 * 1024;

/// The longest page capture the core asks a host for.
///
/// Smaller than [`MAX_MESSAGE_BYTES`] on purpose: this one is not a limit
/// against abuse, it is the amount of a page worth sending. Everything past it
/// is navigation furniture.
pub const MAX_PAGE_CONTEXT_CHARS: u32 = 60_000;

/// How many tool calls one reply may ask for.
pub const MAX_TOOL_CALLS_PER_REPLY: usize = 16;

/// The longest tool arguments or tool result the core will hold, in bytes.
pub const MAX_TOOL_PAYLOAD_BYTES: usize = 64 * 1024;

/// How many times one question may bounce through tools before the browser
/// stops answering it.
///
/// Without a bound, a model that calls a tool, reads the result and calls it
/// again is an unattended loop spending someone's money and someone's rate
/// limit. The person asked one question; twelve rounds is far more than any
/// honest answer needs and far less than a runaway costs.
pub const MAX_TOOL_ROUNDS: usize = 12;

/// The core's handle on one conversation. Minted here, so it is deterministic
/// under test.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ConversationId(pub u64);

/// The core's handle on one message, unique across the whole session.
///
/// Session-wide rather than per conversation so a host can key an in-flight
/// request on this alone: a pair that must be carried together is a pair that
/// can be carried apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct MessageId(pub u64);

/// The model's handle on one tool call.
///
/// A string chosen by whatever answered, not by us — the provider gives every
/// call an id and the result has to be matched back to it. Hostile input:
/// bounded on the way in, never interpreted, never used as a path or a key
/// anywhere it could name something on disk.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ToolCallId(pub String);

/// The page a conversation is about, in the one spelling that decides whether
/// two addresses are the same page.
///
/// # What counts as the same page
///
/// The rule is deliberately short, because every clause in it is a way for two
/// threads to be merged that should not have been, or for the thread somebody
/// wants never to come back. It is built out of two conventions this codebase
/// already has rather than a third:
///
/// - **the host is normalised the way [`crate::routing`] normalises one** —
///   parsed with `url`, so its case and its IDN spelling are settled, its
///   credentials are gone and a default port with them;
/// - **a fragment and a trailing slash are punctuation**, which is the sentence
///   [`crate::internal_url`] already writes about its own addresses.
///
/// And one clause that is this module's own: **the query string is part of the
/// address.** `?tab=readme` is therefore a different page from the bare URL,
/// which costs a second thread on a site that uses the query for a tab strip.
/// Folding it in would cost the other direction, and the other direction is
/// worse: page two of a search would answer out of page one's thread, and a
/// dashboard filtered to one person would open the thread about another. A
/// thread that did not come back is visible and one gesture from being fixed;
/// a thread that came back about the wrong thing reads as the model being
/// confused, and nobody files that.
///
/// Nothing is folded that the site itself has not already folded. The address
/// anchored here is the one a navigation *committed*, which is what a site's
/// own redirect from `http` to `https`, or from the apex to `www`, has already
/// canonicalised. Guessing at either here would key threads on an address
/// nobody ever visited.
///
/// # What a URL cannot smuggle in here
///
/// An anchor is built out of four parts — scheme, host, port, path and query —
/// and userinfo is not one of them, so `https://user:secret@host/` cannot put a
/// password in a conversation's identity. The fragment is dropped for the
/// reason above and takes the OAuth implicit flow's `#access_token=…` with it.
/// A scheme that is not `http`, `https` or `file` is not anchorable at all,
/// which is what keeps `data:`, `blob:`, `about:` and this browser's own
/// `zer0://` pages out — the last of those being the rule ADR-0054 wrote by
/// hand, now held by the type.
///
/// What is left is stated rather than dodged: a signed URL with a token in its
/// query *is* written down, in the same plain text history already holds it in.
/// Hashing it would buy nothing — the same thread's transcript stores the page
/// address beside it (ADR-0049) — and it would cost the one screen that lists
/// threads the ability to say which page each is about.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PageAnchor(String);

/// Schemes a conversation may be anchored to.
///
/// An allowlist rather than a blocklist, because the failure of a blocklist is
/// silent: a scheme nobody thought of gets anchored, and whatever it carries is
/// written to disk under an address.
const ANCHORABLE_SCHEMES: [&str; 3] = ["http", "https", "file"];

impl PageAnchor {
    /// The anchor for a URL, or `None` when it does not name a page a thread
    /// can be about.
    ///
    /// The single door: nothing else in this codebase decides whether two
    /// addresses are the same page, and a caller holding one of these is
    /// holding a decision that has already been made.
    pub fn of(url: &str) -> Option<Self> {
        let parsed = url::Url::parse(url).ok()?;
        if !ANCHORABLE_SCHEMES.contains(&parsed.scheme()) {
            return None;
        }
        // Read out part by part rather than edited in place. Userinfo is not
        // read, so it cannot survive; the fragment is not read, so it cannot
        // either. That is a stronger statement than clearing them would be,
        // because there is no line to delete later.
        let scheme = parsed.scheme();
        let host = parsed.host_str().unwrap_or("");
        // `None` for the scheme's default port, so `:443` never splits a
        // thread off from the same page addressed without it.
        let port = parsed.port().map_or(String::new(), |p| format!(":{p}"));
        let path = trim_trailing_slash(parsed.path());
        let query = parsed
            .query()
            .filter(|q| !q.is_empty())
            .map_or(String::new(), |q| format!("?{q}"));
        Some(Self(format!("{scheme}://{host}{port}{path}{query}")))
    }

    /// The address this anchor is, which is a URL somebody can read and open.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Whether a URL is this page.
    ///
    /// Takes the raw URL rather than an anchor so callers cannot compare two
    /// spellings by accident: the normalisation happens here, once.
    pub fn matches(&self, url: &str) -> bool {
        PageAnchor::of(url).is_some_and(|other| other == *self)
    }
}

/// A trailing slash is punctuation, not a different page — the same sentence
/// [`crate::internal_url`] writes about `zer0://chat/`. The root keeps its
/// slash, because `https://example.com` and `https://example.com/` are one
/// address and `/` is the spelling `url` produces for it.
fn trim_trailing_slash(path: &str) -> &str {
    match path.trim_end_matches('/') {
        "" => "/",
        trimmed => trimmed,
    }
}

#[cfg(feature = "ffi")]
uniffi::custom_newtype!(ConversationId, u64);
#[cfg(feature = "ffi")]
uniffi::custom_newtype!(MessageId, u64);
#[cfg(feature = "ffi")]
uniffi::custom_newtype!(ToolCallId, String);
#[cfg(feature = "ffi")]
uniffi::custom_newtype!(PageAnchor, String);

/// What a conversation is about, which is also what it is isolated by.
///
/// Two variants and no third. There is no global conversation: a thread with
/// no space is a thread whose contents belong to every cookie jar at once,
/// which is the one arrangement this browser has spent seven ADRs refusing.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ConversationScope {
    /// ⌘E. About a page, and it outlives every tab that ever showed it.
    ///
    /// Opening a page discussed before brings that thread back. One page may
    /// hold several threads, but only because somebody asked for a second one:
    /// [`Chat::ensure`] hands back the most recent, and nothing but
    /// [`Chat::start`] ever mints another.
    ///
    /// The space is carried rather than looked up through a tab, so a thread
    /// still names exactly one cookie jar when no tab is showing its page.
    Page { space: SpaceId, page: PageAnchor },
    /// Asked from the command bar, about nothing in particular. One per space.
    Space { space: SpaceId },
}

impl ConversationScope {
    /// The one space this thread belongs to.
    ///
    /// Total, and that is the point: every scope resolves to a space with no
    /// lookup that can fail, which is what lets the projection decide whether a
    /// thread may be written down without going through a tab that may already
    /// be closed (ADR-0023).
    pub fn space(&self) -> SpaceId {
        match self {
            ConversationScope::Page { space, .. } | ConversationScope::Space { space } => *space,
        }
    }

    /// The page this thread is about, when it is about one.
    pub fn page(&self) -> Option<&PageAnchor> {
        match self {
            ConversationScope::Page { page, .. } => Some(page),
            ConversationScope::Space { .. } => None,
        }
    }
}

/// Who said it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum MessageRole {
    /// Typed by the person.
    User,
    /// From the model.
    Assistant,
    /// Nobody said this: it is what the browser attached about a page.
    ///
    /// Its own role rather than a `User` message with the page pasted in,
    /// because the difference between "you sent this" and "the browser sent
    /// this on your behalf" is exactly the thing a person needs to be able to
    /// see, and it is the thing that decides what may be written to disk.
    PageContext,
    /// What a tool returned. Addressed to the model, shown to the person.
    ToolResult,
}

/// Where a message is in its life.
///
/// Every state except `Streaming` is terminal, the same way a download's are:
/// a reply that stopped never resumes, and asking again is a new message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum MessageState {
    /// Text is arriving.
    Streaming,
    /// The whole reply is here.
    Complete,
    /// The person stopped it, or the thing it was about went away. Whatever
    /// had arrived is kept.
    Cancelled,
    /// It broke. `Conversation::error` says how.
    Failed,
    /// The browser went away while it was still arriving. Distinct from
    /// `Failed` because nothing went wrong with the reply: we did.
    Interrupted,
    /// It ran past what the core is willing to hold, and was cut.
    ///
    /// A separate state rather than a flag, because a truncated answer that
    /// looks complete is the interface asserting something it cannot back up
    /// (ADR-0018).
    Truncated,
}

impl MessageState {
    pub fn is_terminal(self) -> bool {
        !matches!(self, MessageState::Streaming)
    }
}

/// A page a conversation was told about.
///
/// The address and the title, which are facts the browser already holds about
/// the tab. The page's *text* is not in here — it lives on the message, and it
/// is the one part that is never written to disk.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct PageReference {
    pub url: String,
    pub title: String,
}

/// What the model asked to call, before anybody said whether it may.
///
/// `server` and `tool` are names out of the browser's own configuration, which
/// is why a call naming anything else is refused rather than queried:
/// consenting to something the browser cannot name is not consent.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ToolInvocation {
    pub id: ToolCallId,
    /// Which configured MCP server. Never an address or a command line: how a
    /// server is reached is the host's business and the core does not know it.
    pub server: String,
    pub tool: String,
    /// JSON, exactly as the model wrote it. Never parsed here — the core has
    /// no schema to check it against and inventing one would mean silently
    /// changing what was asked for.
    pub arguments: String,
}

/// Where a tool call is in its life, including the two states that only exist
/// because somebody has to say yes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ToolCallState {
    /// The model asked. Nobody has answered, and nothing has run.
    AwaitingConsent,
    /// Approved, and out with the host.
    Running,
    Completed,
    /// It ran and it broke.
    Failed,
    /// Somebody said no, or the browser refused on their behalf because it
    /// could not name what was being asked for.
    Refused,
    /// Cancelled along with the reply that asked for it.
    Cancelled,
}

impl ToolCallState {
    /// Whether this call still has something to happen to it.
    pub fn is_settled(self) -> bool {
        matches!(
            self,
            ToolCallState::Completed
                | ToolCallState::Failed
                | ToolCallState::Refused
                | ToolCallState::Cancelled
        )
    }
}

/// One tool call, with the answer if there is one.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ToolCall {
    pub invocation: ToolInvocation,
    pub state: ToolCallState,
    /// What came back, or why it did not. Empty until something did.
    pub result: String,
    pub requested_at_ms: u64,
}

/// One message.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Message {
    pub id: MessageId,
    pub role: MessageRole,
    pub text: String,
    /// Set only on [`MessageRole::PageContext`].
    pub page: Option<PageReference>,
    pub state: MessageState,
    /// Only ever non-empty on an assistant message.
    pub tool_calls: Vec<ToolCall>,
    /// Which call a [`MessageRole::ToolResult`] answers.
    pub answers: Option<ToolCallId>,
    /// What actually replied, as the host reported it after resolving the
    /// configuration. `None` until it has said, and on anything the model did
    /// not write.
    ///
    /// Recorded rather than derived from settings, because settings change and
    /// a thread that relabels last week's answers with this week's model is
    /// telling you something that never happened (ADR-0018).
    pub model: Option<String>,
    pub created_at_ms: u64,
}

impl Message {
    fn new(id: MessageId, role: MessageRole, text: String, now_ms: u64) -> Self {
        let (text, state) = clamp_text(text);
        Self {
            id,
            role,
            text,
            page: None,
            state: if role == MessageRole::Assistant {
                MessageState::Streaming
            } else {
                state
            },
            tool_calls: Vec::new(),
            answers: None,
            model: None,
            created_at_ms: now_ms,
        }
    }

    /// A page the browser read, on somebody's behalf.
    ///
    /// Complete the moment it exists: unlike a reply, there is nothing more of
    /// it to arrive.
    pub(crate) fn page(id: MessageId, text: String, now_ms: u64) -> Self {
        Self::new(id, MessageRole::PageContext, text, now_ms)
    }

    pub fn is_in_flight(&self) -> bool {
        self.state == MessageState::Streaming
    }

    /// Add another piece of a reply, stopping the message dead if it runs past
    /// what the core will hold.
    ///
    /// A provider that streams without end is not a hypothetical: it is what a
    /// looping model looks like from here. The cut is a terminal state rather
    /// than a silent drop, so the interface can say the answer is a fragment
    /// instead of drawing it as whole.
    pub(crate) fn append_delta(&mut self, delta: &str) {
        if self.text.len() + delta.len() <= MAX_MESSAGE_BYTES {
            self.text.push_str(delta);
            return;
        }
        let room = MAX_MESSAGE_BYTES.saturating_sub(self.text.len());
        let mut cut = room.min(delta.len());
        while cut > 0 && !delta.is_char_boundary(cut) {
            cut -= 1;
        }
        self.text.push_str(&delta[..cut]);
        self.state = MessageState::Truncated;
    }

    /// Tool calls nobody has answered for yet.
    pub fn awaiting_consent(&self) -> Vec<&ToolCall> {
        self.tool_calls
            .iter()
            .filter(|c| c.state == ToolCallState::AwaitingConsent)
            .collect()
    }

    fn every_call_settled(&self) -> bool {
        self.tool_calls.iter().all(|c| c.state.is_settled())
    }
}

/// Cut a message to what the core is willing to hold, saying so if it had to.
fn clamp_text(text: String) -> (String, MessageState) {
    if text.len() <= MAX_MESSAGE_BYTES {
        return (text, MessageState::Complete);
    }
    let mut cut = MAX_MESSAGE_BYTES;
    while cut > 0 && !text.is_char_boundary(cut) {
        cut -= 1;
    }
    (text[..cut].to_string(), MessageState::Truncated)
}

/// Why a conversation could not go on, in terms the interface can act on.
///
/// Decided here rather than in the shell for the same reason
/// [`crate::NavigationErrorKind`] is: "nothing is configured" and "you are
/// being rate limited" are different screens offering different actions on
/// every platform, and an HTTP 429 with a provider's JSON body in it is not
/// something any interface can branch on. Only the wording belongs to the
/// shell.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ChatErrorKind {
    /// Nothing is set up to answer. The first thing anybody sees, and the only
    /// one whose useful action is a settings screen rather than "try again".
    NoProviderConfigured,
    /// There is a key and the provider would not take it.
    NotAuthorised,
    /// Too many, too fast.
    RateLimited,
    /// There is no network at all.
    Offline,
    /// The provider could not be reached, or dropped the connection partway.
    ConnectionFailed,
    Timeout,
    /// The conversation no longer fits in what the model will read.
    ContextTooLong,
    /// The provider answered with something the host could not read.
    MalformedResponse,
    /// The provider answered, and the answer was a refusal: a model that is
    /// gone, a request it will not serve.
    ProviderRefused,
    /// A configured tool server would not answer.
    ToolUnavailable,
    /// A tool ran and failed.
    ToolFailed,
    /// One question spent [`MAX_TOOL_ROUNDS`] rounds calling tools and was
    /// stopped.
    ToolLoop,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ChatError {
    pub kind: ChatErrorKind,
    /// What the host said, verbatim. Only worth showing when `kind` is
    /// `Unknown` and there is nothing better.
    pub detail: String,
}

/// A tool the browser knows about, because something configured it.
///
/// `summary` is the server's own description of its own tool. It is carried so
/// a person can read it and never presented as the browser's statement: a
/// server describing its tool as harmless is the thing being trusted
/// describing itself, which is exactly the evidence ADR-0028 refuses for
/// extension permissions.
///
/// The schema and the three hints travel with it because everything downstream
/// needs them and nothing downstream should go looking. A provider host cannot
/// write a usable tool definition without the schema — a model handed a name
/// and a sentence invents its own arguments — and the fingerprint an approval
/// is bound to is taken over the name, the summary and the schema, so a
/// descriptor missing either is a descriptor nobody can check.
///
/// The hints are the server's claims about its own code, and they are carried
/// exactly as they arrived: `None` is "the server did not say", which
/// [`crate::mcp`] reads pessimistically for gating and honestly for prose. A
/// type that folded `None` into `false` on the way through would decide that
/// question here, in the wrong place, and for every reader at once.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ToolDescriptor {
    pub server: String,
    pub tool: String,
    pub summary: String,
    /// The raw JSON of the tool's `inputSchema`, exactly as the server
    /// published it. Text rather than a parsed type because it arrives verbatim
    /// and leaves verbatim; parsing it here would only create somewhere to lose
    /// a keyword.
    pub input_schema_json: String,
    /// `annotations.readOnlyHint`. Absent means false, per the specification.
    pub read_only_hint: Option<bool>,
    /// `annotations.destructiveHint`. Absent means **true**.
    pub destructive_hint: Option<bool>,
    /// `annotations.openWorldHint`. Absent means **true**.
    pub open_world_hint: Option<bool>,
}

/// What somebody chose about one tool call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ConsentChoice {
    /// Run it this time, and ask again next time.
    Once,
    /// Run it, and stop asking for this tool on this server.
    Always,
    /// Not this time. Nothing is written down, so the next call asks again.
    Refuse,
    /// Never, and remember that.
    Never,
}

/// One remembered answer about one tool.
///
/// Per `(server, tool)` and never per server. Approving a server is approving
/// tools it has not published yet, which is the same failure ADR-0028 names
/// for a manifest that grows a permission after the install.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ToolGrant {
    pub server: String,
    pub tool: String,
    pub allowed: bool,
    pub decided_at_ms: u64,
}

/// The browser's ledger of what may run without asking.
///
/// Refusals are stored rather than inferred from absence, for the reason
/// ADR-0028 gives: absence has to keep meaning "nobody was asked", which is
/// what happens when a server publishes a tool it did not have before.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ToolConsent {
    grants: Vec<ToolGrant>,
}

impl ToolConsent {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn all(&self) -> &[ToolGrant] {
        &self.grants
    }

    /// `None` means nobody was ever asked, which is not the same as no.
    pub fn decision(&self, server: &str, tool: &str) -> Option<bool> {
        self.grants
            .iter()
            .find(|g| g.server == server && g.tool == tool)
            .map(|g| g.allowed)
    }

    pub fn record(&mut self, server: &str, tool: &str, allowed: bool, decided_at_ms: u64) {
        self.grants
            .retain(|g| !(g.server == server && g.tool == tool));
        self.grants.push(ToolGrant {
            server: server.to_string(),
            tool: tool.to_string(),
            allowed,
            decided_at_ms,
        });
    }

    /// Take an answer back, so the next call asks again.
    pub fn forget(&mut self, server: &str, tool: &str) -> bool {
        let before = self.grants.len();
        self.grants
            .retain(|g| !(g.server == server && g.tool == tool));
        before != self.grants.len()
    }

    /// Every answer about one server, for a Settings row that lists them.
    pub fn for_server(&self, server: &str) -> Vec<&ToolGrant> {
        self.grants.iter().filter(|g| g.server == server).collect()
    }

    pub fn load(grants: Vec<ToolGrant>) -> Self {
        Self { grants }
    }
}

/// One thread.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Conversation {
    pub id: ConversationId,
    pub scope: ConversationScope,
    pub messages: Vec<Message>,
    /// Why the last attempt stopped, if it did. Cleared the moment another one
    /// starts, so a thread that recovered never keeps showing an error.
    pub error: Option<ChatError>,
    /// Set while the browser is reading the page to attach. Nothing is sent
    /// until it clears, and Escape clears it.
    pub awaiting_page: bool,
    pub created_at_ms: u64,
}

impl Conversation {
    /// The reply currently arriving, if one is.
    pub fn streaming(&self) -> Option<&Message> {
        self.messages.iter().find(|m| m.is_in_flight())
    }

    pub fn message(&self, id: MessageId) -> Option<&Message> {
        self.messages.iter().find(|m| m.id == id)
    }

    pub(crate) fn message_mut(&mut self, id: MessageId) -> Option<&mut Message> {
        self.messages.iter_mut().find(|m| m.id == id)
    }

    /// Whether anything is happening that the person could stop.
    pub fn is_busy(&self) -> bool {
        self.awaiting_page
            || self.streaming().is_some()
            || self.messages.iter().any(|m| {
                m.tool_calls
                    .iter()
                    .any(|c| matches!(c.state, ToolCallState::Running))
            })
    }

    /// Whether anything is waiting on somebody to say yes.
    pub fn needs_consent(&self) -> bool {
        self.messages
            .iter()
            .any(|m| !m.awaiting_consent().is_empty())
    }

    /// When anything last happened here.
    ///
    /// Derived from the messages rather than kept as a field, because a stored
    /// field can disagree with the rows it was stored beside — and the thing
    /// that disagreement decides is which of somebody's threads opens when they
    /// press ⌘E. A thread with nothing in it falls back to when it was minted,
    /// which is the only moment it has.
    pub fn last_activity_ms(&self) -> u64 {
        self.messages
            .last()
            .map_or(self.created_at_ms, |m| m.created_at_ms)
    }

    /// What this thread would be called in a list of threads about one page.
    ///
    /// The first thing the person typed, which is the only line in a transcript
    /// they wrote on purpose to say what they wanted. Empty when they have not
    /// asked anything yet.
    pub fn opening_question(&self) -> &str {
        self.messages
            .iter()
            .find(|m| m.role == MessageRole::User)
            .map_or("", |m| m.text.as_str())
    }

    /// The page most recently attached to this thread, if any.
    pub fn last_page(&self) -> Option<&PageReference> {
        self.messages
            .iter()
            .rev()
            .find(|m| m.role == MessageRole::PageContext)
            .and_then(|m| m.page.as_ref())
    }

    pub(crate) fn find_call_mut(&mut self, id: &ToolCallId) -> Option<&mut ToolCall> {
        self.messages
            .iter_mut()
            .flat_map(|m| m.tool_calls.iter_mut())
            .find(|c| &c.invocation.id == id)
    }

    /// How many assistant turns this question has already spent.
    ///
    /// Counted back to the last thing the person typed, because the bound is
    /// on one question rather than on the thread.
    pub(crate) fn rounds_since_user(&self) -> usize {
        self.messages
            .iter()
            .rev()
            .take_while(|m| m.role != MessageRole::User)
            .filter(|m| m.role == MessageRole::Assistant)
            .count()
    }

    /// Whether there is a question sitting here with no answer under way.
    pub(crate) fn wants_a_reply(&self) -> bool {
        if self.awaiting_page || self.streaming().is_some() {
            return false;
        }
        // One unanswered call is enough to wait on. Going ahead without it
        // would ask the model to carry on as though a tool it asked for had
        // returned nothing, which is a different conversation from the one it
        // is having.
        if !self.messages.iter().all(Message::every_call_settled) {
            return false;
        }
        match self.messages.last() {
            None => false,
            Some(last) => match last.role {
                MessageRole::User | MessageRole::PageContext | MessageRole::ToolResult => true,
                // An assistant turn that asked for tools is answered once every
                // call has settled; one that asked for nothing is finished.
                MessageRole::Assistant => !last.tool_calls.is_empty(),
            },
        }
    }

    /// Put a page in front of the question it was attached for.
    ///
    /// The person typed first and the browser read the page afterwards, but
    /// the model has to be told what it is looking at before it is asked about
    /// it. Arrival order is not the order of the conversation.
    pub(crate) fn insert_page_before_question(&mut self, message: Message) {
        let at = self
            .messages
            .iter()
            .rposition(|m| m.role == MessageRole::User)
            .unwrap_or(self.messages.len());
        self.messages.insert(at, message);
        self.trim();
    }

    fn trim(&mut self) {
        while self.messages.len() > MAX_MESSAGES {
            self.messages.remove(0);
        }
    }
}

/// Every conversation this browser is holding, plus what may run without
/// asking.
///
/// What tools *exist* is deliberately not here. That is
/// [`crate::mcp::McpRegistry`], and it is one list rather than two because two
/// lists of the same tools eventually disagree about which tool a name means —
/// and the half that is wrong is always the half a call is checked against.
/// This side holds the answers; that side holds what they were about.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Chat {
    conversations: Vec<Conversation>,
    consent: ToolConsent,
    next_conversation: u64,
    next_message: u64,
}

impl Chat {
    pub fn new() -> Self {
        Self {
            conversations: Vec::new(),
            consent: ToolConsent::new(),
            next_conversation: 1,
            next_message: 1,
        }
    }

    pub fn all(&self) -> &[Conversation] {
        &self.conversations
    }

    pub fn consent(&self) -> &ToolConsent {
        &self.consent
    }

    pub fn consent_mut(&mut self) -> &mut ToolConsent {
        &mut self.consent
    }

    pub fn get(&self, id: ConversationId) -> Option<&Conversation> {
        self.conversations.iter().find(|c| c.id == id)
    }

    pub fn get_mut(&mut self, id: ConversationId) -> Option<&mut Conversation> {
        self.conversations.iter_mut().find(|c| c.id == id)
    }

    /// Every thread with this subject, most recent first.
    ///
    /// One subject may hold several threads, and which of them opens is
    /// behaviour rather than presentation, so the order is decided here and no
    /// shell sorts anything. Ties break on the id, descending: two threads
    /// whose last message shares a millisecond still have a first and a second,
    /// and the later-minted one is the more recent.
    pub fn for_scope(&self, scope: &ConversationScope) -> Vec<&Conversation> {
        let mut found: Vec<&Conversation> = self
            .conversations
            .iter()
            .filter(|c| c.scope == *scope)
            .collect();
        found.sort_by(|a, b| {
            b.last_activity_ms()
                .cmp(&a.last_activity_ms())
                .then_with(|| b.id.cmp(&a.id))
        });
        found
    }

    /// The thread this subject opens with: the most recent one, or none yet.
    pub fn latest_for_scope(&self, scope: &ConversationScope) -> Option<&Conversation> {
        self.for_scope(scope).into_iter().next()
    }

    /// Every thread about the same subject as `id`, most recent first, `id`
    /// among them.
    ///
    /// What the screen listing threads about one page is drawn from. Empty for
    /// a conversation that does not exist, which is a screen with nothing on it
    /// rather than a crash.
    pub fn siblings_of(&self, id: ConversationId) -> Vec<&Conversation> {
        match self.get(id) {
            Some(c) => self.for_scope(&c.scope),
            None => Vec::new(),
        }
    }

    /// Which thread a message belongs to.
    ///
    /// A host reports against a message id alone, so this is the one lookup
    /// the reducer needs on every piece of a reply.
    pub fn conversation_of_message(&self, message: MessageId) -> Option<ConversationId> {
        self.conversations
            .iter()
            .find(|c| c.messages.iter().any(|m| m.id == message))
            .map(|c| c.id)
    }

    /// Which thread a tool call belongs to.
    pub fn conversation_of_call(&self, call: &ToolCallId) -> Option<ConversationId> {
        self.conversations
            .iter()
            .find(|c| {
                c.messages
                    .iter()
                    .any(|m| m.tool_calls.iter().any(|t| &t.invocation.id == call))
            })
            .map(|c| c.id)
    }

    /// The thread this subject opens with, minting one if it has never had a
    /// thread at all.
    ///
    /// **Never a second thread about a page that already has one.** Opening a
    /// page discussed before has to bring that conversation back, or the
    /// feature does not exist; a browser that quietly minted a fresh thread
    /// each time would look identical from here and be worthless. Wanting
    /// another is [`Chat::start`], and reaching it is somebody's deliberate
    /// act.
    pub(crate) fn ensure(&mut self, scope: ConversationScope, now_ms: u64) -> ConversationId {
        match self.latest_for_scope(&scope) {
            Some(existing) => existing.id,
            None => self.start(scope, now_ms),
        }
    }

    /// Another thread about the same subject, whether or not one already
    /// exists.
    ///
    /// The only way a page gets a second conversation, which is what makes the
    /// second one deliberate rather than a thing that happened.
    pub(crate) fn start(&mut self, scope: ConversationScope, now_ms: u64) -> ConversationId {
        let id = ConversationId(self.next_conversation);
        self.next_conversation += 1;

        while self.conversations.len() >= MAX_CONVERSATIONS {
            self.conversations.remove(0);
        }
        self.conversations.push(Conversation {
            id,
            scope,
            messages: Vec::new(),
            error: None,
            awaiting_page: false,
            created_at_ms: now_ms,
        });
        id
    }

    pub(crate) fn next_message_id(&mut self) -> MessageId {
        let id = MessageId(self.next_message);
        self.next_message += 1;
        id
    }

    /// Append a message and hand back its id.
    pub(crate) fn append(
        &mut self,
        conversation: ConversationId,
        role: MessageRole,
        text: String,
        now_ms: u64,
    ) -> Option<MessageId> {
        let id = self.next_message_id();
        let target = self.get_mut(conversation)?;
        target.messages.push(Message::new(id, role, text, now_ms));
        target.trim();
        Some(id)
    }

    /// Forget one thread outright.
    pub(crate) fn remove(&mut self, id: ConversationId) -> Option<Conversation> {
        let at = self.conversations.iter().position(|c| c.id == id)?;
        Some(self.conversations.remove(at))
    }

    /// Every conversation belonging to `space`.
    ///
    /// No list of tabs is needed any more: every scope names its space
    /// outright, so a thread whose page has no tab open is still found — and a
    /// space that is closing must take its threads with it whether or not
    /// anything was showing them.
    pub(crate) fn ids_for_space(&self, space: SpaceId) -> Vec<ConversationId> {
        self.conversations
            .iter()
            .filter(|c| c.scope.space() == space)
            .map(|c| c.id)
            .collect()
    }

    /// Rebuild from what a store kept.
    ///
    /// The two counters are derived from what arrived rather than stored
    /// beside it. A saved counter can disagree with the rows it was saved with
    /// — a half-written file, a hand-edited one — and the failure that
    /// disagreement produces is a new message overwriting an old one, which is
    /// the kind of bug nobody traces back to a number in a `meta` table.
    #[cfg(feature = "store")]
    pub(crate) fn load(conversations: Vec<Conversation>, consent: ToolConsent) -> Self {
        let mut conversations = conversations;
        conversations.truncate(MAX_CONVERSATIONS);

        let next_conversation = conversations.iter().map(|c| c.id.0).max().unwrap_or(0) + 1;
        let next_message = conversations
            .iter()
            .flat_map(|c| c.messages.iter())
            .map(|m| m.id.0)
            .max()
            .unwrap_or(0)
            + 1;

        Self {
            conversations,
            consent,
            next_conversation,
            next_message,
        }
    }
}

/// Cut a payload that came off a network down to what will be held.
///
/// Applied to tool arguments and tool results, both of which are chosen by
/// something that is not us.
pub(crate) fn clamp_payload(value: String) -> String {
    if value.len() <= MAX_TOOL_PAYLOAD_BYTES {
        return value;
    }
    let mut cut = MAX_TOOL_PAYLOAD_BYTES;
    while cut > 0 && !value.is_char_boundary(cut) {
        cut -= 1;
    }
    value[..cut].to_string()
}

#[cfg(test)]
#[path = "chat_tests.rs"]
mod tests;
