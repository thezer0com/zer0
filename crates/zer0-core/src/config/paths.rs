//! Where the file lives, and how to replace it without breaking a symlink.
//!
//! # `~/.config/zer0/config.toml`, not Application Support
//!
//! `session.sqlite` lives in `~/Library/Application Support/zer0/` and belongs
//! there: it is a database this app owns, nobody opens it by hand, and Apple's
//! guidance for app-managed data is exactly that directory.
//!
//! This file is the opposite kind of thing. Its whole purpose is to be opened
//! by hand, committed, and symlinked out of a dotfiles checkout. And nobody
//! symlinks into `~/Library/Application Support` — every dotfiles tool in use,
//! `stow`, `chezmoi`, `yadm`, home-manager, targets `~/.config`. Putting a file
//! meant for version control somewhere no version-control workflow reaches
//! would be choosing the convention over the reason the convention exists.
//!
//! Three more things follow from the same argument:
//!
//! - `~/Library` is **hidden in Finder**. A non-technical person told "your
//!   settings are in a file" has to be able to find the file.
//! - Application Support is what migration assistants and "clean up this app"
//!   tools sweep. A hand-written config disappearing into that is a bad day.
//! - The applications that have a file like this one — `git`, `ssh`, `nvim`,
//!   `ghostty`, `zed`, `wezterm` — all put it under `~/.config` **on macOS**,
//!   because their users asked them to. That is the precedent that matters
//!   here, not the one for opaque state.
//!
//! `XDG_CONFIG_HOME` is honoured, because the people who set it are precisely
//! the people this file is for.
//!
//! # Replacing a file that is a symlink
//!
//! This is the part that is easy to get quietly wrong. Once the settings window
//! can write, the ordinary durable-write recipe — write a temporary file,
//! rename it over the target — **destroys a dotfiles setup**: the rename
//! replaces the symlink at `~/.config/zer0/config.toml` with a regular file,
//! and the repository copy it pointed at is orphaned. Everything keeps working
//! until the next `git status` shows no changes and the next machine gets an
//! old config.
//!
//! So the target is resolved through its symlinks first, and the temporary file
//! is written next to the *resolved* file. The link is never touched, the
//! rename lands on the real file inside the repository, and it is still atomic
//! because the temporary file is on the same filesystem.
//!
//! Both dotfiles shapes matter and both are covered: the file itself being a
//! link, and the far more common case of `~/.config/zer0` being a link to a
//! directory in the checkout.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// Where the configuration file is, from this process's environment.
///
/// In the core rather than in each shell because two platforms disagreeing
/// about where someone's config lives is not a difference either of them could
/// justify.
pub fn default_config_path() -> PathBuf {
    config_path(
        std::env::var("ZER0_CONFIG").ok().as_deref(),
        std::env::var("XDG_CONFIG_HOME").ok().as_deref(),
        std::env::var("HOME").ok().as_deref(),
    )
}

/// The resolution rule, as a function of its inputs so it can be tested without
/// touching the process environment.
///
/// `ZER0_CONFIG` wins outright and is taken literally — it is what a second
/// profile, a test, and "try this config for a minute" all need.
pub fn config_path(
    zer0_config: Option<&str>,
    xdg_config_home: Option<&str>,
    home: Option<&str>,
) -> PathBuf {
    if let Some(explicit) = zer0_config.filter(|v| !v.trim().is_empty()) {
        return PathBuf::from(explicit);
    }
    if let Some(xdg) = xdg_config_home.filter(|v| !v.trim().is_empty()) {
        return Path::new(xdg).join("zer0").join("config.toml");
    }
    if let Some(home) = home.filter(|v| !v.trim().is_empty()) {
        return Path::new(home)
            .join(".config")
            .join("zer0")
            .join("config.toml");
    }
    // No home directory at all is a broken launch or a bare test harness. A
    // relative path fails locally and visibly; anything absolute would be
    // guessing at somebody's disk.
    PathBuf::from(".config/zer0/config.toml")
}

/// The real file behind `path`, following every symlink on the way.
///
/// Also resolves a symlinked *parent*, which is the shape a dotfiles checkout
/// usually takes, and works for a file that does not exist yet — which is the
/// case the first time the settings window writes anything.
pub fn resolve(path: &Path) -> io::Result<PathBuf> {
    if let Ok(resolved) = fs::canonicalize(path) {
        return Ok(resolved);
    }
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty());
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "the config path does not name a file",
        )
    })?;
    match parent {
        Some(parent) => {
            fs::create_dir_all(parent)?;
            Ok(fs::canonicalize(parent)?.join(name))
        }
        None => Ok(PathBuf::from(name)),
    }
}

/// Put `contents` at `path`, all of it or none of it, without following the
/// symlink off a cliff.
///
/// The same promise `SessionStore::save` makes, for the same reason: a save
/// runs while a person is clicking, a process can go away mid-write, and a
/// half-written config is a browser that comes back with no providers.
pub fn write_atomically(path: &Path, contents: &str) -> io::Result<()> {
    let target = resolve(path)?;
    let directory = target.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(directory)?;

    let temporary = directory.join(format!(
        ".{}.{}.tmp",
        target
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("config.toml"),
        std::process::id()
    ));

    let result = (|| -> io::Result<()> {
        {
            let mut file = fs::File::create(&temporary)?;
            io::Write::write_all(&mut file, contents.as_bytes())?;
            // Rename is atomic; rename of a file whose bytes are still in the
            // page cache is not. Without this a power cut leaves an empty file
            // where a good one used to be.
            file.sync_all()?;
        }
        copy_permissions(&target, &temporary)?;
        fs::rename(&temporary, &target)?;
        // The rename itself has to reach the disk too, for the same reason.
        // Best effort: a directory that will not open for reading is not a
        // reason to report a write that did happen as a failure.
        if let Ok(dir) = fs::File::open(directory) {
            let _ = dir.sync_all();
        }
        Ok(())
    })();

    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

/// Keep the mode the file already had, and start a new one at `0600`.
///
/// It holds no secrets, so this is not protecting a key. It is that a file
/// somebody chose to `chmod` should not silently change mode because they
/// clicked a toggle, and that a config naming which services you use is nobody
/// else's business on a shared machine.
#[cfg(unix)]
fn copy_permissions(target: &Path, temporary: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mode = fs::metadata(target)
        .map(|m| m.permissions().mode() & 0o7777)
        .unwrap_or(0o600);
    fs::set_permissions(temporary, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn copy_permissions(_target: &Path, _temporary: &Path) -> io::Result<()> {
    Ok(())
}
