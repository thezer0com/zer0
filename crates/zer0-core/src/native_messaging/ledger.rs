//! Which programs an extension has been allowed to start.
//!
//! ## Why there is a second answer at all
//!
//! ADR-0028 asks once, at install, and `nativeMessaging` reads *"Talk to
//! programs installed on this Mac"*. That sentence is true and it is the most
//! that could honestly be said at that moment: which program is not knowable
//! then, because the registration that names it belongs to whatever installed
//! the desktop app and may not exist yet.
//!
//! So the second question is not a second grant. It is the same grant, asked
//! again at the one moment its object exists — *this* program, at *this* path,
//! registered by *this* browser. A person who granted "talk to programs" did
//! not grant "run `/Applications/Something.app/…/helper`", and the difference
//! is the whole of what makes the first answer informed.
//!
//! ## Keyed by the program and not by the name it was asked for
//!
//! `chrome.runtime.connectNative` names an application id, and an id is a
//! string a package chooses. What runs is a path, and a path is what a person
//! can be shown. Keying the answer on the path means two ids resolving to one
//! program are one question, which is not a tidying: 1Password's extension asks
//! for `com.1password.1password` and then `com.1password.1password7` on the
//! first press of its button, and a ledger keyed on the id would put two sheets
//! on screen for one decision.
//!
//! It also means a registration that is later repointed at a different program
//! is a new question, which is the behaviour to want: the answer was about the
//! program, so it does not travel to another one.

/// One answer about one program, for one extension.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct NativeHostDecision {
    pub extension_id: String,
    /// The absolute path of the program, exactly as the registration named it.
    pub program: String,
    pub allowed: bool,
    pub decided_at_ms: u64,
}

/// Every answer anybody has given, in the order they were given.
///
/// A refusal is stored rather than inferred from absence, for the reason
/// ADR-0028 gives: absence has to keep meaning *nobody was asked*, because that
/// is what happens when an extension reaches for a program it has never reached
/// for before. A ledger that could not tell the two apart would re-ask a
/// question somebody has already said no to, on every press, forever.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct NativeHostLedger {
    entries: Vec<NativeHostDecision>,
}

impl NativeHostLedger {
    pub fn new() -> Self {
        Self::default()
    }

    /// Rebuild from storage.
    pub fn load(entries: Vec<NativeHostDecision>) -> Self {
        Self { entries }
    }

    /// Everything decided, for the store to write down.
    pub fn all(&self) -> &[NativeHostDecision] {
        &self.entries
    }

    /// What was said about this extension starting this program, or `None` for
    /// a question nobody has been asked.
    pub fn decision(&self, extension_id: &str, program: &str) -> Option<&NativeHostDecision> {
        self.entries
            .iter()
            .find(|e| e.extension_id == extension_id && e.program == program)
    }

    /// Record an answer, replacing any earlier one about the same program.
    ///
    /// Replacing in place keeps the order things were first asked in, which is
    /// the order the Extensions screen lists them in.
    pub fn record(&mut self, decision: NativeHostDecision) {
        if let Some(existing) = self
            .entries
            .iter_mut()
            .find(|e| e.extension_id == decision.extension_id && e.program == decision.program)
        {
            *existing = decision;
            return;
        }
        self.entries.push(decision);
    }

    /// The programs this extension may start, in the order they were allowed.
    pub fn allowed_programs(&self, extension_id: &str) -> Vec<String> {
        self.entries
            .iter()
            .filter(|e| e.extension_id == extension_id && e.allowed)
            .map(|e| e.program.clone())
            .collect()
    }

    /// Forget an extension entirely, on uninstall.
    ///
    /// The same rule as the consent ledger and the pins next door: a reinstall
    /// is different code and must not inherit permission to start a program
    /// that was granted to whatever held the id before it.
    pub fn forget(&mut self, extension_id: &str) {
        self.entries.retain(|e| e.extension_id != extension_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decision(extension: &str, program: &str, allowed: bool) -> NativeHostDecision {
        NativeHostDecision {
            extension_id: extension.to_string(),
            program: program.to_string(),
            allowed,
            decided_at_ms: 1_000,
        }
    }

    #[test]
    fn nobody_has_been_asked_about_a_program_nobody_has_been_asked_about() {
        let ledger = NativeHostLedger::new();

        assert!(ledger.decision("a", "/bin/helper").is_none());
    }

    /// The difference this ledger exists to hold. A refusal that read as
    /// "not asked" would put the sheet back on screen at every press.
    #[test]
    fn a_refusal_is_a_recorded_answer_and_not_an_absence() {
        let mut ledger = NativeHostLedger::new();
        ledger.record(decision("a", "/bin/helper", false));

        let answer = ledger.decision("a", "/bin/helper").expect("it was asked");
        assert!(!answer.allowed);
        assert!(ledger.allowed_programs("a").is_empty());
    }

    /// An answer is about one extension and one program. Neither half travels.
    #[test]
    fn an_answer_about_one_extension_says_nothing_about_another() {
        let mut ledger = NativeHostLedger::new();
        ledger.record(decision("a", "/bin/helper", true));

        assert!(ledger.decision("b", "/bin/helper").is_none());
        assert!(ledger.decision("a", "/bin/other").is_none());
    }

    #[test]
    fn answering_again_replaces_the_answer_and_keeps_the_place() {
        let mut ledger = NativeHostLedger::new();
        ledger.record(decision("a", "/bin/one", true));
        ledger.record(decision("a", "/bin/two", true));
        ledger.record(decision("a", "/bin/one", false));

        assert_eq!(ledger.all().len(), 3 - 1);
        assert_eq!(ledger.allowed_programs("a"), ["/bin/two"]);
        assert_eq!(ledger.all()[0].program, "/bin/one");
    }

    #[test]
    fn uninstalling_takes_every_answer_with_it() {
        let mut ledger = NativeHostLedger::new();
        ledger.record(decision("a", "/bin/one", true));
        ledger.record(decision("b", "/bin/one", true));

        ledger.forget("a");

        assert!(ledger.decision("a", "/bin/one").is_none());
        assert!(ledger.decision("b", "/bin/one").is_some());
    }
}
