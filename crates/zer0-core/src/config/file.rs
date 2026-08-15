//! The file as a live thing: read it, watch it change, change it back.
//!
//! Three rules hold this together, and all three are about not making somebody
//! else's mistake worse.
//!
//! **A file that does not parse never replaces one that did.** An editor saving
//! is not atomic in most editors — the file is truncated and then written — so
//! "read a config with nothing in it" is a thing that genuinely happens, several
//! times a minute, while somebody edits. Reacting to it by dropping every
//! provider would make the browser flicker between configured and not. So the
//! last configuration that parsed stays in force, and what changes is the
//! diagnostics.
//!
//! **We never write over a file we could not read.** This is ADR-0017's rule
//! for `session.sqlite`, and it matters more here because this file is
//! hand-written: if there is a typo on line 3, a click in the settings window
//! must not rewrite the file from a model that never saw lines 4 to 90. The
//! edit is refused and says why.
//!
//! **An edit re-reads first.** Between the settings window opening and a
//! checkbox being clicked, the file may have been edited in a terminal or
//! pulled from a dotfiles repository. Writing what was loaded a minute ago
//! would silently revert it.
//!
//! What is *not* here is when to reload. That is the shell's: a file watcher is
//! `DispatchSource` on one platform and `inotify` on another, and neither
//! belongs in a crate that also runs on the other one.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use toml_edit::DocumentMut;

use super::edit::{self, EditRefusal};
use super::parse::parse;
use super::paths;
use super::{Config, ConfigDiagnostic, McpServerConfig, ProviderConfig};

/// Why a change to the file did not happen.
///
/// Three, because the caller says something different for each: `Io` is the
/// disk, `Refused` is the request, and `Unreadable` is the file — and only the
/// last one means "go and fix your config first".
#[derive(Debug, thiserror::Error)]
#[cfg_attr(feature = "ffi", derive(uniffi::Error))]
#[cfg_attr(feature = "ffi", uniffi(flat_error))]
pub enum ConfigError {
    #[error("the config file could not be written: {message}")]
    Io { message: String },
    #[error("{message}")]
    Refused { message: String },
    #[error(
        "zer0 will not change the config file while it has an error in it, \
         because it would have to rewrite the parts it could not read. {message}"
    )]
    Unreadable { message: String },
}

impl From<EditRefusal> for ConfigError {
    fn from(refusal: EditRefusal) -> Self {
        Self::Refused {
            message: refusal.message(),
        }
    }
}

impl From<io::Error> for ConfigError {
    fn from(error: io::Error) -> Self {
        Self::Io {
            message: error.to_string(),
        }
    }
}

/// The configuration file, and the last configuration it successfully gave us.
pub struct ConfigFile {
    path: PathBuf,
    /// Exactly the bytes last read, so a reload can tell "changed" from
    /// "touched". Editors and file watchers produce plenty of the latter.
    text: String,
    config: Config,
    diagnostics: Vec<ConfigDiagnostic>,
    /// Whether the *file as it is on disk right now* could be read. False means
    /// [`ConfigFile::config`] is the last one that worked, and that nothing may
    /// be written.
    readable: bool,
}

impl ConfigFile {
    /// Open the file at `path`, or start from defaults if it is not there.
    ///
    /// Never fails. A browser must not refuse to launch because of a config
    /// file, and a missing one is the normal state on a machine nobody has
    /// configured yet — not an error, not a warning, not a prompt.
    pub fn open(path: impl Into<PathBuf>) -> Self {
        let mut file = Self {
            path: path.into(),
            text: String::new(),
            config: Config::default(),
            diagnostics: Vec::new(),
            readable: true,
        };
        file.read();
        file
    }

    /// A configuration with no file behind it, for tests and for a run started
    /// with configuration switched off.
    pub fn from_text(text: &str) -> Self {
        let mut file = Self {
            path: PathBuf::new(),
            text: String::new(),
            config: Config::default(),
            diagnostics: Vec::new(),
            readable: true,
        };
        file.absorb(text.to_string());
        file
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn diagnostics(&self) -> &[ConfigDiagnostic] {
        &self.diagnostics
    }

    /// Whether what is on disk right now could be read.
    ///
    /// When this is false the settings window is showing the last configuration
    /// that worked, and it has to say so — the same reasoning as
    /// `BrowserModel.loadError`. Somebody editing a config in another window
    /// and seeing settings that do not match it should be told which one is
    /// live.
    pub fn is_readable(&self) -> bool {
        self.readable
    }

    /// Whether the file is on disk at all. A first launch has no file, and the
    /// settings window offers to write the commented example rather than
    /// creating one nobody asked for.
    pub fn exists(&self) -> bool {
        self.path.exists()
    }

    /// Re-read, and say whether anything a caller cares about changed.
    ///
    /// `false` means the bytes are identical to last time, which is most of
    /// what a file watcher reports: editors touch, `git` restores files to the
    /// content they already had, and a save writes twice. Answering honestly
    /// here is what keeps the shell from tearing down every MCP connection
    /// because somebody hit save with no changes.
    pub fn reload(&mut self) -> bool {
        let before = (self.config.clone(), self.diagnostics.clone(), self.readable);
        self.read();
        (self.config.clone(), self.diagnostics.clone(), self.readable) != before
    }

    fn read(&mut self) {
        match fs::read_to_string(&self.path) {
            Ok(text) => self.absorb(text),
            // Not there is not a failure, and it must not be reported as one:
            // it is what every machine looks like before anybody configures it.
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                self.text = String::new();
                self.config = Config::default();
                self.diagnostics = Vec::new();
                self.readable = true;
            }
            // There and unreadable — no permission, a directory, a dead
            // symlink. Keep whatever was working and say what happened.
            Err(error) => {
                self.readable = false;
                self.diagnostics = vec![ConfigDiagnostic::error(
                    0,
                    0,
                    format!("{} could not be read: {error}", self.path.display()),
                )];
            }
        }
    }

    fn absorb(&mut self, text: String) {
        match parse(&text) {
            Ok(parsed) => {
                self.text = text;
                self.config = parsed.config;
                self.diagnostics = parsed.diagnostics;
                self.readable = true;
            }
            // The configuration is deliberately left alone. See the note at the
            // top: half-written files are ordinary, and flickering between
            // configured and not is worse than being briefly out of date.
            Err(diagnostic) => {
                self.text = text;
                self.diagnostics = vec![diagnostic];
                self.readable = false;
            }
        }
    }

    // MARK: - Changing it

    pub fn set_default_provider(&mut self, id: Option<&str>) -> Result<(), ConfigError> {
        self.apply(|document| edit::set_default_provider(document, id))
    }

    pub fn upsert_provider(&mut self, provider: &ProviderConfig) -> Result<(), ConfigError> {
        self.apply(|document| edit::upsert_provider(document, provider))
    }

    pub fn remove_provider(&mut self, id: &str) -> Result<(), ConfigError> {
        self.apply(|document| edit::remove_entry(document, "provider", id))
    }

    pub fn set_provider_enabled(&mut self, id: &str, enabled: bool) -> Result<(), ConfigError> {
        self.apply(|document| edit::set_enabled(document, "provider", id, enabled))
    }

    pub fn upsert_mcp_server(&mut self, server: &McpServerConfig) -> Result<(), ConfigError> {
        self.apply(|document| edit::upsert_mcp_server(document, server))
    }

    pub fn remove_mcp_server(&mut self, id: &str) -> Result<(), ConfigError> {
        self.apply(|document| edit::remove_entry(document, "mcp_server", id))
    }

    pub fn set_mcp_server_enabled(&mut self, id: &str, enabled: bool) -> Result<(), ConfigError> {
        self.apply(|document| edit::set_enabled(document, "mcp_server", id, enabled))
    }

    /// Put the commented example on disk, for somebody who has never seen one.
    ///
    /// Refuses when a file is already there. "Start from an example" must never
    /// be able to mean "lose what I wrote", and a confirmation dialog is a worse
    /// answer than an operation that cannot do the damage.
    pub fn write_example(&mut self) -> Result<(), ConfigError> {
        if self.exists() {
            return Err(ConfigError::Refused {
                message: format!(
                    "{} already exists. zer0 will not write over it.",
                    self.path.display()
                ),
            });
        }
        paths::write_atomically(&self.path, super::example_config())?;
        self.read();
        Ok(())
    }

    /// Re-read, refuse if unreadable, apply, write, re-read.
    ///
    /// The re-read at the front is what keeps a settings click from reverting
    /// an edit made in a terminal thirty seconds ago; the one at the back is
    /// what makes `config()` agree with the disk before this returns, so the
    /// interface never draws a state that is already stale.
    fn apply<F>(&mut self, change: F) -> Result<(), ConfigError>
    where
        F: FnOnce(&mut DocumentMut) -> Result<(), EditRefusal>,
    {
        self.read();
        if !self.readable {
            return Err(ConfigError::Unreadable {
                message: self
                    .diagnostics
                    .first()
                    .map(ConfigDiagnostic::describe)
                    .unwrap_or_else(|| "The file could not be read.".to_string()),
            });
        }

        let mut document =
            self.text
                .parse::<DocumentMut>()
                .map_err(|error| ConfigError::Unreadable {
                    message: error.to_string(),
                })?;
        change(&mut document)?;

        paths::write_atomically(&self.path, &document.to_string())?;
        self.read();
        Ok(())
    }
}
