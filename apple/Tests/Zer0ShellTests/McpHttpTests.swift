import Foundation
import Testing
import Zer0Core

@testable import Zer0Shell

/// A tool server reached at a URL: which ones the shell will build a link to,
/// and what a person is told when one is not there.
///
/// The rule itself is locked in Rust, where it is decided
/// (`mcp_http_tests.rs`). What these ask is the other half, and the half that
/// has gone wrong in this project before: whether the shell actually goes
/// through the core's answer instead of arriving at its own.

@MainActor
private func http(_ id: String, _ url: String?, credential: String? = nil) -> McpServerConfig {
    McpServerConfig(
        id: id,
        name: id,
        transport: .http,
        command: nil,
        args: [],
        env: [],
        secretEnv: [],
        url: url,
        credential: credential,
        enabled: true
    )
}

@Suite("MCP over HTTP")
@MainActor
struct McpHttpLinkTests {
    @Test("a proxy on this Mac is reachable over plain http")
    func aLoopbackProxyGetsALink() throws {
        // The case this transport exists for: the author's own proxy.
        let link = try makeMcpLink(
            http("proxy", "http://127.0.0.1:7332/mcp"),
            environment: [:],
            secret: { _ in nil }
        )
        #expect(link is HttpLink)
    }

    @Test("plain http to anywhere else is refused rather than upgraded")
    func plaintextOffThisMacIsRefused() {
        // Refused, not retried over https. An address that silently becomes a
        // different address is the failure this project keeps naming.
        for address in ["http://example.com/mcp", "http://192.168.1.10/mcp"] {
            #expect(throws: MisconfiguredServer.self) {
                try makeMcpLink(http("remote", address), environment: [:], secret: { _ in nil })
            }
        }
        #expect(throws: Never.self) {
            try makeMcpLink(
                http("remote", "https://example.com/mcp"),
                environment: [:],
                secret: { _ in nil }
            )
        }
    }

    @Test("the shell does not have its own opinion about an address")
    func theRefusalIsTheCoresSentence() {
        // If the shell wrote its own sentence here, this is where the two would
        // start disagreeing — and the shell's copy is always the one that is
        // wrong (ADR-0002).
        let expected: String
        switch mcpEndpointVerdict(url: "http://example.com/mcp") {
        case let .refused(reason): expected = reason
        case .allowed: Issue.record("the core allowed plaintext off this Mac"); return
        }

        do {
            _ = try makeMcpLink(
                http("remote", "http://example.com/mcp"),
                environment: [:],
                secret: { _ in nil }
            )
            Issue.record("the shell allowed what the core refused")
        } catch {
            #expect((error as? LocalizedError)?.errorDescription == expected)
        }
    }

    @Test("a server with no address is not started with a guess")
    func aServerWithNoAddressIsRefused() {
        for address in [nil, ""] {
            #expect(throws: MisconfiguredServer.self) {
                try makeMcpLink(http("nowhere", address), environment: [:], secret: { _ in nil })
            }
        }
    }

    @Test("a missing token connects without one instead of stopping")
    func aMissingTokenIsNotAFailureToStart() throws {
        // A stdio server with a missing credential cannot start, because the
        // program would run without what it needs. An HTTP endpoint answers
        // 401 in its own words, which is more useful than zer0 guessing that a
        // token was required.
        let link = try makeMcpLink(
            http("proxy", "http://127.0.0.1:7332/mcp", credential: "absent"),
            environment: [:],
            secret: { _ in nil }
        )
        #expect(link is HttpLink)
    }
}

// MARK: - Against a real server

/// The whole client, end to end, against a proxy actually running on this Mac.
///
/// **Opt-in**, like the screenshot harnesses and for a related reason: a test
/// that reaches the network is a test that fails on a machine where the network
/// is not what it expected, and the failure reads as a defect in the code it
/// ran through. Run it deliberately:
///
/// ```sh
/// ZER0_MCP_LIVE=http://127.0.0.1:7332/mcp \
///   ZER0_MCP_TOOL=outl__outl_workspace_info swift test --filter LiveProxy
/// ```
///
/// `ZER0_MCP_TOOL` is optional and **has to be named rather than guessed**. An
/// earlier version picked whichever listed tool declared no required arguments,
/// which against a 255-tool proxy meant calling something arbitrary — one run
/// hit a tool that took longer than the probe was willing to wait, and the
/// failure said nothing about the transport it was supposed to be exercising.
///
/// It is not a lock and must never be named as one — a test that does not run
/// defends nothing. It exists because everything else here is a stub, and
/// "connects to the thing on your machine" is the one claim stubs cannot
/// support.
@Suite("A proxy really running on this Mac")
@MainActor
struct LiveProxyTests {
    @Test(
        "the whole client lists and calls against a live server",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_MCP_LIVE"] == nil)
    )
    func theWholeClientWorksAgainstALiveServer() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["ZER0_MCP_LIVE"])

        let host = McpHost(appVersion: "live")
        var states: [McpServerState] = []
        var listed: [ReportedTool] = []
        var results: [String] = []

        host.makeLink = { server, environment in
            try makeMcpLink(server, environment: environment, secret: { _ in nil })
        }
        host.setServerState = { _, state in states.append(state) }
        // `if case` rather than a `switch`: a switch over `Action` may not carry
        // a `default:` (ADR-0031), and enumerating two hundred cases to ignore
        // them would be noise rather than a guarantee.
        host.emit = { action in
            if case let .toolsListed(_, tools) = action { listed = tools }
            if case let .toolCallFinished(_, result) = action { results.append(result) }
            if case let .toolCallFailed(_, _, detail) = action {
                results.append("failed: \(detail)")
            }
        }

        // Deadline rather than a fixed sleep: the point is what arrived, and a
        // sleep long enough to be safe is a slow test on every good run.
        func waitUntil(_ done: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            while !done(), Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        host.start(http("live", address))
        try await waitUntil { !listed.isEmpty }

        let ready = states.contains { if case .ready = $0 { true } else { false } }
        #expect(ready, "the handshake settled: \(states)")
        #expect(!listed.isEmpty, "the server published tools: \(listed.count)")

        guard let wanted = ProcessInfo.processInfo.environment["ZER0_MCP_TOOL"] else {
            host.stopAll()
            return
        }
        try #require(
            listed.contains { $0.name == wanted },
            "the server publishes \(wanted)"
        )
        host.run(call: "one", server: "live", tool: wanted, arguments: "{}")
        try await waitUntil { !results.isEmpty }
        #expect(!results.isEmpty, "calling \(wanted) came back with something")

        host.stopAll()
    }
}

// MARK: - What a person sees while a server is not there

@Suite("A connection that is not up")
@MainActor
struct McpConnectionStatusTests {
    /// A settings model over a file that really describes a proxy on this Mac,
    /// with nothing behind it — which is the state every test here wants: the
    /// file is perfect and nothing has connected.
    private func model(_ fixture: ConfigFixture) throws -> (ChatSettingsModel, McpServerConfig) {
        try """
        [[mcp_server]]
        id = "proxy"
        transport = "http"
        url = "http://127.0.0.1:7332/mcp"
        """.write(toFile: fixture.path, atomically: true, encoding: .utf8)

        let chat = ChatSettingsModel(
            // `watching: false` because a `DispatchSource` on a temp directory
            // would fire while the next test is still writing into it.
            host: ConfigHost(path: fixture.path, secrets: InMemorySecrets(), watching: false)
        )
        chat.refresh()
        let server = try #require(chat.servers.first { $0.id == "proxy" })
        return (chat, server)
    }

    @Test("a server that could not be reached does not read as ready")
    func anUnreachableServerIsNotHealthy() throws {
        // The regression this exists for: readiness of the *file* was being
        // shown as the state of the *connection*, so a proxy that was not
        // running showed a clock and the word "Ready" — which is the browser
        // asserting something it had no evidence for (ADR-0018).
        let fixture = try ConfigFixture()
        let (chat, server) = try model(fixture)
        chat.noteConnection(
            server.id,
            .failed(failure: .unreachable, message: "Could not connect to the server.")
        )

        let status = chat.status(of: server)
        #expect(!status.healthy)
        #expect(status.summary == "Could not connect to the server.")
        #expect(!status.summary.contains("Ready"))
    }

    @Test("a connection nobody has tried yet says so rather than claiming to be up")
    func anIdleServerSaysItHasNotConnected() throws {
        let fixture = try ConfigFixture()
        let (chat, server) = try model(fixture)
        #expect(chat.status(of: server).summary.contains("not connected yet"))
    }

    @Test("a failure is the server's situation and never zer0 breaking")
    func aFailureBlamesNobody() throws {
        // A local proxy somebody quit is the normal state of a local proxy. The
        // sentence has to be about the connection, not about this browser.
        let fixture = try ConfigFixture()
        let (chat, server) = try model(fixture)
        for failure in [McpFailure.unreachable, .crashed, .unauthorized, .rejected] {
            chat.noteConnection(server.id, .failed(failure: failure, message: ""))
            let status = chat.status(of: server)
            #expect(!status.healthy)
            // Falls back to the core's own sentence rather than an empty row.
            #expect(status.summary == failure.reasonText)
        }
    }

    @Test("a row about a proxy on this Mac does not say it goes over the internet")
    func aLoopbackRowDoesNotClaimTheInternet() {
        // Inventing a risk that is not there costs the same trust as hiding one
        // that is.
        switch mcpEndpointVerdict(url: "http://127.0.0.1:7332/mcp") {
        case let .allowed(_, loopback): #expect(loopback)
        case .refused: Issue.record("the core refused the proxy on this Mac")
        }
        switch mcpEndpointVerdict(url: "https://tools.example.com/mcp") {
        case let .allowed(_, loopback): #expect(!loopback)
        case .refused: Issue.record("the core refused an https endpoint")
        }
    }
}
