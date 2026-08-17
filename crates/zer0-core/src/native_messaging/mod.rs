//! Finding the program an extension asked to talk to.
//!
//! `chrome.runtime.connectNative("com.example.thing")` names an *application
//! id*, not a program. What turns one into the other is a JSON file in a
//! directory a browser owns, written by whatever installed the desktop
//! application, naming an absolute path and the extensions allowed to reach it.
//! Chrome calls that file a native messaging host manifest. This module reads
//! them, and its whole job is refusing.
//!
//! ## The identity that is compared, and why it cannot be chosen
//!
//! `allowed_origins` authorises by Chrome Web Store id — `chrome-extension://
//! aeblfdkhhhdcdjpifhhbdiojplfjncoa/`. An extension's origin in this browser is
//! `webkit-extension://<uuid>`, and WebKit mints that uuid per launch, so no
//! stable origin of ours could ever be written into anybody's manifest and
//! there is nothing to compare origins against.
//!
//! What is compared is **the id this browser derived from the package's signing
//! key at install time**. `ext::crx::parse` refuses a package whose declared id
//! is not the first 16 bytes of the SHA-256 of a public key the package carries
//! a proof for, and `install_extension` names the directory after that verified
//! id. So a package cannot choose its id: claiming 1Password's would mean
//! finding a key whose digest collides with 1Password's over 128 bits. The two
//! locks on that are
//! `crx.rs::a_package_claiming_someone_elses_id_is_rejected` and
//! `crx.rs::a_package_none_of_whose_keys_derive_its_id_is_still_rejected`.
//!
//! What that does **not** cover is stated in ADR-0105 rather than implied here:
//! `installed_extensions` reads the directory name back and does not re-derive
//! it, so anybody who can write inside this browser's own profile can put code
//! under a name the signature check would have refused. That is the same
//! attacker who can rewrite the session database or add a registration of their
//! own, and it is declared debt rather than something this file closes.
//!
//! ## Why the match cannot be loosened later
//!
//! [`ExtensionId`] is a newtype whose only constructor is [`ExtensionId::parse`],
//! which takes exactly 32 characters drawn from `a`..`p` and nothing else. A
//! wildcard, a prefix, a suffix and an empty string have **no representation**,
//! so "any extension may talk to any host" is not a state this code can reach
//! by being simplified. That is the guarantee; the comparison being `==` is
//! merely how it is spelled today.

mod ledger;
mod wire;

use std::fs;
use std::path::{Component, Path, PathBuf};

pub use ledger::{NativeHostDecision, NativeHostLedger};
pub use wire::{LENGTH_PREFIX_BYTES, MAX_NATIVE_MESSAGE_BYTES, NativeMessageStep, frame, step};

/// The directory every browser keeps its registrations in, under whatever it
/// calls its own support directory. Chrome's name, adopted by everybody.
pub const HOST_DIRECTORY_NAME: &str = "NativeMessagingHosts";

/// The permission an extension must hold before any of this happens.
pub const NATIVE_MESSAGING_PERMISSION: &str = "nativeMessaging";

/// The most a registration file may be. A JSON file naming one path and a
/// handful of ids is a few hundred bytes; this is four orders of magnitude of
/// headroom and still bounds a file somebody replaced with a disk image.
const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;

/// The most an application id may be, as a name on disk.
const MAX_APPLICATION_ID_CHARS: usize = 255;

/// A Chrome Web Store extension id.
///
/// Exactly 32 characters drawn from `a`..`p` — Chrome's encoding of the first
/// 16 bytes of the SHA-256 of a signing key. [`Self::parse`] is the only
/// constructor, so there is no value of this type standing for "any
/// extension", and no way to obtain one by relaxing a comparison.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtensionId(String);

impl ExtensionId {
    pub fn parse(value: &str) -> Option<Self> {
        if value.len() != 32 || !value.bytes().all(|b| (b'a'..=b'p').contains(&b)) {
            return None;
        }
        Some(Self(value.to_string()))
    }

    /// The origin Chrome writes into `allowed_origins`, read back.
    ///
    /// Deliberately strict about the whole shape rather than about the middle
    /// of it: the scheme is fixed, the trailing slash is required, and there is
    /// nowhere for a path, a port or a query to sit. `chrome-extension://*/`
    /// simply is not an id and comes back `None`.
    fn from_origin(value: &str) -> Option<Self> {
        let rest = value.strip_prefix("chrome-extension://")?;
        let id = rest.strip_suffix('/')?;
        Self::parse(id)
    }
}

/// A browser whose registrations this one is willing to read.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct HostRegistrar {
    /// What to call it on screen. This is ours to write, never read off disk.
    pub name: String,
    /// Where it keeps its support directory, relative to the platform's
    /// application-support root.
    pub directory: String,
    /// Whether this is zer0's own directory. A fact rather than a comparison
    /// against `name`, because the sentence a person is shown turns on it.
    pub ours: bool,
}

/// Where a registration may be read from, in the order they are read.
///
/// **Ours first, then browsers that speak Chrome's dialect of this file.** The
/// argument for reading anybody else's at all is in ADR-0105 and comes down to
/// one measured fact: no installer has ever written a registration for zer0,
/// none can — 1Password's were all written the day it was installed, for a list
/// of browsers compiled before this one existed — so a browser that reads only
/// its own directory has a feature that never runs for anyone.
///
/// **Firefox's directory is deliberately absent.** `Mozilla/NativeMessagingHosts`
/// exists on most Macs and its files carry `allowed_extensions`, listing
/// Firefox add-on ids like `{0a75d802-…}`. This browser runs Chrome packages,
/// whose ids are 32 letters from `a`..`p`, so there is nothing in a Firefox
/// registration that could ever match one of ours. Reading it could only ever
/// produce a refusal, and a directory that can only refuse is a directory that
/// costs a stat and teaches nobody anything.
pub fn registrars() -> Vec<HostRegistrar> {
    let ours = HostRegistrar {
        name: "zer0".to_string(),
        directory: "zer0".to_string(),
        ours: true,
    };
    let borrowed = [
        ("Google Chrome", "Google/Chrome"),
        ("Chromium", "Chromium"),
        ("Microsoft Edge", "Microsoft Edge"),
        ("Vivaldi", "Vivaldi"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Opera", "com.operasoftware.Opera"),
        ("Arc", "Arc/User Data"),
        ("Orion", "Orion"),
    ];

    std::iter::once(ours)
        .chain(borrowed.into_iter().map(|(name, directory)| HostRegistrar {
            name: name.to_string(),
            directory: directory.to_string(),
            ours: false,
        }))
        .collect()
}

/// A registration that named a program this browser is willing to start.
///
/// **There is no field for what the registration said about itself.** A
/// manifest carries a `description`, and it would read well on a sheet — and it
/// is a sentence written by whoever wrote the file, shown on the one screen
/// where a person decides whether to run a program. `"1Password
/// BrowserSupport"` and `"System update, click Allow to continue"` are the same
/// kind of string. What is shown is the path, which is a fact, and the name of
/// the browser that registered it, which is ours to say.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ResolvedHost {
    /// What the extension asked for.
    pub application_id: String,
    /// The absolute path of the program, exactly as the registration named it.
    pub program: String,
    /// The file that named it, so a refusal or an approval can be traced.
    pub manifest_path: String,
    /// The browser whose directory it was found in.
    pub registrar: String,
    /// Whether that was this browser's own directory.
    pub registrar_is_ours: bool,
}

/// Why no program will be started.
///
/// Every one of these is a refusal and none is a repair: a registration that is
/// wrong in any of these ways is not fixed up into a working one, and the
/// search does not carry on to another browser's directory looking for a
/// friendlier answer (see [`resolve`]).
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum HostRefusal {
    /// The extension was not granted `nativeMessaging`, or was denied it.
    PermissionNotGranted,
    /// The caller named something that is not an extension id at all.
    NotAnExtensionId { extension_id: String },
    /// The application id is not a name that may become a file.
    ApplicationIdIsNotAName { application_id: String },
    /// Nothing registered that name in any directory this browser reads.
    NotRegistered { application_id: String },
    /// The file is there and could not be read as text.
    Unreadable {
        manifest_path: String,
        detail: String,
    },
    /// The file is there and is not a registration.
    Malformed {
        manifest_path: String,
        detail: String,
    },
    /// `type` was something other than `stdio`. Chrome has never defined a
    /// second value and a browser that guessed at one would be inventing a
    /// protocol.
    NotStdio { manifest_path: String, kind: String },
    /// `path` was not an absolute path made only of ordinary components.
    ProgramNotNamedAbsolutely {
        manifest_path: String,
        program: String,
    },
    /// `path` named something that is not there.
    ProgramMissing {
        manifest_path: String,
        program: String,
    },
    /// `path` named a symbolic link, so the program that would run is not the
    /// program the person would be shown.
    ProgramIsALink {
        manifest_path: String,
        program: String,
    },
    /// `path` named something that is not an executable file.
    ProgramNotExecutable {
        manifest_path: String,
        program: String,
    },
    /// The registration exists and does not list this extension.
    NotForThisExtension { manifest_path: String },
    /// Somebody was asked about this program and said no.
    PersonRefused { program: String },
}

/// The sentence for a refusal.
///
/// In the core because it is what a person reads, and what a refusal costs
/// somebody is not something two platforms get to disagree about (ADR-0028).
/// Every one of them names the file or the path, because the only useful thing
/// a person can do with any of this is go and look.
pub fn refusal_sentence(refusal: &HostRefusal) -> String {
    match refusal {
        HostRefusal::PermissionNotGranted => {
            "This extension was not allowed to talk to programs on this Mac.".to_string()
        }
        HostRefusal::NotAnExtensionId { extension_id } => {
            format!("“{extension_id}” is not an extension this browser installed.")
        }
        HostRefusal::ApplicationIdIsNotAName { application_id } => {
            format!("“{application_id}” is not a name a program can be registered under.")
        }
        HostRefusal::NotRegistered { application_id } => format!(
            "No program on this Mac is registered as “{application_id}”. \
             The application it belongs to may not be installed."
        ),
        HostRefusal::Unreadable {
            manifest_path,
            detail,
        } => format!("{manifest_path} could not be read: {detail}."),
        HostRefusal::Malformed {
            manifest_path,
            detail,
        } => format!("{manifest_path} is not a native messaging registration: {detail}."),
        HostRefusal::NotStdio {
            manifest_path,
            kind,
        } => format!(
            "{manifest_path} asks to be reached over “{kind}”, and zer0 only speaks to a \
             program over its input and output."
        ),
        HostRefusal::ProgramNotNamedAbsolutely {
            manifest_path,
            program,
        } => format!("{manifest_path} names “{program}”, which is not an absolute path."),
        HostRefusal::ProgramMissing {
            manifest_path,
            program,
        } => format!("{manifest_path} names {program}, which is not there."),
        HostRefusal::ProgramIsALink {
            manifest_path,
            program,
        } => format!(
            "{manifest_path} names {program}, which is a link to something else. zer0 starts \
             the program it can name."
        ),
        HostRefusal::ProgramNotExecutable {
            manifest_path,
            program,
        } => format!("{manifest_path} names {program}, which is not a program."),
        HostRefusal::NotForThisExtension { manifest_path } => {
            format!("{manifest_path} does not list this extension.")
        }
        HostRefusal::PersonRefused { program } => {
            format!("You did not allow this extension to start {program}.")
        }
    }
}

/// The question a person is asked before a program is started.
///
/// Every string here is composed in this file. Nothing in it is read out of the
/// registration except the two paths, which are facts about the filesystem
/// rather than prose somebody wrote — see [`ResolvedHost`] for why the
/// registration's own `description` never gets this far.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct NativeHostPrompt {
    pub title: String,
    /// The program that will run, absolute, exactly as it will be started.
    pub program: String,
    /// Who registered it, which is the fact that makes this worth asking.
    pub provenance: String,
    /// What granting this costs, in the second person.
    pub detail: String,
    /// The file that named the program, for anybody who wants to go and look.
    pub manifest_path: String,
}

/// How much of an extension's own name is shown.
///
/// A name comes out of somebody else's package, and this sheet is the one
/// screen where a person decides whether to run a program. A name long enough
/// to push the program's path off the sheet is a name that hid it.
const MAX_EXTENSION_NAME_CHARS: usize = 60;

/// Compose the question.
///
/// In the core because what a grant costs somebody is not something two
/// platforms get to disagree about — the same reason ADR-0028 puts the
/// permission vocabulary here. The shell draws weight, colour and order.
pub fn prompt(extension_name: &str, host: &ResolvedHost) -> NativeHostPrompt {
    let mut name: String = extension_name
        .chars()
        .filter(|c| !c.is_control())
        .take(MAX_EXTENSION_NAME_CHARS)
        .collect();
    if name.trim().is_empty() {
        name = "This extension".to_string();
    }

    let provenance = if host.registrar_is_ours {
        format!(
            "“{}” was registered with zer0 to run this program.",
            host.application_id
        )
    } else {
        // The sentence that earns the question. A registration in another
        // browser's directory is that browser's answer, not this one's, and a
        // person who never installed anything for zer0 should be told that this
        // is where the program came from.
        format!(
            "“{}” is registered with {}, not with zer0. zer0 found the program there.",
            host.application_id, host.registrar
        )
    };

    NativeHostPrompt {
        title: format!("{name} wants to start a program on this Mac"),
        program: host.program.clone(),
        provenance,
        detail: "It will run outside the browser, as you, for as long as the extension \
                 keeps talking to it. zer0 cannot see what it then does."
            .to_string(),
        manifest_path: host.manifest_path.clone(),
    }
}

/// The origin a program is told is calling it.
///
/// Chrome's shape exactly: `chrome-extension://<id>/`. `None` for anything
/// that is not an extension id, so there is no way to hand a program a name
/// this browser never verified.
pub fn caller_origin(extension_id: &str) -> Option<String> {
    ExtensionId::parse(extension_id).map(|id| format!("chrome-extension://{}/", id.0))
}

// Ffi-gated, and the three gates below it travel with it: the binding layer
// is the only caller, because starting a process is the shell's to do. The
// bare core still resolves, frames and remembers — the parts two platforms
// could not disagree about.
/// What is to happen about one `connectNative` or `sendNativeMessage`.
#[cfg(feature = "ffi")]
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum NativeHostOutcome {
    /// Start this program. Somebody has already said yes to this extension
    /// starting this one.
    Start { host: ResolvedHost },
    /// This is the program, and nobody has been asked about it. Nothing starts
    /// until somebody answers.
    Ask { host: ResolvedHost },
    /// Nothing starts, and this is what to say about it.
    Refused {
        refusal: HostRefusal,
        sentence: String,
    },
}

/// The one door. Everything between an extension naming an application id and
/// a process existing goes through here.
///
/// Three gates in one place, deliberately, because each of them enforced
/// somewhere else is a way for the other two to be forgotten:
///
/// 1. **The extension holds `nativeMessaging`.** WebKit gates its own
///    `sendNativeMessage` on the permission, but nothing gates the delegate:
///    the callback arrives whatever the context was told, and an extension
///    whose grant was revoked from the Extensions screen would otherwise keep
///    starting programs. ADR-0028's ledger is the authority, not the engine's
///    copy of it.
/// 2. **A registration names the program and lists this extension**
///    ([`resolve`]).
/// 3. **Somebody said yes to this program.** Absence is *not asked*, and not
///    asked is not yes.
#[cfg(feature = "ffi")]
pub fn outcome(
    application_support: &Path,
    consent: Option<&crate::extension_permissions::ConsentDecision>,
    ledger: &NativeHostLedger,
    extension_id: &str,
    application_id: &str,
) -> NativeHostOutcome {
    let granted = consent.is_some_and(|decision| {
        decision
            .granted_permissions
            .iter()
            .any(|permission| permission == NATIVE_MESSAGING_PERMISSION)
    });
    if !granted {
        return refused(HostRefusal::PermissionNotGranted);
    }

    let host = match resolve(application_support, application_id, extension_id) {
        Ok(host) => host,
        Err(refusal) => return refused(refusal),
    };

    match ledger.decision(extension_id, &host.program) {
        Some(decision) if decision.allowed => NativeHostOutcome::Start { host },
        Some(_) => refused(HostRefusal::PersonRefused {
            program: host.program,
        }),
        None => NativeHostOutcome::Ask { host },
    }
}

#[cfg(feature = "ffi")]
fn refused(refusal: HostRefusal) -> NativeHostOutcome {
    let sentence = refusal_sentence(&refusal);
    NativeHostOutcome::Refused { refusal, sentence }
}

/// Find the program `application_id` names, for `extension_id`.
///
/// **The search stops at the first directory holding a file with that name.**
/// A registration is an answer, and a second directory's file is a different
/// answer to the same question; carrying on because the first one said no would
/// be shopping for a yes. So every refusal below is terminal, including the
/// dull ones — a malformed file in Chrome's directory refuses the call rather
/// than being stepped over on the way to Vivaldi's.
///
/// `application_support` is the platform's application-support root and is
/// supplied by the host, because that is the one thing here two platforms
/// genuinely disagree about. Which directories are read, in what order, and
/// what is done with what is in them, is this side's.
pub fn resolve(
    application_support: &Path,
    application_id: &str,
    extension_id: &str,
) -> Result<ResolvedHost, HostRefusal> {
    let wanted = ExtensionId::parse(extension_id).ok_or_else(|| HostRefusal::NotAnExtensionId {
        extension_id: extension_id.to_string(),
    })?;
    let file = application_file_name(application_id).ok_or_else(|| {
        HostRefusal::ApplicationIdIsNotAName {
            application_id: application_id.to_string(),
        }
    })?;

    for registrar in registrars() {
        let path = application_support
            .join(&registrar.directory)
            .join(HOST_DIRECTORY_NAME)
            .join(&file);
        if !path.is_file() {
            continue;
        }
        return read(&path, &registrar, application_id, &wanted);
    }

    Err(HostRefusal::NotRegistered {
        application_id: application_id.to_string(),
    })
}

/// The file name an application id becomes, or `None` for an id that may not
/// become one.
///
/// This is the check that stops `../../../../etc/passwd` and
/// `../../Google/Chrome/NativeMessagingHosts/com.1password.1password` from
/// being names: the id arrives from an extension's own JavaScript and is about
/// to be joined onto a path. Chrome's own rule, which is also the tightest
/// thing that still accepts every real host id: lowercase letters, digits,
/// underscores and dots, with no run of two dots and none at either end.
fn application_file_name(application_id: &str) -> Option<String> {
    if application_id.is_empty() || application_id.len() > MAX_APPLICATION_ID_CHARS {
        return None;
    }
    if !application_id
        .bytes()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'.')
    {
        return None;
    }
    if application_id.starts_with('.')
        || application_id.ends_with('.')
        || application_id.contains("..")
    {
        return None;
    }
    Some(format!("{application_id}.json"))
}

/// Read one registration and decide whether it names a program we may start.
fn read(
    path: &Path,
    registrar: &HostRegistrar,
    application_id: &str,
    wanted: &ExtensionId,
) -> Result<ResolvedHost, HostRefusal> {
    let manifest_path = path.to_string_lossy().into_owned();
    let unreadable = |detail: String| HostRefusal::Unreadable {
        manifest_path: manifest_path.clone(),
        detail,
    };
    let malformed = |detail: &str| HostRefusal::Malformed {
        manifest_path: manifest_path.clone(),
        detail: detail.to_string(),
    };

    // Sized before it is read, because a file in a directory anything on this
    // machine can write to is hostile input like any other (ADR-0024), and
    // `read_to_string` on a hundred-gigabyte file is a browser that stops.
    let size = fs::metadata(path)
        .map_err(|e| unreadable(e.to_string()))?
        .len();
    if size > MAX_MANIFEST_BYTES {
        return Err(malformed("the file is far too big to be a registration"));
    }
    let text = fs::read_to_string(path).map_err(|e| unreadable(e.to_string()))?;
    let json: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| malformed(&e.to_string()))?;

    let object = json
        .as_object()
        .ok_or_else(|| malformed("it is not an object"))?;

    match object.get("type").and_then(|v| v.as_str()) {
        Some("stdio") => {}
        Some(kind) => {
            return Err(HostRefusal::NotStdio {
                manifest_path,
                kind: kind.to_string(),
            });
        }
        None => return Err(malformed("it does not say how to reach the program")),
    }

    let program = object
        .get("path")
        .and_then(|v| v.as_str())
        .ok_or_else(|| malformed("it does not name a program"))?
        .to_string();

    // Every check below is on the path as written. Nothing is normalised, no
    // link is followed and no relative path is resolved against anything,
    // because the path is what a person is shown and what is shown has to be
    // what runs.
    let candidate = PathBuf::from(&program);
    let ordinary = candidate
        .components()
        .all(|component| matches!(component, Component::RootDir | Component::Normal(_)));
    if !candidate.is_absolute() || !ordinary {
        return Err(HostRefusal::ProgramNotNamedAbsolutely {
            manifest_path,
            program,
        });
    }

    let metadata = fs::symlink_metadata(&candidate).map_err(|_| HostRefusal::ProgramMissing {
        manifest_path: manifest_path.clone(),
        program: program.clone(),
    })?;
    if metadata.file_type().is_symlink() {
        return Err(HostRefusal::ProgramIsALink {
            manifest_path,
            program,
        });
    }
    if !metadata.is_file() || !is_executable(&metadata) {
        return Err(HostRefusal::ProgramNotExecutable {
            manifest_path,
            program,
        });
    }

    if !allows(object, wanted) {
        return Err(HostRefusal::NotForThisExtension { manifest_path });
    }

    Ok(ResolvedHost {
        application_id: application_id.to_string(),
        program,
        manifest_path,
        registrar: registrar.name.clone(),
        registrar_is_ours: registrar.ours,
    })
}

/// Whether the metadata says this file may be started: any of the three
/// execute bits.
///
/// Off unix there is no bit to read, and a program this browser cannot prove
/// may run is not a program it starts — `false` is the fail-closed answer, not
/// a guess at the platform's own rules.
#[cfg(unix)]
fn is_executable(metadata: &fs::Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;
    metadata.permissions().mode() & 0o111 != 0
}

#[cfg(not(unix))]
fn is_executable(_metadata: &fs::Metadata) -> bool {
    false
}

/// Whether this registration authorises this extension.
///
/// An entry that is not exactly `chrome-extension://<32 letters a..p>/` is
/// dropped rather than interpreted — including `chrome-extension://*/`, which
/// is the one that matters, and Firefox's `allowed_extensions`, which is a
/// different key and is not read at all. A list that is empty once the
/// unreadable entries are gone authorises nobody, which is the fail-closed
/// answer and not an oversight.
fn allows(object: &serde_json::Map<String, serde_json::Value>, wanted: &ExtensionId) -> bool {
    let Some(origins) = object.get("allowed_origins").and_then(|v| v.as_array()) else {
        return false;
    };
    origins
        .iter()
        .filter_map(|v| v.as_str())
        .filter_map(ExtensionId::from_origin)
        .any(|allowed| allowed == *wanted)
}

#[cfg(test)]
#[path = "host_tests.rs"]
mod tests;
