//! The configuration file as the shell sees it.
//!
//! Its own object rather than more methods on [`crate::Zer0`], because the two
//! have different lifetimes and different failure modes: the browser is opened
//! once and is always there, and the configuration file can be absent, can be
//! replaced under us, and can be broken while everything else is fine. Folding
//! it in would mean `Zer0::open` deciding what to do about a config error at a
//! moment when there is nothing on screen to say it with.
//!
//! Everything here is a thin wrapper. The judgements — what a missing
//! credential means, which provider a chat opens on, whether an edit may be
//! written — are all in [`crate::config`], where they are tested without a
//! window and where a second platform inherits them.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

use crate::config::{
    Config, ConfigDiagnostic, ConfigError, ConfigFile, McpServerConfig, ProviderConfig, Readiness,
};

/// Where the configuration file is on this machine.
///
/// Exported so the settings window can show the path and open it in an editor:
/// "your settings are in a file" is not useful without the file's name, and a
/// person who has symlinked it wants to see where it actually points.
#[uniffi::export]
pub fn default_config_path() -> String {
    crate::config::default_config_path()
        .to_string_lossy()
        .into_owned()
}

/// The commented starting point, for a settings window offering to create one.
#[uniffi::export]
pub fn example_config() -> String {
    crate::config::example_config().to_string()
}

/// How a provider kind is spelled in the file.
///
/// A free function because a uniffi enum carries no methods across the FFI, and
/// this mapping has to exist exactly once — writing it again in Swift is how
/// the picker and the parser end up disagreeing about what `openai-compatible`
/// is called.
#[uniffi::export]
pub fn provider_kind_wire(kind: crate::config::ProviderKind) -> String {
    kind.as_wire().to_string()
}

/// Every kind, in the order a picker should offer them.
#[uniffi::export]
pub fn provider_kinds() -> Vec<crate::config::ProviderKind> {
    crate::config::ProviderKind::all()
}

/// Whether this kind cannot be reached without a `base_url`.
///
/// Exported so the settings window can mark the field required rather than
/// letting somebody save an entry the parser will drop.
#[uniffi::export]
pub fn provider_kind_needs_base_url(kind: crate::config::ProviderKind) -> bool {
    kind.needs_base_url()
}

/// How a transport is spelled in the file. Same reasoning as above.
#[uniffi::export]
pub fn transport_kind_wire(transport: crate::config::TransportKind) -> String {
    transport.as_wire().to_string()
}

#[uniffi::export]
pub fn transport_kinds() -> Vec<crate::config::TransportKind> {
    crate::config::TransportKind::all()
}

/// Whether a string that should be the *name* of a credential is a credential.
///
/// Exported so a settings text field can say so as it is typed, rather than
/// letting somebody paste a key, click Save and get an error. The rule lives in
/// the core because it is the same rule the file parser applies, and two copies
/// of it would drift.
#[uniffi::export]
pub fn looks_like_a_secret(value: String) -> bool {
    crate::config::looks_like_a_secret(&value)
}

struct State {
    file: ConfigFile,
    /// The credential names the platform's store actually has, last time the
    /// shell looked.
    ///
    /// Held here rather than fetched, because fetching is a Keychain call and
    /// the Keychain is not something this crate knows about. The shell asks
    /// [`Zer0Config::credential_refs`] what to look for, looks, and reports
    /// back. Names only — no value ever crosses this boundary.
    available_credentials: Vec<String>,
}

/// Handle on the configuration file, held by the shell for the run.
#[derive(uniffi::Object)]
pub struct Zer0Config {
    state: Mutex<State>,
}

impl Zer0Config {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().expect("config lock poisoned")
    }
}

#[uniffi::export]
impl Zer0Config {
    /// Read the file at `path`, or start from defaults if there is none.
    #[uniffi::constructor]
    pub fn open(path: String) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(State {
                file: ConfigFile::open(PathBuf::from(path)),
                available_credentials: Vec::new(),
            }),
        })
    }

    /// A configuration from text, with no file behind it. For tests, and for a
    /// window that has to render something before anything is on disk.
    #[uniffi::constructor]
    pub fn from_text(toml: String) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(State {
                file: ConfigFile::from_text(&toml),
                available_credentials: Vec::new(),
            }),
        })
    }

    pub fn path(&self) -> String {
        self.lock().file.path().to_string_lossy().into_owned()
    }

    /// Whether there is a file at all. False is a first launch, and the
    /// settings window shows an empty state rather than an error.
    pub fn exists(&self) -> bool {
        self.lock().file.exists()
    }

    pub fn config(&self) -> Config {
        self.lock().file.config().clone()
    }

    pub fn diagnostics(&self) -> Vec<ConfigDiagnostic> {
        self.lock().file.diagnostics().to_vec()
    }

    /// Whether the file on disk right now could be read.
    ///
    /// False means [`Zer0Config::config`] is the last one that worked and the
    /// interface has to say so, rather than showing settings that do not match
    /// the file somebody is looking at in another window.
    pub fn is_readable(&self) -> bool {
        self.lock().file.is_readable()
    }

    /// Re-read the file. `true` when something a caller cares about changed.
    ///
    /// Called by the shell's watcher and again when the app comes back to the
    /// front. `false` for the common case of a touch with no change, so
    /// reconnecting MCP servers can be hung off the return value without
    /// tearing them down every time an editor saves.
    pub fn reload(&self) -> bool {
        self.lock().file.reload()
    }

    /// Every credential name the file mentions.
    ///
    /// The shell's shopping list for the Keychain, and the only thing it needs
    /// to ask about. Nothing here is a value.
    pub fn credential_refs(&self) -> Vec<String> {
        self.lock().file.config().credential_refs()
    }

    /// Which of those names the platform's store actually has.
    ///
    /// **Names, not values.** A secret never crosses this call, and there is no
    /// call on this object that takes one — which is what makes "a key cannot
    /// reach the config file" a property of the interface rather than a rule
    /// somebody has to remember.
    pub fn set_available_credentials(&self, names: Vec<String>) {
        self.lock().available_credentials = names;
    }

    pub fn provider_readiness(&self, id: String) -> Readiness {
        let state = self.lock();
        state
            .file
            .config()
            .provider_readiness(&id, &state.available_credentials)
    }

    pub fn mcp_readiness(&self, id: String) -> Readiness {
        let state = self.lock();
        state
            .file
            .config()
            .mcp_readiness(&id, &state.available_credentials)
    }

    /// Which provider a new chat opens on, given what is actually usable.
    pub fn effective_provider(&self) -> Option<ProviderConfig> {
        let state = self.lock();
        state
            .file
            .config()
            .effective_provider(&state.available_credentials)
            .cloned()
    }

    // MARK: - Changing it

    pub fn set_default_provider(&self, id: Option<String>) -> Result<(), ConfigError> {
        self.lock().file.set_default_provider(id.as_deref())
    }

    pub fn upsert_provider(&self, provider: ProviderConfig) -> Result<(), ConfigError> {
        self.lock().file.upsert_provider(&provider)
    }

    pub fn remove_provider(&self, id: String) -> Result<(), ConfigError> {
        self.lock().file.remove_provider(&id)
    }

    pub fn set_provider_enabled(&self, id: String, enabled: bool) -> Result<(), ConfigError> {
        self.lock().file.set_provider_enabled(&id, enabled)
    }

    pub fn upsert_mcp_server(&self, server: McpServerConfig) -> Result<(), ConfigError> {
        self.lock().file.upsert_mcp_server(&server)
    }

    pub fn remove_mcp_server(&self, id: String) -> Result<(), ConfigError> {
        self.lock().file.remove_mcp_server(&id)
    }

    pub fn set_mcp_server_enabled(&self, id: String, enabled: bool) -> Result<(), ConfigError> {
        self.lock().file.set_mcp_server_enabled(&id, enabled)
    }

    /// Write the commented example, for a machine that has no file yet.
    /// Refuses when one already exists.
    pub fn write_example(&self) -> Result<(), ConfigError> {
        self.lock().file.write_example()
    }
}
