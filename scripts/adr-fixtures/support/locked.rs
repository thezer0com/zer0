// Lock targets for the adr-check fixtures. Not part of any crate: it sits
// outside `crates/`, so `cargo` never sees it and nobody ever has a reason to
// rename what is in here.
//
// That isolation is the point. If the fixtures locked onto a real test, then
// renaming that test would redden the fixture suite for a reason that has
// nothing to do with the checker, and the next person would learn to ignore it.

/// The happy path: a lock naming this resolves.
#[test]
fn a_lock_that_resolves() {
    assert_eq!(1 + 1, 2);
}

/// A test that is present in the file and never runs. `#[ignore]` satisfies
/// "the name is really in it" while defending nothing, which is the hole the
/// `lock-ignored-rust-test` fixture exists to keep closed.
#[test]
#[ignore]
fn a_test_that_never_runs() {
    assert_eq!(1 + 1, 2);
}
