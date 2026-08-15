import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Renders the Chat and Connections panes, light and dark, so they can be
/// looked at rather than reasoned about.
///
/// **Opt-in.** `ZER0_SHOT=1 swift test --filter ZZChatSettings`. A harness pumps
/// the run loop for tens of seconds and starves the timing tests when it runs
/// by default, so `scripts/check.sh` verifies every case here carries the gate.
///
/// `NSHostingView` + `cacheDisplay` rather than `ImageRenderer`, because
/// `ImageRenderer` does not draw materials — and the add sheet is a material.
@Suite("ZZ chat settings shots")
struct ZZChatSettingsShots {
    /// Four levels up is the repo root: `apple/Tests/Zer0ShellTests/<this>`.
    private static let output = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "design/chat-settings")

    @Test(
        "render the chat settings panes",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    @MainActor
    func renderTheChatPanes() async throws {
        try FileManager.default.createDirectory(
            at: Self.output, withIntermediateDirectories: true
        )

        let pane = CGSize(width: 700, height: 620)
        let sheet = CGSize(width: 520, height: 640)

        // Built once, before anything is drawn. A `@ViewBuilder` closure cannot
        // throw, and a fixture that reaches the disk can — so the reaching
        // happens here and the drawing takes a value.
        let fresh = try Fixtures.fresh()
        let keyed = try await Fixtures.keyed()
        let refused = try await Fixtures.refused()
        let connected = try await Fixtures.connected()
        let filesDraft = McpCatalogue.files.server(from: ["root": Fixtures.folder])

        for dark in [false, true] {
            // 01 — the screen everybody meets. Nothing configured, and the
            // empty state is the chooser rather than a screen leading to one.
            try shoot("01-chat-empty", size: pane, dark: dark) {
                Fixtures.pane { ChatSettings(fresh) }
            }

            // 02 — a key that was checked and accepted, with the model list it
            // came back with.
            try shoot("02-chat-working", size: pane, dark: dark) {
                Fixtures.pane { ChatSettings(keyed) }
            }

            // 03 — the state this pane exists for: a key the provider said no
            // to, said before the window is closed.
            try shoot("03-chat-refused", size: pane, dark: dark) {
                Fixtures.pane { ChatSettings(refused) }
            }

            // 04 — no connections yet.
            try shoot("04-connections-empty", size: pane, dark: dark) {
                Fixtures.pane { ConnectionsSettings(fresh) }
                    .environment(Fixtures.browser)
            }

            // 05 — two connections, one of them waiting on a key it was never
            // given, which is what a cloned dotfiles repository looks like.
            try shoot("05-connections-added", size: pane, dark: dark) {
                Fixtures.pane { ConnectionsSettings(connected) }
                    .environment(Fixtures.browser)
            }

            // 06 — the three doors.
            try shoot("06-add-choose", size: sheet, dark: dark) {
                McpAddSheet(chat: fresh)
            }

            // 07 — what a catalogue entry needs, each answer its own control.
            try shoot("07-add-fill", size: sheet, dark: dark) {
                McpAddSheet(chat: fresh, startingAt: .fill("github"))
            }

            // 08 — the last screen before anything runs, for a recipe zer0
            // shipped: consequences first, the program named underneath.
            try shoot("08-add-review", size: sheet, dark: dark) {
                McpAddSheet(
                    chat: fresh,
                    startingAt: .review(
                        servers: [filesDraft],
                        catalogue: "files",
                        secrets: [:]
                    )
                )
            }

            // 09 — the same screen for something pasted, where zer0 has nothing
            // to assert and says so instead of inventing a list.
            try shoot("09-add-review-unknown", size: sheet, dark: dark) {
                McpAddSheet(
                    chat: fresh,
                    startingAt: .review(
                        servers: [Fixtures.pastedServer],
                        catalogue: nil,
                        secrets: ["team-api-token": "lifted"]
                    )
                )
            }
        }
    }

    /// Draw a view offscreen and write it out.
    ///
    /// `controlActiveState: .key` is forced because the test process can never
    /// become the active app, and without it every accent-coloured prominent
    /// button renders grey — which on these boards is exactly the pixel you
    /// came to look at.
    @MainActor
    private func shoot(
        _ name: String,
        size: CGSize,
        dark: Bool,
        @ViewBuilder content: () -> some View
    ) throws {
        let root = content()
            .environment(\.controlActiveState, .key)
            .zer0Palette()
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(dark ? .dark : .light)

        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let window = testWindow(host.frame, styleMask: [.borderless])
        window.appearance = host.appearance
        window.contentView = host
        window.displayIfNeeded()

        // Let the layout settle: a material and a hosting view both resolve a
        // frame later than the first pass.
        for _ in 0 ..< 12 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("no bitmap rep for \(name)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("no png for \(name)")
            return
        }
        try png.write(to: Self.output.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
    }
}

// MARK: - The states worth looking at

/// Models in each state a person actually meets, built through the real path
/// rather than assembled: a fixture that sets a field the app cannot set is a
/// picture of a screen nobody can reach.
@MainActor
private enum Fixtures {
    /// Kept alive for the run: a `ChatSettingsModel` reads its file on every
    /// refresh, and a temp directory removed too early renders an empty pane.
    private static var directories: [URL] = []

    static let folder = "\(NSHomeDirectory())/Documents/Notes"

    /// A browser for the two panes that read one out of the environment.
    ///
    /// In memory, so the harness never opens the session anybody is using.
    static let browser = BrowserModel(storagePath: nil)

    static func pane(@ViewBuilder _ content: () -> some View) -> some View {
        // The column the settings window gives a pane, so these are the same
        // measurements the real screen has.
        ScrollView {
            content()
                .padding(Design.Space.loose)
                .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private static func newModel(
        probe: ChatProviderProbe = StubProbe(.working([]))
    ) throws -> ChatSettingsModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)

        return ChatSettingsModel(
            host: ConfigHost(
                path: directory.appendingPathComponent("zer0.toml").path,
                secrets: InMemorySecrets(),
                watching: false
            ),
            probe: probe,
            dispatch: { _ in }
        )
    }

    /// Nothing configured.
    static func fresh() throws -> ChatSettingsModel { try newModel() }

    /// A key that was checked and accepted, with the models it came back with.
    static func keyed() async throws -> ChatSettingsModel {
        let chat = try newModel(probe: StubProbe(.working([
            "claude-opus-4-20250514",
            "claude-sonnet-4-20250514",
            "claude-haiku-4-20250514",
        ])))
        guard let provider = chat.choose(ChatProviderStyles.style(for: .anthropic)) else {
            return chat
        }
        await chat.submit(key: "sk-ant-a-key-that-works", for: provider)
        return chat
    }

    /// The state this pane exists for.
    static func refused() async throws -> ChatSettingsModel {
        let chat = try newModel(probe: StubProbe(.refused(
            "Claude did not accept that key. Check that you copied all of it, and that it "
                + "has not been revoked."
        )))
        guard let provider = chat.choose(ChatProviderStyles.style(for: .anthropic)) else {
            return chat
        }
        await chat.submit(key: "sk-ant-mistyped", for: provider)
        return chat
    }

    /// Two connections: one ready, one described but with no key on this Mac.
    static func connected() async throws -> ChatSettingsModel {
        let chat = try newModel()
        await chat.add(McpCatalogue.files.server(from: ["root": folder]))
        await chat.add(McpCatalogue.github.server(from: [:]))
        // What a server publishes only arrives once it has connected, so the
        // board that shows a reviewed permission has to be given one.
        chat.ingest(
            tools: [
                ToolDescriptor(
                    server: "files", tool: "read_file",
                    summary: "Read the complete contents of a file from the file system.",
                    inputSchemaJson: #"{"type":"object"}"#,
                    readOnlyHint: true, destructiveHint: false, openWorldHint: false
                ),
                ToolDescriptor(
                    server: "files", tool: "write_file",
                    summary: "Create a new file or completely overwrite an existing file.",
                    inputSchemaJson: #"{"type":"object"}"#,
                    readOnlyHint: false, destructiveHint: true, openWorldHint: false
                ),
            ],
            grants: [
                ToolGrant(server: "files", tool: "read_file", allowed: true, decidedAtMs: 1),
                ToolGrant(server: "files", tool: "write_file", allowed: false, decidedAtMs: 2),
            ]
        )
        return chat
    }

    /// Something out of a README: a program nobody shipped a recipe for, with
    /// the token already lifted out of it.
    static let pastedServer = McpServerConfig(
        id: "team-search",
        name: "team-search",
        transport: TransportKind.stdio,
        command: "npx",
        args: ["-y", "@acme/team-search-mcp", "--workspace", "acme"],
        env: [EnvVar(name: "ACME_REGION", value: "eu-west-1")],
        secretEnv: [SecretEnvVar(name: "ACME_API_TOKEN", credential: "team-api-token")],
        url: nil,
        credential: nil,
        enabled: true
    )

}
