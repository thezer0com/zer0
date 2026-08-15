//! Chrome's native messaging framing.
//!
//! A 4-byte little-endian length, then that many bytes of JSON, in both
//! directions, forever. There is no handshake, no message id and no way to tell
//! two conversations apart on one pipe — a port is the unit, and a second
//! conversation is a second process.
//!
//! It is here rather than in the shell because the framing is Chrome's and not
//! Apple's: `webkit2gtk` will speak exactly these bytes to exactly these
//! programs. What belongs to a host is the pipe, which is the dull half
//! (ADR-0002). This is the same split `mcp_wire` already lives by.
//!
//! ## Why the reader hands back what it still needs
//!
//! [`step`] is a pure function over the bytes that have arrived so far, and the
//! caller keeps the buffer. Asked after every chunk over a growing buffer that
//! would be quadratic, so a `Waiting` answer says how many bytes the buffer must
//! hold before there is any point asking again. A host writing a 1 MB reply in
//! 16 kB chunks then costs one scan rather than sixty-four.

/// The most a single message may be, in either direction.
///
/// Chrome documents 1 MB from the host and refuses more. This is sixteen times
/// that, and the multiple is the point rather than the number: what the cap
/// exists for is a child that writes and never stops, which would otherwise buy
/// the browser's memory a chunk at a time until the machine gives up. It is not
/// a claim about what any host sends, and a message over it ends the connection
/// with a sentence rather than being truncated into something that parses.
pub const MAX_NATIVE_MESSAGE_BYTES: u64 = 16 * 1024 * 1024;

/// How many bytes a length prefix is. Four, little-endian, unsigned.
pub const LENGTH_PREFIX_BYTES: u64 = 4;

/// What the bytes so far amount to.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum NativeMessageStep {
    /// Nothing complete yet. `needed` is how many bytes the buffer must hold
    /// before asking again — never fewer than it already has.
    Waiting { needed: u64 },
    /// One whole message, and how many bytes of the front of the buffer it
    /// used. The caller drops that many and may ask again.
    Message { json: String, consumed: u64 },
    /// A length prefix beyond what this browser will hold. The connection ends;
    /// there is no way to skip a message whose length you refuse to believe.
    TooLarge { declared: u64, limit: u64 },
    /// The length was readable and what followed was not a JSON message.
    Malformed { detail: String },
}

/// Read the front of `buffer`.
///
/// **Never repairs.** A body that is not UTF-8, or is UTF-8 and is not JSON, is
/// `Malformed` and ends the connection. Chrome's framing has no resynchronising
/// mark, so there is nothing to skip forward to: after one bad length every
/// subsequent byte is misread, and a reader that carried on would hand the
/// extension messages assembled out of the middle of other messages.
pub fn step(buffer: &[u8]) -> NativeMessageStep {
    let prefix = LENGTH_PREFIX_BYTES as usize;
    if buffer.len() < prefix {
        return NativeMessageStep::Waiting {
            needed: LENGTH_PREFIX_BYTES,
        };
    }

    let declared = u64::from(u32::from_le_bytes([
        buffer[0], buffer[1], buffer[2], buffer[3],
    ]));
    if declared > MAX_NATIVE_MESSAGE_BYTES {
        return NativeMessageStep::TooLarge {
            declared,
            limit: MAX_NATIVE_MESSAGE_BYTES,
        };
    }

    // Checked rather than `+`: `declared` came off a pipe a stranger's program
    // is writing, and it is capped above, but the addition is written so that
    // moving the cap can never be the thing that overflows.
    let total = LENGTH_PREFIX_BYTES.saturating_add(declared);
    if (buffer.len() as u64) < total {
        return NativeMessageStep::Waiting { needed: total };
    }

    let body = &buffer[prefix..prefix + declared as usize];
    let Ok(text) = std::str::from_utf8(body) else {
        return NativeMessageStep::Malformed {
            detail: "the message was not UTF-8".to_string(),
        };
    };
    if let Err(e) = serde_json::from_str::<serde_json::Value>(text) {
        return NativeMessageStep::Malformed {
            detail: format!("the message was not JSON: {e}"),
        };
    }

    NativeMessageStep::Message {
        json: text.to_string(),
        consumed: total,
    }
}

/// Frame one message for the host, or `None` for one this browser will not
/// send.
///
/// `None` for two reasons and both are refusals rather than repairs: a body
/// that is not JSON would be framed as bytes the host cannot read, and a body
/// over the cap is the outbound half of the same unbounded-growth problem —
/// an extension can call `port.postMessage` in a loop as easily as a host can
/// write in one.
pub fn frame(json: &str) -> Option<Vec<u8>> {
    if serde_json::from_str::<serde_json::Value>(json).is_err() {
        return None;
    }
    let body = json.as_bytes();
    let length = u32::try_from(body.len()).ok()?;
    if u64::from(length) > MAX_NATIVE_MESSAGE_BYTES {
        return None;
    }

    let mut out = Vec::with_capacity(body.len() + LENGTH_PREFIX_BYTES as usize);
    out.extend_from_slice(&length.to_le_bytes());
    out.extend_from_slice(body);
    Some(out)
}

#[cfg(test)]
#[path = "wire_tests.rs"]
mod tests;
