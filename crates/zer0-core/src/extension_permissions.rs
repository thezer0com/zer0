//! What an extension asked for, said in plain language, and what was allowed.
//!
//! Two things live here, and they are deliberately in the core rather than in
//! the shell.
//!
//! **The words.** A manifest says `<all_urls>`; a person needs to be told
//! "Read and change everything you do on every site". Translating a permission
//! key into its consequence is a judgement about what the browser is willing
//! to be asked, not a matter of taste, and two platforms must not disagree
//! about it. The shell decides the colour of the row; it does not decide what
//! the row says.
//!
//! **The record.** [`ExtensionConsent`] is the browser's own ledger of what
//! was approved, refused, and never understood. `WKWebExtensionContext` also
//! holds granted permissions, but it is rebuilt from nothing on every launch:
//! a consent that lives only there is a consent that resets, and a consent
//! that resets trains people to click through. So the ledger is session state,
//! saved beside preferences, and the context is a projection of it applied at
//! load.
//!
//! ## What is never approved
//!
//! A host pattern the browser cannot read is not offered, not granted and not
//! shown as granted — it is listed as unreadable and nothing else. Presenting
//! something nobody parsed as if it had been understood and approved would
//! make the whole dialog a lie, and it is the exact shape of lie this file
//! exists to prevent.

/// How much a permission can cost you if the extension turns out to be
/// hostile — or merely careless, which is far more common.
///
/// Ordering is the whole point: a flat alphabetical list hides the worst item
/// in the middle of the harmless ones.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum PermissionRisk {
    /// Everything you do, or a way out of the browser entirely.
    Critical,
    /// A durable record of your browsing, or your signed-in identity.
    High,
    /// Real access, bounded to something you can picture.
    Moderate,
    /// Costs you nothing you would miss.
    Low,
    /// The browser has no description for this one, so it cannot tell you
    /// what granting it allows.
    Unknown,
}

impl PermissionRisk {
    /// Worst first. Used for ordering and nothing else.
    fn severity(self) -> u8 {
        match self {
            PermissionRisk::Critical => 0,
            PermissionRisk::High => 1,
            // An unknown permission sits with the moderate ones rather than at
            // the bottom: not knowing is not the same as being harmless.
            PermissionRisk::Unknown => 2,
            PermissionRisk::Moderate => 3,
            PermissionRisk::Low => 4,
        }
    }
}

/// Whether a permission is about sites or about a browser API.
///
/// They are granted through different calls on the host side, so the
/// distinction has to survive the crossing rather than being re-derived from
/// the string on the far side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum PermissionKind {
    /// A match pattern: which sites the extension may read and change.
    Site,
    /// A `chrome.*` API the extension may call.
    Api,
}

fn kind_order(kind: PermissionKind) -> u8 {
    match kind {
        // Site access above APIs at equal risk: it is the one people actually
        // have an opinion about.
        PermissionKind::Site => 0,
        PermissionKind::Api => 1,
    }
}

/// One thing to say yes or no to.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct PermissionRequest {
    /// Exactly as the manifest wrote it. This is what gets granted, and what
    /// the ledger records; the prose below is never parsed back.
    pub key: String,
    pub kind: PermissionKind,
    pub risk: PermissionRisk,
    /// The consequence, in one line, in the second person.
    pub title: String,
    /// What that means concretely, for someone who does not know what a
    /// content script is.
    pub detail: String,
    /// Whether the dialog arrives with this one already ticked.
    ///
    /// Everything the browser can explain arrives ticked, because an
    /// extension that installs switched off is an extension that looks broken.
    /// Anything it cannot explain arrives unticked: there is no informed
    /// consent to be had for a sentence nobody can write. Anything it cannot
    /// *provide* arrives unticked too, for the reason in
    /// [`PermissionRequest::not_provided`].
    pub default_granted: bool,
    /// Set when granting this would reach nothing, holding both which kind of
    /// nothing it is and the sentence that says so. `None` means granting it
    /// reaches the extension.
    ///
    /// One field rather than a flag beside a string, so a row cannot be marked
    /// inert without carrying the reason it is inert — and so the shell has no
    /// way to draw the state without printing why.
    pub not_provided: Option<NotProvided>,
}

/// Why granting a permission would reach nothing — and whether that could
/// change.
///
/// One sentence used to carry two opposite facts. `downloads` reached nothing
/// because nobody had built it, and `management` reaches nothing because this
/// browser declines to build it and would decline it on an engine that shipped
/// the API tomorrow. A reader could not tell those apart, and neither could the
/// code.
///
/// An enum rather than a second boolean, for the reason AGENTS.md gives: a
/// third kind of not-provided has to be a third variant, which breaks every
/// exhaustive switch in the shell until it earns its own sentence. It cannot
/// arrive wearing one of these two.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum NotProvided {
    /// Work nobody has done. The sentence states the gap and promises no date,
    /// because there is nothing here that could keep a date.
    NotBuiltYet { sentence: String },
    /// Work this browser refuses to do. The sentence states the position, and
    /// it is the same position on the day WebKit ships the API.
    Declined { sentence: String },
}

impl NotProvided {
    /// What the row prints. The one thing both kinds have in common, so a
    /// surface that only needs the words does not have to pick a kind.
    pub fn sentence(&self) -> &str {
        match self {
            Self::NotBuiltYet { sentence } | Self::Declined { sentence } => sentence,
        }
    }
}

/// Everything one extension is asking for, ordered worst first.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ConsentRequest {
    pub extension_id: String,
    pub extension_name: String,
    /// Sorted: most dangerous first, sites before APIs, then alphabetical so
    /// the same manifest always produces the same screen.
    pub requests: Vec<PermissionRequest>,
    /// Site rules the browser could not read. Shown as skipped, never offered,
    /// never granted.
    pub unreadable_hosts: Vec<String>,
}

impl ConsentRequest {
    /// The decision you get by accepting the dialog as it opened.
    ///
    /// Exists so "the default" is one rule in one place rather than something
    /// each shell re-derives from the same fields.
    pub fn default_decision(&self, decided_at_ms: u64) -> ConsentDecision {
        let mut decision = ConsentDecision::refusing_everything(
            self.extension_id.clone(),
            decided_at_ms,
            self.unreadable_hosts.clone(),
        );
        for request in self.requests.iter().filter(|r| r.default_granted) {
            decision.allow(request.kind, &request.key);
        }
        for request in self.requests.iter().filter(|r| !r.default_granted) {
            decision.refuse(request.kind, &request.key);
        }
        decision
    }
}

/// What was decided about one extension, and when.
///
/// Denials are written down rather than inferred from absence. A permission
/// missing from both lists is one nobody was ever asked about — a manifest
/// that grew a new entry since the install — and that is a different situation
/// from one that was refused, which must stay refused.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ConsentDecision {
    pub extension_id: String,
    pub granted_permissions: Vec<String>,
    pub granted_hosts: Vec<String>,
    pub denied_permissions: Vec<String>,
    pub denied_hosts: Vec<String>,
    /// Patterns nobody could parse. Kept so the record says what actually
    /// happened instead of quietly losing them.
    pub unreadable_hosts: Vec<String>,
    pub decided_at_ms: u64,
}

impl ConsentDecision {
    /// A decision that says no to everything. Build up from here.
    pub fn refusing_everything(
        extension_id: impl Into<String>,
        decided_at_ms: u64,
        unreadable_hosts: Vec<String>,
    ) -> Self {
        Self {
            extension_id: extension_id.into(),
            granted_permissions: Vec::new(),
            granted_hosts: Vec::new(),
            denied_permissions: Vec::new(),
            denied_hosts: Vec::new(),
            unreadable_hosts,
            decided_at_ms,
        }
    }

    pub fn allow(&mut self, kind: PermissionKind, key: &str) {
        // An unreadable pattern is never granted, whatever anyone asks for.
        // This is the last gate before the ledger, so it is checked here and
        // not only where the request is built.
        if kind == PermissionKind::Site && self.unreadable_hosts.iter().any(|h| h == key) {
            return;
        }
        // And neither is a permission this browser cannot provide. Same gate,
        // same reason: a recorded approval that reaches nothing is an approval
        // in name only, and it would be read back by every screen as a grant
        // (ADR-0084). Putting it here rather than only in the views is what
        // makes the missing switch a consequence instead of a promise.
        // Every kind of it, which is why this asks the one function rather than
        // naming the kinds: a variant added to `NotProvided` is granted by
        // nobody without anybody having to remember to come back here.
        if kind == PermissionKind::Api && not_provided(key).is_some() {
            return;
        }
        let (granted, denied) = self.lists_mut(kind);
        denied.retain(|k| k != key);
        if !granted.iter().any(|k| k == key) {
            granted.push(key.to_string());
        }
    }

    pub fn refuse(&mut self, kind: PermissionKind, key: &str) {
        let (granted, denied) = self.lists_mut(kind);
        granted.retain(|k| k != key);
        if !denied.iter().any(|k| k == key) {
            denied.push(key.to_string());
        }
    }

    pub fn grants(&self, kind: PermissionKind, key: &str) -> bool {
        match kind {
            PermissionKind::Site => self.granted_hosts.iter().any(|k| k == key),
            PermissionKind::Api => self.granted_permissions.iter().any(|k| k == key),
        }
    }

    pub fn refuses(&self, kind: PermissionKind, key: &str) -> bool {
        match kind {
            PermissionKind::Site => self.denied_hosts.iter().any(|k| k == key),
            PermissionKind::Api => self.denied_permissions.iter().any(|k| k == key),
        }
    }

    /// Nothing at all was allowed. The extension is installed and does not run,
    /// and the interface has to say so rather than showing it as active.
    pub fn grants_nothing(&self) -> bool {
        self.granted_permissions.is_empty() && self.granted_hosts.is_empty()
    }

    /// Record that the host could not parse a pattern after all.
    ///
    /// The core reads match patterns itself, but the engine has the final say:
    /// something we accepted and it refused was never really granted, and the
    /// ledger has to stop claiming otherwise the moment we find out.
    pub fn mark_unreadable(&mut self, pattern: &str) {
        self.granted_hosts.retain(|h| h != pattern);
        self.denied_hosts.retain(|h| h != pattern);
        if !self.unreadable_hosts.iter().any(|h| h == pattern) {
            self.unreadable_hosts.push(pattern.to_string());
        }
    }

    fn lists_mut(&mut self, kind: PermissionKind) -> (&mut Vec<String>, &mut Vec<String>) {
        match kind {
            PermissionKind::Site => (&mut self.granted_hosts, &mut self.denied_hosts),
            PermissionKind::Api => (&mut self.granted_permissions, &mut self.denied_permissions),
        }
    }
}

/// Every decision the browser has made about an extension.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ExtensionConsent {
    decisions: Vec<ConsentDecision>,
}

impl ExtensionConsent {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn load(decisions: Vec<ConsentDecision>) -> Self {
        Self { decisions }
    }

    pub fn all(&self) -> &[ConsentDecision] {
        &self.decisions
    }

    /// What was decided about this extension, or `None` if nobody was ever
    /// asked. `None` is not "nothing was granted": it is "do not run this yet".
    pub fn decision(&self, extension_id: &str) -> Option<&ConsentDecision> {
        self.decisions
            .iter()
            .find(|d| d.extension_id == extension_id)
    }

    /// Replace whatever was decided before. Reinstalling is also how a manifest
    /// that grew a new permission gets asked about again.
    pub fn record(&mut self, decision: ConsentDecision) {
        self.decisions
            .retain(|d| d.extension_id != decision.extension_id);
        self.decisions.push(decision);
    }

    /// Take a permission back. It becomes an explicit refusal, so it survives
    /// a relaunch instead of quietly reverting to whatever the manifest wants.
    pub fn revoke(&mut self, extension_id: &str, kind: PermissionKind, key: &str) -> bool {
        let Some(decision) = self.decision_mut(extension_id) else {
            return false;
        };
        if !decision.grants(kind, key) {
            return false;
        }
        decision.refuse(kind, key);
        true
    }

    /// Give one back, from the same screen that took it away.
    pub fn grant(&mut self, extension_id: &str, kind: PermissionKind, key: &str) -> bool {
        let Some(decision) = self.decision_mut(extension_id) else {
            return false;
        };
        if decision.grants(kind, key) {
            return false;
        }
        decision.allow(kind, key);
        decision.grants(kind, key)
    }

    /// The engine refused a pattern we accepted. Stop claiming it is granted.
    pub fn mark_unreadable(&mut self, extension_id: &str, pattern: &str) {
        if let Some(decision) = self.decision_mut(extension_id) {
            decision.mark_unreadable(pattern);
        }
    }

    /// Uninstalling forgets the decision. Keeping it would mean a reinstall
    /// silently inherits an answer given about different code.
    pub fn forget(&mut self, extension_id: &str) {
        self.decisions.retain(|d| d.extension_id != extension_id);
    }

    fn decision_mut(&mut self, extension_id: &str) -> Option<&mut ConsentDecision> {
        self.decisions
            .iter_mut()
            .find(|d| d.extension_id == extension_id)
    }
}

/// What this browser holds for one extension, in the vocabulary every screen
/// that draws one needs.
///
/// **One answer, in the core.** The row in Settings, the button injected into
/// the store's own page and the banner all ask the same question — is it here,
/// was it decided, is it running — and three surfaces working it out from the
/// ledger themselves is three chances to disagree about what "running" means.
/// The store page is the reason this had to become a value rather than stay a
/// pair of `if`s in Swift: a button drawn in somebody else's page must never be
/// able to answer it from the page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ExtensionStanding {
    /// Nothing on disk under this id.
    NotInstalled,
    /// On disk, and nobody has said what it may do. It does not run, and the
    /// only useful thing to offer is the decision itself.
    Undecided,
    /// On disk, decided, and holding nothing. It does not run.
    GrantedNothing,
    /// On disk and running, holding `held` of the `asked` things it asked for.
    Running {
        held: u32,
        asked: u32,
        withheld: Withheld,
    },
}

/// What an extension asked for and did not get, in the only terms that change
/// what the browser may honestly say when something then goes wrong.
///
/// `held < asked` is arithmetic and answers the wrong question. A row that
/// sends somebody to a switch has to know whether that switch could have made
/// any difference, and a permission this browser cannot provide could not
/// (ADR-0084).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum Withheld {
    /// Everything it asked for, it holds.
    Nothing,
    /// At least one thing it asked for and did not get is something this
    /// browser could actually provide. Switching that on can change the
    /// outcome.
    SomethingProvidable,
    /// Everything it asked for and did not get is something this browser does
    /// not implement. There is no switch that would change anything.
    OnlyTheUnprovidable,
}

/// Read one extension's standing off the ledger.
///
/// `installed` and `asked` come from disk, which is why this takes them rather
/// than reading them: the words and the arithmetic are testable without a
/// package, and the file system stays on the other side of the FFI.
///
/// `asked` is the described request rather than a count of it, because
/// [`Withheld`] cannot be worked out from a number — it needs to know *which*
/// rows are not held, and whether this browser could have provided them.
pub fn standing(
    installed: bool,
    decision: Option<&ConsentDecision>,
    asked: &[PermissionRequest],
) -> ExtensionStanding {
    if !installed {
        return ExtensionStanding::NotInstalled;
    }
    // Absence is not an empty grant. It means nobody was asked — which is what
    // happens to anything installed before this browser started asking, and to
    // an install whose sheet was never answered.
    let Some(decision) = decision else {
        return ExtensionStanding::Undecided;
    };
    if decision.grants_nothing() {
        return ExtensionStanding::GrantedNothing;
    }
    let held = decision.granted_permissions.len() + decision.granted_hosts.len();
    ExtensionStanding::Running {
        held: held as u32,
        // A manifest that grew a permission since the decision can leave more
        // held than were asked about. Saying "3 of 2" would be the browser
        // reporting a count it cannot justify (ADR-0018).
        asked: asked.len().max(held) as u32,
        withheld: withheld(decision, asked),
    }
}

fn withheld(decision: &ConsentDecision, asked: &[PermissionRequest]) -> Withheld {
    let mut answer = Withheld::Nothing;
    for row in asked {
        if decision.grants(row.kind, &row.key) {
            continue;
        }
        if row.not_provided.is_none() {
            // One is enough, and it is the strongest answer there is.
            return Withheld::SomethingProvidable;
        }
        answer = Withheld::OnlyTheUnprovidable;
    }
    answer
}

/// Build the dialog's contents for one extension.
///
/// Takes the manifest's two lists rather than the manifest itself, so this
/// module stays out of the `ext` feature and can be tested without a CRX.
pub fn consent_request(
    extension_id: impl Into<String>,
    extension_name: impl Into<String>,
    api_permissions: &[String],
    host_patterns: &[String],
) -> ConsentRequest {
    let mut requests = Vec::new();
    let mut unreadable_hosts = Vec::new();

    for pattern in host_patterns {
        match describe_host(pattern) {
            Some(request) => requests.push(request),
            None => {
                if !unreadable_hosts.iter().any(|h| h == pattern) {
                    unreadable_hosts.push(pattern.clone());
                }
            }
        }
    }
    for permission in api_permissions {
        requests.push(describe_api(permission));
    }

    requests.sort_by(|a, b| {
        a.risk
            .severity()
            .cmp(&b.risk.severity())
            .then_with(|| kind_order(a.kind).cmp(&kind_order(b.kind)))
            .then_with(|| a.key.cmp(&b.key))
    });
    requests.dedup_by(|a, b| a.kind == b.kind && a.key == b.key);

    ConsentRequest {
        extension_id: extension_id.into(),
        extension_name: extension_name.into(),
        requests,
        unreadable_hosts,
    }
}

// MARK: - Host patterns

/// A match pattern, as far as the browser is willing to read one.
struct HostPattern {
    scheme: String,
    /// `*` in the host position: every site.
    all_hosts: bool,
    /// `*.example.com`: the domain and everything under it.
    subdomains: bool,
    /// The host with any leading `*.` removed. Empty for `file:`.
    domain: String,
}

/// The schemes Chrome's match-pattern grammar allows. Anything else is not a
/// pattern we understand, and something we do not understand is never granted.
const KNOWN_SCHEMES: [&str; 6] = ["*", "http", "https", "file", "ftp", "urn"];

/// Read a match pattern, or return `None` if it is not one.
///
/// Deliberately strict. Being generous here means presenting a guess as an
/// understanding, and the guess is what someone then approves.
fn parse_host_pattern(raw: &str) -> Option<HostPattern> {
    let raw = raw.trim();
    if raw == "<all_urls>" {
        return Some(HostPattern {
            scheme: "*".into(),
            all_hosts: true,
            subdomains: false,
            domain: String::new(),
        });
    }

    let (scheme, rest) = raw.split_once("://")?;
    let scheme = scheme.to_lowercase();
    if !KNOWN_SCHEMES.contains(&scheme.as_str()) {
        return None;
    }

    // Chrome's grammar requires a path, and the path is the part we do not
    // describe: "everything you do on the site" is true of `/*` and of
    // `/only/here/*` alike, because a script on one page of a site can reach
    // the rest of it.
    let (host, _path) = rest.split_once('/')?;
    let host = host.to_lowercase();

    if scheme == "file" {
        // `file:///…` has an empty host and nothing else is legal.
        return host.is_empty().then(|| HostPattern {
            scheme,
            all_hosts: false,
            subdomains: false,
            domain: String::new(),
        });
    }

    if host == "*" {
        return Some(HostPattern {
            scheme,
            all_hosts: true,
            subdomains: false,
            domain: String::new(),
        });
    }

    let (subdomains, domain) = match host.strip_prefix("*.") {
        Some(domain) => (true, domain),
        None => (false, host.as_str()),
    };
    // A `*` anywhere else is not a pattern Chrome accepts, and neither is an
    // empty host.
    if domain.is_empty() || domain.contains('*') {
        return None;
    }

    Some(HostPattern {
        scheme,
        all_hosts: false,
        subdomains,
        domain: domain.to_string(),
    })
}

/// Turn a match pattern into something worth reading, or `None` if it is not
/// a pattern at all.
fn describe_host(raw: &str) -> Option<PermissionRequest> {
    let pattern = parse_host_pattern(raw)?;

    let (risk, title, detail) = if pattern.scheme == "file" {
        (
            PermissionRisk::Critical,
            "Read the files on this Mac that you open in the browser".to_string(),
            "Anything you open with a file:// address, wherever it is on disk.".to_string(),
        )
    } else if pattern.all_hosts {
        (
            PermissionRisk::Critical,
            "Read and change everything you do on every site".to_string(),
            format!(
                "Every page you open, including your bank, your email and anything you are \
                 signed in to. It can see what is on the page, read what you type into it, \
                 and change what you see.{}",
                scheme_note(&pattern.scheme)
            ),
        )
    } else if pattern.subdomains {
        (
            PermissionRisk::High,
            format!(
                "Read and change everything you do on {} and every site under it",
                pattern.domain
            ),
            format!(
                "Every page on {} and on its subdomains, including anything you are signed \
                 in to there.{}",
                pattern.domain,
                scheme_note(&pattern.scheme)
            ),
        )
    } else {
        (
            PermissionRisk::Moderate,
            format!("Read and change everything you do on {}", pattern.domain),
            format!(
                "Every page on {}, including anything you are signed in to there.{}",
                pattern.domain,
                scheme_note(&pattern.scheme)
            ),
        )
    };

    Some(PermissionRequest {
        key: raw.trim().to_string(),
        kind: PermissionKind::Site,
        risk,
        title,
        detail,
        default_granted: true,
        // Site access is the one thing this engine implements without a gap.
        not_provided: None,
    })
}

/// Said only when it narrows anything. `*` narrows nothing, so it says nothing.
fn scheme_note(scheme: &str) -> &'static str {
    match scheme {
        "https" => " Encrypted pages, which in practice is all of them.",
        "http" => " Unencrypted pages only.",
        "ftp" => " FTP addresses only.",
        "urn" => " urn: addresses only.",
        _ => "",
    }
}

// MARK: - API permissions

/// Whether granting a permission would reach anything, and which kind of
/// nothing it reaches when it would not.
///
/// **Only something the vocabulary describes can be called unprovided.** A
/// permission with no arm is one nobody has looked at, and either sentence
/// below about a key nobody has measured would be the browser asserting a fact
/// it does not have (ADR-0018). Those stay switchable and keep saying that we
/// cannot explain them, which is the true statement.
///
/// **The declined list is asked first, and that is the decision rather than an
/// ordering detail.** A position does not become a gap because an engine caught
/// up: the day WebKit ships `chrome.management`, this browser still does not
/// let one extension switch off another, and asking `ENGINE_PROVIDES` first
/// would silently turn that refusal back into a live switch.
fn not_provided(key: &str) -> Option<NotProvided> {
    let (risk, _, _) = api_description(key);
    if risk == PermissionRisk::Unknown {
        return None;
    }
    if let Some((_, position)) = DECLINED.iter().find(|(declined, _)| *declined == key) {
        return Some(NotProvided::Declined {
            sentence: format!("zer0 will not provide this — {position}"),
        });
    }
    if ENGINE_PROVIDES.contains(&key) || ZER0_PROVIDES.contains(&key) {
        return None;
    }
    Some(NotProvided::NotBuiltYet {
        sentence: NOT_BUILT_YET.to_string(),
    })
}

/// What a `chrome.*` permission actually costs you.
///
/// Written as consequences rather than as names. "webNavigation" tells you
/// nothing; "sees every page you go to, as you go to it" tells you whether you
/// mind.
fn describe_api(key: &str) -> PermissionRequest {
    let (risk, title, detail) = api_description(key);
    let not_provided = not_provided(key);
    PermissionRequest {
        key: key.to_string(),
        kind: PermissionKind::Api,
        risk,
        title: title.to_string(),
        detail: detail.to_string(),
        // Two reasons to arrive unticked, and they are not the same reason.
        // Unknown: nobody wrote the sentence, so there is no informed consent
        // to be had. Not provided: there is nothing to consent *to*, and
        // writing down an approval that reaches nothing is the fail-open
        // direction should `ENGINE_PROVIDES` ever be wrong (ADR-0084).
        default_granted: risk != PermissionRisk::Unknown && not_provided.is_none(),
        not_provided,
    }
}

/// What a row says when the thing it asks for is work nobody has done.
///
/// One sentence for all of them, because there is one fact: the API is not in
/// the extension's context and this browser has not put one there. A
/// per-permission variation would be prose invented around a single measured
/// fact.
///
/// **"yet" is the whole of it, and it promises nothing else.** No date, no
/// order, no undertaking that it will ever be done — only that this is a gap
/// rather than a position, which is the one thing a reader cannot work out from
/// a missing switch. What tells it apart from [`DECLINED`] on screen is that
/// word and the verb beside it: *does not … yet* against *will not*.
///
/// Short because it repeats. 1Password asks for six of these, and the line that
/// finished "…so a switch would change nothing" was measured at two wrapped
/// lines apiece — six identical paragraphs stacked down the block, which reads
/// as a rendering fault rather than as six rows with the same status.
const NOT_BUILT_YET: &str = "zer0 does not provide this yet — WebKit does not implement it.";

/// The permissions this browser refuses, and the position it refuses each from.
///
/// **These are not waiting on WebKit.** Every one of them would still be
/// refused on an engine that shipped the API in the next release, which is why
/// [`not_provided`] reads this list before it reads either providing list. The
/// sentence is a position stated in one clause, not an apology and not a
/// promise: nothing here says "yet", and nothing here blames the engine.
///
/// Faking any of them is the specific harm. `privacy` hands an extension a
/// switch it believes turned a protection off; the protection is still on, the
/// extension reports success to the person who installed it, and nothing
/// anywhere is wrong enough to notice. `management` is worse in kind rather
/// than in degree — one extension quietly removing another is a thing this
/// browser should not be able to do at all, so it is refused at the door rather
/// than left unimplemented, where it would read as a gap somebody might helpfully
/// fill.
///
/// `management.getSelf` is not covered by this and does not need to be: it
/// needs no permission in Chrome either, it answers out of the extension's own
/// manifest, and the compatibility file provides it from facts the extension
/// already holds.
const DECLINED: [(&str, &str); 5] = [
    (
        "contentSettings",
        "what a site may do is set in zer0's own settings.",
    ),
    (
        "debugger",
        "nothing gets the developer tools' reach over every page.",
    ),
    (
        "management",
        "one extension does not get to switch off another.",
    ),
    (
        "privacy",
        "your privacy and security settings are yours to change.",
    ),
    (
        "proxy",
        "where your traffic goes is not an extension's to redirect.",
    ),
];

/// The `chrome.*` permissions **zer0** answers itself, because WebKit does not.
///
/// Kept apart from [`ENGINE_PROVIDES`] on purpose, and the reason is that the
/// other list is a *measurement* of what Apple's engine installs. Folding these
/// into it would make it a measurement of nothing and cost the next person the
/// one thing it is for — re-running the harness on a new macOS and seeing what
/// changed. Both lists answer the same question for a row on screen; only one
/// of them is a fact about WebKit.
///
/// What lands here is what `crates/zer0-core/src/ext/api.rs` really carries out
/// and `ext/compat.js` really installs. A key added here and nowhere else is a
/// switch that changes nothing, which is the exact defect ADR-0084 removed.
const ZER0_PROVIDES: [&str; 3] = ["downloads", "downloads.open", "idle"];

/// The `chrome.*` permissions whose API this browser's engine really installs.
///
/// **A list of what works rather than a list of what does not, on purpose.** A
/// permission nobody has measured is one this browser has no evidence about,
/// and the fail-closed answer for no evidence is to keep offering the switch —
/// the opposite list would silently mark every permission added to Chrome after
/// today as something we can prove is inert (ADR-0018).
///
/// Measured on macOS 26.6 by loading a generated MV3 extension into a real
/// `WKWebExtensionController`, granting every permission in it, and asking the
/// background service worker `typeof chrome[name]` for each. Seventeen
/// namespaces exist; twenty-five of the permissions this file describes gate a
/// namespace that does not, whatever is granted. Two of those seventeen —
/// `menus` and `contextMenus` — are one namespace under two spellings, and
/// `activeTab`, `clipboardRead`, `clipboardWrite`, `favicon`, `geolocation`,
/// `nativeMessaging`, `unlimitedStorage`, `background`,
/// `webRequestAuthProvider`, `webRequestBlocking` and
/// `declarativeNetRequestFeedback` are here because they gate something other
/// than a namespace, so their absence is not something this measurement can
/// see. They keep their switch; see ADR-0084 for why that is the honest
/// default and not a shrug.
const ENGINE_PROVIDES: [&str; 22] = [
    "activeTab",
    "alarms",
    "background",
    "clipboardRead",
    "clipboardWrite",
    "contextMenus",
    "cookies",
    "declarativeNetRequest",
    "declarativeNetRequestFeedback",
    "declarativeNetRequestWithHostAccess",
    "favicon",
    "geolocation",
    "menus",
    "nativeMessaging",
    "scripting",
    "storage",
    "tabs",
    "unlimitedStorage",
    "webNavigation",
    "webRequest",
    "webRequestAuthProvider",
    "webRequestBlocking",
];

fn api_description(key: &str) -> (PermissionRisk, &'static str, &'static str) {
    use PermissionRisk::{Critical, High, Low, Moderate, Unknown};

    match key {
        "debugger" => (
            Critical,
            "Take complete control of the browser",
            "The same reach the developer tools have: every page, every request, and \
             everything you type into any of them.",
        ),
        "nativeMessaging" => (
            Critical,
            "Talk to programs installed on this Mac",
            "It can exchange messages with software outside the browser, and the browser \
             cannot see what that software then does.",
        ),
        "proxy" => (
            Critical,
            "Send everything you browse through a server it chooses",
            "Every page you load can be routed somewhere else first, without anything on \
             screen changing.",
        ),
        "desktopCapture" => (
            Critical,
            "Capture your screen",
            "Not only the browser: whatever is in front of you when it asks.",
        ),
        "webAuthenticationProxy" => (
            Critical,
            "Stand between you and your security key",
            "Sign-ins that rely on a passkey or a hardware key go through it first.",
        ),
        "cookies" => (
            High,
            "Read and change the cookies that keep you signed in",
            "A cookie is what proves to a site that you are you. Reading one can be enough \
             to act as you.",
        ),
        "history" => (
            High,
            "Read and erase your entire browsing history",
            "Every page you have visited, going back as far as the record does, and the \
             ability to delete it.",
        ),
        "browsingData" => (
            High,
            "Erase your browsing data whenever it likes",
            "History, cookies, caches and saved site data, on its own schedule rather than \
             yours.",
        ),
        "tabs" => (
            High,
            "See the address and title of every tab you have open",
            "Across every window, whether or not you are looking at it. Kept over time, \
             that is a record of what you browse.",
        ),
        "webNavigation" => (
            High,
            "See every page you go to, as you go to it",
            "Each navigation is reported to the extension while it happens.",
        ),
        "webRequest" => (
            High,
            "See every request the browser sends on the sites it can reach",
            "Not just pages: the images, scripts and background calls each page makes.",
        ),
        "webRequestBlocking" => (
            High,
            "Block or rewrite requests before they are sent",
            "It sits in front of the network for the sites it can reach.",
        ),
        "management" => (
            High,
            "See, switch off and remove your other extensions",
            "Including the ones you rely on to block or protect something.",
        ),
        "privacy" => (
            High,
            "Change your privacy and security settings",
            "The browser's own protections are among the things it can turn off.",
        ),
        "downloads" => (
            High,
            "See your downloads and start new ones",
            "Everything you have downloaded, plus the ability to start a download you did \
             not ask for.",
        ),
        // Chrome's own separate key, and separate for a good reason: starting a
        // download puts a file on the disk, and opening one hands it to whatever
        // the system opens that kind of file with. The second is a way out of
        // the browser, so it is its own answer rather than a rider on the first.
        "downloads.open" => (
            Critical,
            "Open the files you have downloaded",
            "It can hand a downloaded file to whatever program opens that kind of file, \
             which is a way out of the browser entirely.",
        ),
        "clipboardRead" => (
            High,
            "Read whatever you copy",
            "Including a password copied out of a password manager.",
        ),
        "userScripts" => (
            High,
            "Run code it was handed later on the sites it can reach",
            "Not the code that came in the package: scripts given to it afterwards, which nobody \
             reviewed before they ran on your pages.",
        ),
        "webRequestAuthProvider" => (
            High,
            "Answer the sign-in prompts a site or a proxy puts up",
            "It can supply the username and password a protected site demands, in place of the \
             box the browser would have shown you.",
        ),
        "declarativeNetRequestWithHostAccess" => (
            High,
            "Block, redirect and rewrite requests on the sites it can reach",
            "The rules travel inside the extension; the browser applies them without \
             showing them to you.",
        ),
        "pageCapture" => (
            High,
            "Save a whole page exactly as it reached you",
            "The complete page, including everything on it that you had to sign in to see.",
        ),
        "tabCapture" => (
            High,
            "Record what a tab is showing and playing",
            "A live stream of the picture and the sound, not a snapshot.",
        ),
        "identity" => (
            Moderate,
            "See the account you are signed in with",
            "Usually the email address, so the extension can tie what it stores to you.",
        ),
        "bookmarks" => (
            Moderate,
            "Read and change your bookmarks",
            "Including adding and deleting them without asking.",
        ),
        "geolocation" => (
            Moderate,
            "See where you are",
            "Your location, as precisely as this Mac can work it out.",
        ),
        "topSites" => (
            Moderate,
            "See the sites you visit most",
            "A short list, but it is a list about you.",
        ),
        "sessions" => (
            Moderate,
            "See and reopen tabs you recently closed",
            "Including the ones you closed on purpose.",
        ),
        "scripting" => (
            Moderate,
            "Run its own code on the sites it can already reach",
            "Bounded by the site access above it, and no further.",
        ),
        "declarativeNetRequest" => (
            Moderate,
            "Block and redirect requests using rules you cannot read",
            "This is how a blocker works. The rules ship inside the extension; the browser \
             applies them without showing them to you.",
        ),
        "declarativeNetRequestFeedback" => (
            Moderate,
            "See which of its own blocking rules matched",
            "Diagnostics for the rules above; it reveals the addresses they matched.",
        ),
        "contentSettings" => (
            Moderate,
            "Change what sites are allowed to do",
            "Such as which sites may run scripts, show notifications or use your camera.",
        ),
        "activeTab" => (
            Low,
            "Read and change the page you are on, only when you click it",
            "Nothing happens until you use the extension, and then only on that one tab.",
        ),
        "storage" => (
            Low,
            "Store its own settings on this Mac",
            "Its own data, in its own place. It cannot read anyone else's.",
        ),
        "unlimitedStorage" => (
            Low,
            "Store as much on this Mac as it likes",
            "The cap that normally limits how much disk an extension may take does not apply \
             to it.",
        ),
        "alarms" => (
            Low,
            "Schedule its own background work",
            "So it can do something on a timer instead of only while you watch.",
        ),
        "contextMenus" => (
            Low,
            "Add items to the right-click menu",
            "Its own entries, alongside the browser's.",
        ),
        // Firefox's name for the permission above. An extension built for both
        // browsers declares both spellings, and a manifest that does gets two
        // rows — so they had better not be two of the same sentence.
        "menus" => (
            Low,
            "Add items to the right-click menu, asked for under Firefox's name for it",
            "The same thing as the entry Chrome calls contextMenus. This browser acts on \
             Chrome's spelling, so granting this one on its own changes nothing.",
        ),
        "notifications" => (
            Low,
            "Show you notifications",
            "The same ones any app on this Mac can show.",
        ),
        "clipboardWrite" => (
            Low,
            "Put things on your clipboard",
            "It can replace what you last copied; it cannot read it.",
        ),
        "idle" => (
            Low,
            "Tell when you have stepped away",
            "Whether the machine is idle, and nothing about what you were doing.",
        ),
        "power" => (
            Low,
            "Keep this Mac from going to sleep",
            "Nothing else, and only while it is running.",
        ),
        "favicon" => (
            Low,
            "Read the icons sites use",
            "The small image in a tab, and nothing around it.",
        ),
        "fontSettings" => (
            Low,
            "Change which fonts pages use",
            "How pages look, not what they contain.",
        ),
        "tabGroups" => (
            Low,
            "See and change your tab groups",
            "How tabs are grouped, not what is in them.",
        ),
        "search" => (
            Low,
            "Run searches on your behalf",
            "It can open a search in a tab; it does not see the results.",
        ),
        "background" => (
            Low,
            "Keep running while the browser is open",
            "Even when none of its windows are on screen.",
        ),
        "offscreen" => (
            Low,
            "Work in a page that is never on screen",
            "A hidden document of its own, which is where an extension does the things only a \
             page can do — playing a sound, reading the clipboard, parsing HTML.",
        ),
        "sidePanel" => (
            Low,
            "Put a panel of its own beside the page",
            "Its own interface, in a column next to what you are reading, when you open it.",
        ),
        _ => (
            Unknown,
            "Something zer0 cannot explain",
            "This permission is not one zer0 has a description for, so it cannot tell you \
             what granting it allows. It is off unless you switch it on.",
        ),
    }
}

#[cfg(test)]
#[path = "extension_permissions_tests.rs"]
mod tests;
