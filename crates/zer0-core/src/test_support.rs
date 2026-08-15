//! The one place a test is allowed to spell `std::env::temp_dir()`.
//!
//! Two tests that share a path do not fail where the mistake is. They fail on
//! whichever one lost the race, on whichever machine happened to interleave
//! them, and the failure reads as flakiness in code that is correct — so it
//! gets rerun, goes green, and nobody learns anything. This project has
//! already spent two debugging sessions chasing exactly that.
//!
//! `scripts/scratch-check.sh` enforces it mechanically: `temp_dir()` may be
//! written here and nowhere else under test, and no test may name a path under
//! `/tmp` by hand.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

/// A path under the system temp directory that nothing else will pick.
///
/// The name is not created — the caller decides whether it wants a directory
/// or a file, and owns removing it.
///
/// Three things go into it, and each covers a way the last collision happened:
/// the process id covers two `cargo test` runs at once, the thread id covers
/// the harness running tests in parallel inside one run, and the counter
/// covers a single test asking twice.
pub(crate) fn scratch_path(label: &str) -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(0);

    std::env::temp_dir().join(format!(
        "zer0-{label}-{}-{:?}-{}",
        std::process::id(),
        std::thread::current().id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ))
}
