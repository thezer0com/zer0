//! The provider layer, as the Apple shell sees it.
//!
//! Everything here is a free function or a handle around one. There is no
//! session, no client, no connection: the shell performs the request and hands
//! the bytes back, which is the same arrangement `EngineHost` has with WebKit
//! and for the same reason — the only part that is genuinely platform is the
//! socket, and the only part that is genuinely behaviour is what the bytes
//! mean.

use std::sync::Mutex;

use crate::chat::{ChatErrorKind, Message};
use crate::protocol::ReplyStop;

use super::{
    HttpRequest, ModelInfo, ProviderEndpoint, ProviderError, ProviderErrorKind, StopReason,
    StreamDecoder, StreamEvent, ToolSpec, WireFormat,
};

/// A failure crossing the boundary as something Swift can `catch`.
///
/// A wrapper rather than making [`ProviderError`] itself the error type: it is
/// a record on the way out of a stream (inside [`StreamEvent::Failed`]) and a
/// thrown error on the way out of a builder, and one type cannot be both across
/// this bridge.
#[derive(Debug, uniffi::Error)]
pub enum ChatRequestError {
    Provider { error: ProviderError },
}

impl std::fmt::Display for ChatRequestError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let ChatRequestError::Provider { error } = self;
        write!(formatter, "{:?}: {}", error.kind, error.message)
    }
}

impl std::error::Error for ChatRequestError {}

impl From<ProviderError> for ChatRequestError {
    fn from(error: ProviderError) -> Self {
        ChatRequestError::Provider { error }
    }
}

/// The defaults for a wire: address and how the token is presented.
///
/// A free function because a uniffi record carries no methods across the FFI,
/// and this is the same argument `download_fraction` makes: adding a provider
/// in Settings is picking one thing rather than filling in four, and a default
/// that lives in a text field is a default two platforms will disagree about.
#[uniffi::export]
pub fn chat_provider_preset(wire: WireFormat, id: String) -> ProviderEndpoint {
    ProviderEndpoint::preset(wire, id)
}

/// Whether this provider needs a token at all.
///
/// Decides whether Settings shows a key field, and whether a missing key is
/// reported before a socket is opened. A local model has none, and asking for
/// one is how a local provider ends up with a field nobody can fill in.
#[uniffi::export]
pub fn chat_provider_needs_token(endpoint: ProviderEndpoint) -> bool {
    endpoint.needs_token()
}

/// Read a wire off a config file, where it is a word somebody typed.
///
/// `None` for anything unrecognised, so config can point at the line rather
/// than guess and produce a 404 that reads like an outage.
#[uniffi::export]
pub fn chat_wire_format(name: String) -> Option<WireFormat> {
    WireFormat::parse(&name)
}

/// Build the streaming request for one turn.
///
/// `token` comes out of the Keychain immediately before this call and is not
/// stored anywhere on the way through. What comes back has it in exactly one
/// header and nowhere else — never in the URL, where it would land in every log
/// on the path.
#[uniffi::export]
pub fn chat_request(
    endpoint: ProviderEndpoint,
    token: Option<String>,
    model: String,
    system: Option<String>,
    transcript: Vec<Message>,
    tools: Vec<ToolSpec>,
) -> Result<HttpRequest, ChatRequestError> {
    Ok(super::request(
        &endpoint,
        token.as_deref(),
        &model,
        system.as_deref(),
        &transcript,
        &tools,
    )?)
}

/// Ask a provider what models it has.
#[uniffi::export]
pub fn chat_models_request(
    endpoint: ProviderEndpoint,
    token: Option<String>,
) -> Result<HttpRequest, ChatRequestError> {
    Ok(super::models_request(&endpoint, token.as_deref())?)
}

#[uniffi::export]
pub fn chat_decode_models(
    wire: WireFormat,
    body: String,
) -> Result<Vec<ModelInfo>, ChatRequestError> {
    Ok(super::decode_models(wire, &body)?)
}

/// What a non-2xx response means.
///
/// Called with the body the shell read and the `Retry-After` header it saw, so
/// that "your key is wrong" and "wait thirty seconds" are decided once rather
/// than in every host.
#[uniffi::export]
pub fn chat_decode_error(
    wire: WireFormat,
    status: u16,
    body: String,
    retry_after: Option<String>,
) -> ProviderError {
    super::decode_error(wire, status, &body, retry_after.as_deref())
}

/// Nothing answered: no route, refused connection, DNS, TLS, timeout.
#[uniffi::export]
pub fn chat_unreachable(message: String) -> ProviderError {
    super::unreachable(message)
}

/// What the browser tells a model about itself when nothing else is configured.
#[uniffi::export]
pub fn chat_default_system_prompt() -> String {
    super::DEFAULT_SYSTEM_PROMPT.to_owned()
}

/// Whether a failure is worth offering to retry.
///
/// Exported rather than reimplemented in Swift for the reason
/// `download_fraction` is: it decides what buttons a screen has, it has to be
/// one rule, and a second copy is how one platform starts offering "Try again"
/// on a wrong API key.
#[uniffi::export]
pub fn chat_error_is_transient(error: ProviderError) -> bool {
    error.is_transient()
}

/// Whether the fix is in Settings.
#[uniffi::export]
pub fn chat_error_is_configuration_fault(error: ProviderError) -> bool {
    error.is_configuration_fault()
}

/// The core's own category for a failure the provider layer produced.
///
/// The whole point of the taxonomy: a provider's JSON is not something any
/// interface can branch on, and [`ChatErrorKind`] is. Cancellation is `None`
/// because it is not a failure — a stopped reply is reported by cancelling it,
/// not by failing it, and turning one into the other would put an error on a
/// thread somebody deliberately stopped.
#[uniffi::export]
pub fn chat_error_kind(error: ProviderError) -> Option<ChatErrorKind> {
    Some(match error.kind {
        ProviderErrorKind::Cancelled => return None,
        ProviderErrorKind::Unauthorized => ChatErrorKind::NotAuthorised,
        // A key that works and does not reach this model, an account that is
        // switched off, a request the provider will not serve: all of them are
        // the provider declining rather than anything to retry.
        ProviderErrorKind::Forbidden
        | ProviderErrorKind::QuotaExhausted
        | ProviderErrorKind::ModelNotFound
        | ProviderErrorKind::ContentFiltered
        | ProviderErrorKind::InvalidRequest => ChatErrorKind::ProviderRefused,
        // Overloaded lands here rather than on a connection failure because the
        // action is the same as a rate limit's — wait, then try again — and the
        // action is what the category is for.
        ProviderErrorKind::RateLimited | ProviderErrorKind::Overloaded => {
            ChatErrorKind::RateLimited
        }
        ProviderErrorKind::ContextTooLong => ChatErrorKind::ContextTooLong,
        ProviderErrorKind::MalformedResponse => ChatErrorKind::MalformedResponse,
        ProviderErrorKind::Unreachable | ProviderErrorKind::ServerError => {
            ChatErrorKind::ConnectionFailed
        }
    })
}

/// What a stop means: a turn that ended, or a refusal.
///
/// Two functions rather than one returning a union, because uniffi has no
/// `Result`-shaped value type and a host that had to guess would guess wrong on
/// the one case that matters.
#[uniffi::export]
pub fn chat_reply_stop(stop: StopReason) -> Option<ReplyStop> {
    super::reply_outcome(stop).ok()
}

#[uniffi::export]
pub fn chat_reply_refusal(stop: StopReason) -> Option<ChatErrorKind> {
    super::reply_outcome(stop).err()
}

/// A stream being read, one chunk at a time.
///
/// Behind a lock because uniffi hands out `Arc<Self>` and decoding is stateful
/// — a tool call's arguments are half-assembled between two chunks. The lock is
/// never contended in practice: one reader feeds one decoder.
#[derive(uniffi::Object)]
pub struct ChatStream {
    decoder: Mutex<StreamDecoder>,
}

#[uniffi::export]
impl ChatStream {
    /// `tools` must be the same list, in the same order, that was given to
    /// [`chat_request`]. The names the model sees are derived from it, and a
    /// call coming home is resolved against the same derivation.
    #[uniffi::constructor]
    pub fn new(wire: WireFormat, tools: Vec<ToolSpec>) -> Self {
        Self {
            decoder: Mutex::new(StreamDecoder::new(wire, &tools)),
        }
    }

    /// Feed whatever arrived. Sizes do not matter and boundaries do not matter.
    pub fn push(&self, bytes: Vec<u8>) -> Vec<StreamEvent> {
        self.locked().push(&bytes)
    }

    /// The connection closed. Always called, including after a failure, because
    /// it is what turns "the reply just stopped" into an ending somebody can
    /// see rather than a thread that spins.
    pub fn finish(&self) -> Vec<StreamEvent> {
        self.locked().finish()
    }

    /// Somebody pressed Escape. Whatever arrived stays where it is.
    pub fn cancel(&self) -> Vec<StreamEvent> {
        self.locked().cancel()
    }

    pub fn is_done(&self) -> bool {
        self.locked().is_done()
    }
}

impl ChatStream {
    /// A poisoned lock means a previous decode panicked, which cannot leave a
    /// half-decoded reply readable. Recovering the guard and carrying on is
    /// wrong; the stream is finished either way, so the panic is propagated.
    fn locked(&self) -> std::sync::MutexGuard<'_, StreamDecoder> {
        self.decoder.lock().expect("a decoder is never shared")
    }
}
