//! The native messaging wire, for whatever owns the pipe.
//!
//! Free functions only. A host spawns the program, writes bytes and reads
//! bytes; what a message *is* — where the length lives, how big one may be,
//! what counts as one at all, and what a program is told about who is calling
//! it — is decided here, so a Linux host that reimplements `Process` does not
//! also reimplement Chrome's framing. The same split `mcp_ffi` lives by.
//!
//! The lookup half is on [`crate::ffi::Zer0`] rather than here, because it
//! reads a ledger and a ledger is state.

use crate::native_messaging::{self, NativeHostPrompt, NativeMessageStep, ResolvedHost};

/// Frame one message for a host, or `None` for one this browser will not send.
#[uniffi::export]
pub fn native_message_frame(json: String) -> Option<Vec<u8>> {
    native_messaging::frame(&json)
}

/// Read the front of what has arrived.
///
/// A `Waiting` answer says how many bytes the buffer must hold before there is
/// any point asking again, so a host that appends a chunk and asks does not
/// rescan everything it already has.
#[uniffi::export]
pub fn native_message_step(buffer: Vec<u8>) -> NativeMessageStep {
    native_messaging::step(&buffer)
}

/// What a native messaging host is told about who is calling it.
///
/// Chrome passes the calling extension's origin as the program's one argument,
/// and programs read it: 1Password's helper is measurably one of them. It is
/// composed here rather than in a host because it is a fact about Chrome's
/// protocol, and because composing it anywhere else would be a second place
/// that could hand a program an id this browser never verified.
///
/// `None` for anything that is not an extension id, which is the same refusal
/// the lookup makes and for the same reason.
#[uniffi::export]
pub fn native_host_argument(extension_id: String) -> Option<String> {
    native_messaging::caller_origin(&extension_id)
}

/// The question a person is asked before a program is started.
///
/// Composed in the core so that no screen writes its own account of what
/// starting a program costs (ADR-0028's rule, applied to a second kind of
/// grant). The shell draws weight, colour and order.
#[uniffi::export]
pub fn native_host_prompt(extension_name: String, host: ResolvedHost) -> NativeHostPrompt {
    native_messaging::prompt(&extension_name, &host)
}
