//! Addresses somebody decided to keep.
//!
//! A bookmark is the fourth thing this browser can do with a page, and its
//! whole point is that it is **not** a tab. A favorite crosses spaces, a pinned
//! tab belongs to one, and a `Today` tab expires on its own — all three cost a
//! web view, a row in the list you look at all day, and memory. A bookmark
//! costs an address and a name. That is the job "I want to read this in March"
//! actually needs, and no tab does it: keeping a tab open for eight months is
//! not keeping a page, it is paying rent on one.
//!
//! Three things are deliberately absent, and each absence is the decision:
//!
//! **No space.** [`Bookmark`] has no field for one, so no store can write down
//! which space a page was saved from and no rule about it can be got wrong. A
//! space is a cookie jar and an identity (ADR-0007); a bookmark holds neither.
//! It is an address and a word, and where it *opens* is already answered by the
//! routing table (ADR-0026), which is the one place in this browser that
//! decides which jar a URL belongs in. Scoping bookmarks to a space would be a
//! second answer to a question that already has one, and the two would drift.
//!
//! **No tree.** Folders make you answer "where does this go" at the moment you
//! know least — the moment you are saving it — and they can only ever hold one
//! answer. Tags are optional, plural, and added later. A bookmark with no tags
//! is complete. This is affordable because retrieval is
//! [`crate::command_bar`], which already ranks and fuzzy-matches: structure is
//! what you build when search does not work.
//!
//! **No parent, no order you maintain.** The list is newest-kept-first, derived
//! from [`Bookmark::saved_at_ms`], so there is no stored order that can
//! disagree with the data.
//!
//! ADR-0059 records why each of those is the decision rather than the shortcut,
//! and ADR-0061 records why ⌘D is the chord that reaches this.

/// How many tags one bookmark may carry.
///
/// Not a UI limit — a bound on what ranking has to walk. Tags arrive from a
/// person and from disk, and ADR-0024 says the file is hostile: a hand-edited
/// row with ten thousand tags on it would be paid for on every keystroke in the
/// command bar. Nobody labels one page sixteen ways.
pub const MAX_TAGS: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct BookmarkId(pub u64);

#[cfg(feature = "ffi")]
uniffi::custom_newtype!(BookmarkId, u64);

/// One kept address.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Bookmark {
    pub id: BookmarkId,
    pub url: String,
    /// What the page called itself when it was kept, or whatever it was
    /// renamed to since. May be empty; see [`Bookmark::display_title`].
    pub title: String,
    /// Lowercased, trimmed, in the order they were given. Never empty strings,
    /// never duplicated.
    pub tags: Vec<String>,
    /// When the decision to keep it was taken. Not "when it was last opened":
    /// that would make the list reorder itself under the person as a side
    /// effect of reading, which is the one thing a list you filed has to not do.
    pub saved_at_ms: u64,
}

impl Bookmark {
    /// What a row shows: the title, else the address. Never a placeholder —
    /// unlike a tab, a bookmark always has an address, because there is no way
    /// to make one without it.
    pub fn display_title(&self) -> &str {
        if self.title.is_empty() {
            &self.url
        } else {
            &self.title
        }
    }
}

/// Everything kept, newest first.
///
/// The invariant this type holds is one bookmark per URL. It is held here
/// rather than by a `UNIQUE` constraint in a backend because a constraint
/// violation on save fails the whole transaction, and by ADR-0017 losing a
/// save is losing the session — a duplicate row is worth strictly less than
/// that.
#[derive(Debug, Clone, PartialEq)]
pub struct Bookmarks {
    /// Newest `saved_at_ms` first. This ordering is the type's, not a caller's:
    /// there is one order a person can predict without reading the list, and
    /// keeping it here means no view has to sort and get it slightly different.
    entries: Vec<Bookmark>,
    next_id: u64,
}

/// Written out rather than derived, because a derived one would start
/// `next_id` at zero and hand the first bookmark `BookmarkId(0)` — an id every
/// other counter in this crate treats as "nothing".
impl Default for Bookmarks {
    fn default() -> Self {
        Self::new()
    }
}

impl Bookmarks {
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
            next_id: 1,
        }
    }

    /// Keep this page.
    ///
    /// **Keeping a page that is already kept changes nothing** and hands back
    /// the bookmark that was already there. Not a no-op out of tidiness: ⌘D is
    /// a chord fingers press without looking, and a second press that
    /// overwrote a title somebody had edited — or worse, removed the
    /// bookmark — would make the safest key in the browser destructive.
    /// Removing is [`Bookmarks::remove`], which nothing reaches by accident.
    ///
    /// `None` for an empty address. There is nothing to go back to.
    pub fn save(&mut self, url: &str, title: &str, now_ms: u64) -> Option<BookmarkId> {
        if url.is_empty() {
            return None;
        }
        if let Some(existing) = self.entries.iter().find(|b| b.url == url) {
            return Some(existing.id);
        }

        let id = BookmarkId(self.next_id);
        // Saturating for the same reason tab ids are: a corrupt row can push
        // the counter to the top, and wrapping to zero would start handing out
        // ids that collide with bookmarks somebody still has.
        self.next_id = self.next_id.saturating_add(1);

        self.entries.insert(
            0,
            Bookmark {
                id,
                url: url.to_string(),
                title: title.to_string(),
                tags: Vec::new(),
                saved_at_ms: now_ms,
            },
        );
        Some(id)
    }

    /// Rename one, or relabel it. The only thing that edits a bookmark.
    ///
    /// `saved_at_ms` is untouched, so renaming does not shuffle the list under
    /// whoever is looking at it.
    pub fn edit(&mut self, id: BookmarkId, title: &str, tags: &[String]) -> bool {
        let tags = normalise_tags(tags);
        match self.entries.iter_mut().find(|b| b.id == id) {
            Some(bookmark) => {
                bookmark.title = title.to_string();
                bookmark.tags = tags;
                true
            }
            None => false,
        }
    }

    pub fn remove(&mut self, id: BookmarkId) -> bool {
        let before = self.entries.len();
        self.entries.retain(|b| b.id != id);
        before != self.entries.len()
    }

    /// Newest kept first.
    pub fn all(&self) -> &[Bookmark] {
        &self.entries
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The bookmark for this exact address, if there is one.
    ///
    /// What the interface asks to know whether ⌘D on this page would keep it or
    /// has already kept it.
    pub fn for_url(&self, url: &str) -> Option<&Bookmark> {
        self.entries.iter().find(|b| b.url == url)
    }

    pub fn get(&self, id: BookmarkId) -> Option<&Bookmark> {
        self.entries.iter().find(|b| b.id == id)
    }

    /// Every tag in use, alphabetically, each once.
    pub fn tags(&self) -> Vec<String> {
        let mut all: Vec<String> = self
            .entries
            .iter()
            .flat_map(|b| b.tags.iter().cloned())
            .collect();
        all.sort_unstable();
        all.dedup();
        all
    }

    /// Rebuild from storage.
    ///
    /// Everything a backend could have got wrong is corrected here rather than
    /// trusted, because by ADR-0024 the file is hostile even when we wrote it:
    /// the order is recomputed from the data, duplicate addresses collapse to
    /// the one kept longest, tags are re-normalised, and `next_id` is put past
    /// anything present so a new bookmark cannot land on an id somebody is
    /// still holding.
    pub fn load(entries: Vec<Bookmark>) -> Self {
        let next_id = entries
            .iter()
            .map(|b| b.id.0)
            .max()
            .unwrap_or(0)
            .saturating_add(1);

        let mut entries: Vec<Bookmark> = entries
            .into_iter()
            .filter(|b| !b.url.is_empty())
            .map(|mut b| {
                b.tags = normalise_tags(&b.tags);
                b
            })
            .collect();

        // Newest first, ties broken by address so two bookmarks kept in the
        // same millisecond do not swap places between launches.
        entries.sort_by(|a, b| {
            b.saved_at_ms
                .cmp(&a.saved_at_ms)
                .then_with(|| a.url.cmp(&b.url))
        });

        // One bookmark per address. The survivor is the first one the sort put
        // up, which is the most recently kept: if the file somehow holds two,
        // the newer title is the one somebody last meant.
        let mut seen: Vec<&str> = Vec::new();
        let mut deduped: Vec<Bookmark> = Vec::with_capacity(entries.len());
        for bookmark in &entries {
            if seen.contains(&bookmark.url.as_str()) {
                continue;
            }
            seen.push(&bookmark.url);
            deduped.push(bookmark.clone());
        }

        Self {
            entries: deduped,
            next_id,
        }
    }
}

/// Lowercased, trimmed, deduplicated, capped, empties dropped.
///
/// Lowercasing is what makes "Rust" and "rust" one label rather than two that
/// look identical in a list and match separately — which is the failure that
/// makes people give up on tags everywhere else.
fn normalise_tags(tags: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for tag in tags {
        let tag = tag.trim().to_lowercase();
        if tag.is_empty() || out.contains(&tag) {
            continue;
        }
        out.push(tag);
        if out.len() == MAX_TAGS {
            break;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kept(marks: &Bookmarks) -> Vec<&str> {
        marks.all().iter().map(|b| b.url.as_str()).collect()
    }

    #[test]
    fn keeping_a_page_finds_it_again() {
        let mut marks = Bookmarks::new();

        let id = marks.save("https://avelino.run/", "Avelino", 100).unwrap();

        let found = marks.for_url("https://avelino.run/").unwrap();
        assert_eq!(found.id, id);
        assert_eq!(found.display_title(), "Avelino");
        assert!(found.tags.is_empty(), "a bookmark with no tags is complete");
    }

    #[test]
    fn saving_the_same_page_twice_keeps_one_bookmark() {
        // ⌘D is pressed without looking. A second press must not duplicate the
        // row, must not overwrite a title somebody edited, and — above all —
        // must not be the thing that deletes it.
        let mut marks = Bookmarks::new();
        let first = marks.save("https://avelino.run/", "Avelino", 100).unwrap();
        marks.edit(first, "Read later", &["rust".into()]);

        let again = marks
            .save("https://avelino.run/", "Something Else Entirely", 200)
            .unwrap();

        assert_eq!(again, first, "the second press finds the same bookmark");
        assert_eq!(marks.len(), 1);
        let bookmark = marks.get(first).unwrap();
        assert_eq!(bookmark.title, "Read later", "an edited title survives ⌘D");
        assert_eq!(bookmark.tags, vec!["rust"]);
        assert_eq!(bookmark.saved_at_ms, 100, "kept when it was first kept");
    }

    #[test]
    fn an_address_is_required_and_a_title_is_not() {
        let mut marks = Bookmarks::new();

        assert_eq!(marks.save("", "Nowhere", 100), None);
        assert!(marks.is_empty());

        let id = marks.save("https://a.com/", "", 100).unwrap();
        assert_eq!(
            marks.get(id).unwrap().display_title(),
            "https://a.com/",
            "an untitled page shows its address rather than a placeholder"
        );
    }

    #[test]
    fn the_newest_thing_you_kept_is_first() {
        // The ordering rule, and the only order a person can predict without
        // reading the list.
        let mut marks = Bookmarks::new();
        marks.save("https://one.com/", "One", 100);
        marks.save("https://two.com/", "Two", 200);
        marks.save("https://three.com/", "Three", 300);

        assert_eq!(
            kept(&marks),
            ["https://three.com/", "https://two.com/", "https://one.com/"]
        );
    }

    #[test]
    fn renaming_does_not_move_it() {
        // A list that reshuffles because you fixed a typo is a list you stop
        // trusting to stay still while you read it.
        let mut marks = Bookmarks::new();
        marks.save("https://one.com/", "One", 100);
        let two = marks.save("https://two.com/", "Two", 200).unwrap();

        marks.edit(two, "Two, renamed", &[]);

        assert_eq!(kept(&marks), ["https://two.com/", "https://one.com/"]);
        assert_eq!(marks.get(two).unwrap().saved_at_ms, 200);
    }

    #[test]
    fn removing_takes_one_and_leaves_the_rest() {
        let mut marks = Bookmarks::new();
        let one = marks.save("https://one.com/", "One", 100).unwrap();
        marks.save("https://two.com/", "Two", 200);

        assert!(marks.remove(one));
        assert!(
            !marks.remove(one),
            "removing twice reports the second is a no-op"
        );
        assert_eq!(kept(&marks), ["https://two.com/"]);
    }

    #[test]
    fn a_removed_address_can_be_kept_again() {
        let mut marks = Bookmarks::new();
        let one = marks.save("https://one.com/", "One", 100).unwrap();
        marks.remove(one);

        let again = marks.save("https://one.com/", "One", 300).unwrap();

        assert_ne!(again, one, "a new decision gets a new id");
        assert_eq!(marks.get(again).unwrap().saved_at_ms, 300);
    }

    #[test]
    fn tags_are_one_label_however_they_were_typed() {
        let mut marks = Bookmarks::new();
        let id = marks.save("https://a.com/", "A", 100).unwrap();

        marks.edit(
            id,
            "A",
            &[
                "Rust".into(),
                " rust ".into(),
                "".into(),
                "   ".into(),
                "READ later".into(),
            ],
        );

        assert_eq!(marks.get(id).unwrap().tags, vec!["rust", "read later"]);
    }

    #[test]
    fn one_page_can_belong_to_more_than_one_thing() {
        // The whole reason this is tags and not a folder: a link is about two
        // subjects often enough that being made to choose is the friction.
        let mut marks = Bookmarks::new();
        let id = marks.save("https://a.com/", "A", 100).unwrap();

        marks.edit(id, "A", &["rust".into(), "browsers".into()]);

        assert_eq!(marks.get(id).unwrap().tags, vec!["rust", "browsers"]);
        assert_eq!(marks.tags(), vec!["browsers", "rust"]);
    }

    #[test]
    fn a_bookmark_cannot_carry_an_unbounded_pile_of_tags() {
        let mut marks = Bookmarks::new();
        let id = marks.save("https://a.com/", "A", 100).unwrap();
        let many: Vec<String> = (0..500).map(|i| format!("tag{i}")).collect();

        marks.edit(id, "A", &many);

        assert_eq!(marks.get(id).unwrap().tags.len(), MAX_TAGS);
    }

    #[test]
    fn editing_something_that_is_not_there_changes_nothing() {
        let mut marks = Bookmarks::new();
        marks.save("https://a.com/", "A", 100);

        assert!(!marks.edit(BookmarkId(999), "Gone", &["x".into()]));
        assert_eq!(marks.len(), 1);
    }

    // MARK: - Coming back off disk

    #[test]
    fn loading_puts_the_order_back_whatever_the_file_said() {
        let marks = Bookmarks::load(vec![
            Bookmark {
                id: BookmarkId(1),
                url: "https://old.com/".into(),
                title: "Old".into(),
                tags: vec![],
                saved_at_ms: 100,
            },
            Bookmark {
                id: BookmarkId(2),
                url: "https://new.com/".into(),
                title: "New".into(),
                tags: vec![],
                saved_at_ms: 300,
            },
        ]);

        assert_eq!(kept(&marks), ["https://new.com/", "https://old.com/"]);
    }

    #[test]
    fn a_file_holding_the_same_address_twice_loads_as_one_bookmark() {
        let marks = Bookmarks::load(vec![
            Bookmark {
                id: BookmarkId(1),
                url: "https://a.com/".into(),
                title: "First".into(),
                tags: vec![],
                saved_at_ms: 100,
            },
            Bookmark {
                id: BookmarkId(2),
                url: "https://a.com/".into(),
                title: "Second".into(),
                tags: vec![],
                saved_at_ms: 200,
            },
        ]);

        assert_eq!(marks.len(), 1);
        assert_eq!(marks.for_url("https://a.com/").unwrap().title, "Second");
    }

    #[test]
    fn a_new_bookmark_never_lands_on_an_id_that_is_already_out() {
        let mut marks = Bookmarks::load(vec![Bookmark {
            id: BookmarkId(7),
            url: "https://a.com/".into(),
            title: "A".into(),
            tags: vec![],
            saved_at_ms: 100,
        }]);

        let id = marks.save("https://b.com/", "B", 200).unwrap();

        assert!(id.0 > 7, "{id:?} would collide with a live bookmark");
    }

    #[test]
    fn a_stored_row_with_no_address_is_dropped() {
        let marks = Bookmarks::load(vec![Bookmark {
            id: BookmarkId(1),
            url: String::new(),
            title: "Nowhere".into(),
            tags: vec![],
            saved_at_ms: 100,
        }]);

        assert!(marks.is_empty());
    }

    #[test]
    fn stored_tags_are_normalised_on_the_way_in() {
        let marks = Bookmarks::load(vec![Bookmark {
            id: BookmarkId(1),
            url: "https://a.com/".into(),
            title: "A".into(),
            tags: vec!["Rust".into(), "rust".into(), " ".into()],
            saved_at_ms: 100,
        }]);

        assert_eq!(marks.all()[0].tags, vec!["rust"]);
    }
}
