use super::*;

/// The smallest thing that is really a PNG.
fn png() -> Vec<u8> {
    let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
    bytes.extend_from_slice(b"the rest does not have to be real");
    bytes
}

fn declared(url: &str, size_px: Option<u32>) -> IconCandidate {
    IconCandidate {
        url: url.to_string(),
        size_px,
    }
}

// MARK: - Which one to ask for

#[test]
fn the_smallest_one_big_enough_to_draw_sharp_wins() {
    let chosen = choose(
        &[
            declared("https://a.com/16.png", Some(16)),
            declared("https://a.com/32.png", Some(32)),
            declared("https://a.com/512.png", Some(512)),
        ],
        "https://a.com/page",
    );

    assert_eq!(chosen.as_deref(), Some("https://a.com/32.png"));
}

#[test]
fn nothing_big_enough_means_the_largest_there_is() {
    // Scaling 24 up to 32 loses less than scaling 16 up to 32 does.
    let chosen = choose(
        &[
            declared("https://a.com/16.png", Some(16)),
            declared("https://a.com/24.png", Some(24)),
        ],
        "https://a.com/page",
    );

    assert_eq!(chosen.as_deref(), Some("https://a.com/24.png"));
}

#[test]
fn a_declaration_with_no_size_is_still_better_than_guessing() {
    let chosen = choose(
        &[declared("https://a.com/icon.svg", None)],
        "https://a.com/page",
    );

    assert_eq!(chosen.as_deref(), Some("https://a.com/icon.svg"));
}

#[test]
fn a_page_that_declares_nothing_still_gets_the_conventional_favicon() {
    let chosen = choose(&[], "https://a.com/deep/page?q=1#frag");

    assert_eq!(chosen.as_deref(), Some("https://a.com/favicon.ico"));
}

#[test]
fn the_conventional_favicon_keeps_a_non_standard_port() {
    let chosen = choose(&[], "http://localhost:8080/page");

    assert_eq!(chosen.as_deref(), Some("http://localhost:8080/favicon.ico"));
}

#[test]
fn a_page_that_is_not_on_the_web_is_never_asked_about() {
    // A local file and a blank tab have no site to have an icon, and
    // `file:///favicon.ico` would be the browser reading the disk on a page's
    // say-so.
    assert_eq!(choose(&[], "file:///Users/me/notes.html"), None);
    assert_eq!(choose(&[], "about:blank"), None);
    assert_eq!(choose(&[], "not a url at all"), None);
}

#[test]
fn a_declaration_the_page_should_not_be_able_to_make_is_refused() {
    // Every one of these is a page pointing the fetcher somewhere it has no
    // business going, and every one of them falls back to the conventional
    // URL rather than being followed.
    for hostile in [
        "javascript:alert(1)",
        "file:///etc/passwd",
        "data:image/png;base64,AAAA",
        "about:blank",
        "https://",
    ] {
        let chosen = choose(&[declared(hostile, Some(64))], "https://a.com/page");
        assert_eq!(
            chosen.as_deref(),
            Some("https://a.com/favicon.ico"),
            "{hostile} should not have been followed"
        );
    }
}

#[test]
fn a_page_cannot_make_us_walk_a_thousand_declarations() {
    let flood: Vec<IconCandidate> = (0..5000)
        .map(|i| declared(&format!("https://a.com/{i}.png"), Some(64)))
        .collect();

    let chosen = choose(&flood, "https://a.com/page");

    // Whatever it picked, it came out of the first window, not the flood.
    let index: usize = chosen
        .as_deref()
        .and_then(|url| {
            url.trim_start_matches("https://a.com/")
                .strip_suffix(".png")
        })
        .and_then(|n| n.parse().ok())
        .expect("a candidate should still have been chosen");
    assert!(index < MAX_CANDIDATES, "walked past the cap: {index}");
}

// MARK: - What a server is allowed to hand back

#[test]
fn html_served_as_an_icon_is_refused() {
    // The common shape of this: a site with no `/favicon.ico` answers 200 with
    // its own 404 page. A browser that trusted the status code would file a
    // web page as a picture and then draw nothing at all.
    for html in [
        &b"<!DOCTYPE html><html><body>Not found</body></html>"[..],
        &b"<html><head><title>404</title></head></html>"[..],
        &b"  \n <!doctype HTML>\n<html>"[..],
    ] {
        assert!(!is_image(html), "accepted HTML as an image");
    }
}

#[test]
fn an_oversized_response_is_refused() {
    let mut huge = b"\x89PNG\r\n\x1a\n".to_vec();
    huge.resize(MAX_ICON_BYTES as usize + 1, 0);

    assert!(!is_image(&huge));
    // And one byte under the line is still fine, so the limit is a limit
    // rather than an approximation.
    huge.truncate(MAX_ICON_BYTES as usize);
    assert!(is_image(&huge));
}

#[test]
fn an_empty_body_is_not_an_image() {
    assert!(!is_image(&[]));
}

#[test]
fn json_and_plain_text_are_not_images() {
    assert!(!is_image(b"{\"error\":\"not found\"}"));
    assert!(!is_image(b"Not Found"));
    assert!(!is_image(b"\x00\x00\x00\x00 almost an ico"));
}

#[test]
fn the_formats_a_site_actually_serves_are_accepted() {
    assert!(is_image(&png()));
    assert!(is_image(b"\xff\xd8\xff\xe0 jpeg"));
    assert!(is_image(b"GIF89a and the rest"));
    assert!(is_image(b"\x00\x00\x01\x00 an ico"));
    assert!(is_image(b"RIFF\x00\x00\x00\x00WEBPVP8 "));
    assert!(is_image(
        b"<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"
    ));
    assert!(is_image(
        b"<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"/>"
    ));
}

#[test]
fn xml_that_is_not_an_svg_is_refused() {
    assert!(!is_image(b"<?xml version=\"1.0\"?><rss><channel/></rss>"));
}

// MARK: - The cache

#[test]
fn a_site_we_have_nothing_for_is_worth_asking_about() {
    let icons = Icons::new();
    assert!(icons.wants(&IconKey::new("ds", "a.com"), 0));
}

#[test]
fn a_site_we_already_have_is_not_asked_again() {
    let mut icons = Icons::new();
    icons.record(IconKey::new("ds", "a.com"), png(), 1_000);

    assert!(!icons.wants(&IconKey::new("ds", "a.com"), 1_000));
    assert!(!icons.wants(&IconKey::new("ds", "a.com"), u64::MAX));
}

#[test]
fn a_request_already_out_is_not_sent_twice() {
    // Ten tabs opening on one host at once is one request.
    let mut icons = Icons::new();
    icons.begin(IconKey::new("ds", "a.com"));

    assert!(!icons.wants(&IconKey::new("ds", "a.com"), 0));
}

#[test]
fn a_site_that_gave_nothing_is_left_alone_for_a_week() {
    let mut icons = Icons::new();
    icons.record(IconKey::new("ds", "a.com"), Vec::new(), 1_000);

    // Without the memory of the failure, every navigation to a site with no
    // icon would be another request to that site.
    assert!(!icons.wants(&IconKey::new("ds", "a.com"), 1_000));
    assert!(!icons.wants(
        &IconKey::new("ds", "a.com"),
        1_000 + RETRY_MISSING_AFTER_MS - 1
    ));
    assert!(icons.wants(&IconKey::new("ds", "a.com"), 1_000 + RETRY_MISSING_AFTER_MS));
}

#[test]
fn a_clock_that_went_backwards_does_not_start_a_retry_storm() {
    let mut icons = Icons::new();
    icons.record(IconKey::new("ds", "a.com"), Vec::new(), 10_000);

    assert!(!icons.wants(&IconKey::new("ds", "a.com"), 1));
}

#[test]
fn a_failed_fetch_leaves_the_row_with_its_letter() {
    let mut icons = Icons::new();
    icons.record(IconKey::new("ds", "a.com"), Vec::new(), 1_000);

    // Not an empty slice — nothing at all, which is what makes the badge draw
    // its letter rather than a blank square.
    assert_eq!(icons.bytes(&IconKey::new("ds", "a.com")), None);
}

#[test]
fn two_spaces_never_share_one_icon() {
    // The cache is keyed by cookie jar, so a site visited at work is not
    // served from cache at home. The absence of a second request is something
    // the site can see, and that is the correlation this exists to refuse.
    let mut icons = Icons::new();
    icons.record(IconKey::new("ds-work", "a.com"), png(), 1_000);

    assert!(icons.bytes(&IconKey::new("ds-work", "a.com")).is_some());
    assert_eq!(icons.bytes(&IconKey::new("ds-home", "a.com")), None);
    assert!(icons.wants(&IconKey::new("ds-home", "a.com"), 1_000));
}

#[test]
fn closing_a_space_takes_its_icons_with_it() {
    let mut icons = Icons::new();
    icons.record(IconKey::new("ds-gone", "a.com"), png(), 1_000);
    icons.record(IconKey::new("ds-kept", "a.com"), png(), 1_000);
    let _ = icons.take_dirty();

    icons.forget_data_store("ds-gone");

    assert_eq!(icons.bytes(&IconKey::new("ds-gone", "a.com")), None);
    assert!(icons.bytes(&IconKey::new("ds-kept", "a.com")).is_some());
    // And the disk is told, or the rows outlive the space that owned them with
    // no way to reach them from the interface.
    assert_eq!(icons.take_dropped(), vec!["ds-gone".to_string()]);
}

#[test]
fn a_dropped_jar_does_not_leave_a_write_queued_behind_it() {
    let mut icons = Icons::new();
    icons.record(IconKey::new("ds-gone", "a.com"), png(), 1_000);

    icons.forget_data_store("ds-gone");

    // Flushing a row for a jar we just deleted would put it straight back.
    assert!(icons.take_dirty().is_empty());
}

#[test]
fn the_revision_moves_whenever_a_row_would_look_different() {
    let mut icons = Icons::new();
    let before = icons.revision();

    icons.record(IconKey::new("ds", "a.com"), png(), 1_000);
    let after_hit = icons.revision();
    assert_ne!(before, after_hit);

    // A miss counts too: it is what turns "not asked yet" into "asked, and
    // there is nothing", and the shell stops re-asking on the strength of it.
    icons.record(IconKey::new("ds", "b.com"), Vec::new(), 1_000);
    assert_ne!(after_hit, icons.revision());
}

#[test]
fn what_is_flushed_is_what_changed() {
    let mut icons = Icons::new();
    icons.record(IconKey::new("ds", "a.com"), png(), 1_000);
    icons.record(IconKey::new("ds", "b.com"), Vec::new(), 2_000);

    let flushed = icons.take_dirty();
    assert_eq!(flushed.len(), 2);
    assert!(icons.take_dirty().is_empty());
}

#[test]
fn loading_from_storage_is_not_a_fetch() {
    let icons = Icons::load(vec![StoredIcon {
        data_store_id: "ds".into(),
        host: "a.com".into(),
        bytes: png(),
        fetched_at_ms: 1_000,
    }]);

    assert!(icons.bytes(&IconKey::new("ds", "a.com")).is_some());
    // Nothing to write back: it came from there.
    assert_eq!(icons.revision(), 0);
}

// MARK: - Working out the key

#[test]
fn the_host_is_lowercased_so_one_site_is_one_row() {
    assert_eq!(
        host_of("https://GitHub.COM/x").as_deref(),
        Some("github.com")
    );
}

#[test]
fn a_page_with_no_site_has_no_key() {
    assert_eq!(host_of("about:blank"), None);
    assert_eq!(host_of("file:///tmp/x.html"), None);
    assert_eq!(host_of("data:text/html,<p>hi"), None);
    assert_eq!(host_of(""), None);
}
