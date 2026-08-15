//! The refusals, which are the whole feature.
//!
//! Weighted deliberately: there are more tests here about what must not be
//! offered than about what may be. A password manager that fills the right form
//! is table stakes; one that cannot be talked into filling the wrong one is the
//! product. Every `Refuse` below is a bug somebody has shipped.

use super::*;

/// A field that passes everything, so each test can spoil exactly one thing and
/// the failure names the clause it broke.
fn an_ordinary_field() -> ReportedField {
    ReportedField {
        width: 240.0,
        height: 32.0,
        opacity: 1.0,
        x: 40.0,
        y: 200.0,
        viewport_width: 1200.0,
        viewport_height: 800.0,
        disabled: false,
        readonly: false,
        topmost: true,
    }
}

fn origin(scheme: &str, host: &str, port: u32) -> ReportedOrigin {
    ReportedOrigin {
        scheme: scheme.to_string(),
        host: host.to_string(),
        port,
    }
}

/// An ordinary login page: same origin top and frame, https, a visible pair of
/// fields.
fn a_login_form_on(host: &str) -> ReportedForm {
    ReportedForm {
        page: origin("https", host, 0),
        form: origin("https", host, 0),
        username: Some(an_ordinary_field()),
        password: an_ordinary_field(),
    }
}

fn a_saved_login(origin: &str, username: &str) -> SavedLogin {
    SavedLogin {
        origin: origin.to_string(),
        username: username.to_string(),
    }
}

// --- the shape everything else is a departure from ---------------------------

#[test]
fn an_ordinary_login_page_is_filled_and_saved() {
    let form = a_login_form_on("github.com");
    assert_eq!(
        fill_verdict(&form),
        FillVerdict::Fill {
            origin: "https://github.com".to_string()
        }
    );
    assert_eq!(
        save_verdict(&form, true),
        SaveVerdict::Save {
            origin: "https://github.com".to_string()
        }
    );
}

// --- origin binding ----------------------------------------------------------

#[test]
fn a_lookalike_origin_is_offered_nothing() {
    // ADR-0026 set the standard for this and did it with a suffix rule, which
    // is right for routing and wrong here. These are the hosts that rule would
    // also refuse, plus the ones only exact matching refuses.
    let saved = vec![a_saved_login("https://github.com", "avelino")];

    for impostor in [
        "https://github.com.evil.tld",
        "https://githubb.com",
        "https://fakegithub.com",
        "https://notgithub.com",
        "https://github.com.br",
        // The one a suffix rule would wrongly allow. A credential is not shared
        // with a subdomain, because on a host where strangers get subdomains
        // that is a stranger.
        "https://gist.github.com",
        "https://pages.github.com",
    ] {
        assert_eq!(
            offerable(impostor, &saved),
            Vec::new(),
            "a credential saved for github.com must never be offered to {impostor}"
        );
    }
}

#[test]
fn an_exact_origin_is_the_only_thing_that_matches() {
    let saved = vec![a_saved_login("https://github.com", "avelino")];
    assert_eq!(offerable("https://github.com", &saved), saved);
}

#[test]
fn a_downgrade_to_http_does_not_collect_a_credential_saved_over_https() {
    let saved = vec![a_saved_login("https://example.com", "avelino")];
    assert_eq!(offerable("http://example.com", &saved), Vec::new());
}

#[test]
fn a_different_port_is_a_different_origin() {
    let saved = vec![a_saved_login("https://example.com:8443", "avelino")];
    assert_eq!(offerable("https://example.com", &saved), Vec::new());
    assert_eq!(offerable("https://example.com:8443", &saved), saved);
}

#[test]
fn an_idn_lookalike_does_not_borrow_the_latin_spellings_credential() {
    // `аpple.com` with a Cyrillic а. It canonicalises to punycode, so the two
    // are different strings rather than the same one drawn twice.
    let form = a_login_form_on("аpple.com");
    let FillVerdict::Fill { origin: cyrillic } = fill_verdict(&form) else {
        panic!("an IDN origin is still an origin");
    };
    assert_ne!(cyrillic, "https://apple.com");
    assert!(
        cyrillic.contains("xn--"),
        "the key must be the punycode spelling a person can act on, got {cyrillic}"
    );

    let saved = vec![a_saved_login("https://apple.com", "avelino")];
    assert_eq!(offerable(&cyrillic, &saved), Vec::new());
}

#[test]
fn a_cross_origin_frame_is_refused_even_when_the_frame_is_genuine() {
    let mut form = a_login_form_on("docs.google.com");
    form.form = origin("https", "accounts.google.com", 0);

    assert_eq!(
        fill_verdict(&form),
        FillVerdict::Refuse {
            because: Refusal::CrossOrigin {
                page: "https://docs.google.com".to_string(),
                form: "https://accounts.google.com".to_string(),
            }
        }
    );
    assert!(matches!(
        save_verdict(&form, true),
        SaveVerdict::Refuse {
            because: Refusal::CrossOrigin { .. }
        }
    ));
}

#[test]
fn a_page_that_is_not_an_origin_gets_nothing() {
    for scheme in ["file", "data", "about", "zer0", "javascript", "blob"] {
        let mut form = a_login_form_on("example.com");
        form.page = origin(scheme, "example.com", 0);
        form.form = origin(scheme, "example.com", 0);
        assert_eq!(
            fill_verdict(&form),
            FillVerdict::Refuse {
                because: Refusal::NotAnOrigin
            },
            "{scheme}: only http and https carry logins"
        );
    }
}

#[test]
fn an_origin_with_an_empty_host_is_not_an_origin() {
    let mut form = a_login_form_on("example.com");
    form.page = origin("https", "", 0);
    form.form = origin("https", "", 0);
    assert_eq!(
        fill_verdict(&form),
        FillVerdict::Refuse {
            because: Refusal::NotAnOrigin
        }
    );
}

// --- encryption --------------------------------------------------------------

#[test]
fn an_unencrypted_page_is_refused() {
    let mut form = a_login_form_on("example.com");
    form.page = origin("http", "example.com", 0);
    form.form = origin("http", "example.com", 0);

    assert_eq!(
        fill_verdict(&form),
        FillVerdict::Refuse {
            because: Refusal::Insecure {
                origin: "http://example.com".to_string()
            }
        }
    );
    assert!(matches!(
        save_verdict(&form, true),
        SaveVerdict::Refuse {
            because: Refusal::Insecure { .. }
        }
    ));
}

#[test]
fn loopback_over_http_is_allowed_because_there_is_no_wire_to_watch() {
    for host in ["localhost", "app.localhost", "127.0.0.1"] {
        let mut form = a_login_form_on(host);
        form.page = origin("http", host, 3000);
        form.form = origin("http", host, 3000);
        assert!(
            matches!(fill_verdict(&form), FillVerdict::Fill { .. }),
            "{host} is where anybody building a login form actually works"
        );
    }
}

#[test]
fn a_host_that_merely_looks_like_loopback_is_still_unencrypted() {
    for host in ["localhost.evil.tld", "notlocalhost", "127.0.0.1.evil.tld"] {
        let mut form = a_login_form_on(host);
        form.page = origin("http", host, 0);
        form.form = origin("http", host, 0);
        assert!(
            matches!(
                fill_verdict(&form),
                FillVerdict::Refuse {
                    because: Refusal::Insecure { .. }
                }
            ),
            "{host} is not loopback"
        );
    }
}

// --- the hidden field, which is the attack this feature has to survive -------

#[test]
fn a_field_nobody_can_see_is_filled_with_nothing() {
    // Each of these is a real harvesting form, and each spoils exactly one
    // clause of `usable`. They are listed together because the danger is a
    // future refactor that folds them into one score.
    /// One way of drawing a field nobody can see, and what to call it when it
    /// gets through.
    type Harvest = (&'static str, fn(&mut ReportedField));

    let cases: [Harvest; 9] = [
        ("display:none, reported as a zero box", |f| {
            f.width = 0.0;
            f.height = 0.0;
        }),
        ("one pixel tall", |f| f.height = 1.0),
        ("one pixel wide", |f| f.width = 1.0),
        ("opacity: 0", |f| f.opacity = 0.0),
        ("opacity: 0.001", |f| f.opacity = 0.001),
        ("a computed style that produced NaN", |f| {
            f.opacity = f64::NAN
        }),
        ("parked off-screen at left: -9999px", |f| f.x = -9999.0),
        ("parked below the fold at top: -9999px", |f| f.y = -9999.0),
        ("covered by something drawn on top of it", |f| {
            f.topmost = false
        }),
    ];

    for (description, spoil) in cases {
        let mut form = a_login_form_on("example.com");
        spoil(&mut form.password);
        assert_eq!(
            fill_verdict(&form),
            FillVerdict::Refuse {
                because: Refusal::UnusableField
            },
            "{description}: a page must not be able to harvest a fill this way"
        );
    }
}

#[test]
fn a_field_that_cannot_be_typed_into_is_not_filled_either() {
    for spoil in [
        (|f: &mut ReportedField| f.disabled = true) as fn(&mut ReportedField),
        |f: &mut ReportedField| f.readonly = true,
    ] {
        let mut form = a_login_form_on("example.com");
        spoil(&mut form.password);
        assert_eq!(
            fill_verdict(&form),
            FillVerdict::Refuse {
                because: Refusal::UnusableField
            }
        );
    }
}

#[test]
fn a_field_only_partly_on_screen_is_still_a_field() {
    // The boundary matters in the honest direction too: a form scrolled so that
    // its top half is above the fold is ordinary, and refusing it would make
    // the feature feel broken for a reason nobody could see.
    let mut form = a_login_form_on("example.com");
    form.password.y = -10.0;
    form.password.height = 32.0;
    assert!(matches!(fill_verdict(&form), FillVerdict::Fill { .. }));
}

#[test]
fn a_hidden_username_field_does_not_stop_the_password_being_filled() {
    // Plenty of real sites collect the username on a previous screen and keep
    // it in a hidden input. Refusing that would be refusing a large fraction of
    // the web to defend against something the password field's own check
    // already covers.
    let mut form = a_login_form_on("example.com");
    form.username = Some(ReportedField {
        width: 0.0,
        height: 0.0,
        ..an_ordinary_field()
    });
    assert!(matches!(fill_verdict(&form), FillVerdict::Fill { .. }));
}

// --- an ephemeral space ------------------------------------------------------

#[test]
fn an_ephemeral_space_writes_no_password_down() {
    let form = a_login_form_on("github.com");
    assert_eq!(
        save_verdict(&form, false),
        SaveVerdict::Refuse {
            because: Refusal::Ephemeral
        }
    );
}

#[test]
fn an_ephemeral_space_is_refused_before_the_page_is_even_looked_at() {
    // The refusal names the space, not the page. A private space refuses for a
    // reason that has nothing to do with what is on screen, and reporting the
    // page's problem instead would send somebody off fixing the wrong thing.
    let mut form = a_login_form_on("example.com");
    form.page = origin("http", "example.com", 0);
    form.form = origin("http", "example.com", 0);
    assert_eq!(
        save_verdict(&form, false),
        SaveVerdict::Refuse {
            because: Refusal::Ephemeral
        }
    );
}

#[test]
fn an_ephemeral_space_cannot_be_given_a_keychain_scope_to_write_into() {
    // The structural half. Without this string the shell has no query to build
    // and no value it could reasonably put there instead.
    assert_eq!(keychain_scope("6E8F…", false), None);
    assert_eq!(keychain_scope("", true), None);
    assert_eq!(keychain_scope("   ", true), None);
}

#[test]
fn two_spaces_get_two_scopes_so_the_same_site_holds_two_logins() {
    // The product's own premise (ADR-0007): work and personal on one site.
    let work = keychain_scope("A1B2", true);
    let personal = keychain_scope("C3D4", true);
    assert!(work.is_some());
    assert_ne!(work, personal);
}

// --- what the list is allowed to say -----------------------------------------

#[test]
fn the_list_is_ordered_and_deduplicated_so_it_does_not_shuffle() {
    let saved = vec![
        a_saved_login("https://example.com", "zoe"),
        a_saved_login("https://example.com", "avelino"),
        a_saved_login("https://example.com", "avelino"),
        a_saved_login("https://elsewhere.com", "avelino"),
    ];
    let offers = offerable("https://example.com", &saved);
    assert_eq!(
        offers,
        vec![
            a_saved_login("https://example.com", "avelino"),
            a_saved_login("https://example.com", "zoe"),
        ]
    );
}

#[test]
fn nothing_saved_means_nothing_offered_rather_than_a_guess() {
    assert_eq!(offerable("https://example.com", &[]), Vec::new());
}

// --- the round trip the Keychain is keyed by ---------------------------------

#[test]
fn a_canonical_origin_comes_apart_into_the_attributes_it_was_built_from() {
    assert_eq!(
        keychain_fields("https://github.com"),
        Some(KeychainFields {
            scheme: "https".to_string(),
            host: "github.com".to_string(),
            // Resolved rather than left at 0: the Keychain has no "default".
            port: 443,
        })
    );
    assert_eq!(
        keychain_fields("http://localhost:3000"),
        Some(KeychainFields {
            scheme: "http".to_string(),
            host: "localhost".to_string(),
            port: 3000,
        })
    );
}

#[test]
fn every_origin_the_core_produces_can_be_taken_back_apart() {
    // The two halves must not drift. This is the bug `SecretStore.swift`
    // already records once: stored under one key, looked for under another.
    for host in ["github.com", "аpple.com", "münchen.de", "example.co.uk"] {
        for port in [0_u32, 8443] {
            let form = ReportedForm {
                page: origin("https", host, port),
                form: origin("https", host, port),
                username: None,
                password: an_ordinary_field(),
            };
            let FillVerdict::Fill { origin: canonical } = fill_verdict(&form) else {
                panic!("{host}:{port} should be fillable");
            };
            let fields = keychain_fields(&canonical)
                .unwrap_or_else(|| panic!("the core produced {canonical} and cannot read it back"));
            assert_eq!(fields.scheme, "https");
            assert_eq!(fields.port, if port == 0 { 443 } else { port });
            assert!(
                canonical.contains(&fields.host),
                "{canonical} and {} disagree about the host",
                fields.host
            );
        }
    }
}

#[test]
fn something_that_is_not_an_origin_yields_no_keychain_fields() {
    for not_an_origin in ["", "github.com", "file:///etc/passwd", "ftp://example.com"] {
        assert_eq!(keychain_fields(not_an_origin), None);
    }
}

// --- the thing that must stay true of the module as a whole ------------------

#[test]
fn no_type_in_this_module_can_hold_a_password() {
    // ADR-0048's guarantee, kept honest by reading this file rather than by
    // remembering. `password` here is a *field* — geometry — and `username` is
    // not a secret; a field whose name says otherwise is the regression.
    let source = include_str!("passwords.rs");
    for banned in [
        "pub password: String",
        "password: String",
        "pub secret: String",
        "fn password(",
    ] {
        assert!(
            !source.contains(banned),
            "`{banned}` puts a credential value into the core, and ADR-0048 says \
             the core has no type that can hold one"
        );
    }
}
