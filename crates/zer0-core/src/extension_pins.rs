//! Which extension buttons are on show, and in what order.
//!
//! An extension with no visible affordance is not an extension: 1Password
//! exists to be clicked. But a browser that shows every installed extension
//! forever is the toolbar ADR-0010 refuses, so which ones are on show is a
//! choice, and a choice a person makes is a preference — which means it lives
//! here and survives a relaunch (ADR-0045), rather than in whichever view drew
//! the row last.
//!
//! ## Why an entry rather than a list of ids
//!
//! The obvious shape is `Vec<String>` of what is pinned. It cannot express the
//! difference between *"nobody has ever decided about this extension"* and
//! *"somebody deliberately took this one off the row"*, and those have to be
//! different, for the reason ADR-0028 gives about denied permissions: a new
//! extension that declares a button is pinned on arrival, because an extension
//! that installs with nowhere to click it is the defect this exists to fix. If
//! absence meant "not pinned", that rule would re-pin, on every launch, the one
//! extension somebody went out of their way to hide.
//!
//! So an entry is written for every extension the browser has ever adopted, and
//! it carries the answer. Absence means *not asked yet*, exactly as it does in
//! the consent ledger next door.

/// One extension's place in the row, or its deliberate absence from it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ExtensionPin {
    pub extension_id: String,
    pub pinned: bool,
}

/// Every extension the browser has taken a view on, in the order they are
/// drawn.
///
/// The order is the order they were adopted. That is a real order and it is
/// stable — the same extension keeps the same place, launch after launch, which
/// is what makes a chord like ⇧⌘1 mean the same thing tomorrow — and it is
/// deliberately not a rearrangeable one. A reordering gesture with nothing to
/// perform it would be an order nobody can see and nobody can change.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ExtensionPins {
    entries: Vec<ExtensionPin>,
}

impl ExtensionPins {
    pub fn new() -> Self {
        Self::default()
    }

    /// Rebuild from storage. Order is data (ADR-0045 clause 3): the caller
    /// hands these back in the order they were written.
    pub fn load(entries: Vec<ExtensionPin>) -> Self {
        Self { entries }
    }

    /// Everything decided, in order, for the store to write down.
    pub fn all(&self) -> &[ExtensionPin] {
        &self.entries
    }

    /// The ids on show, in the order they are drawn.
    ///
    /// This is the ordering the shell renders and the chords index into, so it
    /// is computed here rather than by whoever is drawing.
    pub fn pinned_ids(&self) -> Vec<String> {
        self.entries
            .iter()
            .filter(|e| e.pinned)
            .map(|e| e.extension_id.clone())
            .collect()
    }

    /// Whether this extension is on show. An extension nobody has decided about
    /// is not — [`Self::adopt`] is what turns "not asked" into "yes".
    pub fn is_pinned(&self, extension_id: &str) -> bool {
        self.entries
            .iter()
            .any(|e| e.extension_id == extension_id && e.pinned)
    }

    /// Whether anyone has ever taken a view on this extension.
    pub fn decided(&self, extension_id: &str) -> bool {
        self.entries.iter().any(|e| e.extension_id == extension_id)
    }

    /// Somebody chose. Keeps the place an already-known extension has, so
    /// unpinning and pinning again does not shuffle it to the end and silently
    /// re-point every chord after it.
    pub fn decide(&mut self, extension_id: &str, pinned: bool) {
        if let Some(existing) = self
            .entries
            .iter_mut()
            .find(|e| e.extension_id == extension_id)
        {
            existing.pinned = pinned;
            return;
        }
        self.entries.push(ExtensionPin {
            extension_id: extension_id.to_string(),
            pinned,
        });
    }

    /// Put an extension on the row because it has just started running and
    /// nobody has said otherwise.
    ///
    /// Returns whether anything changed, so a caller can avoid a save that has
    /// nothing in it. **Once only, by construction**: an extension that has been
    /// unpinned is already decided, so this does nothing to it. That is the
    /// whole reason a decision is written down rather than inferred.
    pub fn adopt(&mut self, extension_id: &str) -> bool {
        if self.decided(extension_id) {
            return false;
        }
        self.entries.push(ExtensionPin {
            extension_id: extension_id.to_string(),
            pinned: true,
        });
        true
    }

    /// Forget an extension entirely, on uninstall.
    ///
    /// A reinstall is different code and has to be adopted again, for the same
    /// reason `ExtensionConsent::forget` exists: an answer given about one
    /// package must not be inherited by another wearing its id.
    pub fn forget(&mut self, extension_id: &str) {
        self.entries.retain(|e| e.extension_id != extension_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_extension_nobody_decided_about_is_not_on_the_row() {
        let pins = ExtensionPins::new();
        assert!(!pins.is_pinned("a"));
        assert!(!pins.decided("a"));
    }

    #[test]
    fn an_adopted_extension_is_on_the_row() {
        let mut pins = ExtensionPins::new();
        assert!(pins.adopt("a"));
        assert!(pins.is_pinned("a"));
    }

    /// The whole reason a refusal is stored rather than inferred from absence.
    /// Adoption runs every time an extension starts, which is every launch.
    #[test]
    fn adopting_never_undoes_a_deliberate_unpinning() {
        let mut pins = ExtensionPins::new();
        pins.adopt("a");
        pins.decide("a", false);

        assert!(!pins.adopt("a"), "a decided extension is not adopted again");
        assert!(!pins.is_pinned("a"));
    }

    #[test]
    fn the_row_keeps_the_order_things_arrived_in() {
        let mut pins = ExtensionPins::new();
        pins.adopt("a");
        pins.adopt("b");
        pins.adopt("c");

        assert_eq!(pins.pinned_ids(), ["a", "b", "c"]);
    }

    /// Chords index into this list, so a round trip through the row must not
    /// move anything: ⇧⌘2 meaning a different extension after you hid and
    /// showed one is exactly the kind of quiet defect nobody files.
    #[test]
    fn hiding_one_and_showing_it_again_leaves_it_where_it_was() {
        let mut pins = ExtensionPins::new();
        pins.adopt("a");
        pins.adopt("b");
        pins.adopt("c");

        pins.decide("b", false);
        assert_eq!(pins.pinned_ids(), ["a", "c"]);

        pins.decide("b", true);
        assert_eq!(pins.pinned_ids(), ["a", "b", "c"]);
    }

    #[test]
    fn uninstalling_takes_the_decision_with_it() {
        let mut pins = ExtensionPins::new();
        pins.adopt("a");
        pins.decide("a", false);

        pins.forget("a");

        assert!(!pins.decided("a"));
        // And a reinstall starts over rather than inheriting the answer given
        // about the code that used to hold the id.
        assert!(pins.adopt("a"));
        assert!(pins.is_pinned("a"));
    }

    #[test]
    fn deciding_about_something_never_seen_records_it() {
        let mut pins = ExtensionPins::new();
        pins.decide("a", false);

        assert!(pins.decided("a"));
        assert!(!pins.is_pinned("a"));
        assert_eq!(pins.all().len(), 1);
    }
}
