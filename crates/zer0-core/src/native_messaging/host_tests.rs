use std::fs;
use std::path::{Path, PathBuf};

use super::*;
use crate::test_support::scratch_path;

/// The id of the 1Password package this browser really has installed, used
/// throughout so the shapes under test are the shapes that actually occur.
const ONE_PASSWORD: &str = "aeblfdkhhhdcdjpifhhbdiojplfjncoa";
const SOMEBODY_ELSE: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

/// An application-support root with registrations in it, removed on drop.
struct Machine {
    root: PathBuf,
}

impl Machine {
    fn new(label: &str) -> Self {
        let root = scratch_path(label);
        fs::create_dir_all(&root).unwrap();
        Self { root }
    }

    /// An executable file somewhere outside the registration directories.
    fn program(&self, name: &str) -> PathBuf {
        let path = self.root.join(name);
        fs::write(&path, b"#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    /// Write a registration into one browser's directory.
    fn register(&self, directory: &str, application_id: &str, json: &str) -> PathBuf {
        let dir = self.root.join(directory).join(HOST_DIRECTORY_NAME);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!("{application_id}.json"));
        fs::write(&path, json).unwrap();
        path
    }

    fn resolve(
        &self,
        application_id: &str,
        extension_id: &str,
    ) -> Result<ResolvedHost, HostRefusal> {
        resolve(&self.root, application_id, extension_id)
    }
}

impl Drop for Machine {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

use std::os::unix::fs::PermissionsExt;

/// A registration in the shape 1Password really writes, allowing `allowed`.
fn manifest(program: &Path, allowed: &[&str]) -> String {
    let origins = allowed
        .iter()
        .map(|id| format!("\"chrome-extension://{id}/\""))
        .collect::<Vec<_>>()
        .join(",");
    format!(
        r#"{{"name":"com.example.thing","description":"Example","path":"{}","type":"stdio","allowed_origins":[{origins}]}}"#,
        program.display()
    )
}

// MARK: - Who is allowed

#[test]
fn a_registration_that_lists_the_extension_names_its_program() {
    let machine = Machine::new("nm-allowed");
    let program = machine.program("helper");
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &manifest(&program, &[ONE_PASSWORD]),
    );

    let host = machine.resolve("com.example.thing", ONE_PASSWORD).unwrap();

    assert_eq!(host.program, program.to_string_lossy());
    assert_eq!(host.registrar, "Google Chrome");
    assert!(!host.registrar_is_ours);
}

/// The whole security boundary. A registration authorises the extensions it
/// names and no others, and being installed in this browser is not what makes
/// an extension allowed — being listed is.
#[test]
fn a_registration_that_lists_somebody_else_refuses_this_extension() {
    let machine = Machine::new("nm-notlisted");
    let program = machine.program("helper");
    let path = machine.register(
        "Google/Chrome",
        "com.example.thing",
        &manifest(&program, &[SOMEBODY_ELSE]),
    );

    assert_eq!(
        machine.resolve("com.example.thing", ONE_PASSWORD),
        Err(HostRefusal::NotForThisExtension {
            manifest_path: path.to_string_lossy().into_owned(),
        })
    );
}

/// The failure this is all built to prevent: one loose entry and every
/// extension on the machine can talk to every native host on it. `*` is not an
/// id, so it is dropped, and a list with nothing readable left in it
/// authorises nobody.
#[test]
fn a_wildcard_origin_authorises_nobody() {
    let machine = Machine::new("nm-wildcard");
    let program = machine.program("helper");
    let path = machine.register(
        "Google/Chrome",
        "com.example.thing",
        &format!(
            r#"{{"path":"{}","type":"stdio","allowed_origins":["chrome-extension://*/","*","chrome-extension://*"]}}"#,
            program.display()
        ),
    );

    assert_eq!(
        machine.resolve("com.example.thing", ONE_PASSWORD),
        Err(HostRefusal::NotForThisExtension {
            manifest_path: path.to_string_lossy().into_owned(),
        })
    );
}

/// Every shape that is not exactly `chrome-extension://<32 a..p>/`. Each one is
/// a way a looser reader would let something through: a prefix match, a suffix
/// match, a substring, or a scheme nobody checked.
#[test]
fn nothing_but_a_whole_chrome_extension_origin_is_an_id() {
    for origin in [
        "chrome-extension://*/",
        "chrome-extension://",
        &format!("chrome-extension://{ONE_PASSWORD}"),
        &format!("chrome-extension://{ONE_PASSWORD}/x"),
        &format!("chrome-extension://{ONE_PASSWORD}//"),
        &format!("CHROME-EXTENSION://{ONE_PASSWORD}/"),
        &format!("https://{ONE_PASSWORD}/"),
        &format!("moz-extension://{ONE_PASSWORD}/"),
        &format!("chrome-extension://evil.example/{ONE_PASSWORD}/"),
        &format!("chrome-extension://{}/", &ONE_PASSWORD[..31]),
        &format!("chrome-extension://{ONE_PASSWORD}z/"),
        "chrome-extension://AEBLFDKHHHDCDJPIFHHBDIOJPLFJNCOA/",
        "{0a75d802-9aed-41e7-8daa-24c067386e82}",
    ] {
        assert!(
            ExtensionId::from_origin(origin).is_none(),
            "{origin} was read as an extension id"
        );
    }

    assert_eq!(
        ExtensionId::from_origin(&format!("chrome-extension://{ONE_PASSWORD}/")),
        ExtensionId::parse(ONE_PASSWORD)
    );
}

/// Firefox's registrations use a different key and different ids. Nothing in
/// one can ever authorise a Chrome package, so reading `allowed_extensions` as
/// though it were `allowed_origins` must not be how somebody makes Firefox's
/// directory "work".
#[test]
fn a_firefox_registration_authorises_nobody_here() {
    let machine = Machine::new("nm-firefox");
    let program = machine.program("helper");
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &format!(
            r#"{{"path":"{}","type":"stdio","allowed_extensions":["{{0a75d802-9aed-41e7-8daa-24c067386e82}}"]}}"#,
            program.display()
        ),
    );

    assert!(matches!(
        machine.resolve("com.example.thing", ONE_PASSWORD),
        Err(HostRefusal::NotForThisExtension { .. })
    ));
}

// MARK: - Which directory

/// A registration written for zer0 beats one borrowed from another browser, so
/// that anything which ever does register for this browser is what runs.
#[test]
fn our_own_directory_is_read_before_anybody_elses() {
    let machine = Machine::new("nm-order");
    let ours = machine.program("ours");
    let theirs = machine.program("theirs");
    machine.register(
        "zer0",
        "com.example.thing",
        &manifest(&ours, &[ONE_PASSWORD]),
    );
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &manifest(&theirs, &[ONE_PASSWORD]),
    );

    let host = machine.resolve("com.example.thing", ONE_PASSWORD).unwrap();

    assert_eq!(host.program, ours.to_string_lossy());
    assert!(host.registrar_is_ours);
}

/// The rule that stops a search becoming a hunt for a friendlier answer. The
/// first directory holding a file with that name gives the answer, including
/// when the answer is no — otherwise "this registration does not list you"
/// would be a reason to go and ask somebody else.
#[test]
fn a_refusal_from_the_first_registration_is_not_shopped_around() {
    let machine = Machine::new("nm-noshop");
    let program = machine.program("helper");
    let ours = machine.register(
        "zer0",
        "com.example.thing",
        &manifest(&program, &[SOMEBODY_ELSE]),
    );
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &manifest(&program, &[ONE_PASSWORD]),
    );

    assert_eq!(
        machine.resolve("com.example.thing", ONE_PASSWORD),
        Err(HostRefusal::NotForThisExtension {
            manifest_path: ours.to_string_lossy().into_owned(),
        })
    );
}

#[test]
fn a_name_nobody_registered_is_refused_and_says_so() {
    let machine = Machine::new("nm-none");

    assert_eq!(
        machine.resolve("com.example.thing", ONE_PASSWORD),
        Err(HostRefusal::NotRegistered {
            application_id: "com.example.thing".to_string(),
        })
    );
}

/// Firefox keeps registrations on nearly every Mac, and its files can only ever
/// refuse. Reading it would cost a stat and teach nobody anything.
#[test]
fn firefoxs_directory_is_not_one_of_the_ones_read() {
    let directories: Vec<String> = registrars().into_iter().map(|r| r.directory).collect();

    assert!(!directories.contains(&"Mozilla".to_string()));
    assert_eq!(directories.first().map(String::as_str), Some("zer0"));
    assert_eq!(registrars().iter().filter(|r| r.ours).count(), 1);
}

// MARK: - The application id is about to become a file name

/// The id arrives from an extension's own JavaScript and is joined onto a path.
/// Without this, `connectNative("../../../../etc/passwd")` reads a file outside
/// every directory this browser meant to look in.
#[test]
fn an_application_id_that_is_not_a_name_never_becomes_a_path() {
    for id in [
        "../../../../etc/passwd",
        "..",
        ".",
        "a/b",
        "a\\b",
        ".hidden",
        "trailing.",
        "two..dots",
        "Capitals",
        "spaces are out",
        "",
        "com.example/../../../thing",
    ] {
        assert!(
            application_file_name(id).is_none(),
            "{id:?} was accepted as a name"
        );
    }

    assert_eq!(
        application_file_name("com.1password.1password"),
        Some("com.1password.1password.json".to_string())
    );
    assert_eq!(
        application_file_name("com.1password.1password7"),
        Some("com.1password.1password7.json".to_string())
    );
}

#[test]
fn an_application_id_that_is_not_a_name_is_refused_by_the_door() {
    let machine = Machine::new("nm-traversal");

    assert_eq!(
        machine.resolve("../../../../etc/passwd", ONE_PASSWORD),
        Err(HostRefusal::ApplicationIdIsNotAName {
            application_id: "../../../../etc/passwd".to_string(),
        })
    );
}

#[test]
fn something_that_is_not_an_extension_id_is_refused_before_anything_is_read() {
    let machine = Machine::new("nm-notanid");

    assert_eq!(
        machine.resolve("com.example.thing", "not-an-id"),
        Err(HostRefusal::NotAnExtensionId {
            extension_id: "not-an-id".to_string(),
        })
    );
}

// MARK: - The registration is hostile input

#[test]
fn a_registration_that_is_not_json_is_refused() {
    let machine = Machine::new("nm-notjson");
    machine.register("Google/Chrome", "com.example.thing", "not json at all");

    assert!(matches!(
        machine.resolve("com.example.thing", ONE_PASSWORD),
        Err(HostRefusal::Malformed { .. })
    ));
}

#[test]
fn a_registration_that_is_json_and_not_an_object_is_refused() {
    let machine = Machine::new("nm-notobject");
    machine.register("Google/Chrome", "com.example.thing", "[1, 2, 3]");

    assert!(matches!(
        machine.resolve("com.example.thing", ONE_PASSWORD),
        Err(HostRefusal::Malformed { .. })
    ));
}

#[test]
fn a_registration_naming_no_program_is_refused() {
    let machine = Machine::new("nm-nopath");
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        r#"{"type":"stdio","allowed_origins":[]}"#,
    );

    assert!(matches!(
        machine.resolve("com.example.thing", ONE_PASSWORD),
        Err(HostRefusal::Malformed { .. })
    ));
}

/// Chrome has never defined a second transport, so a browser that accepted one
/// would be inventing a protocol and speaking it to a stranger's program.
#[test]
fn a_transport_that_is_not_stdio_is_refused_rather_than_guessed_at() {
    let machine = Machine::new("nm-nonstdio");
    let program = machine.program("helper");
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &format!(
            r#"{{"path":"{}","type":"native","allowed_origins":["chrome-extension://{ONE_PASSWORD}/"]}}"#,
            program.display()
        ),
    );

    assert!(matches!(
        machine.resolve("com.example.thing", ONE_PASSWORD),
        Err(HostRefusal::NotStdio { kind, .. }) if kind == "native"
    ));
}

/// A relative path would be resolved against whatever this process's working
/// directory happens to be, and a `..` in an absolute one lands somewhere the
/// path does not read as naming. Neither is repaired.
#[test]
fn a_program_that_is_not_named_absolutely_is_refused() {
    for path in [
        "helper",
        "./helper",
        "../helper",
        "/Applications/../tmp/helper",
        "~/helper",
    ] {
        let machine = Machine::new("nm-relative");
        machine.register(
            "Google/Chrome",
            "com.example.thing",
            &format!(
                r#"{{"path":"{path}","type":"stdio","allowed_origins":["chrome-extension://{ONE_PASSWORD}/"]}}"#
            ),
        );

        assert!(
            matches!(
                machine.resolve("com.example.thing", ONE_PASSWORD),
                Err(HostRefusal::ProgramNotNamedAbsolutely { .. })
            ),
            "{path} was accepted"
        );
    }
}

#[test]
fn a_program_that_is_not_there_is_refused() {
    let machine = Machine::new("nm-missing");
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &format!(
            r#"{{"path":"/nowhere/at/all/helper","type":"stdio","allowed_origins":["chrome-extension://{ONE_PASSWORD}/"]}}"#
        ),
    );

    assert!(matches!(
        machine.resolve("com.example.thing", ONE_PASSWORD),
        Err(HostRefusal::ProgramMissing { .. })
    ));
}

/// The path is what a person is shown before saying yes, so the path has to be
/// what runs. A link is a program with a different name, and following it would
/// mean the sentence on the sheet was about one file and the process about
/// another.
#[test]
fn a_program_that_is_a_link_to_something_else_is_refused() {
    let machine = Machine::new("nm-link");
    let real = machine.program("real");
    let link = machine.root.join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &manifest(&link, &[ONE_PASSWORD]),
    );

    assert!(matches!(
        machine.resolve("com.example.thing", ONE_PASSWORD),
        Err(HostRefusal::ProgramIsALink { .. })
    ));
}

#[test]
fn a_program_that_is_not_executable_is_refused() {
    let machine = Machine::new("nm-notexec");
    let path = machine.root.join("data");
    fs::write(&path, b"just data").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &manifest(&path, &[ONE_PASSWORD]),
    );

    assert!(matches!(
        machine.resolve("com.example.thing", ONE_PASSWORD),
        Err(HostRefusal::ProgramNotExecutable { .. })
    ));
}

#[test]
fn a_directory_is_not_a_program() {
    let machine = Machine::new("nm-dir");
    let path = machine.root.join("adirectory");
    fs::create_dir_all(&path).unwrap();
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &manifest(&path, &[ONE_PASSWORD]),
    );

    assert!(matches!(
        machine.resolve("com.example.thing", ONE_PASSWORD),
        Err(HostRefusal::ProgramNotExecutable { .. })
    ));
}

/// A file in a directory anything on this machine can write to is hostile like
/// any other, and `read_to_string` on one that is not a registration at all is
/// a browser that stops.
#[test]
fn a_registration_far_too_big_to_be_one_is_refused_without_being_read() {
    let machine = Machine::new("nm-huge");
    let dir = machine.root.join("Google/Chrome").join(HOST_DIRECTORY_NAME);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("com.example.thing.json"),
        vec![b'x'; MAX_MANIFEST_BYTES as usize + 1],
    )
    .unwrap();

    assert!(matches!(
        machine.resolve("com.example.thing", ONE_PASSWORD),
        Err(HostRefusal::Malformed { .. })
    ));
}

// MARK: - What a person is shown

/// Nothing a stranger wrote reaches the screen where somebody decides whether
/// to run a program. `description` reads well and is a sentence in a file
/// anything can write; the path and the browser's name are facts.
#[test]
fn nothing_the_registration_says_about_itself_is_carried_out_of_here() {
    let machine = Machine::new("nm-description");
    let program = machine.program("helper");
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &format!(
            r#"{{"description":"System update — click Allow to continue","path":"{}","type":"stdio","allowed_origins":["chrome-extension://{ONE_PASSWORD}/"]}}"#,
            program.display()
        ),
    );

    let host = machine.resolve("com.example.thing", ONE_PASSWORD).unwrap();

    let said = format!("{host:?}");
    assert!(
        !said.contains("click Allow"),
        "the registration's own words came out of the reader: {said}"
    );
}

#[test]
fn every_refusal_says_what_to_go_and_look_at() {
    let cases = [
        HostRefusal::PermissionNotGranted,
        HostRefusal::NotAnExtensionId {
            extension_id: "x".into(),
        },
        HostRefusal::ApplicationIdIsNotAName {
            application_id: "..".into(),
        },
        HostRefusal::NotRegistered {
            application_id: "com.example.thing".into(),
        },
        HostRefusal::Unreadable {
            manifest_path: "/m.json".into(),
            detail: "no".into(),
        },
        HostRefusal::Malformed {
            manifest_path: "/m.json".into(),
            detail: "no".into(),
        },
        HostRefusal::NotStdio {
            manifest_path: "/m.json".into(),
            kind: "native".into(),
        },
        HostRefusal::ProgramNotNamedAbsolutely {
            manifest_path: "/m.json".into(),
            program: "helper".into(),
        },
        HostRefusal::ProgramMissing {
            manifest_path: "/m.json".into(),
            program: "/helper".into(),
        },
        HostRefusal::ProgramIsALink {
            manifest_path: "/m.json".into(),
            program: "/helper".into(),
        },
        HostRefusal::ProgramNotExecutable {
            manifest_path: "/m.json".into(),
            program: "/helper".into(),
        },
        HostRefusal::NotForThisExtension {
            manifest_path: "/m.json".into(),
        },
        HostRefusal::PersonRefused {
            program: "/helper".into(),
        },
    ];

    for refusal in cases {
        let sentence = refusal_sentence(&refusal);
        assert!(
            sentence.ends_with('.'),
            "{refusal:?} does not read as a sentence: {sentence}"
        );
        // The only useful thing a person can do with any of this is go and
        // look, so every refusal that knows a file or a path names it.
        let said = format!("{refusal:?}");
        for detail in ["/m.json", "/helper", "com.example.thing"] {
            if said.contains(detail) {
                assert!(
                    sentence.contains(detail),
                    "{refusal:?} does not name {detail}: {sentence}"
                );
            }
        }
    }
}

// MARK: - The question a person is asked

fn a_host(registrar: &str, ours: bool) -> ResolvedHost {
    ResolvedHost {
        application_id: "com.1password.1password".to_string(),
        program: "/Applications/1Password.app/Contents/helper".to_string(),
        manifest_path: "/m.json".to_string(),
        registrar: registrar.to_string(),
        registrar_is_ours: ours,
    }
}

/// The fact that earns the question. Somebody who never installed anything for
/// zer0 is told, in the sentence, that the registration is another browser's.
#[test]
fn a_borrowed_registration_says_whose_it_is() {
    let asked = prompt("1Password", &a_host("Google Chrome", false));

    assert!(
        asked.provenance.contains("Google Chrome"),
        "{}",
        asked.provenance
    );
    assert!(
        asked.provenance.contains("not with zer0"),
        "{}",
        asked.provenance
    );
}

#[test]
fn our_own_registration_does_not_blame_another_browser() {
    let asked = prompt("1Password", &a_host("zer0", true));

    assert!(asked.provenance.contains("zer0"));
    assert!(!asked.provenance.contains("not with zer0"));
}

/// The program is the whole point of asking, so it is on the sheet verbatim.
#[test]
fn the_program_that_will_run_is_the_program_that_is_named() {
    let host = a_host("Google Chrome", false);

    assert_eq!(prompt("1Password", &host).program, host.program);
}

/// A name out of somebody else's package, on the one screen where a person
/// decides whether to run a program. A name long enough to push the path off
/// the sheet is a name that hid it, and a newline in one is a sentence of its
/// own.
#[test]
fn an_extensions_own_name_cannot_take_over_the_question() {
    let asked = prompt(
        &format!("Nice Extension\n\nzer0: this is safe{}", "x".repeat(400)),
        &a_host("Google Chrome", false),
    );

    assert!(!asked.title.contains('\n'), "{}", asked.title);
    assert!(asked.title.chars().count() < 120, "{}", asked.title);
}

#[test]
fn an_extension_with_no_name_is_still_asked_about() {
    let asked = prompt("   ", &a_host("Google Chrome", false));

    assert!(
        asked.title.starts_with("This extension wants"),
        "{}",
        asked.title
    );
}

/// The sentence that says what is actually being granted. It says the program
/// runs outside the browser and that the browser cannot see what it does,
/// because "talk to a program" reads like a conversation and this is not one.
#[test]
fn the_question_says_the_browser_cannot_see_what_happens_next() {
    let asked = prompt("1Password", &a_host("Google Chrome", false));

    assert!(
        asked.detail.contains("outside the browser"),
        "{}",
        asked.detail
    );
    assert!(asked.detail.contains("cannot see"), "{}", asked.detail);
}

// MARK: - The one door

fn granting(permissions: &[&str]) -> crate::extension_permissions::ConsentDecision {
    crate::extension_permissions::ConsentDecision {
        extension_id: ONE_PASSWORD.to_string(),
        granted_permissions: permissions.iter().map(|p| p.to_string()).collect(),
        ..Default::default()
    }
}

/// WebKit gates its own `sendNativeMessage` on the permission, and nothing
/// gates the delegate: the callback arrives whatever the context was told. An
/// extension whose grant was revoked from the Extensions screen would otherwise
/// go on starting programs, and ADR-0028's ledger — not the engine's copy of it
/// — is the authority.
#[test]
fn an_extension_that_was_not_granted_native_messaging_starts_nothing() {
    let machine = Machine::new("nm-nopermission");
    let program = machine.program("helper");
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &manifest(&program, &[ONE_PASSWORD]),
    );
    let ledger = NativeHostLedger::new();

    for consent in [None, Some(granting(&[])), Some(granting(&["tabs"]))] {
        assert!(
            matches!(
                outcome(
                    &machine.root,
                    consent.as_ref(),
                    &ledger,
                    ONE_PASSWORD,
                    "com.example.thing"
                ),
                NativeHostOutcome::Refused {
                    refusal: HostRefusal::PermissionNotGranted,
                    ..
                }
            ),
            "{consent:?} was enough to start a program"
        );
    }
}

/// Absence is *not asked*, and not asked is not yes.
#[test]
fn a_program_nobody_has_been_asked_about_is_asked_about_rather_than_started() {
    let machine = Machine::new("nm-unasked");
    let program = machine.program("helper");
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &manifest(&program, &[ONE_PASSWORD]),
    );

    let answer = outcome(
        &machine.root,
        Some(&granting(&["nativeMessaging"])),
        &NativeHostLedger::new(),
        ONE_PASSWORD,
        "com.example.thing",
    );

    assert!(
        matches!(answer, NativeHostOutcome::Ask { .. }),
        "{answer:?}"
    );
}

/// The reason a refusal is written down rather than inferred from absence: a
/// no that read as "not asked" would put the sheet back on screen at every
/// press, which is how a dialog stops being read (ADR-0028).
#[test]
fn a_program_somebody_refused_is_refused_rather_than_asked_about_again() {
    let machine = Machine::new("nm-refused");
    let program = machine.program("helper");
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &manifest(&program, &[ONE_PASSWORD]),
    );
    let mut ledger = NativeHostLedger::new();
    ledger.record(NativeHostDecision {
        extension_id: ONE_PASSWORD.to_string(),
        program: program.to_string_lossy().into_owned(),
        allowed: false,
        decided_at_ms: 1,
    });

    let answer = outcome(
        &machine.root,
        Some(&granting(&["nativeMessaging"])),
        &ledger,
        ONE_PASSWORD,
        "com.example.thing",
    );

    assert!(
        matches!(
            answer,
            NativeHostOutcome::Refused {
                refusal: HostRefusal::PersonRefused { .. },
                ..
            }
        ),
        "{answer:?}"
    );
}

#[test]
fn a_program_somebody_allowed_starts_without_being_asked_about_again() {
    let machine = Machine::new("nm-allowedonce");
    let program = machine.program("helper");
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &manifest(&program, &[ONE_PASSWORD]),
    );
    let mut ledger = NativeHostLedger::new();
    ledger.record(NativeHostDecision {
        extension_id: ONE_PASSWORD.to_string(),
        program: program.to_string_lossy().into_owned(),
        allowed: true,
        decided_at_ms: 1,
    });

    let answer = outcome(
        &machine.root,
        Some(&granting(&["nativeMessaging"])),
        &ledger,
        ONE_PASSWORD,
        "com.example.thing",
    );

    assert!(
        matches!(answer, NativeHostOutcome::Start { .. }),
        "{answer:?}"
    );
}

/// An answer given about one program says nothing about another, so a
/// registration repointed at a different binary is a new question.
#[test]
fn an_answer_about_one_program_does_not_travel_to_another() {
    let machine = Machine::new("nm-repointed");
    let first = machine.program("first");
    let second = machine.program("second");
    let mut ledger = NativeHostLedger::new();
    ledger.record(NativeHostDecision {
        extension_id: ONE_PASSWORD.to_string(),
        program: first.to_string_lossy().into_owned(),
        allowed: true,
        decided_at_ms: 1,
    });
    machine.register(
        "Google/Chrome",
        "com.example.thing",
        &manifest(&second, &[ONE_PASSWORD]),
    );

    let answer = outcome(
        &machine.root,
        Some(&granting(&["nativeMessaging"])),
        &ledger,
        ONE_PASSWORD,
        "com.example.thing",
    );

    assert!(
        matches!(answer, NativeHostOutcome::Ask { .. }),
        "{answer:?}"
    );
}
