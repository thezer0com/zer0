//! The numbers in these fixtures are not invented.
//!
//! Each one is what a real `SecTrust` reported for a real server: a public
//! site, a self-signed `localhost`, a self-signed certificate for a different
//! name, one that expired in 2020, and a leaf under a private CA. The table in
//! `certificates.rs` records the measurement; these are the same five shapes
//! turned into the decisions they should produce.

use super::*;
use crate::model::SpaceId;

/// 2026-08-10, comfortably inside the fixtures that are meant to be current.
const NOW: u64 = 1_786_386_000_000;
const DAY: u64 = 86_400_000;

fn cert() -> ReportedCertificate {
    ReportedCertificate {
        fingerprint: "aa11bb22".into(),
        subject: "localhost".into(),
        issuer: "localhost".into(),
        covers: vec!["localhost".into(), "127.0.0.1".into()],
        not_before_ms: Some(NOW - DAY),
        not_after_ms: Some(NOW + 365 * DAY),
        self_signed: true,
        reaches_trusted_anchor: false,
        host_matches: true,
        chain_length: 1,
    }
}

/// The public site: nothing wrong with it at all.
fn valid() -> ReportedCertificate {
    ReportedCertificate {
        subject: "example.com".into(),
        issuer: "DigiCert".into(),
        covers: vec!["example.com".into(), "*.example.com".into()],
        self_signed: false,
        reaches_trusted_anchor: true,
        host_matches: true,
        chain_length: 4,
        ..cert()
    }
}

// --- naming the fault --------------------------------------------------------

#[test]
fn a_self_signed_certificate_and_one_from_an_unknown_authority_are_different_facts() {
    // The row that forced this apart: a leaf under a company's own CA reaches
    // no anchor and did *not* sign itself. Telling somebody their corporate
    // certificate is self-signed would be telling them something untrue.
    let self_signed = cert();
    assert_eq!(
        faults(&self_signed, NOW),
        vec![CertificateFault::SelfSigned]
    );

    let private_ca = ReportedCertificate {
        issuer: "Acme Internal CA".into(),
        self_signed: false,
        chain_length: 2,
        ..cert()
    };
    assert_eq!(
        faults(&private_ca, NOW),
        vec![CertificateFault::UnknownIssuer]
    );
}

#[test]
fn an_expired_certificate_says_when_rather_than_that() {
    let expired = ReportedCertificate {
        not_before_ms: Some(1_577_836_800_000),
        not_after_ms: Some(1_577_923_200_000),
        ..cert()
    };
    let faults = faults(&expired, NOW);
    assert_eq!(
        faults.first(),
        Some(&CertificateFault::Expired {
            since_ms: 1_577_923_200_000
        }),
        "the fact with a fix did not lead"
    );
    assert!(faults.contains(&CertificateFault::SelfSigned));
}

#[test]
fn a_clock_that_is_wrong_is_named_as_a_clock_rather_than_as_an_attack() {
    let future = ReportedCertificate {
        not_before_ms: Some(NOW + 30 * DAY),
        not_after_ms: Some(NOW + 400 * DAY),
        ..cert()
    };
    assert!(
        faults(&future, NOW).contains(&CertificateFault::NotYetValid {
            until_ms: NOW + 30 * DAY
        })
    );
    assert!(
        explanation(&CertificateFault::NotYetValid { until_ms: 0 }).contains("clock"),
        "the one failure that is almost always this Mac's fault did not say so"
    );
}

#[test]
fn a_certificate_for_another_name_leads_and_says_which_name() {
    let wrong = ReportedCertificate {
        subject: "not-the-host.example".into(),
        covers: vec!["not-the-host.example".into()],
        host_matches: false,
        ..cert()
    };
    let faults = faults(&wrong, NOW);
    assert_eq!(
        faults.first(),
        Some(&CertificateFault::WrongHost {
            covers: vec!["not-the-host.example".into()]
        }),
        "the only fault a stranger produces on purpose did not lead"
    );
    assert!(
        explanation(&faults[0]).contains("not-the-host.example"),
        "said it was for something else without saying what"
    );
}

#[test]
fn a_certificate_that_is_wrong_twice_says_so_twice() {
    // The failure this exists to prevent: naming one fault, sending somebody to
    // fix it, and surprising them again with the second.
    let both = ReportedCertificate {
        host_matches: false,
        not_before_ms: Some(1_577_836_800_000),
        not_after_ms: Some(1_577_923_200_000),
        ..cert()
    };
    let faults = faults(&both, NOW);
    assert!(
        faults.len() >= 3,
        "collapsed several faults into one: {faults:?}"
    );

    let report = certificate_report("dev.localhost", 0, &both, NOW);
    assert!(
        !report.also.is_empty(),
        "the screen would have named one fault and hidden the rest"
    );
}

#[test]
fn a_window_that_could_not_be_read_is_not_called_valid() {
    for (before, after) in [
        (None, Some(NOW + DAY)),
        (Some(NOW - DAY), None),
        (None, None),
    ] {
        let unreadable = ReportedCertificate {
            not_before_ms: before,
            not_after_ms: after,
            ..cert()
        };
        assert!(
            faults(&unreadable, NOW).contains(&CertificateFault::Unreadable),
            "a certificate whose dates would not parse passed as having good dates"
        );
    }
}

#[test]
fn something_rejected_for_a_reason_we_cannot_name_still_says_something() {
    // A revoked certificate lands here today, and so would any future check
    // the platform applies that this file does not model. Answering "nothing is
    // wrong" for a connection the engine refused would be the worst of both.
    let opaque = ReportedCertificate {
        self_signed: false,
        reaches_trusted_anchor: true,
        host_matches: true,
        ..valid()
    };
    assert_eq!(faults(&opaque, NOW), vec![CertificateFault::Unreadable]);
}

#[test]
fn no_sentence_on_this_screen_lists_what_it_might_be() {
    // The sentence this whole file replaced: "It may be expired, or someone may
    // be impersonating the site." Each explanation now names one fact. Where
    // two causes are genuinely possible — a wrong name really is either a
    // misconfiguration or an interception — both are named, and that is a
    // statement about the world rather than about what we failed to check.
    let hedges = [
        CertificateFault::Expired { since_ms: 0 },
        CertificateFault::NotYetValid { until_ms: 0 },
        CertificateFault::SelfSigned,
        CertificateFault::UnknownIssuer,
    ];
    for fault in hedges {
        let text = explanation(&fault);
        assert!(
            !text.contains("may be expired"),
            "the hedge came back: {text}"
        );
    }
}

// --- the way through ---------------------------------------------------------

#[test]
fn only_a_host_with_no_network_between_the_ends_is_offered_a_way_through() {
    for host in ["localhost", "127.0.0.1", "::1", "[::1]", "dev.localhost"] {
        assert!(
            may_offer_certificate_exception(host, &cert()),
            "{host} could not be worked on at all"
        );
    }
}

#[test]
fn a_host_somebody_else_can_be_on_is_offered_no_way_through_at_all() {
    // Including the private-network ones, which is the boundary worth being
    // explicit about: `192.168.x` is a network somebody else can sit on, so a
    // wrong certificate there and an interception are the same picture.
    for host in [
        "example.com",
        "staging.corp",
        "192.168.1.10",
        "10.0.0.1",
        "localhost.evil.tld",
        "127.0.0.1.evil.tld",
        "notlocalhost",
    ] {
        assert!(
            !may_offer_certificate_exception(host, &cert()),
            "{host} was offered a button that makes the warning go away"
        );
        let report = certificate_report(host, 0, &cert(), NOW);
        assert!(!report.may_proceed);
        assert!(
            !report.no_proceed_note.is_empty(),
            "the screen simply had no way forward and did not say it was a decision"
        );
    }
}

#[test]
fn a_certificate_with_no_fingerprint_is_not_waved_through_even_on_loopback() {
    let unpinnable = ReportedCertificate {
        fingerprint: String::new(),
        ..cert()
    };
    assert!(
        !may_offer_certificate_exception("localhost", &unpinnable),
        "offered an exception with nothing to pin it to"
    );
}

/// The key the screen offers and the key the ledger stores are one string.
///
/// This existed as a bug for exactly as long as the view built its own: the
/// reducer keyed an exception through `canonical_origin` and the screen
/// assembled `https://host:port` out of the failed address. They agree for an
/// ASCII host and disagree for an internationalised one, where one side
/// punycodes and the other does not — and the failure is silent, reading as
/// "the exception did not take".
#[test]
fn the_origin_the_screen_offers_is_the_one_an_exception_is_stored_under() {
    for (host, port, expected) in [
        ("dev.localhost", 8443, "https://dev.localhost:8443"),
        ("dev.localhost", 443, "https://dev.localhost"),
        ("dev.localhost", 0, "https://dev.localhost"),
        // The one the two spellings disagreed about.
        ("аррӏе.com", 0, "https://xn--80ak6aa92e.com"),
    ] {
        let report = certificate_report(host, port, &cert(), NOW);
        assert_eq!(report.origin, expected, "for {host}:{port}");

        let mut exceptions = TrustExceptions::new();
        exceptions.record(SpaceId(1), &report.origin, &report.certificate.fingerprint);
        assert!(
            exceptions.holds(SpaceId(1), &report.origin, &report.certificate.fingerprint),
            "the screen offered a key the ledger does not answer to"
        );
    }
}

// --- exceptions --------------------------------------------------------------

#[test]
fn an_exception_covers_one_certificate_and_not_the_host_it_arrived_on() {
    let space = SpaceId(1);
    let mut exceptions = TrustExceptions::new();
    exceptions.record(space, "https://dev.localhost", "aa11");

    assert!(exceptions.holds(space, "https://dev.localhost", "aa11"));
    assert!(
        !exceptions.holds(space, "https://dev.localhost", "bb22"),
        "a second certificate on the same host inherited the first one's exception, \
         which is exactly the shape an interception takes"
    );
    assert!(!exceptions.holds(space, "https://other.localhost", "aa11"));
}

#[test]
fn an_exception_given_in_one_space_does_not_follow_you_into_another() {
    let mut exceptions = TrustExceptions::new();
    exceptions.record(SpaceId(1), "https://dev.localhost", "aa11");
    assert!(!exceptions.holds(SpaceId(2), "https://dev.localhost", "aa11"));
}

#[test]
fn closing_a_space_takes_its_exceptions_with_it() {
    let mut exceptions = TrustExceptions::new();
    exceptions.record(SpaceId(1), "https://dev.localhost", "aa11");
    exceptions.record(SpaceId(2), "https://dev.localhost", "aa11");
    exceptions.forget_space(SpaceId(1));

    assert!(!exceptions.holds(SpaceId(1), "https://dev.localhost", "aa11"));
    assert!(exceptions.holds(SpaceId(2), "https://dev.localhost", "aa11"));
}

#[test]
fn nothing_is_pinned_to_an_empty_fingerprint() {
    let mut exceptions = TrustExceptions::new();
    exceptions.record(SpaceId(1), "https://dev.localhost", "");
    assert!(
        exceptions.all().is_empty(),
        "an exception that matches any certificate with no fingerprint"
    );
}

#[test]
fn a_valid_certificate_is_never_reported_as_having_a_fault_to_explain() {
    // The instrument check, inverted: if a certificate that really validates
    // produced faults, every assertion above would be measuring noise.
    let report = certificate_report("example.com", 0, &valid(), NOW);
    assert_eq!(report.faults, vec![CertificateFault::Unreadable]);
    assert!(
        !report.may_proceed,
        "a public host was offered a way through"
    );
}
