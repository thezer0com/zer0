use super::{SiteZooms, StoredZoom};
use crate::model::{Browser, SpaceId, TabKind};

fn insert_restored_tab(browser: &mut Browser, url: &str, factor: f64) {
    let tab = browser.insert_tab(browser.active_space(), TabKind::Today, None);
    if let Some(tab) = browser.tab_mut(tab) {
        tab.url = Some(url.to_string());
        tab.zoom_factor = factor;
    }
}

#[test]
fn persisted_zoom_rows_are_refused_when_invalid() {
    let invalid = [
        ("NaN factor", "https://nan.example", f64::NAN),
        (
            "positive infinite factor",
            "https://positive-infinity.example",
            f64::INFINITY,
        ),
        (
            "negative infinite factor",
            "https://negative-infinity.example",
            f64::NEG_INFINITY,
        ),
        ("default factor", "https://default.example", 1.0),
        ("factor below minimum", "https://below.example", 0.24),
        ("factor above maximum", "https://above.example", 5.01),
        ("invalid origin", "", 1.25),
        ("opaque origin", "data:text/plain,hello", 1.25),
        (
            "non-canonical origin",
            "https://non-canonical.example/",
            1.25,
        ),
    ];

    for (case, origin, factor) in invalid {
        let zooms = SiteZooms::load(vec![StoredZoom {
            space: SpaceId(1),
            origin: origin.to_string(),
            factor,
        }]);

        assert!(zooms.all().is_empty(), "accepted {case}");
    }
}

#[test]
fn adoption_skips_invalid_rows_before_the_first_valid_zoom() {
    let mut browser = Browser::new("Personal", "ds-personal");
    for factor in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 0.24, 5.01, 1.0] {
        insert_restored_tab(&mut browser, "https://example.com/first", factor);
    }
    insert_restored_tab(&mut browser, "data:text/plain,hello", 1.25);
    insert_restored_tab(&mut browser, "https://example.com/valid", 1.5);
    insert_restored_tab(&mut browser, "https://example.com/later", 1.75);
    let space = browser.active_space();
    let mut zooms = SiteZooms::default();

    zooms.adopt(&mut browser);

    assert_eq!(zooms.get(space, "https://example.com/elsewhere"), Some(1.5));
}

#[test]
fn all_lists_zooms_by_space_then_origin() {
    let zooms = SiteZooms::load(vec![
        StoredZoom {
            space: SpaceId(2),
            origin: "https://z.example".into(),
            factor: 1.5,
        },
        StoredZoom {
            space: SpaceId(1),
            origin: "https://z.example".into(),
            factor: 1.25,
        },
        StoredZoom {
            space: SpaceId(2),
            origin: "https://a.example".into(),
            factor: 2.0,
        },
        StoredZoom {
            space: SpaceId(1),
            origin: "https://m.example".into(),
            factor: 0.75,
        },
        StoredZoom {
            space: SpaceId(1),
            origin: "https://a.example".into(),
            factor: 0.5,
        },
    ]);

    let keys: Vec<_> = zooms
        .all()
        .into_iter()
        .map(|zoom| (zoom.space, zoom.origin))
        .collect();

    assert_eq!(
        keys,
        vec![
            (SpaceId(1), "https://a.example".into()),
            (SpaceId(1), "https://m.example".into()),
            (SpaceId(1), "https://z.example".into()),
            (SpaceId(2), "https://a.example".into()),
            (SpaceId(2), "https://z.example".into()),
        ]
    );
}

#[test]
fn forgetting_requires_the_exact_canonical_origin() {
    let space = SpaceId(1);

    for origin in ["", "data:text/plain,hello", "https://example.com/"] {
        let mut zooms = SiteZooms::load(vec![StoredZoom {
            space,
            origin: "https://example.com".into(),
            factor: 1.5,
        }]);

        let changed = zooms.forget(space, origin);

        assert!(!changed, "accepted {origin:?}");
        assert_eq!(zooms.get(space, "https://example.com/page"), Some(1.5));
    }
}
