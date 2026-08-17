//! What the configuration file has to survive.
//!
//! Weighted to failure on purpose. The happy path here is one function call and
//! it would be strange to get it wrong; what will actually happen to this code
//! is an editor saving half a file, a repeated id, a key pasted in the wrong
//! place, and a symlink into somebody's dotfiles checkout.
//!
//! The one that matters most is `a_secret_can_never_reach_the_file`. Everything
//! else in here is a bug; that one is a credential in a public repository.

use std::fs;
use std::path::{Path, PathBuf};

use super::*;

/// A temp directory that cleans itself up, matching `ext_tests.rs`.
struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        let path = crate::test_support::scratch_path(&format!("config-{label}"));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }

    fn file(&self, name: &str, contents: &str) -> PathBuf {
        let path = self.0.join(name);
        fs::write(&path, contents).unwrap();
        path
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn load(text: &str) -> Config {
    parse(text).expect("should be valid TOML").config
}

fn diagnostics_of(text: &str) -> Vec<ConfigDiagnostic> {
    parse(text).expect("should be valid TOML").diagnostics
}

fn errors_of(text: &str) -> Vec<ConfigDiagnostic> {
    diagnostics_of(text)
        .into_iter()
        .filter(|d| d.severity == ConfigSeverity::Error)
        .collect()
}

const TWO_PROVIDERS: &str = r#"
[chat]
default_provider = "anthropic"

[[provider]]
id = "anthropic"
kind = "anthropic"
credential = "anthropic"
models = ["opus", "sonnet"]

[[provider]]
id = "local"
name = "Ollama"
kind = "ollama"
"#;

// MARK: - Absence is the normal first state

#[test]
fn no_file_at_all_is_a_first_run_and_not_an_error() {
    let dir = TempDir::new("absent");
    let file = ConfigFile::open(dir.path().join("nothing-here.toml"));

    assert_eq!(file.config(), &Config::default());
    assert!(file.diagnostics().is_empty(), "absence is not a complaint");
    // Readable, because there is nothing wrong. A browser that has never been
    // configured must not show an error, and must be free to write a file later.
    assert!(file.is_readable());
    assert!(!file.exists());
}

#[test]
fn an_empty_file_and_a_file_of_only_comments_are_both_just_defaults() {
    for text in ["", "\n\n", "# nothing to see\n# still nothing\n"] {
        let parsed = parse(text).expect("comments and blank lines are valid TOML");
        assert_eq!(parsed.config, Config::default(), "for {text:?}");
        assert!(parsed.diagnostics.is_empty(), "for {text:?}");
    }
}

#[test]
fn opening_a_file_never_creates_one() {
    // Writing into ~/.config uninvited would put a file in somebody's dotfiles
    // repository that they did not add and did not want.
    let dir = TempDir::new("no-create");
    let path = dir.path().join("config.toml");
    let _ = ConfigFile::open(&path);
    assert!(!path.exists());
}

// MARK: - A file that will not parse

#[test]
fn a_file_that_is_not_toml_names_the_line_it_broke_on() {
    let diagnostic = parse("[chat]\ndefault_provider = \"a\"\n\n[[provider]]\nid = broken\n")
        .expect_err("unquoted value is not TOML");

    assert_eq!(diagnostic.severity, ConfigSeverity::Error);
    assert_eq!(diagnostic.line, 5, "the line the value is on");
    assert!(diagnostic.column > 0);
    assert!(
        diagnostic.describe().contains("line 5"),
        "a person has to be able to put the cursor somewhere: {}",
        diagnostic.describe()
    );
}

#[test]
fn a_broken_file_does_not_replace_the_configuration_that_was_working() {
    // The one that happens several times a minute while somebody edits: most
    // editors truncate and then write, so a watcher fires on an empty or
    // half-written file. Dropping every provider each time would make the
    // browser flicker between configured and not.
    let dir = TempDir::new("half-written");
    let path = dir.file("config.toml", TWO_PROVIDERS);
    let mut file = ConfigFile::open(&path);
    assert_eq!(file.config().providers.len(), 2);

    fs::write(&path, "[chat]\ndefault_provider = \"anth").unwrap();
    file.reload();

    assert_eq!(
        file.config().providers.len(),
        2,
        "the last configuration that parsed stays in force"
    );
    assert!(!file.is_readable(), "and the interface is told it is stale");
    assert_eq!(file.diagnostics().len(), 1);
}

#[test]
fn a_file_that_becomes_valid_again_clears_the_error_by_itself() {
    let dir = TempDir::new("recovers");
    let path = dir.file("config.toml", "nonsense = = =");
    let mut file = ConfigFile::open(&path);
    assert!(!file.is_readable());

    fs::write(&path, TWO_PROVIDERS).unwrap();
    assert!(file.reload());

    assert!(file.is_readable());
    assert!(file.diagnostics().is_empty());
    assert_eq!(file.config().providers.len(), 2);
}

#[test]
fn a_reload_with_nothing_changed_says_nothing_changed() {
    // Watchers fire on touches, `git` restores files to what they already were,
    // and saves write twice. Reconnecting every MCP server on each of those
    // would be a browser that drops its tools whenever somebody hits ⌘S.
    let dir = TempDir::new("unchanged");
    let path = dir.file("config.toml", TWO_PROVIDERS);
    let mut file = ConfigFile::open(&path);

    assert!(!file.reload());
    fs::write(&path, TWO_PROVIDERS).unwrap();
    assert!(!file.reload(), "same bytes, same answer");
}

// MARK: - One bad entry does not take the file down

#[test]
fn an_unknown_provider_kind_is_dropped_and_the_rest_of_the_file_survives() {
    let config = load(
        r#"
[[provider]]
id = "first"
kind = "anthropic"

[[provider]]
id = "typo"
kind = "anthropik"

[[mcp_server]]
id = "github"
transport = "stdio"
command = "gh-mcp"
"#,
    );

    assert_eq!(
        config
            .providers
            .iter()
            .map(|p| p.id.as_str())
            .collect::<Vec<_>>(),
        ["first"],
        "the bad one goes and nothing else does"
    );
    assert_eq!(config.mcp_servers.len(), 1, "and not the servers under it");
}

#[test]
fn an_unknown_kind_is_never_guessed_into_something_plausible() {
    // Defaulting it would fail at the first request with a message about JSON
    // rather than about configuration, which is a much longer afternoon.
    let errors = errors_of("[[provider]]\nid = \"x\"\nkind = \"anthropik\"\n");
    assert_eq!(errors.len(), 1);
    assert_eq!(errors[0].line, 3);
    assert!(
        errors[0].message.contains("anthropic"),
        "the message lists what is allowed: {}",
        errors[0].message
    );
}

#[test]
fn a_repeated_id_keeps_the_first_and_names_the_line_of_the_second() {
    let text = "[[provider]]\nid = \"dup\"\nkind = \"anthropic\"\n\n[[provider]]\nid = \"dup\"\nkind = \"ollama\"\n";
    let parsed = parse(text).unwrap();

    assert_eq!(parsed.config.providers.len(), 1);
    assert_eq!(parsed.config.providers[0].kind, ProviderKind::Anthropic);
    let error = parsed
        .diagnostics
        .iter()
        .find(|d| d.severity == ConfigSeverity::Error)
        .expect("the second one is reported");
    assert_eq!(error.line, 6);
}

#[test]
fn a_misspelt_key_is_a_warning_that_names_the_line_and_costs_nothing() {
    // A setting that silently does nothing is the worst way for a config to
    // fail: everything looks right and nothing happens.
    let parsed =
        parse("[[provider]]\nid = \"x\"\nkind = \"ollama\"\ncredentail = \"oops\"\n").unwrap();

    assert_eq!(parsed.config.providers.len(), 1, "the provider still loads");
    let warning = parsed
        .diagnostics
        .iter()
        .find(|d| d.severity == ConfigSeverity::Warning)
        .expect("but the typo is called out");
    assert_eq!(warning.line, 4);
    assert!(warning.message.contains("credentail"));
}

#[test]
fn an_entry_missing_the_thing_that_makes_it_reachable_is_refused() {
    let cases = [
        (
            "[[provider]]\nid = \"x\"\nkind = \"openai-compatible\"\n",
            "base_url",
        ),
        (
            "[[mcp_server]]\nid = \"x\"\ntransport = \"stdio\"\n",
            "command",
        ),
        ("[[mcp_server]]\nid = \"x\"\ntransport = \"http\"\n", "url"),
    ];
    for (text, missing) in cases {
        let parsed = parse(text).unwrap();
        assert!(
            parsed.config.providers.is_empty() && parsed.config.mcp_servers.is_empty(),
            "an entry with no {missing} cannot be reached, so keeping it would \
             mean a server that silently never starts"
        );
        let error = parsed
            .diagnostics
            .iter()
            .find(|d| d.severity == ConfigSeverity::Error)
            .unwrap_or_else(|| panic!("missing {missing} is reported"));
        assert!(error.message.contains(missing), "{}", error.message);
    }
}

#[test]
fn a_default_provider_naming_nothing_falls_back_rather_than_failing() {
    let config = load(
        "[chat]\ndefault_provider = \"deleted\"\n\n[[provider]]\nid = \"here\"\nkind = \"ollama\"\n",
    );

    assert_eq!(
        config.effective_provider(&[]).map(|p| p.id.as_str()),
        Some("here")
    );
    let warning = diagnostics_of(
        "[chat]\ndefault_provider = \"deleted\"\n\n[[provider]]\nid = \"here\"\nkind = \"ollama\"\n",
    )
    .into_iter()
    .find(|d| d.severity == ConfigSeverity::Warning)
    .expect("silently using a different model than the file asks for is a surprise");
    assert_eq!(warning.line, 2);
}

#[test]
fn a_disabled_provider_is_kept_in_the_file_and_out_of_the_picker() {
    // Deleting to switch something off and retyping it to switch it back on is
    // not a toggle.
    let config = load(
        "[[provider]]\nid = \"off\"\nkind = \"anthropic\"\nenabled = false\n\n[[provider]]\nid = \"on\"\nkind = \"ollama\"\n",
    );

    assert_eq!(config.providers.len(), 2, "both are still written down");
    assert_eq!(config.provider_readiness("off", &[]), Readiness::Disabled);
    assert_eq!(
        config.effective_provider(&[]).map(|p| p.id.as_str()),
        Some("on")
    );
}

// MARK: - Secrets. The part that matters.

#[test]
fn a_secret_can_never_reach_the_file_however_the_settings_window_asks() {
    // The whole design in one test. Every way a settings window can change the
    // file is tried with a real-looking key in the field that takes a name, and
    // none of them may put those bytes on disk.
    //
    // This is stronger than checking one path because the guarantee is supposed
    // to be structural: there is no field in these types that can hold a value,
    // and the only field that could be *mistaken* for one is checked on the way
    // in and on the way out.
    const KEY: &str = "sk-ant-api03-tHiSiSaReAlLoOkInGkEyDoNoTcOmMiT-0123456789abcdef";
    let dir = TempDir::new("no-secret");
    let path = dir.file("config.toml", TWO_PROVIDERS);
    let mut file = ConfigFile::open(&path);

    let mut provider = ProviderConfig::new("anthropic", ProviderKind::Anthropic);
    provider.credential = Some(KEY.to_string());
    assert!(file.upsert_provider(&provider).is_err());

    let mut server = McpServerConfig::new("github", TransportKind::Stdio);
    server.command = Some("gh-mcp".to_string());
    server.credential = Some(KEY.to_string());
    assert!(file.upsert_mcp_server(&server).is_err());

    server.credential = None;
    server.env = vec![EnvVar {
        name: "GITHUB_TOKEN".to_string(),
        value: KEY.to_string(),
    }];
    assert!(file.upsert_mcp_server(&server).is_err());

    server.env = Vec::new();
    server.secret_env = vec![SecretEnvVar {
        name: "GITHUB_TOKEN".to_string(),
        credential: KEY.to_string(),
    }];
    assert!(file.upsert_mcp_server(&server).is_err());

    let on_disk = fs::read_to_string(&path).unwrap();
    assert!(
        !on_disk.contains(KEY),
        "a key reached the file, and the next `git push` publishes it"
    );
    assert!(
        !on_disk.contains("sk-ant"),
        "not even a fragment of one: {on_disk}"
    );
}

#[test]
fn a_key_written_into_credential_by_hand_is_refused_and_told_where_it_goes() {
    let text = "[[provider]]\nid = \"anthropic\"\nkind = \"anthropic\"\ncredential = \"sk-ant-api03-0123456789abcdefghijklmnop\"\n";
    let parsed = parse(text).unwrap();

    assert!(
        parsed.config.providers.is_empty(),
        "kept with the credential dropped, it would look ready and fail with a 401"
    );
    let error = &parsed.diagnostics[0];
    assert_eq!(error.line, 4);
    assert!(
        error.message.contains("Keychain"),
        "the message says where the key belongs: {}",
        error.message
    );
}

#[test]
fn a_key_in_an_mcp_env_var_is_refused_and_points_at_secret_env() {
    // This is where it would actually have gone: almost every stdio MCP server
    // authenticates through an environment variable, so without this check the
    // careful work everywhere else buys nothing.
    let parsed = parse(
        "[[mcp_server]]\nid = \"github\"\ntransport = \"stdio\"\ncommand = \"gh-mcp\"\n\n[mcp_server.env]\nGITHUB_TOKEN = \"ghp_0123456789abcdefghijklmnopqrstuvwxyzAB\"\n",
    )
    .unwrap();

    let server = &parsed.config.mcp_servers[0];
    assert!(server.env.is_empty(), "the variable is not carried");
    let error = parsed
        .diagnostics
        .iter()
        .find(|d| d.severity == ConfigSeverity::Error)
        .expect("and it is reported");
    assert_eq!(error.line, 7);
    assert!(error.message.contains("secret_env"), "{}", error.message);
}

#[test]
fn a_credential_is_written_as_a_name_and_reads_back_as_a_name() {
    let dir = TempDir::new("name-only");
    let path = dir.path().join("config.toml");
    let mut file = ConfigFile::open(&path);

    let mut provider = ProviderConfig::new("anthropic", ProviderKind::Anthropic);
    provider.credential = Some("work-anthropic".to_string());
    file.upsert_provider(&provider).unwrap();

    let on_disk = fs::read_to_string(&path).unwrap();
    assert!(on_disk.contains("credential = \"work-anthropic\""));
    assert_eq!(
        file.config().providers[0].credential.as_deref(),
        Some("work-anthropic")
    );
}

#[test]
fn what_counts_as_looking_like_a_key() {
    // False positives cost a rename. A false negative is a credential in a
    // public repository, so the rules lean hard one way.
    for secret in [
        "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123",
        "sk-proj-abcdef0123456789",
        "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB",
        "github_pat_11ABCDEFG0123456789",
        "xoxb-1234-5678-abcdefghijklmnop",
        "AIzaSyA0123456789abcdefghijklmnopqrstu",
        "AKIAIOSFODNN7EXAMPLE",
        "glpat-0123456789abcdefghij",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "Bearer abc123",
        // No known prefix, but forty characters of unbroken letters and digits
        // is not a name anybody typed.
        "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0",
    ] {
        assert!(looks_like_a_secret(secret), "should be refused: {secret}");
    }

    for name in [
        "anthropic",
        "work-openai",
        "openai_personal",
        "my anthropic key",
        "grafana",
        "",
        // Long, but it has spaces, so a person wrote it.
        "the anthropic key I use for work and nothing else at all",
    ] {
        assert!(!looks_like_a_secret(name), "should be allowed: {name}");
    }
}

// MARK: - A credential that is named and not there

#[test]
fn a_config_cloned_onto_a_new_machine_loads_and_says_which_keys_are_missing() {
    // Five minutes after cloning a dotfiles repository, every provider is
    // described perfectly and none of them has a key. That is a to-do list,
    // not a broken config, and it must not read as one.
    let config = load(TWO_PROVIDERS);

    assert_eq!(config.providers.len(), 2, "the file loads fine");
    assert_eq!(
        config.provider_readiness("anthropic", &[]),
        Readiness::MissingCredential {
            credential: "anthropic".to_string()
        },
        "and it names the entry to add, not just 'not configured'"
    );
    assert_eq!(
        config.provider_readiness("local", &[]),
        Readiness::Ready,
        "a provider that needs no key is ready with no keys present"
    );
}

#[test]
fn a_provider_needing_no_credential_is_not_the_same_as_one_whose_key_is_missing() {
    let config = load("[[provider]]\nid = \"local\"\nkind = \"ollama\"\n");
    assert_eq!(config.provider_readiness("local", &[]), Readiness::Ready);
    assert!(config.providers[0].credential.is_none());
}

#[test]
fn the_missing_credential_is_the_first_one_the_file_mentions() {
    let config = load(
        "[[mcp_server]]\nid = \"s\"\ntransport = \"http\"\nurl = \"http://x\"\ncredential = \"first\"\n\n[mcp_server.secret_env]\nTOKEN = \"second\"\n",
    );

    assert_eq!(
        config.mcp_readiness("s", &[]),
        Readiness::MissingCredential {
            credential: "first".to_string()
        }
    );
    assert_eq!(
        config.mcp_readiness("s", &["first".to_string()]),
        Readiness::MissingCredential {
            credential: "second".to_string()
        },
        "and then the next one, so the list can be worked through"
    );
    assert_eq!(
        config.mcp_readiness("s", &["first".to_string(), "second".to_string()]),
        Readiness::Ready
    );
}

#[test]
fn nothing_with_this_id_is_its_own_answer() {
    // Not `MissingCredential`, and not `Ready`. A settings window asking about
    // a provider somebody deleted has to be able to tell the difference.
    let config = load(TWO_PROVIDERS);
    assert_eq!(config.provider_readiness("ghost", &[]), Readiness::Unknown);
    assert_eq!(config.mcp_readiness("ghost", &[]), Readiness::Unknown);
}

#[test]
fn the_default_provider_is_skipped_when_its_key_is_not_on_this_machine() {
    // Opening a chat on a provider that cannot answer, because the file says so,
    // would be a spinner and then an error. Falling through to one that works is
    // what somebody expects on a machine they have not finished setting up.
    let config = load(TWO_PROVIDERS);
    assert_eq!(
        config.effective_provider(&[]).map(|p| p.id.as_str()),
        Some("local")
    );
    assert_eq!(
        config
            .effective_provider(&["anthropic".to_string()])
            .map(|p| p.id.as_str()),
        Some("anthropic"),
        "and it goes back to the one they asked for once the key is there"
    );
}

#[test]
fn credential_refs_names_everything_once_in_the_order_the_file_mentions_it() {
    let config = load(
        r#"
[[provider]]
id = "a"
kind = "anthropic"
credential = "shared"

[[mcp_server]]
id = "s"
transport = "http"
url = "http://x"
credential = "shared"

[mcp_server.secret_env]
TOKEN = "other"
"#,
    );

    assert_eq!(config.credential_refs(), ["shared", "other"]);
}

// MARK: - Where the file lives

#[test]
fn the_path_prefers_an_explicit_override_then_xdg_then_home() {
    assert_eq!(
        config_path(Some("/tmp/elsewhere.toml"), Some("/x"), Some("/home/a")),
        PathBuf::from("/tmp/elsewhere.toml")
    );
    assert_eq!(
        config_path(None, Some("/x/cfg"), Some("/home/a")),
        PathBuf::from("/x/cfg/zer0/config.toml"),
        "XDG_CONFIG_HOME is set by exactly the people this file is for"
    );
    assert_eq!(
        config_path(None, None, Some("/home/a")),
        PathBuf::from("/home/a/.config/zer0/config.toml"),
        "not Application Support: nobody symlinks a dotfiles checkout into ~/Library"
    );
    // An empty variable is an unset one. Shells export empty strings all the
    // time, and treating one as a path puts the config at `/zer0/config.toml`.
    assert_eq!(
        config_path(Some(""), Some("  "), Some("/home/a")),
        PathBuf::from("/home/a/.config/zer0/config.toml")
    );
}

// MARK: - Writing without destroying a dotfiles setup

// The two symlink tests below are unix only: the dotfiles shapes they build
// (stow, chezmoi) are unix idioms and they are built with
// `std::os::unix::fs::symlink`, which does not exist on msvc. On Windows the
// write path is still exercised by every other test in this file; what cannot
// be proved there is the link-preservation promise, and no Windows CI job
// claims it.
#[test]
#[cfg(unix)]
fn writing_through_a_symlinked_file_keeps_the_link_and_updates_the_checkout() {
    // The bug this exists to prevent: the ordinary write-a-temp-file-and-rename
    // recipe replaces the symlink with a regular file, orphaning the repository
    // copy. Everything keeps working until `git status` shows no changes and
    // the next machine gets an old config.
    let dir = TempDir::new("symlink-file");
    let checkout = dir.path().join("dotfiles");
    fs::create_dir_all(&checkout).unwrap();
    let real = checkout.join("zer0.toml");
    fs::write(&real, TWO_PROVIDERS).unwrap();

    let link = dir.path().join("config.toml");
    std::os::unix::fs::symlink(&real, &link).unwrap();

    let mut file = ConfigFile::open(&link);
    file.set_provider_enabled("local", false).unwrap();

    assert!(
        fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink(),
        "the link was replaced by a regular file, and the checkout is orphaned"
    );
    assert!(
        fs::read_to_string(&real)
            .unwrap()
            .contains("enabled = false"),
        "the change has to land in the repository copy"
    );
}

#[test]
#[cfg(unix)]
fn writing_through_a_symlinked_directory_lands_in_the_checkout() {
    // The commoner dotfiles shape: ~/.config/zer0 is the link, not the file.
    let dir = TempDir::new("symlink-dir");
    let checkout = dir.path().join("dotfiles-zer0");
    fs::create_dir_all(&checkout).unwrap();
    let link_dir = dir.path().join("zer0");
    std::os::unix::fs::symlink(&checkout, &link_dir).unwrap();

    let mut file = ConfigFile::open(link_dir.join("config.toml"));
    file.upsert_provider(&ProviderConfig::new("local", ProviderKind::Ollama))
        .unwrap();

    assert!(
        checkout.join("config.toml").exists(),
        "the file has to appear inside the checkout, not beside the link"
    );
    assert!(
        fs::symlink_metadata(&link_dir)
            .unwrap()
            .file_type()
            .is_symlink()
    );
}

#[test]
fn a_write_leaves_nothing_behind_beside_the_file() {
    let dir = TempDir::new("no-litter");
    let mut file = ConfigFile::open(dir.path().join("config.toml"));
    file.upsert_provider(&ProviderConfig::new("a", ProviderKind::Ollama))
        .unwrap();

    let names: Vec<String> = fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(
        names,
        ["config.toml"],
        "a stray temp file in a dotfiles repository shows up in `git status`"
    );
}

// MARK: - Editing keeps what somebody wrote

#[test]
fn switching_a_provider_off_changes_one_line_and_keeps_every_comment() {
    // Somebody who keeps this in a repository has comments, an order they chose
    // and blank lines where they wanted them. Serialising the model back over
    // the top would destroy all three, and the diff would be the whole file.
    let original = r#"# My zer0 config.
[chat]
default_provider = "anthropic"

# The good one.
[[provider]]
id = "anthropic"
kind = "anthropic"
credential = "anthropic"

# For when the wifi is bad.
[[provider]]
id = "local"
kind = "ollama"
"#;
    let dir = TempDir::new("preserve");
    let path = dir.file("config.toml", original);
    let mut file = ConfigFile::open(&path);

    file.set_provider_enabled("local", false).unwrap();
    let after = fs::read_to_string(&path).unwrap();

    assert!(after.contains("# My zer0 config."));
    assert!(after.contains("# The good one."));
    assert!(after.contains("# For when the wifi is bad."));

    let changed: Vec<&str> = after
        .lines()
        .filter(|line| !original.lines().any(|o| o == *line))
        .collect();
    assert_eq!(changed, ["enabled = false"], "one added line, nothing else");
}

#[test]
fn switching_it_back_on_gives_back_the_file_it_started_as() {
    // `enabled = true` is the default, so writing it would leave a line behind
    // that says nothing. Off and on again should be a no-op in `git diff`.
    let original = "[[provider]]\nid = \"local\"\nkind = \"ollama\"\n";
    let dir = TempDir::new("round-trip-toggle");
    let path = dir.file("config.toml", original);
    let mut file = ConfigFile::open(&path);

    file.set_provider_enabled("local", false).unwrap();
    file.set_provider_enabled("local", true).unwrap();

    assert_eq!(fs::read_to_string(&path).unwrap(), original);
}

#[test]
fn a_key_zer0_does_not_understand_survives_a_write() {
    // We warned about it at load. Deleting somebody's text because we did not
    // recognise it is not ours to do — it may be for a newer version than this
    // one, which is exactly what a shared dotfiles repository looks like.
    let dir = TempDir::new("keeps-unknown");
    let path = dir.file(
        "config.toml",
        "[[provider]]\nid = \"local\"\nkind = \"ollama\"\nfuture_setting = 42\n",
    );
    let mut file = ConfigFile::open(&path);
    file.set_provider_enabled("local", false).unwrap();

    assert!(
        fs::read_to_string(&path)
            .unwrap()
            .contains("future_setting = 42")
    );
}

// MARK: - Never write over what could not be read

#[test]
fn a_settings_change_is_refused_while_the_file_has_a_syntax_error() {
    // ADR-0017's rule, and it matters more here because this file is written by
    // hand: with a typo on line 3, rewriting from a model that never saw lines
    // 4 to 90 would delete the rest of somebody's configuration.
    let dir = TempDir::new("refuse-write");
    let path = dir.file("config.toml", TWO_PROVIDERS);
    let mut file = ConfigFile::open(&path);

    let broken = format!("{TWO_PROVIDERS}\n[[provider]\nid = \"oops\"\n");
    fs::write(&path, &broken).unwrap();

    let error = file
        .set_provider_enabled("local", false)
        .expect_err("must not write");
    assert!(matches!(error, ConfigError::Unreadable { .. }));
    assert_eq!(
        fs::read_to_string(&path).unwrap(),
        broken,
        "and the bytes are left exactly as they were, for a later fix"
    );
}

#[test]
fn an_edit_re_reads_first_so_it_does_not_revert_what_an_editor_just_did() {
    // Between the settings window opening and a checkbox being clicked, the file
    // may have been edited in a terminal or pulled from a dotfiles repository.
    let dir = TempDir::new("re-read");
    let path = dir.file(
        "config.toml",
        "[[provider]]\nid = \"local\"\nkind = \"ollama\"\n",
    );
    let mut file = ConfigFile::open(&path);

    fs::write(
        &path,
        "[[provider]]\nid = \"local\"\nkind = \"ollama\"\n\n[[provider]]\nid = \"added-in-vim\"\nkind = \"anthropic\"\n",
    )
    .unwrap();

    file.set_provider_enabled("local", false).unwrap();

    let after = fs::read_to_string(&path).unwrap();
    assert!(
        after.contains("added-in-vim"),
        "the settings window silently reverted an edit made elsewhere"
    );
    assert!(after.contains("enabled = false"));
}

// MARK: - Round trips

#[test]
fn every_provider_kind_and_transport_survives_the_file() {
    // A wire spelling drifting from its variant would silently turn somebody's
    // Anthropic provider into a dropped entry on the next launch.
    for kind in ProviderKind::all() {
        assert!(kind.round_trips(), "{kind:?}");
    }
    for transport in TransportKind::all() {
        assert_eq!(
            TransportKind::from_wire(transport.as_wire()),
            Some(transport)
        );
    }
}

#[test]
fn a_config_written_from_nothing_reads_back_as_what_went_in() {
    let dir = TempDir::new("round-trip");
    let path = dir.path().join("config.toml");
    let mut file = ConfigFile::open(&path);

    let mut provider = ProviderConfig::new("anthropic", ProviderKind::Anthropic);
    provider.name = "Anthropic".to_string();
    provider.credential = Some("anthropic".to_string());
    provider.models = vec!["opus".to_string(), "sonnet".to_string()];
    provider.default_model = Some("sonnet".to_string());

    let mut server = McpServerConfig::new("github", TransportKind::Stdio);
    server.command = Some("gh-mcp".to_string());
    server.args = vec!["--stdio".to_string()];
    server.env = vec![EnvVar {
        name: "GH_HOST".to_string(),
        value: "github.com".to_string(),
    }];
    server.secret_env = vec![SecretEnvVar {
        name: "GITHUB_TOKEN".to_string(),
        credential: "github".to_string(),
    }];

    file.upsert_provider(&provider).unwrap();
    file.upsert_mcp_server(&server).unwrap();
    file.set_default_provider(Some("anthropic")).unwrap();

    let reread = ConfigFile::open(&path);
    assert!(
        reread.diagnostics().is_empty(),
        "{:?}",
        reread.diagnostics()
    );
    assert_eq!(reread.config().providers, vec![provider]);
    assert_eq!(reread.config().mcp_servers, vec![server]);
    assert_eq!(
        reread.config().default_provider.as_deref(),
        Some("anthropic")
    );
}

#[test]
fn switching_a_server_to_another_transport_drops_the_fields_that_no_longer_apply() {
    // A stale `url` on a server that now runs a command is a line that reads as
    // true and is not.
    let dir = TempDir::new("transport-swap");
    let path = dir.path().join("config.toml");
    let mut file = ConfigFile::open(&path);

    let mut server = McpServerConfig::new("s", TransportKind::Http);
    server.url = Some("http://localhost:7332/mcp/sse".to_string());
    file.upsert_mcp_server(&server).unwrap();

    server.transport = TransportKind::Stdio;
    server.command = Some("some-mcp".to_string());
    file.upsert_mcp_server(&server).unwrap();

    let text = fs::read_to_string(&path).unwrap();
    assert!(text.contains("command = \"some-mcp\""));
    assert!(!text.contains("url ="), "{text}");
}

#[test]
fn a_removed_provider_leaves_no_empty_block_behind() {
    let dir = TempDir::new("remove");
    let path = dir.file(
        "config.toml",
        "[[provider]]\nid = \"only\"\nkind = \"ollama\"\n",
    );
    let mut file = ConfigFile::open(&path);

    file.remove_provider("only").unwrap();

    assert!(file.config().providers.is_empty());
    assert!(!fs::read_to_string(&path).unwrap().contains("provider"));
    assert!(
        file.remove_provider("only").is_err(),
        "and again is an error"
    );
}

// MARK: - The example we ship

#[test]
fn the_example_config_loads_with_nothing_to_complain_about() {
    // It is the first thing anybody sees, and it is also a specification of the
    // format. An example that warns about one of its own keys is worse than no
    // example at all.
    let parsed = parse(example_config()).expect("the shipped example has to be valid TOML");
    assert!(
        parsed.diagnostics.is_empty(),
        "the example we hand people is not clean: {:?}",
        parsed.diagnostics
    );
    assert_eq!(parsed.config.providers.len(), 3);
    assert_eq!(parsed.config.mcp_servers.len(), 2);
    assert!(
        !parsed.config.credential_refs().is_empty(),
        "and it demonstrates the credential mechanism"
    );
}

#[test]
fn writing_the_example_refuses_when_something_is_already_there() {
    // "Start from an example" must never be able to mean "lose what I wrote",
    // and an operation that cannot do the damage beats a confirmation dialog.
    let dir = TempDir::new("example");
    let path = dir.path().join("config.toml");
    let mut file = ConfigFile::open(&path);

    file.write_example().unwrap();
    assert!(file.exists());
    assert_eq!(file.config().providers.len(), 3);

    assert!(file.write_example().is_err());
    assert_eq!(fs::read_to_string(&path).unwrap(), example_config());
}

#[test]
fn a_preferred_model_is_the_named_one_then_the_first_listed() {
    let mut provider = ProviderConfig::new("p", ProviderKind::Anthropic);
    assert_eq!(provider.preferred_model(), None);

    provider.models = vec!["opus".to_string(), "sonnet".to_string()];
    assert_eq!(provider.preferred_model(), Some("opus"));

    provider.default_model = Some("sonnet".to_string());
    assert_eq!(provider.preferred_model(), Some("sonnet"));

    // Named a model it does not offer: fall back rather than asking for one the
    // provider will reject.
    provider.default_model = Some("gone".to_string());
    assert_eq!(provider.preferred_model(), Some("opus"));
}
