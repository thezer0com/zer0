import Foundation
import Testing
import Zer0Core

@testable import Zer0Shell

/// A server that never existed, driven line by line from the test.
///
/// The whole point of `McpLink` being a protocol: a server that fails to start,
/// one that answers with rubbish and one that never answers at all are the
/// three cases worth testing, and none of them should need a program on disk.
@MainActor
final class FakeLink: McpLink {
    var onLine: (@MainActor (String) -> Void)?
    var onClose: (@MainActor (McpFailure, String) -> Void)?

    /// Everything the host has written, oldest first.
    private(set) var sent: [String] = []
    private(set) var closed = false

    /// What to answer with, keyed by the method the host asked for. A method
    /// with no answer here is a server that simply never replies.
    var answers: [String: (Int64) -> String] = [:]

    /// The era each written line went out under, oldest first. Over a pipe it
    /// changes nothing; over HTTP it decides the headers, so it is worth being
    /// able to assert on.
    private(set) var eras: [ServerEra?] = []

    func send(_ line: String, era: ServerEra?) {
        sent.append(line)
        eras.append(era)
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String
        else { return }
        let id = (object["id"] as? NSNumber)?.int64Value ?? 0
        guard let answer = answers[method] else { return }
        onLine?(answer(id))
    }

    func close() { closed = true }

    /// What method a written line called, for asserting on the conversation.
    func methods() -> [String] {
        sent.compactMap { line in
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["method"] as? String
        }
    }
}

@MainActor
private func stdio(_ id: String) -> McpServerConfig {
    McpServerConfig(
        id: id,
        name: id,
        transport: .stdio,
        command: "/usr/bin/true",
        args: ["--serve"],
        env: [],
        secretEnv: [],
        url: nil,
        credential: nil,
        enabled: true
    )
}

/// A host wired to a fake link, with everything it reports captured.
@MainActor
private final class Rig {
    let host = McpHost(appVersion: "test")
    let link = FakeLink()
    var states: [(String, McpServerState)] = []
    var actions: [Action] = []

    /// What this host reported a server offers, read back out of the actions it
    /// emitted. Read rather than captured separately, because a listing that
    /// reached a side channel instead of the reducer would never reach the
    /// register that decides whether a call may run.
    var listings: [(String, [ReportedTool])] {
        actions.compactMap { action in
            guard case let .toolsListed(server, tools) = action else { return nil }
            return (server, tools)
        }
    }
    /// Set to make the link refuse to be created at all.
    var launchFailure: Error?

    init() {
        host.makeLink = { [weak self] _, _ in
            guard let self else { throw CancellationError() }
            if let launchFailure { throw launchFailure }
            return link
        }
        host.setServerState = { [weak self] id, state in self?.states.append((id, state)) }
        host.emit = { [weak self] action in self?.actions.append(action) }
        host.secret = { _ in "a-value" }
    }

    var lastState: McpServerState? { states.last?.1 }

    var lastFailure: McpFailure? {
        guard case let .failed(failure, _)? = lastState else { return nil }
        return failure
    }
}

// MARK: - A server that will not start

@Suite("MCP servers that go wrong")
@MainActor
struct McpFailureTests {
    @Test("a program that is not there is reported, not swallowed")
    func aServerThatCannotStartIsReported() {
        struct Missing: LocalizedError {
            var errorDescription: String? { "zer0 could not run /usr/bin/nope." }
        }
        let rig = Rig()
        rig.launchFailure = Missing()

        rig.host.start(stdio("files"))

        #expect(rig.lastFailure == .notFound)
        #expect(rig.host.runningIds.isEmpty)
    }

    @Test("a missing credential stops the server before it runs")
    func aMissingCredentialStopsTheServerBeforeItRuns() {
        let rig = Rig()
        rig.host.secret = { _ in nil }
        var config = stdio("github")
        config.secretEnv = [SecretEnvVar(name: "GITHUB_TOKEN", credential: "github")]

        rig.host.start(config)

        #expect(rig.lastFailure == .unauthorized)
        #expect(rig.link.sent.isEmpty, "nothing is spoken to a server that cannot work")
        // Both names: the credential is what somebody adds in Settings, the
        // variable is how the server's own documentation refers to it.
        if case let .failed(_, message)? = rig.lastState {
            #expect(message.contains("github"))
            #expect(message.contains("GITHUB_TOKEN"))
        } else {
            Issue.record("expected a failure naming the credential and the variable")
        }
    }

    /// The one this file did not ask, and the reason every server with a
    /// secret would have failed to start.
    ///
    /// The test above passed with the lookup keyed by the wrong field, because
    /// its stub answered `nil` to anything: it proved that a missing credential
    /// stops the server, and never proved *which name was asked for*. The
    /// Keychain is filed under `credential`; asking for `name` finds nothing
    /// while the secret sits there the whole time.
    @Test("a secret is looked up by the name the config filed it under")
    func aSecretIsLookedUpByItsCredentialName() {
        let rig = Rig()
        var asked: [String] = []
        rig.host.secret = { key in
            asked.append(key)
            return key == "github" ? "a-value" : nil
        }
        var config = stdio("github")
        config.secretEnv = [SecretEnvVar(name: "GITHUB_PERSONAL_ACCESS_TOKEN", credential: "github")]

        rig.host.start(config)

        #expect(asked == ["github"], "asked for \(asked), which is not what the Keychain holds")
        #expect(rig.lastFailure != .unauthorized, "the secret was there and the server refused to start")
    }

    @Test("a server that dies takes its running calls with it, and says they may have run")
    func aServerThatDiesAnswersWhateverWasInFlight() {
        let rig = Rig()
        rig.link.answers["server/discover"] = { id in
            """
            {"jsonrpc":"2.0","id":\(id),"result":{"supportedVersions":["2026-07-28"],
             "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"w","version":"1"}}}}
            """
        }
        rig.host.start(stdio("files"))
        rig.host.run(call: "call-1", server: "files", tool: "read", arguments: "{}")

        rig.link.onClose?(.crashed, "segmentation fault")

        let failed = rig.actions.compactMap { action -> String? in
            guard case let .toolCallFailed(call, _, detail) = action else { return nil }
            #expect(detail.contains("may still have run"), "we do not know that it did not")
            return call
        }
        #expect(failed == ["call-1"])
        #expect(rig.lastFailure == .crashed)
    }
}

// MARK: - Servers that answer badly

@Suite("MCP servers that answer badly")
@MainActor
struct McpMalformedTests {
    @Test("rubbish on stdout does not kill a working server")
    func rubbishOnThePipeIsIgnored() {
        let rig = Rig()
        rig.link.answers["server/discover"] = { id in
            """
            {"jsonrpc":"2.0","id":\(id),"result":{"supportedVersions":["2026-07-28"],
             "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"w","version":"1"}}}}
            """
        }
        rig.host.start(stdio("files"))
        let statesBefore = rig.states.count

        for junk in [
            "Listening on stdio",
            "",
            "{",
            "null",
            #"{"jsonrpc":"2.0","id":999,"result":{}}"#,
        ] {
            rig.link.onLine?(junk)
        }

        #expect(rig.states.count == statesBefore, "a stray banner is not a failure")
        #expect(rig.host.runningIds == ["files"])
    }

    @Test("a server answering neither handshake is reported as unreadable")
    func aServerThatSpeaksNeitherHandshakeFails() {
        let rig = Rig()
        // Answers `server/discover` with a plain error, then answers
        // `initialize` with something that is not an initialize result.
        rig.link.answers["server/discover"] = { id in
            #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"Method not found"}}"#
        }
        rig.link.answers["initialize"] = { id in
            #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[]}}"#
        }

        rig.host.start(stdio("files"))

        #expect(
            rig.link.methods() == ["server/discover", "initialize"],
            "the modern question first, and the fallback is not keyed to one error code"
        )
        #expect(rig.lastFailure == .malformed)
    }

    @Test("a modern server that refuses our version is not asked the old question")
    func aVersionRefusalDoesNotFallBack() {
        let rig = Rig()
        rig.link.answers["server/discover"] = { id in
            """
            {"jsonrpc":"2.0","id":\(id),"error":{"code":-32022,
             "message":"Unsupported protocol version","data":{"supported":["2099-01-01"]}}}
            """
        }

        rig.host.start(stdio("files"))

        #expect(rig.link.methods() == ["server/discover"])
        #expect(rig.lastFailure == .versionMismatch)
    }
}

// MARK: - Talking to a server that works

@Suite("MCP conversations that work")
@MainActor
struct McpConversationTests {
    @Test("a legacy server is spoken to in the old way, and told the handshake finished")
    func aLegacyServerIsSpokenToInTheOldWay() {
        let rig = Rig()
        rig.link.answers["server/discover"] = { id in
            #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"unknown"}}"#
        }
        rig.link.answers["initialize"] = { id in
            """
            {"jsonrpc":"2.0","id":\(id),"result":{"protocolVersion":"2025-06-18",
             "capabilities":{},"serverInfo":{"name":"old","version":"0.9"}}}
            """
        }
        rig.link.answers["tools/list"] = { id in
            #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"search"}]}}"#
        }

        rig.host.start(stdio("legacy"))

        #expect(rig.link.methods().contains("notifications/initialized"))
        if case let .ready(version, name, _)? = rig.lastState {
            #expect(version == "2025-06-18")
            #expect(name == "old")
        } else {
            Issue.record("expected the server to be ready, got \(String(describing: rig.lastState))")
        }
        #expect(rig.listings.first?.1.map(\.name) == ["search"])
    }

    @Test("a tool list is followed across pages and then reported once")
    func toolPagesAreFollowed() {
        let rig = Rig()
        rig.link.answers["server/discover"] = { id in
            """
            {"jsonrpc":"2.0","id":\(id),"result":{"supportedVersions":["2026-07-28"],
             "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"w","version":"1"}}}}
            """
        }
        var page = 0
        rig.link.answers["tools/list"] = { id in
            page += 1
            return page == 1
                ? #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"a"}],"nextCursor":"n"}}"#
                : #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"b"}]}}"#
        }

        rig.host.start(stdio("files"))

        #expect(rig.listings.count == 1, "one report, not one per page")
        #expect(rig.listings.first?.1.map(\.name) == ["a", "b"])
    }

    @Test("arguments that are not an object never reach the server")
    func nonsenseArgumentsAreRefusedBeforeSending() {
        let rig = Rig()
        rig.link.answers["server/discover"] = { id in
            """
            {"jsonrpc":"2.0","id":\(id),"result":{"supportedVersions":["2026-07-28"],
             "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"w","version":"1"}}}}
            """
        }
        rig.host.start(stdio("files"))
        let before = rig.link.sent.count

        rig.host.run(call: "c1", server: "files", tool: "read", arguments: "not json")

        #expect(rig.link.sent.count == before, "nothing is written down the pipe")
        #expect(rig.actions.contains { action in
            if case let .toolCallFailed(call, _, _) = action { return call == "c1" }
            return false
        })
    }

    @Test("a tool's own failure comes back as a result the model can correct")
    func aToolReportingItsOwnFailureIsNotTheCallFailing() {
        let rig = Rig()
        rig.link.answers["server/discover"] = { id in
            """
            {"jsonrpc":"2.0","id":\(id),"result":{"supportedVersions":["2026-07-28"],
             "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"w","version":"1"}}}}
            """
        }
        rig.link.answers["tools/call"] = { id in
            """
            {"jsonrpc":"2.0","id":\(id),"result":{"isError":true,
             "content":[{"type":"text","text":"the date must be in the future"}]}}
            """
        }
        rig.host.start(stdio("files"))
        rig.host.run(call: "c1", server: "files", tool: "book", arguments: "{}")

        let detail = rig.actions.compactMap { action -> String? in
            guard case let .toolCallFailed(_, kind, detail) = action else { return nil }
            #expect(kind == .toolFailed, "the tool failed; the call did not")
            return detail
        }
        #expect(detail == ["the date must be in the future"])
    }

    @Test("stopping a server closes the link and forgets it")
    func stoppingClosesTheLink() {
        let rig = Rig()
        rig.link.answers["server/discover"] = { id in
            """
            {"jsonrpc":"2.0","id":\(id),"result":{"supportedVersions":["2026-07-28"],
             "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"w","version":"1"}}}}
            """
        }
        rig.host.start(stdio("files"))
        rig.host.stop("files")

        #expect(rig.link.closed)
        #expect(rig.host.runningIds.isEmpty)
    }
}

// MARK: - The words a person reads

@Suite("What MCP says for itself")
@MainActor
struct McpVocabularyTests {
    @Test("the command that will run is shown whole")
    func theExactCommandIsNeverShortened() {
        let long = mcpExactCommand(
            command: "/opt/homebrew/bin/npx",
            args: ["-y", "@vendor/mcp-server-filesystem@1.2.3", "/Users/someone/Documents"]
        )

        #expect(long.contains("@vendor/mcp-server-filesystem@1.2.3"))
        #expect(long.contains("/Users/someone/Documents"))
        #expect(!long.contains("…"))
    }

    @Test("what a local server costs you is a consequence, not a category")
    func theConsequenceIsAConsequence() {
        let said = mcpStdioConsequence()

        #expect(said.contains("runs a program on your Mac"))
        #expect(said.contains("anything you can do"))
        // Not "requires elevated permissions", not "advanced". A phrase nobody
        // can picture has never stopped anybody (ADR-0028).
        #expect(!said.lowercased().contains("permission"))
    }

    @Test("every failure has a sentence, and it comes from the core")
    func everyFailureHasSomethingToSay() {
        for failure in [
            McpFailure.notFound, .crashed, .handshakeTimeout, .versionMismatch,
            .malformed, .disconnected, .unreachable, .unauthorized, .rejected,
        ] {
            #expect(!mcpFailureReason(failure: failure).isEmpty)
        }
    }

    @Test("a name a model uses can always be traced back to one server")
    func aFlatNameSplitsBackToItsServer() {
        let joined = mcpQualifiedName(server: "weather", tool: "forecast")
        #expect(joined == "weather__forecast")

        let split = mcpSplitQualified(qualified: joined)
        #expect(split?.server == "weather")
        #expect(split?.tool == "forecast")

        // A server called `weather` offering a tool called `alpha__search`
        // still reads as `weather`'s, because the split happens at the front.
        let forged = mcpSplitQualified(qualified: "weather__alpha__search")
        #expect(forged?.server == "weather")
        #expect(forged?.tool == "alpha__search")
    }
}
