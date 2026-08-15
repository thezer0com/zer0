//! The configuration file: what someone would want identical on a second Mac.
//!
//! Two stores, and the line between them is not arbitrary. `session.sqlite`
//! holds **what this machine has been doing** — the tabs that are open, where
//! you were in history, what you downloaded, which icons have been fetched.
//! Copying it to another Mac would be copying somebody's afternoon.
//!
//! This file holds **what the browser can reach**: which LLM providers exist,
//! which models they offer, which MCP servers to start. Copying it to another
//! Mac is the entire point. It is text, it is commented, it diffs a line at a
//! time, and it is meant to live in a dotfiles repository under a symlink.
//!
//! Stated as a rule, because the next person adding a setting needs one:
//!
//! > **The file declares what exists. The session store records what happened.**
//!
//! `default_provider` is in the file: it is a standing preference. Which
//! provider a particular chat is using right now is not — that is this
//! machine's afternoon, and it belongs to the session.
//!
//! # Why there is no secret in here
//!
//! A file meant to be committed and an API key in the same file is how
//! credentials leak, and it happens on the first `git push` rather than after a
//! long chain of mistakes. So a provider does not carry a key; it carries the
//! **name** of one, and the value lives in the platform's credential store
//! (the Keychain on macOS), which this crate never touches.
//!
//! The guarantee is the shape, not a rule written down somewhere. Following
//! `storable.rs` and ADR-0028: a value absent from the type cannot be written
//! by mistake. There is no field in [`Config`], [`ProviderConfig`] or
//! [`McpServerConfig`] that can hold a secret, no constructor that accepts one,
//! and no function in this module that returns one. The writer emits from these
//! types and nothing else, so "the file must not contain a key" is not a
//! promise the writer keeps — it is a sentence the writer cannot express.
//!
//! One hole is left, and it is closed separately: a person can type a key into
//! `credential` by hand, because a string field accepts any string. That is
//! caught on the way in and on the way out — see [`looks_like_a_secret`] — and
//! refused with a message saying where to put it instead.

mod edit;
mod file;
mod parse;
mod paths;

pub use file::{ConfigError, ConfigFile};
pub use parse::parse;
pub use paths::{config_path, default_config_path};

/// Everything the configuration file says, with everything it could not say
/// already gone.
///
/// Absent file, empty file and file-with-only-comments all produce
/// [`Config::default`]. None of the three is an error: a first launch has no
/// configuration and that is the normal state, not a broken one.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Config {
    /// Which provider a new chat starts on. `None`, or a name matching no
    /// provider, means the first enabled one — decided at the point of use, so
    /// that a config naming a provider someone later deleted still opens a chat.
    pub default_provider: Option<String>,
    /// In file order. The order is the data: it is what the settings list shows
    /// and what "the first enabled one" means.
    pub providers: Vec<ProviderConfig>,
    /// In file order, same reason.
    pub mcp_servers: Vec<McpServerConfig>,
}

/// Which kind of provider this is, as the file names it.
///
/// Close to `provider::WireFormat` and deliberately not identical to it.
/// `WireFormat` is about the shape on the wire, and by that measure `OpenAi`
/// and `OpenAiCompatible` are one thing. In the file they are two, for two
/// reasons that only exist at this level: `openai-compatible` is the one kind
/// that **has to** carry a `base_url` — nothing else can say which service it
/// is — and a person reading their own config wants the line to say which of
/// the two they meant. Mapping the pair onto one `WireFormat` is one match arm
/// where the request is built.
///
/// A closed set on purpose. An unknown value is not defaulted to something
/// plausible: a provider that silently became `openai-compatible` would fail at
/// the first request with an error about JSON rather than about configuration.
/// It is dropped, and a diagnostic names the line (ADR-0024).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ProviderKind {
    /// `POST /v1/messages`.
    Anthropic,
    /// `POST /v1/chat/completions` at OpenAI itself.
    OpenAi,
    /// The same shape somewhere else — a work gateway, a proxy, something
    /// self-hosted. Requires a `base_url`, because there is nothing else to say
    /// which service it is.
    OpenAiCompatible,
    /// `POST /api/chat` against a local daemon.
    Ollama,
}

impl ProviderKind {
    /// The spelling used in the file. One direction only; parsing is
    /// [`ProviderKind::from_wire`], and having both here is what keeps a
    /// round-trip from quietly renaming somebody's provider.
    pub fn as_wire(self) -> &'static str {
        match self {
            Self::Anthropic => "anthropic",
            Self::OpenAi => "openai",
            Self::OpenAiCompatible => "openai-compatible",
            Self::Ollama => "ollama",
        }
    }

    pub fn from_wire(value: &str) -> Option<Self> {
        match value {
            // `provider::WireFormat`'s own spellings are accepted as well, so a
            // config written against the names used where the request is built
            // loads rather than dropping a provider over a synonym.
            "anthropic" | "anthropic-messages" => Some(Self::Anthropic),
            "openai" | "openai-chat" => Some(Self::OpenAi),
            "openai-compatible" => Some(Self::OpenAiCompatible),
            "ollama" | "ollama-chat" => Some(Self::Ollama),
            _ => None,
        }
    }

    /// Whether this kind cannot be reached without being told where it is.
    ///
    /// Only `openai-compatible`, and that is what distinguishes it from
    /// `openai`: the shape is the same and the endpoint is the whole question.
    pub fn needs_base_url(self) -> bool {
        matches!(self, Self::OpenAiCompatible)
    }

    /// Every spelling the file accepts, for a settings picker and for the error
    /// message that lists them when someone gets one wrong.
    pub fn all() -> Vec<Self> {
        vec![
            Self::Anthropic,
            Self::OpenAi,
            Self::OpenAiCompatible,
            Self::Ollama,
        ]
    }
}

/// One LLM provider, as the file describes it.
///
/// **There is no field here that can hold an API key**, and that is the design
/// rather than an omission. See the module documentation.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ProviderConfig {
    /// Stable across renames: what `default_provider` and the session store
    /// point at. Lowercase, no spaces.
    pub id: String,
    /// What a person sees. Defaults to `id` when the file leaves it out, so a
    /// minimal entry is two lines rather than three.
    pub name: String,
    pub kind: ProviderKind,
    /// `None` means the endpoint the kind ships with. Present for a proxy, a
    /// gateway, or anything self-hosted.
    pub base_url: Option<String>,
    /// **The name of a credential, never a credential.**
    ///
    /// `None` is a provider that needs no key, which is the normal state for
    /// anything running on localhost. It is not "the key is missing" — that is
    /// [`Readiness::MissingCredential`], and the two must not be confused: one
    /// is ready to use and the other is waiting on a person.
    pub credential: Option<String>,
    /// Offered in the model picker, in file order. Empty means the shell asks
    /// the provider what it has, which is what a local server is for.
    pub models: Vec<String>,
    /// `None` means the first entry in `models`.
    pub default_model: Option<String>,
    /// Off keeps the entry, and its models, and its credential name, and takes
    /// it out of the picker. Deleting to turn something off and retyping it to
    /// turn it back on is not a toggle.
    pub enabled: bool,
}

impl ProviderConfig {
    /// A provider with everything optional left out, for the settings UI to
    /// fill in and for a test to build from.
    pub fn new(id: impl Into<String>, kind: ProviderKind) -> Self {
        let id = id.into();
        Self {
            name: id.clone(),
            id,
            kind,
            base_url: None,
            credential: None,
            models: Vec::new(),
            default_model: None,
            enabled: true,
        }
    }

    /// Which model a new chat opens on, or `None` when the file named none and
    /// listed none.
    pub fn preferred_model(&self) -> Option<&str> {
        self.default_model
            .as_deref()
            .filter(|m| self.models.is_empty() || self.models.iter().any(|c| c == m))
            .or_else(|| self.models.first().map(String::as_str))
    }
}

/// How an MCP server is reached.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum TransportKind {
    /// A process we start and talk to over its stdin and stdout.
    Stdio,
    /// A URL we connect to. Covers both HTTP and SSE, which differ in framing
    /// and not in anything the file has to say.
    Http,
}

impl TransportKind {
    pub fn as_wire(self) -> &'static str {
        match self {
            Self::Stdio => "stdio",
            Self::Http => "http",
        }
    }

    pub fn from_wire(value: &str) -> Option<Self> {
        match value {
            "stdio" => Some(Self::Stdio),
            // Both spellings, because a config written against an SSE endpoint
            // reads as "sse" to the person writing it and refusing that would
            // be pedantry with a line number attached.
            "http" | "sse" => Some(Self::Http),
            _ => None,
        }
    }

    pub fn all() -> Vec<Self> {
        vec![Self::Stdio, Self::Http]
    }
}

/// A literal environment variable handed to an MCP server we start.
///
/// A record rather than a map so the order in the file survives a rewrite: a
/// settings toggle that reshuffles someone's environment block produces a diff
/// nobody can read.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct EnvVar {
    pub name: String,
    /// Checked for looking like a secret, and refused if it does. An MCP server
    /// authenticated through `GITHUB_TOKEN` is the ordinary case, and without
    /// this that token would sit in the committed file.
    pub value: String,
}

/// An environment variable whose value comes from the credential store.
///
/// This exists because `env` alone would have made the whole design pointless:
/// almost every stdio MCP server authenticates through an environment variable,
/// so without somewhere to put it, the key goes in `env` and into the
/// repository. Here the file says `GITHUB_TOKEN` comes from the credential
/// named `github`, and the value is fetched at spawn time by the shell.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct SecretEnvVar {
    pub name: String,
    /// The name of a credential, never a credential.
    pub credential: String,
}

/// One MCP server, as the file describes it.
///
/// Both transports in one record rather than an enum carrying each one's
/// fields: a person switching a server from stdio to http in the settings UI
/// keeps what they typed for the other one, and a diff of that change is one
/// line rather than a deleted block and a new one.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct McpServerConfig {
    pub id: String,
    /// Defaults to `id`.
    pub name: String,
    pub transport: TransportKind,
    /// Stdio only. A server with no command is dropped on load.
    pub command: Option<String>,
    pub args: Vec<String>,
    pub env: Vec<EnvVar>,
    pub secret_env: Vec<SecretEnvVar>,
    /// HTTP only. A server with no URL is dropped on load.
    pub url: Option<String>,
    /// The name of a credential for the `Authorization` header, never a
    /// credential.
    pub credential: Option<String>,
    pub enabled: bool,
}

impl McpServerConfig {
    pub fn new(id: impl Into<String>, transport: TransportKind) -> Self {
        let id = id.into();
        Self {
            name: id.clone(),
            id,
            transport,
            command: None,
            args: Vec::new(),
            env: Vec::new(),
            secret_env: Vec::new(),
            url: None,
            credential: None,
            enabled: true,
        }
    }
}

/// Whether something in the file can actually be used right now.
///
/// The interesting variant is [`Readiness::MissingCredential`], and it is the
/// normal state five minutes after cloning a dotfiles repository onto a new
/// Mac: every provider is described perfectly and none of them has a key yet.
/// That is not a failure, it is a to-do list, and it carries the name so the
/// interface can say which key to add rather than "not configured".
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum Readiness {
    Ready,
    /// Switched off in the file.
    Disabled,
    /// The file names a credential and the credential store has no entry under
    /// that name.
    MissingCredential {
        credential: String,
    },
    /// Nothing in the file has this id.
    Unknown,
}

impl Config {
    /// Every credential name the file mentions, deduplicated, in first-mention
    /// order.
    ///
    /// This is the whole question the shell asks the Keychain at launch: which
    /// of these exist. It never asks for a value it is not about to use, so a
    /// browser sitting idle never reads a secret at all.
    pub fn credential_refs(&self) -> Vec<String> {
        let mut names: Vec<String> = Vec::new();
        let mut push = |name: &str| {
            if !name.is_empty() && !names.iter().any(|n| n == name) {
                names.push(name.to_string());
            }
        };
        for provider in &self.providers {
            if let Some(credential) = &provider.credential {
                push(credential);
            }
        }
        for server in &self.mcp_servers {
            if let Some(credential) = &server.credential {
                push(credential);
            }
            for secret in &server.secret_env {
                push(&secret.credential);
            }
        }
        names
    }

    pub fn provider(&self, id: &str) -> Option<&ProviderConfig> {
        self.providers.iter().find(|p| p.id == id)
    }

    pub fn mcp_server(&self, id: &str) -> Option<&McpServerConfig> {
        self.mcp_servers.iter().find(|s| s.id == id)
    }

    /// Which provider a new chat opens on.
    ///
    /// In the core rather than in each shell because "the default named a
    /// provider that is no longer there" has to resolve the same way on every
    /// platform, and the answer — fall back to the first enabled one — is a
    /// judgement, not a rendering detail.
    pub fn effective_provider(&self, available_credentials: &[String]) -> Option<&ProviderConfig> {
        let usable = |p: &&ProviderConfig| {
            p.enabled && self.provider_readiness(&p.id, available_credentials) == Readiness::Ready
        };
        self.default_provider
            .as_deref()
            .and_then(|id| self.provider(id))
            .filter(usable)
            .or_else(|| self.providers.iter().find(usable))
    }

    pub fn provider_readiness(&self, id: &str, available_credentials: &[String]) -> Readiness {
        match self.provider(id) {
            None => Readiness::Unknown,
            Some(provider) if !provider.enabled => Readiness::Disabled,
            Some(provider) => credential_readiness(
                provider.credential.iter().map(String::as_str),
                available_credentials,
            ),
        }
    }

    pub fn mcp_readiness(&self, id: &str, available_credentials: &[String]) -> Readiness {
        match self.mcp_server(id) {
            None => Readiness::Unknown,
            Some(server) if !server.enabled => Readiness::Disabled,
            Some(server) => credential_readiness(
                server
                    .credential
                    .iter()
                    .map(String::as_str)
                    .chain(server.secret_env.iter().map(|s| s.credential.as_str())),
                available_credentials,
            ),
        }
    }
}

/// `Ready` unless one of `wanted` is not in `available`, in which case the
/// first one that is missing, in the order the file mentions them.
fn credential_readiness<'a>(
    wanted: impl Iterator<Item = &'a str>,
    available: &[String],
) -> Readiness {
    for name in wanted {
        if !available.iter().any(|a| a == name) {
            return Readiness::MissingCredential {
                credential: name.to_string(),
            };
        }
    }
    Readiness::Ready
}

/// Whether a string that is supposed to be a *name* looks like a *value*.
///
/// The one hole the type system leaves open: `credential` is a `String`, and a
/// person who has not read the comment above it will paste their key there.
/// Once. Then they commit it. The whole design is worth nothing if that lands
/// silently, so it is refused on the way in from the file **and** on the way
/// out from the settings UI, and the message says where the value belongs.
///
/// Two rules, both deliberately blunt. A credential *name* is something like
/// `anthropic` or `work-openai`: short, memorable, typed by a person. Anything
/// carrying a known key prefix, or forty-odd unbroken characters of mixed
/// letters and digits, is not a name anybody chose.
///
/// False positives are possible and cheap — rename the credential. A false
/// negative is a key in a public repository.
pub fn looks_like_a_secret(value: &str) -> bool {
    const PREFIXES: &[&str] = &[
        "sk-",
        "sk_",
        "rk-",
        "pk_live",
        "ghp_",
        "gho_",
        "ghu_",
        "ghs_",
        "ghr_",
        "github_pat_",
        "glpat-",
        "xoxb-",
        "xoxp-",
        "xoxa-",
        "xapp-",
        "AIza",
        "AKIA",
        "ASIA",
        "hf_",
        "Bearer ",
        "-----BEGIN",
    ];
    let trimmed = value.trim();
    if PREFIXES.iter().any(|p| trimmed.starts_with(p)) {
        return true;
    }
    trimmed.len() >= 40
        && !trimmed.contains(char::is_whitespace)
        && trimmed.chars().any(|c| c.is_ascii_digit())
        && trimmed.chars().any(|c| c.is_ascii_alphabetic())
}

/// How bad a diagnostic is, and therefore what happens to what it is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ConfigSeverity {
    /// Something was dropped. A whole-file `Error` means nothing was loaded and
    /// the previously loaded configuration is still in force.
    Error,
    /// Everything loaded; something is worth saying anyway.
    Warning,
}

/// One thing wrong with the file, with somewhere to put the cursor.
///
/// The line number is the entire reason this type exists. "Invalid
/// configuration" sends someone to read two hundred lines; "line 41: unknown
/// provider kind `anthropik`" sends them to line 41.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ConfigDiagnostic {
    pub severity: ConfigSeverity,
    /// 1-based. `0` when the complaint is about the file as a whole and no
    /// single line is to blame.
    pub line: u32,
    /// 1-based, `0` alongside a `0` line.
    pub column: u32,
    /// Written for the person holding the editor, in one sentence, saying what
    /// to do rather than what failed.
    pub message: String,
}

impl ConfigDiagnostic {
    pub(crate) fn error(line: u32, column: u32, message: impl Into<String>) -> Self {
        Self {
            severity: ConfigSeverity::Error,
            line,
            column,
            message: message.into(),
        }
    }

    pub(crate) fn warning(line: u32, column: u32, message: impl Into<String>) -> Self {
        Self {
            severity: ConfigSeverity::Warning,
            line,
            column,
            message: message.into(),
        }
    }

    /// `"line 12, column 3: …"`, or just the message when there is no line.
    pub fn describe(&self) -> String {
        if self.line == 0 {
            self.message.clone()
        } else {
            format!(
                "line {}, column {}: {}",
                self.line, self.column, self.message
            )
        }
    }
}

/// What [`parse`] produced: a configuration, and everything it had to leave out
/// to produce it.
///
/// Both, always. A file with one bad provider yields the other four and a
/// diagnostic, because losing one setting must not cost the rest (ADR-0024).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedConfig {
    pub config: Config,
    pub diagnostics: Vec<ConfigDiagnostic>,
}

/// The commented starting point written for someone who has never seen this
/// file, offered by the settings UI rather than written at launch.
///
/// **Not created on first run.** No file is the normal first state, and a
/// browser that writes into `~/.config` before being asked is a browser that
/// puts a file in a dotfiles repository nobody added.
pub fn example_config() -> &'static str {
    include_str!("example.toml")
}

#[cfg(test)]
#[path = "config_tests.rs"]
mod tests;
