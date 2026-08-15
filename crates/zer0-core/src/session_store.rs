//! What the core needs from persistence, and what a backend has to promise.
//!
//! The core does not know what a table is. It hands over a whole [`Session`]
//! and asks for a whole one back; everything it does in between — ranking the
//! command bar, walking history, ordering tabs — is answered from the session
//! it already holds in memory. So there is no query interface here, because
//! there is nothing to query. Two writes, two reads and one prune is the
//! entire surface.
//!
//! The contract in the doc comments is the load-bearing part of this file. A
//! backend that compiles against this trait and ignores the contract still
//! loses somebody's tabs, so each clause says what goes wrong when it is
//! broken rather than only what to do. ADR-0045 is the record; this is the
//! version a compiler puts in front of whoever is writing the second backend.

use crate::session::Session;
use crate::storable::StorableSession;

/// Why a store could not do what was asked.
///
/// Two variants rather than one, because the caller acts differently on each.
/// [`StoreError::Backend`] is "the store would not answer" — the disk, the
/// driver, the connection — and says nothing about what is in there.
/// [`StoreError::Unusable`] is "there is something in there and it is not
/// something this version can use", which is a statement about the data.
///
/// Neither is a place to put "there is nothing stored yet". That is not a
/// failure and it does not travel through this type; see [`SessionStore::load`].
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    /// Whatever the backing store said when it refused, in its own words.
    ///
    /// A `String` and not the driver's error type on purpose: this enum is the
    /// abstraction's, and naming one backend's error in it would make every
    /// other backend a second-class implementation.
    #[error("the session store failed: {0}")]
    Backend(String),
    /// Something is stored and it is not a session this version can use.
    #[error("stored session is unusable and was discarded")]
    Unusable,
}

pub type Result<T> = std::result::Result<T, StoreError>;

/// Where a session goes while the browser is not running.
///
/// **What travels through here.** Everything in [`StorableSession`], which is
/// everything in [`Session`] except what must not be stored: the closed-tab
/// ring, deliberately forgotten on quit; the icon cache, which has a store of
/// its own for the reasons in ADR-0044; and the two content rules below.
/// Spaces, tabs and their tree, splits, history with its counts, routing rules
/// in order, the keymap delta, downloads, extension consent and preferences all
/// have to come back or the session did not come back.
///
/// **A backend is not asked for judgement, only for storage.** It never sees a
/// [`Session`]. What arrives at [`SessionStore::save`] has already been through
/// [`StorableSession::project`], so the pages of an ephemeral space and the
/// downloads that must not outlive the run are not withheld from a backend by
/// convention — they are not there. Write down what you are given, faithfully
/// and in order, and the content rules hold for free.
///
/// **Opening is not on this trait.** How you address a store — a file path, a
/// directory, a URL — is the one thing backends cannot agree on, and folding
/// it in here would mean inventing a lowest common denominator for it. The
/// caller picks a backend by name, opens it, and talks to it through this
/// trait from then on.
///
/// **The caller's half of the bargain**, so the promises below are worth
/// something: when [`SessionStore::load`] fails, the store is dropped and
/// never called again for the rest of the run (ADR-0006, ADR-0017). A store
/// that reports a failed read is guaranteed not to be written to afterwards —
/// that is what makes refusing to guess the safe answer rather than a
/// data-losing one.
pub trait SessionStore {
    /// The stored session, or `None` when nothing has ever been stored here.
    ///
    /// **`Ok(None)` and `Err` are different answers and must never be
    /// swapped.** `Ok(None)` means a fresh profile: nothing is there, so the
    /// caller starts a new session and will happily write over the nothing.
    /// `Err` means something *is* there and this version could not turn it
    /// into a session — and the caller detaches, running the whole session
    /// without writing a byte so the stored bytes survive for a later version
    /// or a repair tool.
    ///
    /// A backend that reports a read it could not perform as `Ok(None)`
    /// destroys the session on the first autosave twenty seconds later, with
    /// no backup and no warning, and nothing on screen says so until the next
    /// launch. That failure is the entire reason this method has the shape it
    /// has.
    ///
    /// **Repairing is expected. Inventing is not.** A single value the store
    /// cannot make sense of does not fail the load: a routing rule of an
    /// unknown kind, a rebind for a command this version dropped, a preference
    /// that will not parse, a download whose file is no longer on disk — each
    /// is left out and the rest of the session comes back. Losing one setting
    /// must not cost thirty tabs. What a backend may not do is fill the gap
    /// with a guess: an unreadable permission comes back as unmentioned, never
    /// as granted.
    ///
    /// **Order is part of the data.** Tabs come back in their order, inside
    /// their space, with their parent; routing rules come back in the order
    /// they are matched in. A store whose medium has no inherent order has to
    /// write the order down. And where the reconstruction depends on seeing
    /// two records together, the result must not depend on which arrived
    /// first — this trait promises the same session out of the same content,
    /// whatever order the medium hands it over in.
    fn load(&self) -> Result<Option<Session>>;

    /// Replace the stored session with this one.
    ///
    /// **Replace, not merge.** After this returns `Ok`, what is stored is this
    /// session and nothing else. What the caller no longer has, the store no
    /// longer has: a cleared history stays cleared, a closed space stays
    /// closed. A backend that only ever adds and updates brings deleted pages
    /// back on the next launch — that has already happened here once, and it
    /// is why history is written by replacement.
    ///
    /// **All of it or none of it.** A save that returns `Err`, or that is cut
    /// short by the process dying, must leave the previously stored session
    /// exactly as it was. A later [`SessionStore::load`] returns the last
    /// session that was saved completely — never a mixture of two. Saving runs
    /// on a timer with the interface alive and on the way out of a quit, so
    /// "interrupted halfway" is an ordinary event, not a rare one. A backend
    /// that can leave half a session behind is not a legal implementation of
    /// this trait.
    ///
    /// **What deserves storing was decided before you were called.** The two
    /// promises this browser makes about content — an ephemeral space leaves no
    /// trace of its pages, and a download still running is written down as
    /// interrupted while a failed or cancelled one is not written at all — are
    /// [`StorableSession::project`]'s work, not yours. They hold on every
    /// backend because no backend is trusted with them: an ephemeral space
    /// arrives with no tabs and no split, and there is no value in a
    /// [`StorableSession`] that can say a download failed. Store all of what
    /// you are given, and both promises are kept.
    fn save(&mut self, session: &StorableSession) -> Result<()>;

    /// Record that this run ended properly.
    ///
    /// Its presence has to mean that the save before it is durable, which is
    /// the only reason the marker is worth anything: the next launch reads it
    /// to tell a clean quit from a crash. So it is written last, and a backend
    /// must not let it become visible ahead of the session it is vouching for.
    fn mark_clean_shutdown(&self) -> Result<()>;

    /// Whether the previous run ended properly — and it is a read that
    /// consumes.
    ///
    /// Clearing the marker as it is read is what makes the *current* run count
    /// as unclean until it quits properly too. Called twice, this answers
    /// `true` at most once.
    ///
    /// A store that has never been marked answers `false`. That is not an
    /// error: a session that was never saved cleanly is a normal state, and
    /// the first launch on a new profile is exactly that.
    fn take_clean_shutdown(&self) -> Result<bool>;

    /// Drop stored history visited before `before_ms`, and say how many went.
    ///
    /// The one write that is not a whole session, because it exists to take
    /// something off the disk without the caller having to hold all of history
    /// in memory to do it. It touches history and nothing else — tabs, spaces
    /// and preferences are not its business.
    ///
    /// The count is returned rather than logged because a "clear history" that
    /// silently removed nothing is indistinguishable from one that worked.
    fn forget_history_before(&mut self, before_ms: u64) -> Result<usize>;
}
