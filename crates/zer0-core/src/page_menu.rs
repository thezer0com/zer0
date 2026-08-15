//! What a right-click on a page offers **beyond what the engine already
//! offers**.
//!
//! The engine builds a context menu of its own and it is mostly good: spelling
//! corrections in a field, Look Up, Translate, Share, the media items. Throwing
//! that away to draw eleven rows by hand would lose real work and gain nothing,
//! so this is a list of *additions and corrections* rather than a menu.
//!
//! Which additions a target earns is decided here because two platforms could
//! not reasonably disagree about it: a right-click on a link offers to open it
//! in a new tab, in every browser, on every system. Where each addition sits
//! among the engine's own rows is the host's answer, because the rows it sits
//! among are the host's (ADR-0053).
//!
//! Measured on WebKit before any of this was written, and each measurement is
//! why an item below exists:
//!
//! | the engine's menu says | what it does here |
//! | --- | --- |
//! | nothing about a new tab | — the item is simply absent |
//! | "Open Link in New Window" | `windowFeatures` all `nil`, so ADR-0075 opens a **tab** |
//! | "Download Linked File" | reaches neither `didBecome download` nor any delegate |
//! | "Download Image" | the same |
//! | "Search with Google" | whatever engine Settings names, ignored |

use crate::external_scheme;
use crate::internal_url;

/// What the host found under the pointer, exactly as it read it and with
/// nothing worked out yet.
///
/// Reported rather than interpreted, the same way [`crate::WindowRequest`] is:
/// the host runs a hit test in its own vocabulary and what that adds up to is
/// decided here, so a `webkit2gtk` host inherits every rule below instead of
/// re-deriving it.
///
/// `can_go_back` and `can_go_forward` are the host's because only the engine
/// holds a back-forward list. They are facts, not decisions.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct PageTarget {
    /// The `href` of the nearest enclosing anchor.
    pub link_url: Option<String>,
    /// The resolved source of the image under the pointer.
    pub image_url: Option<String>,
    /// The selected text, but **only when the pointer was on the selection**.
    ///
    /// A selection somewhere else on the page is not what this gesture was
    /// about, and offering to search for it would act on text the person is not
    /// pointing at.
    pub selection: Option<String>,
    pub can_go_back: bool,
    pub can_go_forward: bool,
}

/// One row this browser adds to, or puts right in, the engine's menu.
///
/// No item here is a thing the engine already does correctly. Every one is
/// either missing from its menu or measured to be wrong in ours.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum PageMenuItem {
    /// The single most-used item in a browser whose whole navigation model is a
    /// vertical tab list, and the engine's menu does not have it at all.
    OpenLinkInNewTab,
    /// Replaces the engine's item of the same name, which opens a tab here:
    /// measured, it asks through `createWebViewWith` with every window feature
    /// unset, and a page that described no window gets a tab (ADR-0075).
    OpenLinkInNewWindow,
    /// Replaces the engine's "Download Linked File", measured to reach nothing.
    SaveLinkedFile,
    OpenImageInNewTab,
    /// Replaces the engine's "Download Image", measured to reach nothing.
    SaveImage,
    /// Replaces the engine's "Search with Google", which names an engine
    /// Settings may not be using. The search is spelled once, in
    /// [`crate::url_input`], where the command bar spells it.
    SearchForSelection,
    /// The engine's page menu is one row: Reload.
    Back,
    Forward,
}

/// A selection longer than this is searched for by its first characters.
///
/// A stated limit rather than a silent one: nobody searches the web for a
/// thousand words, and a query built from an unbounded selection is a URL no
/// server accepts.
pub const MAX_SELECTION_CHARS: usize = 512;

/// What this browser adds to the engine's menu for what is under the pointer.
///
/// Order is the order the additions are meant to read in, and the host places
/// each one against a row of the engine's own.
pub fn additions_for(target: &PageTarget) -> Vec<PageMenuItem> {
    let mut out = Vec::new();

    if let Some(link) = openable(target.link_url.as_deref()) {
        out.push(PageMenuItem::OpenLinkInNewTab);
        out.push(PageMenuItem::OpenLinkInNewWindow);
        if downloadable(link) {
            out.push(PageMenuItem::SaveLinkedFile);
        }
    }

    if let Some(image) = openable(target.image_url.as_deref()) {
        out.push(PageMenuItem::OpenImageInNewTab);
        if downloadable(image) {
            out.push(PageMenuItem::SaveImage);
        }
    }

    if search_query(target).is_some() {
        out.push(PageMenuItem::SearchForSelection);
    }

    // Omitted rather than greyed out when there is nowhere to go. A disabled
    // row is a control earning its place by telling you about a road you cannot
    // take, and this menu is short enough that nothing depends on a row staying
    // in the same position.
    if target.can_go_back {
        out.push(PageMenuItem::Back);
    }
    if target.can_go_forward {
        out.push(PageMenuItem::Forward);
    }

    out
}

/// The address an item acts on, or `None` when the item does not act on one.
///
/// The one place an item is turned back into a URL, so the reducer never has to
/// pick between two fields and never picks the wrong one.
pub fn address_for(item: PageMenuItem, target: &PageTarget) -> Option<String> {
    match item {
        PageMenuItem::OpenLinkInNewTab
        | PageMenuItem::OpenLinkInNewWindow
        | PageMenuItem::SaveLinkedFile => openable(target.link_url.as_deref()).map(str::to_string),
        PageMenuItem::OpenImageInNewTab | PageMenuItem::SaveImage => {
            openable(target.image_url.as_deref()).map(str::to_string)
        }
        PageMenuItem::SearchForSelection | PageMenuItem::Back | PageMenuItem::Forward => None,
    }
}

/// What "Search for …" would search for, cut to a length a query can carry.
///
/// `None` when the pointer was not on a selection, or the selection is only
/// whitespace — there is nothing to search for and the row does not appear.
pub fn search_query(target: &PageTarget) -> Option<String> {
    let text = target.selection.as_deref()?.trim();
    if text.is_empty() {
        return None;
    }
    Some(text.chars().take(MAX_SELECTION_CHARS).collect())
}

/// Whether an address is one this browser would open in a tab of its own.
///
/// Two refusals, and each answers a different question:
///
/// **One of ours is never offered.** ADR-0054's answer to a page reaching an
/// address inside the browser is that no road exists, and a menu row is a road.
/// The navigation policy door refuses it as well; this is the second lock, put
/// here so the row is never drawn rather than drawn and then dead.
///
/// **A scheme the system owns is not a page.** "Open Link in New Tab" on a
/// `mailto:` is an offer to put a compose window in a tab, which is not a thing.
fn openable(url: Option<&str>) -> Option<&str> {
    let url = url.map(str::trim).filter(|u| !u.is_empty())?;
    if internal_url::claims_scheme(url) || external_scheme::may_hand_to_the_system(url) {
        return None;
    }
    Some(url)
}

/// Whether the download machinery can fetch this address.
///
/// `blob:` is deliberately out. A blob URL names an object inside one page's
/// script context, and the download runs from outside it — so the row would be
/// an offer to save a file that cannot be fetched, which is exactly the shape
/// ADR-0018 refuses. `data:` stays in: the bytes are in the address itself.
fn downloadable(url: &str) -> bool {
    let Some((scheme, _)) = url.split_once(':') else {
        return false;
    };
    matches!(
        scheme.to_ascii_lowercase().as_str(),
        "http" | "https" | "file" | "data"
    )
}

// MARK: - Across the FFI

/// Free function for the reason every other one in this crate is: a shell that
/// decided its own rows would be a second opinion about what this browser
/// offers, and the Linux host would be free to hold a different one.
#[cfg(feature = "ffi")]
#[uniffi::export]
pub fn page_menu_additions(target: PageTarget) -> Vec<PageMenuItem> {
    additions_for(&target)
}

/// What the "Search for …" row is about, so the host can title it without
/// cutting the text a second time and cutting it differently.
#[cfg(feature = "ffi")]
#[uniffi::export]
pub fn page_menu_search_query(target: PageTarget) -> Option<String> {
    search_query(&target)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn on_a_link(url: &str) -> PageTarget {
        PageTarget {
            link_url: Some(url.to_string()),
            ..PageTarget::default()
        }
    }

    fn on_an_image(url: &str) -> PageTarget {
        PageTarget {
            image_url: Some(url.to_string()),
            ..PageTarget::default()
        }
    }

    #[test]
    fn a_link_can_be_opened_in_a_tab_in_a_window_and_saved() {
        assert_eq!(
            additions_for(&on_a_link("https://example.com/a")),
            vec![
                PageMenuItem::OpenLinkInNewTab,
                PageMenuItem::OpenLinkInNewWindow,
                PageMenuItem::SaveLinkedFile,
            ]
        );
    }

    #[test]
    fn an_image_can_be_opened_in_a_tab_and_saved() {
        assert_eq!(
            additions_for(&on_an_image("https://example.com/a.png")),
            vec![PageMenuItem::OpenImageInNewTab, PageMenuItem::SaveImage]
        );
    }

    /// The whole reason `selection` is only set when the pointer was on it.
    #[test]
    fn a_selection_under_the_pointer_can_be_searched_for() {
        let target = PageTarget {
            selection: Some("  rust vs swift  ".to_string()),
            ..PageTarget::default()
        };
        assert_eq!(
            additions_for(&target),
            vec![PageMenuItem::SearchForSelection]
        );
        assert_eq!(search_query(&target).as_deref(), Some("rust vs swift"));
    }

    #[test]
    fn a_selection_of_nothing_offers_nothing() {
        for text in ["", "   ", "\n\t "] {
            let target = PageTarget {
                selection: Some(text.to_string()),
                ..PageTarget::default()
            };
            assert!(additions_for(&target).is_empty(), "for {text:?}");
            assert_eq!(search_query(&target), None);
        }
    }

    #[test]
    fn a_very_long_selection_is_searched_for_by_its_first_characters() {
        let target = PageTarget {
            selection: Some("é".repeat(MAX_SELECTION_CHARS + 100)),
            ..PageTarget::default()
        };
        let query = search_query(&target).expect("a query");
        // Characters, not bytes: cutting a multi-byte selection by bytes would
        // produce a query ending in half a letter.
        assert_eq!(query.chars().count(), MAX_SELECTION_CHARS);
    }

    /// ADR-0054. A page that puts one of our addresses in a link must not be
    /// handed a row that opens it.
    #[test]
    fn a_link_to_one_of_our_own_addresses_earns_no_row() {
        for url in [
            "zer0://settings",
            "zer0://chat?conversation=7",
            "ZER0://history",
            "zer0://nonsense",
        ] {
            assert!(additions_for(&on_a_link(url)).is_empty(), "for {url}");
            assert_eq!(
                address_for(PageMenuItem::OpenLinkInNewTab, &on_a_link(url)),
                None
            );
        }
    }

    /// A compose window is not a page, so there is nothing to open in a tab.
    #[test]
    fn a_link_the_system_owns_earns_no_row() {
        for url in ["mailto:a@b.com", "tel:+15551234", "facetime:a@b.com"] {
            assert!(additions_for(&on_a_link(url)).is_empty(), "for {url}");
        }
    }

    /// A row offering to save something that cannot be fetched is the same
    /// claim as a progress bar over an unknown length.
    #[test]
    fn a_blob_can_be_opened_and_not_saved() {
        assert_eq!(
            additions_for(&on_an_image("blob:https://example.com/abc")),
            vec![PageMenuItem::OpenImageInNewTab]
        );
        assert_eq!(
            additions_for(&on_a_link("blob:https://example.com/abc")),
            vec![
                PageMenuItem::OpenLinkInNewTab,
                PageMenuItem::OpenLinkInNewWindow
            ]
        );
    }

    #[test]
    fn a_data_image_can_be_saved_because_the_bytes_are_the_address() {
        assert_eq!(
            additions_for(&on_an_image("data:image/gif;base64,R0lGOD")),
            vec![PageMenuItem::OpenImageInNewTab, PageMenuItem::SaveImage]
        );
    }

    #[test]
    fn back_and_forward_appear_only_where_there_is_somewhere_to_go() {
        assert!(additions_for(&PageTarget::default()).is_empty());

        let both = PageTarget {
            can_go_back: true,
            can_go_forward: true,
            ..PageTarget::default()
        };
        assert_eq!(
            additions_for(&both),
            vec![PageMenuItem::Back, PageMenuItem::Forward]
        );

        let back_only = PageTarget {
            can_go_back: true,
            ..PageTarget::default()
        };
        assert_eq!(additions_for(&back_only), vec![PageMenuItem::Back]);
    }

    /// An image inside a link is both, and both sets of rows are true.
    #[test]
    fn an_image_inside_a_link_earns_both_sets_of_rows() {
        let target = PageTarget {
            link_url: Some("https://example.com/a".to_string()),
            image_url: Some("https://example.com/a.png".to_string()),
            can_go_back: true,
            ..PageTarget::default()
        };
        assert_eq!(
            additions_for(&target),
            vec![
                PageMenuItem::OpenLinkInNewTab,
                PageMenuItem::OpenLinkInNewWindow,
                PageMenuItem::SaveLinkedFile,
                PageMenuItem::OpenImageInNewTab,
                PageMenuItem::SaveImage,
                PageMenuItem::Back,
            ]
        );
        assert_eq!(
            address_for(PageMenuItem::OpenLinkInNewTab, &target).as_deref(),
            Some("https://example.com/a")
        );
        assert_eq!(
            address_for(PageMenuItem::SaveImage, &target).as_deref(),
            Some("https://example.com/a.png")
        );
    }

    /// Everything in here came out of a page (ADR-0024).
    #[test]
    fn an_empty_or_blank_address_earns_no_row() {
        for url in ["", "   ", "\n"] {
            assert!(additions_for(&on_a_link(url)).is_empty(), "for {url:?}");
            assert!(additions_for(&on_an_image(url)).is_empty(), "for {url:?}");
        }
    }
}
