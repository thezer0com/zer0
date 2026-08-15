import Foundation
import Testing
import Zer0Core

@testable import Zer0Shell

/// A provider that answers whatever the test tells it to.
///
/// It records the provider it was asked about and **never the key**. A double
/// that could hand a secret back to an assertion is a double that proves the
/// leak it exists to rule out.
@MainActor
final class StubProbe: ChatProviderProbe {
    var result: ChatProbeResult
    private(set) var asked: [String] = []

    init(_ result: ChatProbeResult) {
        self.result = result
    }

    func check(provider: ProviderConfig, key _: String?) async -> ChatProbeResult {
        asked.append(provider.id)
        return result
    }
}

/// A settings file in a directory of its own, deleted when the test ends.
@MainActor
final class ConfigFixture {
    let path: String
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("zer0.toml").path
    }

    /// The bytes on disk. The strongest assertion available about a file that
    /// is meant to be committed: not "the API says no key is stored", but "the
    /// characters are not in there".
    var text: String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// What crosses the border between the settings panes and everything under
/// them: the config file, the Keychain, and the core's tool ledger.
@MainActor
struct ChatSettingsTests {
    private func model(
        _ fixture: ConfigFixture,
        probe: ChatProviderProbe = StubProbe(.working(["a-model"])),
        secrets: InMemorySecrets = InMemorySecrets(),
        dispatch: @escaping (Action) -> Void = { _ in }
    ) -> ChatSettingsModel {
        ChatSettingsModel(
            // `watching: false` because a `DispatchSource` on a temp directory
            // would fire while the next test is still writing into it.
            host: ConfigHost(path: fixture.path, secrets: secrets, watching: false),
            probe: probe,
            dispatch: dispatch
        )
    }

    // MARK: - The empty state

    @Test("a machine with no settings file opens on the empty state")
    func nothingConfiguredYet() throws {
        let fixture = try ConfigFixture()
        let chat = model(fixture)

        #expect(!chat.isConfigured, "a first launch has to reach the chooser")
        #expect(chat.current == nil)
        #expect(!chat.exists, "nothing is written until something is configured")
        #expect(chat.servers.isEmpty)
    }

    @Test("choosing a provider writes it and makes it the one a chat opens on")
    func choosingAProviderReachesTheFile() throws {
        let fixture = try ConfigFixture()
        let chat = model(fixture)

        chat.choose(ChatProviderStyles.style(for: .anthropic))

        #expect(chat.isConfigured)
        #expect(chat.current?.kind == .anthropic)
        #expect(chat.file.defaultProvider == chat.current?.id)
        #expect(fixture.text.contains("anthropic"), "it has to be on disk, not just in memory")
    }

    // MARK: - The key

    @Test("a key the provider refuses is never stored")
    func aRefusedKeyIsNotStored() async throws {
        // The whole reason the pane checks before it saves. A key stored
        // without being checked is one somebody finds out about in the middle
        // of a conversation three days later.
        let fixture = try ConfigFixture()
        let secrets = InMemorySecrets()
        let chat = model(
            fixture,
            probe: StubProbe(.refused("Anthropic did not accept that key.")),
            secrets: secrets
        )
        let provider = try #require(chat.choose(ChatProviderStyles.style(for: .anthropic)))

        await chat.submit(key: "sk-ant-not-a-real-key", for: provider)

        #expect(chat.keyState == .refused("Anthropic did not accept that key."))
        #expect(!chat.hasKey(provider), "a refused key must not look saved")
        #expect(try secrets.names().isEmpty, "nothing should have reached the Keychain")
    }

    @Test("a bad key says so before the window is closed")
    func theRefusalIsOnScreen() async throws {
        let fixture = try ConfigFixture()
        let chat = model(fixture, probe: StubProbe(.refused("Check that you copied all of it.")))
        let provider = try #require(chat.choose(ChatProviderStyles.style(for: .anthropic)))

        await chat.submit(key: "sk-ant-wrong", for: provider)

        guard case let .refused(why) = chat.keyState else {
            Issue.record("a refusal has to be a state the pane can draw")
            return
        }
        #expect(!why.isEmpty)
    }

    @Test("a key that works is stored, and fills the model list in the same breath")
    func aWorkingKeyIsStored() async throws {
        let fixture = try ConfigFixture()
        let secrets = InMemorySecrets()
        let chat = model(
            fixture,
            probe: StubProbe(.working(["claude-opus-4", "claude-sonnet-4"])),
            secrets: secrets
        )
        let provider = try #require(chat.choose(ChatProviderStyles.style(for: .anthropic)))

        await chat.submit(key: "sk-ant-a-key-that-works", for: provider)

        #expect(chat.keyState == .working(models: 2))
        #expect(chat.hasKey(try #require(chat.current)))
        #expect(try secrets.names() == ["anthropic"])

        // The list is the same request that verified the key, which is what
        // stops "typing a model id from memory" being the interface.
        let saved = try #require(chat.current)
        #expect(saved.models == ["claude-opus-4", "claude-sonnet-4"])
        #expect(saved.defaultModel == "claude-opus-4")
    }

    @Test("the key never reaches the settings file")
    func theKeyIsNotInTheFile() async throws {
        let fixture = try ConfigFixture()
        let chat = model(fixture, probe: StubProbe(.working(["m"])))
        let provider = try #require(chat.choose(ChatProviderStyles.style(for: .anthropic)))
        let secret = "sk-ant-0123456789abcdefghijklmnop"

        await chat.submit(key: secret, for: provider)

        // Read off the disk rather than through the API: what matters is the
        // characters in a file somebody may be about to commit.
        #expect(!fixture.text.contains(secret))
        #expect(fixture.text.contains("credential"), "the file records the name instead")
    }

    @Test("a provider that could not be reached is not reported as a bad key")
    func unreachableIsNotRefused() async throws {
        // Telling somebody to go and make a new key because their wifi dropped
        // is how a settings screen loses trust for good.
        let fixture = try ConfigFixture()
        let chat = model(fixture, probe: StubProbe(.unreachable("zer0 could not reach it.")))
        let provider = try #require(chat.choose(ChatProviderStyles.style(for: .anthropic)))

        await chat.submit(key: "sk-ant-something", for: provider)

        guard case .unreachable = chat.keyState else {
            Issue.record("a connection failure must not read as a rejected key")
            return
        }
    }

    @Test("a key pasted under the wrong provider is caught before the network")
    func theWrongProvidersKeyIsCaught() throws {
        let fixture = try ConfigFixture()
        let probe = StubProbe(.working([]))
        let chat = model(fixture, probe: probe)
        let provider = try #require(chat.choose(ChatProviderStyles.style(for: .anthropic)))

        let warning = chat.prefixWarning(for: "sk-proj-abcdefghijklmnop", provider: provider)

        #expect(warning?.contains("ChatGPT") == true)
        #expect(probe.asked.isEmpty, "the hint costs no request")
    }

    @Test("an unusual key is a hint and never a refusal")
    func theHintDoesNotBlock() async throws {
        // A provider is free to change its prefix. A settings screen that
        // refuses a working key because it looks unusual is worse than one that
        // lets the provider answer.
        let fixture = try ConfigFixture()
        let chat = model(fixture, probe: StubProbe(.working(["m"])))
        let provider = try #require(chat.choose(ChatProviderStyles.style(for: .anthropic)))

        await chat.submit(key: "totally-new-prefix-0123456789", for: provider)

        #expect(chat.keyState == .working(models: 1))
    }

    @Test("removing a key takes it out of the Keychain and leaves the provider set up")
    func removingAKey() async throws {
        let fixture = try ConfigFixture()
        let secrets = InMemorySecrets()
        let chat = model(fixture, probe: StubProbe(.working(["m"])), secrets: secrets)
        let provider = try #require(chat.choose(ChatProviderStyles.style(for: .anthropic)))
        await chat.submit(key: "sk-ant-key", for: provider)

        chat.forgetKey(of: try #require(chat.current))

        #expect(try secrets.names().isEmpty)
        #expect(!chat.hasKey(try #require(chat.current)))
        #expect(chat.isConfigured, "removing a key is not removing the provider")
    }

    @Test("a provider needing no key is ready without one")
    func aLocalProviderNeedsNoKey() throws {
        let fixture = try ConfigFixture()
        let chat = model(fixture)

        let provider = try #require(chat.choose(ChatProviderStyles.style(for: .ollama)))

        #expect(provider.credential == nil)
        #expect(chat.hasKey(provider))
        #expect(chat.readiness(of: provider) == .ready)
    }

    @Test("a described provider with no key yet is a to-do, not a failure")
    func missingCredentialNamesWhatIsMissing() throws {
        // The normal state five minutes after cloning a dotfiles repository
        // onto a new Mac.
        let fixture = try ConfigFixture()
        let chat = model(fixture)
        let provider = try #require(chat.choose(ChatProviderStyles.style(for: .anthropic)))

        guard case let .missingCredential(credential) = chat.readiness(of: provider) else {
            Issue.record("a provider with no key yet has to say which key")
            return
        }
        #expect(credential == "anthropic")
    }

    // MARK: - Connections

    @Test("a connection added and removed reaches the settings file")
    func addingAndRemovingAConnection() async throws {
        let fixture = try ConfigFixture()
        let chat = model(fixture)
        let entry = McpCatalogue.files

        let added = await chat.add(entry.server(from: ["root": "/Users/someone/Notes"]))

        #expect(added)
        #expect(chat.servers.map(\.id) == ["files"])
        #expect(fixture.text.contains("server-filesystem"), "it has to be on disk")

        chat.remove(try #require(chat.servers.first))

        #expect(chat.servers.isEmpty)
        #expect(!fixture.text.contains("server-filesystem"))
    }

    @Test("switching a connection off keeps it, and switching it on brings it back")
    func disablingIsNotDeleting() async throws {
        // Deleting to switch something off and retyping it to switch it back on
        // is not a toggle.
        let fixture = try ConfigFixture()
        let chat = model(fixture)
        await chat.add(McpCatalogue.web.server(from: [:]))
        let server = try #require(chat.servers.first)

        chat.setEnabled(server, false)

        #expect(chat.servers.count == 1)
        #expect(chat.servers[0].enabled == false)
        #expect(chat.readiness(of: chat.servers[0]) == .disabled)

        chat.setEnabled(chat.servers[0], true)
        #expect(chat.servers[0].enabled == true)
    }

    @Test("a connection's key goes to the Keychain and its name goes to the file")
    func aConnectionsKeyIsNotInTheFile() async throws {
        let fixture = try ConfigFixture()
        let secrets = InMemorySecrets()
        let chat = model(fixture, secrets: secrets)
        let token = "ghp_0123456789abcdefghijklmnopqrstuvwxyz"

        await chat.add(
            McpCatalogue.github.server(from: [:]),
            secrets: ["github": token]
        )

        #expect(try secrets.names() == ["github"])
        #expect(!fixture.text.contains(token))
        #expect(fixture.text.contains("GITHUB_PERSONAL_ACCESS_TOKEN"))
        #expect(fixture.text.contains("github"), "the credential's name is what is recorded")
    }

    @Test("removing a connection takes its key with it")
    func removingAConnectionForgetsItsKey() async throws {
        // A key left behind under a name nothing points at is a secret nobody
        // can find in order to delete it.
        let fixture = try ConfigFixture()
        let secrets = InMemorySecrets()
        let chat = model(fixture, secrets: secrets)
        await chat.add(McpCatalogue.github.server(from: [:]), secrets: ["github": "ghp_abc"])

        chat.remove(try #require(chat.servers.first))

        #expect(try secrets.names().isEmpty)
    }

    @Test("a connection waiting on a key says which key")
    func aConnectionMissingItsKey() async throws {
        let fixture = try ConfigFixture()
        let chat = model(fixture, secrets: InMemorySecrets())
        // Added without the secret, which is what a config file cloned from a
        // dotfiles repository looks like on a new Mac.
        await chat.add(McpCatalogue.github.server(from: [:]))
        let server = try #require(chat.servers.first)

        guard case let .missingCredential(credential) = chat.readiness(of: server) else {
            Issue.record("a connection with no key yet has to name the key")
            return
        }
        #expect(credential == "github")
        #expect(chat.status(of: server).summary.contains(credential))
    }

    // MARK: - Reading a pasted block

    @Test("a pasted block becomes a connection")
    func aPasteIsRead() throws {
        let reading = try McpConfigPaste.read("""
        {
          "mcpServers": {
            "Weather": {
              "command": "npx",
              "args": ["-y", "@example/weather"]
            }
          }
        }
        """)

        #expect(reading.servers.count == 1)
        #expect(reading.servers[0].name == "Weather")
        #expect(reading.servers[0].id == "weather")
        #expect(reading.servers[0].command == "npx")
        #expect(reading.servers[0].args == ["-y", "@example/weather"])
    }

    @Test("a token pasted inside a block is lifted out before the file is written")
    func aPastedTokenNeverReachesTheFile() async throws {
        // READMEs routinely show a literal token in `env`. Writing that
        // straight through would put a key in a file built to be committed, and
        // the person pasting it would have no idea.
        let fixture = try ConfigFixture()
        let secrets = InMemorySecrets()
        let chat = model(fixture, secrets: secrets)
        let token = "ghp_0123456789abcdefghijklmnopqrstuvwxyz"

        let reading = try McpConfigPaste.read("""
        {
          "mcpServers": {
            "github": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-github"],
              "env": { "GITHUB_TOKEN": "\(token)", "GITHUB_HOST": "github.com" }
            }
          }
        }
        """)

        #expect(reading.secrets.values.contains(token))
        #expect(reading.servers[0].secretEnv.map(\.name) == ["GITHUB_TOKEN"])
        // The one that is not a secret stays a plain setting.
        #expect(reading.servers[0].env.map(\.name) == ["GITHUB_HOST"])

        await chat.add(reading.servers[0], secrets: reading.secrets)

        #expect(!fixture.text.contains(token))
        #expect(fixture.text.contains("GITHUB_HOST"))
    }

    @Test("a remote server in a pasted block starts no program")
    func aPastedRemoteServer() throws {
        let reading = try McpConfigPaste.read("""
        { "mcpServers": { "team": { "url": "https://mcp.example.com/sse" } } }
        """)

        #expect(reading.servers[0].transport == .http)
        #expect(reading.servers[0].command == nil)
        #expect(reading.servers[0].url == "https://mcp.example.com/sse")
    }

    @Test("something that is not a settings block says so rather than adding nothing")
    func aBadPasteIsRefused() throws {
        #expect(throws: McpConfigPaste.Failure.notJson) {
            try McpConfigPaste.read("npx -y @example/weather")
        }
        #expect(throws: McpConfigPaste.Failure.noServers) {
            try McpConfigPaste.read("{ \"mcpServers\": {} }")
        }
        #expect(throws: McpConfigPaste.Failure.unsupported("mystery")) {
            try McpConfigPaste.read("{ \"mcpServers\": { \"mystery\": { \"note\": \"hi\" } } }")
        }
    }

    // MARK: - What a connection may do

    @Test("allowing and revoking a tool reaches the core, and asking again is a third answer")
    func toolConsentReachesTheCore() async throws {
        // A permission screen that repaints a row and tells nobody is worse
        // than no permission screen.
        let fixture = try ConfigFixture()
        var sent: [Action] = []
        let chat = model(fixture, dispatch: { sent.append($0) })

        chat.setConsent(server: "files", tool: "write_file", allowed: true)
        chat.setConsent(server: "files", tool: "write_file", allowed: false)
        chat.forgetConsent(server: "files", tool: "write_file")

        #expect(sent.count == 3)

        guard case let .setToolConsent(server, tool, allowed) = sent[0] else {
            Issue.record("allowing a tool has to reach the core's ledger")
            return
        }
        #expect(server == "files")
        #expect(tool == "write_file")
        #expect(allowed)

        guard case let .setToolConsent(_, _, refused) = sent[1] else {
            Issue.record("revoking a tool has to reach the core's ledger")
            return
        }
        #expect(!refused, "a refusal is stored, not inferred from absence")

        guard case .forgetToolConsent = sent[2] else {
            Issue.record("taking an answer back is its own action")
            return
        }
    }

    @Test("nobody was asked is not the same as no")
    func undecidedIsNotRefused() throws {
        let fixture = try ConfigFixture()
        let chat = model(fixture)

        #expect(chat.decision(server: "files", tool: "read_file") == nil)

        chat.ingest(
            tools: [ToolDescriptor(
                server: "files",
                tool: "read_file",
                summary: "Reads a file",
                inputSchemaJson: #"{"type":"object"}"#,
                readOnlyHint: true,
                destructiveHint: false,
                openWorldHint: false
            )],
            grants: [ToolGrant(
                server: "files", tool: "read_file", allowed: false, decidedAtMs: 1
            )]
        )

        #expect(chat.decision(server: "files", tool: "read_file") == false)
        #expect(chat.decision(server: "files", tool: "write_file") == nil)
    }

    @Test("a connection that has not published anything claims nothing about it")
    func nothingIsClaimedBeforeConnecting() async throws {
        // ADR-0018: where the data does not exist, the interface does not fill
        // the space with a plausible list.
        let fixture = try ConfigFixture()
        let chat = model(fixture)
        await chat.add(McpCatalogue.web.server(from: [:]))
        let server = try #require(chat.servers.first)

        #expect(chat.tools(of: server).isEmpty)
        // Asked as the decision rather than as a sentence. The wording moved
        // when the row started reporting the *connection* instead of the file
        // (ADR-0099), and a test welded to the old phrase would have gone red
        // over a row that had just got more honest. What must hold is that
        // nothing is claimed: no count, and no assertion that it is up.
        let summary = chat.status(of: server).summary
        #expect(!summary.contains("Allowed to do"), "no count over a list nobody has: \(summary)")
        #expect(summary.contains("not connected yet"), "it says so plainly: \(summary)")
    }

    // MARK: - The file itself

    @Test("the pane can always say where the file is, even before there is one")
    func thePathIsAlwaysKnown() throws {
        let fixture = try ConfigFixture()
        let chat = model(fixture)

        #expect(chat.configPath == fixture.path)
        #expect(!chat.exists)

        chat.writeExample()

        #expect(chat.exists)
        #expect(!fixture.text.isEmpty, "the example has to actually land on disk")
    }

    @Test("a broken file is reported with a line number rather than silently ignored")
    func aBrokenFileIsSaid() throws {
        let fixture = try ConfigFixture()
        try "this is not [ valid toml".write(
            toFile: fixture.path, atomically: true, encoding: .utf8
        )

        let chat = model(fixture)

        #expect(!chat.isReadable)
        #expect(chat.worstDiagnostic != nil, "silence here is a pane disagreeing with the file")
    }
}

/// The dependency nobody warns anybody about.
@MainActor
struct McpRuntimeTests {
    @Test("a remote connection needs nothing installed")
    func remoteNeedsNoRuntime() {
        #expect(McpRuntimeCheck.isAvailable(.none))
    }

    @Test("the check looks somewhere a Mac actually keeps things")
    func theCheckIsRealisticAboutWhereThingsLive() {
        // `/bin/sh` is on every Mac, so a check that cannot find it is a check
        // that would tell everyone their runtime is missing.
        #expect(McpRuntimeCheck.isAvailable(McpRuntime.none))
        #expect(FileManager.default.isExecutableFile(atPath: "/bin/sh"))
    }
}

/// Naming, which decides what a settings file looks like to whoever reads it.
@MainActor
struct McpIdentifierTests {
    @Test("a pasted name becomes something a settings file can hold")
    func identifiersAreFileSafe() {
        #expect(McpConfigPaste.identifier(from: "GitHub") == "github")
        #expect(McpConfigPaste.identifier(from: "My Files!") == "my-files")
        #expect(McpConfigPaste.identifier(from: "  ") == "server")
        #expect(McpConfigPaste.identifier(from: "a--b") == "a-b")
    }
}
