import Foundation
import Security
import Testing
import Zer0Core

@testable import Zer0Shell

/// The configuration file where it meets the platform.
///
/// The core already covers parsing, defaults and refusals without a window.
/// What can only be tested here is the seam: that the Keychain is the only
/// place a value lives, that a name with nothing behind it is a clear state
/// rather than an empty string, and that no route through the settings window
/// puts a key on disk.
@MainActor
struct ConfigTests {
    /// Deliberately shaped like the real thing. A test that used "hunter2"
    /// would still pass if a substring check were the only defence.
    static let realLookingKey =
        "sk-ant-api03-Xq7fT2vN8pLm4wZ1cR6yB9hJ0kD5sG3aE7uI2oP4nM6tV8xC1zA9rW5eY3bQ7fH2jK4l"

    private func temporaryDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-config-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func host(
        _ label: String,
        contents: String? = nil,
        secrets: any SecretStore = InMemorySecrets()
    ) -> (ConfigHost, URL) {
        let directory = temporaryDirectory(label)
        let path = directory.appendingPathComponent("config.toml")
        if let contents {
            try? contents.write(to: path, atomically: true, encoding: .utf8)
        }
        // Watching off: the tests drive reloads themselves, so nothing depends
        // on how quickly the filesystem gets round to telling us.
        return (ConfigHost(path: path.path, secrets: secrets, watching: false), path)
    }

    private static let twoProviders = """
    [chat]
    default_provider = "anthropic"

    [[provider]]
    id = "anthropic"
    kind = "anthropic"
    credential = "anthropic"

    [[provider]]
    id = "local"
    kind = "ollama"
    """

    // MARK: - The one that matters

    @Test("no route through the settings window puts a key in the config file")
    func aSecretNeverReachesTheConfigFile() async throws {
        // The whole feature in one test. A real-looking key is put in the
        // credential store, and then every change the settings window can make
        // is made — including ones that try to smuggle the key in through the
        // field that takes its name. Afterwards the file must not contain it.
        //
        // This is the end of the argument that starts in the Rust types: the
        // core has no field that can hold a value and no call that accepts one,
        // so the only thing that can produce a secret is the Keychain, and the
        // only thing that consumes one is the request about to be sent.
        let secrets = InMemorySecrets()
        let (config, path) = host("no-secret", contents: Self.twoProviders, secrets: secrets)

        try config.storeSecret(Self.realLookingKey, named: "anthropic")
        #expect(config.availableCredentials == ["anthropic"])

        var provider = ProviderConfig(
            id: "anthropic",
            name: "Anthropic",
            kind: .anthropic,
            baseUrl: nil,
            credential: "anthropic",
            models: ["claude-sonnet-4"],
            defaultModel: "claude-sonnet-4",
            enabled: true
        )
        try config.upsertProvider(provider)
        try config.setDefaultProvider(id: "anthropic")
        try config.setProvider(id: "local", enabled: false)

        // And now the mistake somebody will actually make: pasting the key
        // where its name goes.
        provider.credential = Self.realLookingKey
        #expect(throws: (any Error).self) { try config.upsertProvider(provider) }

        var server = McpServerConfig(
            id: "github",
            name: "GitHub",
            transport: .stdio,
            command: "gh-mcp",
            args: [],
            env: [EnvVar(name: "GITHUB_TOKEN", value: Self.realLookingKey)],
            secretEnv: [],
            url: nil,
            credential: nil,
            enabled: true
        )
        #expect(throws: (any Error).self) { try config.upsertServer(server) }

        // The right way round: the variable names a Keychain entry.
        server.env = []
        server.secretEnv = [SecretEnvVar(name: "GITHUB_TOKEN", credential: "github")]
        try config.upsertServer(server)

        let onDisk = try String(contentsOf: path, encoding: .utf8)
        #expect(!onDisk.contains(Self.realLookingKey), "a key reached the file")
        #expect(!onDisk.contains("sk-ant"), "not even a fragment of one:\n\(onDisk)")
        #expect(onDisk.contains("credential = \"anthropic\""), "the name is what gets written")

        // And it is still readable where it belongs.
        #expect(try config.secret(named: "anthropic") == Self.realLookingKey)
    }

    @Test("a settings field can tell somebody they are pasting a key as they type")
    func aKeyIsRecognisedBeforeItIsSubmitted() async throws {
        // Cheaper than an error after Save, and the rule is the core's so the
        // field and the parser cannot disagree about it.
        #expect(looksLikeASecret(value: Self.realLookingKey))
        #expect(looksLikeASecret(value: "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB"))
        #expect(!looksLikeASecret(value: "anthropic"))
        #expect(!looksLikeASecret(value: "work-openai"))
    }

    // MARK: - A credential that is named and not there

    @Test("a config cloned onto a new Mac loads, and names the keys it is waiting for")
    func aMissingCredentialIsNamedRatherThanEmpty() async throws {
        // Five minutes after cloning a dotfiles repository this is the state of
        // everything, and it has to read as a to-do list rather than a fault.
        let (config, _) = host("fresh-clone", contents: Self.twoProviders)

        #expect(config.config.providers.count == 2, "the file itself is fine")
        #expect(config.isReadable)
        #expect(config.availableCredentials.isEmpty)

        #expect(config.readiness(ofProvider: "anthropic") == .missingCredential(credential: "anthropic"))
        #expect(config.readiness(ofProvider: "local") == .ready, "a local model needs no key")

        // It does not stop the browser being useful: a chat opens on the one
        // that works rather than on a spinner and an error.
        #expect(config.effectiveProvider()?.id == "local")
    }

    @Test("adding the key is enough, and nothing else has to change")
    func addingTheKeyMakesTheProviderReady() async throws {
        let (config, _) = host("adds-key", contents: Self.twoProviders)
        #expect(config.effectiveProvider()?.id == "local")

        try config.storeSecret(Self.realLookingKey, named: "anthropic")

        #expect(config.readiness(ofProvider: "anthropic") == .ready)
        #expect(config.effectiveProvider()?.id == "anthropic", "and it goes back to the one asked for")
    }

    @Test("reading a name with nothing behind it says which name, not nothing")
    func readingAnAbsentCredentialIsAClearFailure() async throws {
        // A silent empty string would become an `Authorization: Bearer ` header
        // and a 401, which is a much longer way round to the same information.
        let (config, _) = host("absent", contents: Self.twoProviders)

        #expect(throws: SecretStoreError.notFound(name: "anthropic")) {
            try config.secret(named: "anthropic")
        }
    }

    @Test("a credential store that will not answer is not one with nothing in it")
    func aFailingStoreIsNotAnEmptyStore() async throws {
        // Reporting no credentials would make every provider look unconfigured
        // and invite somebody to paste all their keys in again — on top of the
        // ones already there.
        let (config, _) = host("locked", contents: Self.twoProviders, secrets: RefusingSecrets())

        #expect(config.credentialStoreError != nil, "the interface has to be able to say so")
        #expect(config.availableCredentials.isEmpty)
    }

    @Test("only the names the file asks about are reported as available")
    func unrelatedKeychainEntriesAreNotOffered() async throws {
        let secrets = InMemorySecrets([
            "anthropic": Self.realLookingKey,
            "something-else-entirely": "x",
        ])
        let (config, _) = host("filtered", contents: Self.twoProviders, secrets: secrets)

        #expect(config.availableCredentials == ["anthropic"])
    }

    // MARK: - Keychain error codes, without a Keychain

    @Test("a Keychain status code becomes something a person can act on")
    func keychainStatusCodesBecomeActionable() async throws {
        // These are the codes that are awkward to provoke on purpose and that
        // matter most when they happen, so the mapping is tested rather than
        // the framework.
        #expect(Keychain.error(errSecItemNotFound, name: "a") == .notFound(name: "a"))
        #expect(Keychain.error(errSecUserCanceled, name: "a") == .denied(name: "a"))
        #expect(Keychain.error(errSecAuthFailed, name: "a") == .denied(name: "a"))
        #expect(Keychain.error(errSecInteractionNotAllowed, name: "a") == .cannotAsk(name: "a"))

        // Every one of them says what to do next. An error with no way forward
        // is a dead end with a number in it.
        for error in [
            Keychain.error(errSecItemNotFound, name: "anthropic"),
            Keychain.error(errSecUserCanceled, name: "anthropic"),
            Keychain.error(errSecInteractionNotAllowed, name: "anthropic"),
            Keychain.error(errSecDecode, name: "anthropic"),
        ] {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }

        // The name is in the message, because "a key could not be read" when
        // four are configured is not an answer.
        #expect(Keychain.error(errSecItemNotFound, name: "anthropic")
            .errorDescription?.contains("anthropic") == true)
    }

    // MARK: - Reload

    @Test("no file at all is an empty state, not an error")
    func noFileIsNotAnError() async throws {
        let (config, path) = host("absent-file")

        #expect(!config.exists)
        #expect(config.isReadable, "nothing is wrong, there is just nothing there")
        #expect(config.errors.isEmpty)
        #expect(config.config.providers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path.path), "and opening it created nothing")
    }

    @Test("an edit made in an editor is picked up")
    func anEditIsPickedUp() async throws {
        let (config, path) = host("picks-up", contents: Self.twoProviders)
        #expect(config.config.providers.count == 2)

        try (Self.twoProviders + "\n\n[[provider]]\nid = \"added\"\nkind = \"ollama-chat\"\n")
            .write(to: path, atomically: true, encoding: .utf8)

        #expect(config.reloadNow())
        #expect(config.config.providers.count == 3)
    }

    @Test("a save that changed nothing does not tear anything down")
    func anUnchangedReloadIsNotAChange() async throws {
        // Every MCP connection hangs off this. Rebuilding them because somebody
        // hit ⌘S with no edits would be a browser that drops its tools whenever
        // its config is looked at.
        let (config, path) = host("no-change", contents: Self.twoProviders)
        var fired = 0
        config.onChange = { fired += 1 }

        #expect(!config.reloadNow())
        try Self.twoProviders.write(to: path, atomically: true, encoding: .utf8)
        #expect(!config.reloadNow(), "same bytes, same answer")
        #expect(fired == 0)
    }

    @Test("catching a file mid-save keeps the configuration that was working")
    func aHalfWrittenFileIsSurvivable() async throws {
        // Most editors truncate and then write, so this happens several times a
        // minute while somebody edits. Dropping every provider each time would
        // make the browser flicker between configured and not.
        let (config, path) = host("half-written", contents: Self.twoProviders)

        try "[chat]\ndefault_provider = \"anth".write(to: path, atomically: true, encoding: .utf8)
        config.reloadNow()

        #expect(config.config.providers.count == 2, "the last one that parsed stays in force")
        #expect(!config.isReadable, "and the interface is told it is stale")
        #expect(!config.errors.isEmpty)

        // And it heals by itself when the save finishes.
        try Self.twoProviders.write(to: path, atomically: true, encoding: .utf8)
        config.reloadNow()
        #expect(config.isReadable)
        #expect(config.errors.isEmpty)
    }

    @Test("a diagnostic points at a line somebody can put a cursor on")
    func aDiagnosticNamesTheLine() async throws {
        let (config, _) = host(
            "line-number",
            contents: "[[provider]]\nid = \"x\"\nkind = \"anthropik\"\n"
        )

        let error = try #require(config.errors.first)
        #expect(error.line == 3)
        #expect(error.column > 0)
    }

    @Test("the example is offered once and never over the top of something")
    func theExampleIsSafeToOffer() async throws {
        let (config, path) = host("example")

        try config.writeExample()
        #expect(config.exists)
        #expect(config.errors.isEmpty, "the file we hand people has to load cleanly")
        #expect(!config.config.providers.isEmpty)

        let written = try String(contentsOf: path, encoding: .utf8)
        #expect(throws: (any Error).self) { try config.writeExample() }
        #expect(try String(contentsOf: path, encoding: .utf8) == written)
    }
}

/// A credential store that refuses everything, standing in for a locked
/// keychain or a denied prompt.
@MainActor
private final class RefusingSecrets: SecretStore {
    func names() throws -> [String] { throw SecretStoreError.cannotAsk(name: "") }
    func secret(named name: String) throws -> String { throw SecretStoreError.cannotAsk(name: name) }
    func store(_: String, named name: String) throws { throw SecretStoreError.cannotAsk(name: name) }
    func remove(named name: String) throws { throw SecretStoreError.cannotAsk(name: name) }
}
