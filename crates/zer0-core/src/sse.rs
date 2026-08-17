//! Turning a byte stream into whole frames, one arriving chunk at a time.
//!
//! Every provider streams over a long-lived HTTP response, and every one of
//! them frames that response by line. Two framings cover all of them: the event
//! stream everyone but Ollama speaks, and the newline-delimited JSON Ollama
//! speaks natively.
//!
//! It sits at the crate root rather than inside `provider`, where it was
//! written, because MCP over Streamable HTTP reads `text/event-stream` too: a
//! server may answer a POST with a stream instead of a document, and the
//! browser has to read both. A second event-stream reader written next door
//! would be a second set of answers to `data:` continuation, `\r\n`, comment
//! lines and the event that arrives without its final blank line — and the two
//! would disagree about one of them eventually.
//!
//! The whole reason this is a type rather than a `split('\n')` is that bytes
//! arrive in whatever sizes the network felt like. A chunk can end halfway
//! through a UTF-8 character, halfway through a JSON string, or halfway through
//! the word `data`. Nothing here may look at a partial line, so partial lines
//! are held.

/// How a response separates one message from the next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Framing {
    /// `text/event-stream`: `field: value` lines, a blank line ends an event.
    EventStream,
    /// One JSON document per line, no field names, no blank-line terminator.
    // Provider-only, as is `Framer::overflowed`: Ollama's framing is the one
    // speaker of it, and MCP — the other reader here — speaks only the event
    // stream. A bare core that talks to no model has no line-JSON to read.
    #[cfg(feature = "provider")]
    LineJson,
}

/// One complete message off the wire.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Frame {
    /// The `event:` field, when the stream names its events. Anthropic and the
    /// OpenAI Responses API both do; everyone else leaves this `None` and puts
    /// the discriminator inside the JSON.
    pub name: Option<String>,
    /// The payload. For an event stream this is every `data:` line of the
    /// event, joined with newlines, exactly as the spec says.
    pub data: String,
}

/// A single frame this large means the other end is not speaking the protocol
/// we asked for — an HTML error page from a proxy, say, which has no newlines
/// worth the name. Holding it forever is how a browser tab eats a gigabyte.
const MAX_FRAME_BYTES: usize = 1 << 20;

/// Reassembles frames from arbitrary byte chunks.
#[derive(Debug)]
pub(crate) struct Framer {
    framing: Framing,
    /// Bytes seen since the last newline. Never inspected: a partial line is
    /// not a line.
    pending: Vec<u8>,
    /// The `event:` field of the event being accumulated.
    name: Option<String>,
    /// The `data:` lines of the event being accumulated, already joined.
    data: String,
    /// Whether any field of the event in flight has been seen. An event stream
    /// dispatches on a blank line, and consecutive blank lines are not seven
    /// empty events.
    started: bool,
    overflowed: bool,
}

impl Framer {
    pub(crate) fn new(framing: Framing) -> Self {
        Self {
            framing,
            pending: Vec::new(),
            name: None,
            data: String::new(),
            started: false,
            overflowed: false,
        }
    }

    /// The stream stopped making sense and nothing after this point is worth
    /// reading.
    #[cfg(feature = "provider")]
    pub(crate) fn overflowed(&self) -> bool {
        self.overflowed
    }

    /// Feed whatever arrived. Returns the frames that completed inside it,
    /// which is very often none.
    pub(crate) fn push(&mut self, bytes: &[u8]) -> Vec<Frame> {
        let mut out = Vec::new();
        if self.overflowed {
            return out;
        }

        for &byte in bytes {
            if byte == b'\n' {
                let line = std::mem::take(&mut self.pending);
                // Lossy rather than strict: a provider that sends one broken
                // byte should cost that character, not the conversation. The
                // split-mid-character case never reaches here — the bytes of a
                // character all arrive before the newline that ends its line.
                let line = String::from_utf8_lossy(strip_cr(&line)).into_owned();
                if let Some(frame) = self.line(line) {
                    out.push(frame);
                }
                continue;
            }
            self.pending.push(byte);
            if self.pending.len() > MAX_FRAME_BYTES || self.data.len() > MAX_FRAME_BYTES {
                self.overflowed = true;
                self.pending.clear();
                self.data.clear();
                return out;
            }
        }

        out
    }

    /// The connection closed. An event stream that ends without its final blank
    /// line still has an event in it, and a line-JSON stream without a trailing
    /// newline still has a document in it. Both are common enough that dropping
    /// them would lose the last token of a reply.
    pub(crate) fn finish(&mut self) -> Vec<Frame> {
        let mut out = Vec::new();
        if self.overflowed {
            return out;
        }

        if !self.pending.is_empty() {
            let line = std::mem::take(&mut self.pending);
            let line = String::from_utf8_lossy(strip_cr(&line)).into_owned();
            if let Some(frame) = self.line(line) {
                out.push(frame);
            }
        }
        if let Some(frame) = self.dispatch() {
            out.push(frame);
        }
        out
    }

    fn line(&mut self, line: String) -> Option<Frame> {
        match self.framing {
            Framing::EventStream => self.event_stream_line(&line),
            // The line-JSON half exists only where a model speaks it; MCP —
            // the other reader of this framer — is an event stream only.
            #[cfg(feature = "provider")]
            Framing::LineJson => {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    return None;
                }
                Some(Frame {
                    name: None,
                    data: trimmed.to_owned(),
                })
            }
        }
    }

    fn event_stream_line(&mut self, line: &str) -> Option<Frame> {
        if line.is_empty() {
            return self.dispatch();
        }
        // A line opening with a colon is a comment. Providers use them as
        // keep-alives, and reading one as a field would invent an empty event.
        if line.starts_with(':') {
            return None;
        }

        let (field, value) = match line.split_once(':') {
            Some((field, value)) => (field, value.strip_prefix(' ').unwrap_or(value)),
            // A field with no colon at all is the field name with an empty
            // value, per the event-stream spec.
            None => (line, ""),
        };

        match field {
            "event" => {
                self.started = true;
                self.name = Some(value.to_owned());
            }
            "data" => {
                self.started = true;
                if !self.data.is_empty() {
                    self.data.push('\n');
                }
                self.data.push_str(value);
            }
            // `id` and `retry` exist in the spec and mean nothing to any
            // provider here. Ignored rather than rejected: an unknown field is
            // the one thing the spec says to skip.
            _ => {}
        }
        None
    }

    fn dispatch(&mut self) -> Option<Frame> {
        if !self.started {
            return None;
        }
        self.started = false;
        Some(Frame {
            name: self.name.take(),
            data: std::mem::take(&mut self.data),
        })
    }
}

/// `\r\n` is what an HTTP body written by a strict server looks like. A bare
/// `\r` as a line terminator is in the spec and out of the world; treating it
/// as content costs nothing that has ever been observed.
fn strip_cr(line: &[u8]) -> &[u8] {
    match line.split_last() {
        Some((b'\r', rest)) => rest,
        _ => line,
    }
}
