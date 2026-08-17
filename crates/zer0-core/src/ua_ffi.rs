//! The User-Agent surface, as the shell reaches it.
//!
//! Split out of `ffi.rs` the way `passwords_ffi.rs` is: the composition is
//! behaviour and lives in `ua.rs`, tested there. This file exists only because
//! uniffi wants owned arguments and no lifetimes across the FFI, so the core
//! should not grow a second set of signatures to satisfy a binding generator.

use crate::ua::{self, UserAgentContext};

/// The User-Agent one context announces.
///
/// The shell reads the two local facts — the installed Safari's version and
/// this app's own — and hands them over; every rule about the string comes
/// back in the answer (ADR-0119). A space profile's own UA still replaces the
/// answer wholesale where the shell applies it, which is ADR-0008's isolation
/// half and not this function's to know about.
#[uniffi::export]
pub fn user_agent(
    safari_version: Option<String>,
    own_version: Option<String>,
    context: UserAgentContext,
) -> String {
    ua::user_agent(safari_version.as_deref(), own_version.as_deref(), context)
}
