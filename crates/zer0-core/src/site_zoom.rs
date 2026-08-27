//! Zoom remembered per site, per space.
//!
//! ADR-0095 shipped zoom per tab and named per-site as the behaviour people
//! expect; ADR-0129 is the decision that took it. The ledger here is that
//! decision's state: one remembered factor per canonical origin per space,
//! because a Space is an identity (ADR-0007) and the size somebody reads a
//! site at is part of reading it there.
//!
//! An ephemeral space keeps its zooms for the session and writes none of them
//! down: the projection in `storable.rs` is the guarantee, the same shape the
//! tabs rule takes (ADR-0023).

use std::collections::HashMap;

use crate::model::{SpaceId, Tab, TabId};
use crate::site_permissions::origin_of;

/// The bounds a remembered factor may take — the same clamp `SetTabZoom`
/// applies, restated here because a value read off disk is hostile until it
/// has passed them (ADR-0024).
const MIN_FACTOR: f64 = 0.25;
const MAX_FACTOR: f64 = 5.0;

/// One remembered zoom per `(space, canonical origin)`.
///
/// A ledger rather than a column on a tab, for the reason `site_permissions`
/// is one: the fact outlives every tab that set it, and it is asked about by
/// a moment — a commit — that is not a tab.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SiteZooms {
    by_space_and_origin: HashMap<(SpaceId, String), f64>,
}

/// What the store reads a row back as, and what it wrote.
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Debug, Clone, PartialEq)]
pub struct StoredZoom {
    pub space: SpaceId,
    pub origin: String,
    pub factor: f64,
}

fn validated_row(row: StoredZoom) -> Option<((SpaceId, String), f64)> {
    if !row.factor.is_finite()
        || row.factor == Tab::DEFAULT_ZOOM
        || !(MIN_FACTOR..=MAX_FACTOR).contains(&row.factor)
    {
        return None;
    }
    let canonical = origin_of(&row.origin)?;
    if canonical != row.origin {
        return None;
    }
    Some(((row.space, row.origin), row.factor))
}

impl SiteZooms {
    /// The zoom this origin is remembered at in this space, or `None` when
    /// nobody decided — which is not the same as 1.0 being remembered.
    pub fn get(&self, space: SpaceId, url: &str) -> Option<f64> {
        let origin = origin_of(url)?;
        self.by_space_and_origin.get(&(space, origin)).copied()
    }

    /// Remember a zoom, or forget it: the ordinary size is the absence of a
    /// decision, and a row remembering 1.0 would be a row that lies about
    /// being needed.
    ///
    /// A URL with no origin to remember (`about:`, opaque `data:`) is not an
    /// error and leaves nothing behind — the tab's own zoom still applies
    /// until it navigates somewhere with one.
    pub fn set(&mut self, space: SpaceId, url: &str, factor: f64) {
        let Some(origin) = origin_of(url) else { return };
        if factor == Tab::DEFAULT_ZOOM {
            self.by_space_and_origin.remove(&(space, origin));
        } else {
            self.by_space_and_origin.insert((space, origin), factor);
        }
    }

    /// Forget one exact canonical origin. Settings input is refused rather
    /// than repaired, so a page URL or malformed value cannot name a row.
    pub fn forget(&mut self, space: SpaceId, origin: &str) -> bool {
        let Some(canonical) = origin_of(origin) else {
            return false;
        };
        if canonical != origin {
            return false;
        }
        self.by_space_and_origin
            .remove(&(space, canonical))
            .is_some()
    }

    /// A closed space takes its zooms with it, for the reason it takes its
    /// permissions: leaving them would be preferences for a cookie jar that
    /// no longer exists.
    pub fn forget_space(&mut self, space: SpaceId) {
        self.by_space_and_origin.retain(|(s, _), _| *s != space);
    }

    /// Everything remembered, ordered by space then origin for persistence and
    /// presentation to agree on one stable list.
    pub fn all(&self) -> Vec<StoredZoom> {
        let mut rows: Vec<_> = self
            .by_space_and_origin
            .iter()
            .map(|((space, origin), factor)| StoredZoom {
                space: *space,
                origin: origin.clone(),
                factor: *factor,
            })
            .collect();
        rows.sort_by(|a, b| a.space.cmp(&b.space).then_with(|| a.origin.cmp(&b.origin)));
        rows
    }

    /// Everything a file on disk said, minus anything this build refuses to
    /// believe: a non-finite or out-of-bounds factor was never something this
    /// browser would set, and the ordinary factor is absence rather than a
    /// decision. Keeping any of them would invent state (ADR-0024).
    ///
    /// The origin is put through the same `origin_of` door every lookup
    /// uses, so a hand-edited row that does not canonicalise is dropped
    /// rather than kept as a key no page could ever match.
    pub fn load(rows: Vec<StoredZoom>) -> Self {
        let mut by_space_and_origin = HashMap::new();
        for row in rows {
            let Some((key, factor)) = validated_row(row) else {
                continue;
            };
            by_space_and_origin.insert(key, factor);
        }
        Self {
            by_space_and_origin,
        }
    }

    /// Take a session restored by an older build — its zooms on the tabs,
    /// nothing in this ledger — and make it per-site.
    ///
    /// Seeding is first-wins by tab order: two tabs that remembered different
    /// sizes for one origin cannot both be honoured, and the one read first
    /// is the answer nobody will notice moving. An ephemeral space cannot
    /// reach here, because its tabs never reached the file (ADR-0023).
    ///
    /// Then every tab is set to whatever its origin now remembers, so the
    /// first launch after this change is the moment per-site zoom begins —
    /// not a moment where yesterday's sizes quietly move onto today's other
    /// tabs.
    pub fn adopt(&mut self, browser: &mut crate::model::Browser) {
        let tabs: Vec<(TabId, SpaceId, Option<String>, f64)> = browser
            .all_tabs()
            .iter()
            .map(|t| (t.id, t.space, t.url.clone(), t.zoom_factor))
            .collect();

        for (_, space, url, factor) in &tabs {
            let Some(origin) = url.as_deref().and_then(origin_of) else {
                continue;
            };
            let Some((key, factor)) = validated_row(StoredZoom {
                space: *space,
                origin,
                factor: *factor,
            }) else {
                continue;
            };
            self.by_space_and_origin.entry(key).or_insert(factor);
        }

        for (id, space, url, _) in &tabs {
            let wanted = url
                .as_deref()
                .and_then(origin_of)
                .and_then(|origin| self.by_space_and_origin.get(&(*space, origin)).copied())
                .unwrap_or(Tab::DEFAULT_ZOOM);
            if let Some(t) = browser.tab_mut(*id) {
                t.zoom_factor = wanted;
            }
        }
    }
}

#[cfg(test)]
#[path = "site_zoom_tests.rs"]
mod tests;
