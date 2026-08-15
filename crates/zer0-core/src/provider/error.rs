//! What went wrong, in terms someone can act on.
//!
//! Every provider has its own vocabulary for failure, and none of them is a
//! vocabulary a person recognises. `invalid_api_key`, `PERMISSION_DENIED`,
//! `insufficient_quota`, a bare `model "llama3" not found, try pulling it` —
//! four wires, four spellings, and behind them a much shorter list of things
//! that are actually different *to the person looking at the screen*.
//!
//! That shorter list is [`ProviderErrorKind`]. Mapping onto it is the codec's
//! job, and it is not optional: an error that arrives as "something went wrong"
//! is a dead end, and the first one anybody will hit is a mistyped key on the
//! first run.

/// A failure, categorised, with the provider's own words kept beside it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ProviderError {
    pub kind: ProviderErrorKind,
    /// What the provider said, verbatim, or what we say when it said nothing.
    /// Never the whole of what is shown — the kind decides the sentence — but
    /// the detail that makes a report actionable.
    pub message: String,
    /// How long to wait before trying again, when the provider said. Only ever
    /// set on [`ProviderErrorKind::RateLimited`] and
    /// [`ProviderErrorKind::Overloaded`].
    pub retry_after_ms: Option<u64>,
}

/// The categories. One per thing a person would do differently.
///
/// Deliberately shorter than any provider's own list. `authentication_error`
/// and `permission_error` are two words for "your key is not going to work",
/// but they are not the same screen: one is "the key is wrong", the other is
/// "the key is right and does not reach this model", and those have different
/// fixes. `invalid_request_error` covering both a bad `temperature` and a
/// prompt over the context window is the opposite mistake, and it is why
/// [`ProviderErrorKind::ContextTooLong`] is separate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ProviderErrorKind {
    /// No key, a mistyped key, a revoked key. The first-run failure.
    Unauthorized,
    /// The key works and does not reach this. A model not enabled on the
    /// account, an organisation that has turned the endpoint off.
    Forbidden,
    /// Too many requests. Transient by construction.
    RateLimited,
    /// Credit exhausted, or a spend cap reached. Not transient: waiting does
    /// not fix it, and telling someone to retry would be a lie.
    QuotaExhausted,
    /// The model id is not one this provider has. Also what a local server
    /// says about a model nobody has pulled yet.
    ModelNotFound,
    /// The conversation no longer fits. The only error whose fix is inside the
    /// app rather than outside it.
    ContextTooLong,
    /// The provider refused on its own policy grounds, either up front or part
    /// way through generating.
    ContentFiltered,
    /// We built a request the provider will not accept. A bug on our side
    /// until proven otherwise, which is why the message matters most here.
    InvalidRequest,
    /// The provider is up and saying "not now". Transient.
    Overloaded,
    /// The provider is up and broken. Transient, but not our fault to fix.
    ServerError,
    /// Nothing answered. No route, DNS failure, connection refused — which for
    /// a local model is the ordinary case of "the server is not running", not
    /// an exotic one.
    Unreachable,
    /// Something answered and it was not what the protocol says. A proxy's
    /// HTML error page, a truncated event, JSON that does not parse.
    MalformedResponse,
    /// Somebody pressed Escape. An outcome, not a fault, and it is in here so
    /// that a stream has exactly one way to end badly.
    Cancelled,
}

impl ProviderError {
    pub fn new(kind: ProviderErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            retry_after_ms: None,
        }
    }

    pub fn retry_after(mut self, ms: Option<u64>) -> Self {
        self.retry_after_ms = ms;
        self
    }

    /// Whether trying the identical request again could plausibly work.
    ///
    /// This is behaviour, not wording: it decides whether the interface offers
    /// "Try again" at all. Offering it on a wrong API key is the browser
    /// pretending it does not know what is wrong.
    pub fn is_transient(&self) -> bool {
        matches!(
            self.kind,
            ProviderErrorKind::RateLimited
                | ProviderErrorKind::Overloaded
                | ProviderErrorKind::ServerError
                | ProviderErrorKind::Unreachable
        )
    }

    /// Whether the fix is in Settings.
    ///
    /// Also behaviour: it decides whether the interface offers a way straight
    /// to the setting that is wrong. Someone who has just pasted a key with a
    /// trailing space should not have to go looking.
    pub fn is_configuration_fault(&self) -> bool {
        matches!(
            self.kind,
            ProviderErrorKind::Unauthorized
                | ProviderErrorKind::Forbidden
                | ProviderErrorKind::QuotaExhausted
                | ProviderErrorKind::ModelNotFound
        )
    }
}

/// The category an HTTP status alone implies.
///
/// Every codec narrows this with whatever its body says, and every codec falls
/// back to it when the body says nothing readable — which is exactly what a
/// gateway timeout served as HTML looks like. Getting a usable category out of
/// a response we could not parse is the point.
pub(crate) fn kind_for_status(status: u16) -> ProviderErrorKind {
    match status {
        400 | 422 => ProviderErrorKind::InvalidRequest,
        401 => ProviderErrorKind::Unauthorized,
        402 => ProviderErrorKind::QuotaExhausted,
        403 => ProviderErrorKind::Forbidden,
        404 => ProviderErrorKind::ModelNotFound,
        413 => ProviderErrorKind::ContextTooLong,
        429 => ProviderErrorKind::RateLimited,
        // 529 is Anthropic's "overloaded"; 503 is everyone's. Neither is a
        // fault anybody reading the screen introduced.
        503 | 529 => ProviderErrorKind::Overloaded,
        500..=599 => ProviderErrorKind::ServerError,
        _ => ProviderErrorKind::ServerError,
    }
}

/// `Retry-After` as milliseconds.
///
/// The header is defined as either a count of seconds or an HTTP date. Only
/// the seconds form is read: the date form needs a clock, the core does not
/// have one (`Action::Tick` is why), and no provider here has ever been
/// observed sending it. A date arrives as "no advice", which costs a default
/// backoff rather than a wrong one.
pub(crate) fn retry_after_ms(header: Option<&str>) -> Option<u64> {
    let seconds: f64 = header?.trim().parse().ok()?;
    if !seconds.is_finite() || seconds < 0.0 {
        return None;
    }
    // A provider asking us to wait an hour is asking us to give up. Clamped so
    // a bad header cannot park a retry past anybody's patience.
    Some((seconds.min(300.0) * 1000.0) as u64)
}
