//! # zer0-core
//!
//! The browser's state and behaviour, with no engine and no UI attached.
//!
//! The shell (SwiftUI on Apple platforms) owns the views and the web engine.
//! It sends [`Action`]s in and carries out the [`EngineCommand`]s that come
//! back. Nothing decides anything on the shell side, so the same core drives a
//! `WKWebView` on macOS and a `webkit2gtk` view on Linux without changing.
//!
//! ```
//! use zer0_core::{Action, EngineCommand, Session, dispatch};
//!
//! let mut session = Session::new("Personal", "some-data-store-uuid");
//!
//! let commands = dispatch(&mut session, Action::OpenTab {
//!     space: None,
//!     url: Some("avelino.run".into()),
//!     parent: None,
//! });
//!
//! let tab = session.browser.active_tab().unwrap();
//! assert!(commands.contains(&EngineCommand::LoadUrl {
//!     tab,
//!     url: "https://avelino.run".into(),
//! }));
//! ```

mod blocking;
mod bookmarks;
mod certificates;
mod chat;
mod command_bar;
#[cfg(feature = "config")]
mod config;
#[cfg(feature = "ffi")]
mod config_ffi;
mod downloads;
#[cfg(feature = "ext")]
mod ext;
// Ffi-gated because every caller is the binding layer: the scheme handler the
// shell routes `zer0-extension-api://` through is reached over uniffi, and no
// other door into this module exists yet. A bare core that answers no
// `chrome.*` call has no reason to carry it.
#[cfg(feature = "ffi")]
mod extension_api;
mod extension_permissions;
mod extension_pins;
mod extension_url;
mod external_scheme;
#[cfg(feature = "ffi")]
mod ffi;
mod history;
mod http_auth;
#[cfg(feature = "store")]
mod icon_store;
mod icons;
mod internal_url;
mod mcp;
#[cfg(feature = "ffi")]
mod mcp_ffi;
mod mcp_http;
mod mcp_wire;
mod model;
mod native_messaging;
#[cfg(feature = "ffi")]
mod native_messaging_ffi;
mod navigation_state;
mod page_dialogs;
mod page_menu;
mod passwords;
#[cfg(feature = "ffi")]
mod passwords_ffi;
mod preferences;
#[cfg(feature = "prose")]
mod prose;
mod protocol;
#[cfg(feature = "provider")]
pub mod provider;
mod reducer;
mod routing;
mod session;
#[cfg(feature = "store")]
mod session_store;
mod shortcuts;
mod site_permissions;
mod sse;
#[cfg(feature = "store")]
mod storable;
#[cfg(feature = "store")]
mod store;
#[cfg(test)]
mod test_support;
mod tint;
mod url_input;

pub use blocking::{
    BlockingSummary, MAX_EXCEPTIONS as MAX_BLOCKING_EXCEPTIONS,
    rule_list_identifier as blocking_rule_list_identifier,
    rule_list_json as blocking_rule_list_json, shipped_host_count as blocked_host_count,
    summary as blocking_summary, usable_exception,
};
pub use bookmarks::{Bookmark, BookmarkId, Bookmarks, MAX_TAGS};
pub use certificates::{
    CertificateFault, CertificateReport, ReportedCertificate, ServerTrustRequest, TrustDecision,
    TrustException, TrustExceptions, certificate_origin, certificate_report,
    may_offer_certificate_exception,
};
pub use chat::{
    Chat, ChatError, ChatErrorKind, ConsentChoice, Conversation, ConversationId, ConversationScope,
    MAX_CONVERSATIONS, MAX_MESSAGE_BYTES, MAX_MESSAGES, MAX_PAGE_CONTEXT_CHARS,
    MAX_TOOL_CALLS_PER_REPLY, MAX_TOOL_PAYLOAD_BYTES, MAX_TOOL_ROUNDS, Message, MessageId,
    MessageRole, MessageState, PageReference, ToolCall, ToolCallId, ToolCallState, ToolConsent,
    ToolDescriptor, ToolGrant, ToolInvocation,
};
pub use command_bar::{CommandBarIntent, Suggestion, accept, fuzzy_score, search_history, suggest};
#[cfg(feature = "config")]
pub use config::{
    Config, ConfigDiagnostic, ConfigError, ConfigFile, ConfigSeverity, EnvVar, McpServerConfig,
    ParsedConfig, ProviderConfig, ProviderKind, Readiness, SecretEnvVar, TransportKind,
    config_path, default_config_path, example_config, looks_like_a_secret, parse as parse_config,
};
pub use downloads::{
    Download, DownloadError, DownloadErrorKind, DownloadId, DownloadState, Downloads,
    destination_in, safe_filename,
};
#[cfg(feature = "ext")]
pub use ext::{
    CHROME_VERSION_FOR_DOWNLOADS, CompatNotice, ExtError, ExtensionManifest, InstalledExtension,
    StoreHosts, default_extension_directory, download_url, extension_id_from_store_url,
    install_extension, installed_extensions, store_hosts, uninstall_extension,
};
#[cfg(feature = "ffi")]
pub use extension_api::{ExtensionApiAnswer, ExtensionApiOutcome, HostFacts};
pub use extension_permissions::{
    ConsentDecision, ConsentRequest, ExtensionConsent, ExtensionStanding, NotProvided,
    PermissionKind, PermissionRequest, PermissionRisk, Withheld, consent_request, standing,
};
pub use extension_pins::{ExtensionPin, ExtensionPins};
pub use external_scheme::may_hand_to_the_system;
pub use history::{History, HistoryEntry, HistoryRange};
pub use http_auth::{
    AuthChoice, AuthDecision, AuthGate, AuthPrompt, HttpAuth, HttpAuthRequest, HttpAuthScheme,
    gate as gate_http_auth, is_loopback, keychain_origin as auth_keychain_origin,
};
#[cfg(feature = "store")]
pub use icon_store::IconStore;
pub use icons::{
    IconCandidate, IconKey, Icons, MAX_ICON_BYTES, RETRY_MISSING_AFTER_MS, StoredIcon,
    TARGET_ICON_PX,
};
pub use internal_url::{
    Effect as InternalEffect, InternalAddress, SCHEME as INTERNAL_SCHEME,
    parse as parse_internal_url,
};
pub use mcp::{
    ApprovedShape, DEFAULT_CALL_TIMEOUT_MS, HANDSHAKE_TIMEOUT_MS, HTTP_CONSEQUENCE,
    MAX_DESCRIPTION_CHARS, MAX_TOOLS_PER_SERVER, McpFailure, McpRegistry, McpServerState, McpTool,
    QUALIFIER, ReportedTool, STDIO_CONSEQUENCE, ToolDisclosure, ToolVerdict, adopt_tools,
    exact_command, fingerprint, is_valid_server_id, qualified_name, sanitize_tool_name,
    split_qualified,
};
pub use mcp_http::{
    EndpointVerdict, HttpOutcome, authorization_header, endpoint_verdict, http_headers,
    http_reply_lines, http_status_failure,
};
pub use mcp_wire::{
    CLIENT_NAME, EraProbe, Expect, LEGACY_PROTOCOL_VERSION, MAX_TOOL_PAGES, PROTOCOL_VERSION,
    Reply, ServerEra, cancel_notification, detect_era, discover_request, initialize_request,
    initialized_notification, parse_notification, parse_reply, reply_id, tools_call_request,
    tools_list_request,
};
pub use model::{
    Browser, DEFAULT_ARCHIVE_AFTER_MS, DEFAULT_SPLIT_RATIO, MAX_SPLIT_RATIO, MIN_SPLIT_RATIO,
    NavigationError, NavigationErrorKind, Space, SpaceId, SpaceProfile, Split, Tab, TabId, TabKind,
    Window, WindowId, clamp_split_ratio,
};
pub use native_messaging::{
    HostRefusal, HostRegistrar, LENGTH_PREFIX_BYTES, MAX_NATIVE_MESSAGE_BYTES,
    NATIVE_MESSAGING_PERMISSION, NativeHostDecision, NativeHostLedger, NativeHostPrompt,
    NativeMessageStep, ResolvedHost, caller_origin as native_host_caller_origin,
    frame as frame_native_message, prompt as native_host_prompt,
    refusal_sentence as native_host_refusal_sentence, registrars as native_host_registrars,
    resolve as resolve_native_host, step as read_native_message,
};
pub use page_dialogs::{
    DIALOGS_BEFORE_SILENCE, DialogGate, EXTENSION_NAME_LIMIT as DIALOG_EXTENSION_NAME_LIMIT,
    MESSAGE_LIMIT as DIALOG_MESSAGE_LIMIT, PageDialog, PageDialogAnswer, PageDialogKind,
    PageDialogRequest, PageDialogSource, PageDialogSpeaker, PageDialogs, gate as gate_page_dialog,
};
pub use page_menu::{
    MAX_SELECTION_CHARS as MAX_MENU_SELECTION_CHARS, PageMenuItem, PageTarget,
    additions_for as page_menu_additions_for, address_for as page_menu_address_for,
    search_query as page_menu_search_query_for,
};
pub use passwords::{
    FillVerdict, KeychainFields, Refusal as PasswordRefusal, ReportedField, ReportedForm,
    SaveVerdict, SavedLogin, fill_verdict, keychain_fields, keychain_scope,
    matches as credential_matches, offerable, save_verdict, usable as field_is_usable,
};
pub use preferences::{
    Preferences, SearchEngine, StartupBehaviour, ThemePreference, search_engine_name,
    search_engines,
};
#[cfg(feature = "prose")]
pub use prose::{ProseBlock, ProseKind, ProseRun, blocks as prose_blocks_of};
pub use protocol::{Action, ChatSubject, EngineCommand, ReplyStop, WindowContents};
pub use reducer::{dispatch, rehydrate};
pub use routing::{Route, RoutePattern, RoutingTable};
pub use session::Session;
#[cfg(feature = "store")]
pub use session_store::{SessionStore, StoreError};
pub use shortcuts::{Binding, Chord, Key, Keymap, Modifiers, UiCommand};
pub use site_permissions::{
    CaptureRequest, Gate as SitePermissionGate, PROMPT_SETTLE_MS, ReportedOrigin, SiteCapability,
    SiteChoice, SiteDecision, SiteGrant, SitePermissionPrompt, SitePermissionRequest,
    SitePermissions, SiteVerdict, answered_too_soon, canonical_origin,
    gate as gate_site_permission, origin_of,
};
#[cfg(feature = "store")]
pub use storable::{StorableDownload, StorableDownloadState, StorableSession, StorableSpace};
#[cfg(feature = "store")]
pub use store::Store;
pub use tint::{
    DeclaredColor, MAX_DECLARED_COLORS, MAX_LUMINANCE_FOR_LIGHT_INK, MIN_INK_CONTRAST,
    MIN_LUMINANCE_FOR_DARK_INK, PageTint, tint_for,
};
pub use url_input::{Resolved, resolve as resolve_input};

#[cfg(feature = "ffi")]
pub use config_ffi::Zer0Config;
#[cfg(feature = "ffi")]
pub use ffi::{BrowserSnapshot, Zer0};

#[cfg(feature = "ffi")]
uniffi::setup_scaffolding!();
