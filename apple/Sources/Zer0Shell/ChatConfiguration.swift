import AppKit
import Foundation
import Zer0Core

// MARK: - How a provider reads

/// What the settings window says about a kind of provider.
///
/// Presentation, so it is here and not in the core: `ProviderKind` is the
/// closed set of wire protocols the core will speak, and this is the sentence a
/// person reads before they know what any of those words mean. Two platforms
/// may reasonably word it differently; neither may disagree about what
/// `openai-compatible` *is*.
struct ChatProviderStyle: Sendable {
    let kind: ProviderKind
    /// The name people use, not the company's. Somebody looking for the thing
    /// they have an account with is looking for "Claude", not "Anthropic".
    let name: String
    /// One line saying what picking this costs and what it gets you.
    let summary: String
    let symbol: String
    /// Whether a key is needed at all. A model on this machine needs none, and
    /// for somebody who has never held an API key that is the most useful fact
    /// on the pane.
    let needsKey: Bool
    /// Where a key comes from. There is no click inside this app that mints
    /// one, so the honest move is one click to the page that does.
    let keyPage: URL?
    let keyPageName: String?
    /// What a key from here starts with. Used to catch a key pasted under the
    /// wrong provider *before* the network is touched, and never to refuse one:
    /// a provider is free to change its prefix, and a settings screen that
    /// rejects a working key because it looks unusual is worse than one that
    /// lets the provider answer.
    let keyPrefix: String?
    /// Whether the entry needs a `base_url` before it can be used at all.
    let needsBaseUrl: Bool

    /// The credential name a first-time entry gets.
    ///
    /// A *name*, never a value — `ProviderConfig.credential` is a key into the
    /// Keychain and `looksLikeASecret` refuses anything that is not. Derived
    /// from the id so somebody reading the committed file sees `credential =
    /// "anthropic"` and can guess what it means.
    static func credentialName(forProvider id: String) -> String { id }
}

enum ChatProviderStyles {
    static let all: [ChatProviderStyle] = [
        ChatProviderStyle(
            kind: .anthropic,
            name: "Claude",
            summary: "Anthropic's models. You pay Anthropic for what you use.",
            symbol: "sparkle",
            needsKey: true,
            keyPage: URL(string: "https://console.anthropic.com/settings/keys"),
            keyPageName: "console.anthropic.com",
            keyPrefix: "sk-ant-",
            needsBaseUrl: false
        ),
        ChatProviderStyle(
            kind: .openAi,
            name: "ChatGPT",
            summary: "OpenAI's models. You pay OpenAI for what you use.",
            symbol: "bubble.left.and.bubble.right",
            needsKey: true,
            keyPage: URL(string: "https://platform.openai.com/api-keys"),
            keyPageName: "platform.openai.com",
            keyPrefix: "sk-",
            needsBaseUrl: false
        ),
        ChatProviderStyle(
            kind: .ollama,
            name: "On this Mac",
            summary: "A model running locally through Ollama. No account, no key, "
                + "and nothing you type leaves this machine.",
            symbol: "desktopcomputer",
            needsKey: false,
            keyPage: URL(string: "https://ollama.com/download"),
            keyPageName: "ollama.com",
            keyPrefix: nil,
            needsBaseUrl: false
        ),
        ChatProviderStyle(
            kind: .openAiCompatible,
            name: "Somewhere else",
            summary: "Any service that speaks OpenAI's shape — a work gateway, a proxy, "
                + "something you host. You will need the address it lives at.",
            symbol: "network",
            needsKey: true,
            keyPage: nil,
            keyPageName: nil,
            keyPrefix: nil,
            needsBaseUrl: true
        ),
    ]

    static func style(for kind: ProviderKind) -> ChatProviderStyle {
        all.first { $0.kind == kind } ?? all[0]
    }

    /// A first entry for this kind, with the credential named after it.
    static func newProvider(_ style: ChatProviderStyle) -> ProviderConfig {
        var provider = ProviderConfig(
            id: style.kind.asWire(),
            name: style.name,
            kind: style.kind,
            baseUrl: nil,
            credential: nil,
            models: [],
            defaultModel: nil,
            enabled: true
        )
        if style.needsKey {
            provider.credential = ChatProviderStyle.credentialName(forProvider: provider.id)
        }
        return provider
    }
}

// MARK: - Showing a key without showing a key

enum ChatKeyDisplay {
    /// A key as it is allowed to appear on screen.
    ///
    /// The last four characters are what makes two keys distinguishable, which
    /// is the only reason to show any of it. Anything shorter shows nothing at
    /// all rather than most of a short key.
    static func redact(_ secret: String) -> String {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return String(repeating: "•", count: 12) }
        return String(repeating: "•", count: 12) + trimmed.suffix(4)
    }
}

/// What the last check of a key said.
enum ChatKeyState: Equatable, Sendable {
    /// Nothing has been entered, or the file names a credential the Keychain
    /// has no entry for. Both are the same to-do.
    case absent
    case checking
    /// The provider answered, and answered with models.
    case working(models: Int)
    /// The provider answered and said no. The string is the consequence, not
    /// the status code.
    case refused(String)
    /// Nobody answered. Different from refused on purpose: one is a bad key,
    /// the other is a bad afternoon, and telling somebody to go and make a new
    /// key because their wifi dropped is how a settings screen loses trust.
    case unreachable(String)
    /// A key is stored and has not been checked this launch. Not a warning:
    /// re-checking every key every time the window opens would be a request to
    /// a paid API for opening a settings pane.
    case stored
}

// MARK: - Asking a provider whether a key works

@MainActor
protocol ChatProviderProbe: AnyObject {
    func check(provider: ProviderConfig, key: String?) async -> ChatProbeResult
}

enum ChatProbeResult: Equatable, Sendable {
    case working([String])
    case refused(String)
    case unreachable(String)
}

/// A real request, over `URLSession`.
///
/// The shell makes the call for the same reason it downloads an extension
/// package rather than having Rust do it: `URLSession` already speaks the
/// system's proxy and certificate settings, and a client inside the core would
/// have to be taught both.
///
/// Every kind here answers `GET /v1/models` with its catalogue, which makes
/// verifying the key and filling the model menu **the same request**. That is
/// not cleverness for its own sake: it is why a key going green also leaves
/// somebody with a list to pick from, and why there is no separate step to
/// forget to press.
@MainActor
final class NetworkChatProviderProbe: ChatProviderProbe {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func check(provider: ProviderConfig, key: String?) async -> ChatProbeResult {
        let style = ChatProviderStyles.style(for: provider.kind)
        guard let request = Self.request(provider: provider, key: key) else {
            return .unreachable("zer0 does not know where to reach \(provider.name) yet. "
                + "It needs an address.")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("\(provider.name) answered with something unreadable.")
            }
            switch http.statusCode {
            case 200 ..< 300:
                return .working(Self.models(in: data))
            case 401, 403:
                return .refused("\(provider.name) did not accept that key. Check that you "
                    + "copied all of it, and that it has not been revoked.")
            case 429:
                return .refused("That key works, but \(provider.name) is rate limiting it "
                    + "right now. Try again in a minute.")
            default:
                return .unreachable("\(provider.name) answered \(http.statusCode). "
                    + "That is not about your key.")
            }
        } catch {
            // Deliberately not the system's message on its own. What somebody
            // needs to know here is that this is not their key's fault.
            return .unreachable(style.needsKey
                ? "zer0 could not reach \(provider.name). That is a connection problem, "
                    + "not a problem with the key."
                : "zer0 could not reach \(provider.name). Check that it is running.")
        }
    }

    private static func request(provider: ProviderConfig, key: String?) -> URLRequest? {
        let base = provider.baseUrl?.trimmingCharacters(in: .whitespaces)
        switch provider.kind {
        case .anthropic:
            guard let url = URL(string: (base ?? "https://api.anthropic.com") + "/v1/models") else {
                return nil
            }
            var request = URLRequest(url: url)
            request.setValue(key ?? "", forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return request
        case .openAi:
            guard let url = URL(string: (base ?? "https://api.openai.com") + "/v1/models") else {
                return nil
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(key ?? "")", forHTTPHeaderField: "Authorization")
            return request
        case .openAiCompatible:
            guard let base, !base.isEmpty,
                  let url = URL(string: base.hasSuffix("/") ? base + "v1/models" : base + "/v1/models")
            else { return nil }
            var request = URLRequest(url: url)
            if let key, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            return request
        case .ollama:
            guard let url = URL(string: (base ?? "http://127.0.0.1:11434") + "/v1/models") else {
                return nil
            }
            return URLRequest(url: url)
        }
    }

    /// `{ "data": [ { "id": … } ] }`, read leniently: a provider adding a field
    /// must not empty this menu.
    private static func models(in data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0["id"] as? String }
    }
}

// MARK: - The catalogue

/// Something a person has to supply before a connection can be made.
///
/// The whole point of the enum is that each case is a **control**, not a text
/// field with a placeholder. A folder is a folder picker, so nobody types a
/// path or learns what `~` means. A key is a secure field with one button to
/// the page that issues one. Only `text` is typing, and it exists for the few
/// things that genuinely are a typed value.
enum McpInput: Identifiable, Equatable, Sendable {
    case folder(id: String, label: String, help: String)
    /// Goes to the Keychain under `credential`, and the file records only that
    /// name. This is the case that keeps a token out of a committed file.
    case secret(
        id: String,
        label: String,
        help: String,
        variable: String,
        credential: String,
        from: URL?,
        fromName: String?
    )
    case text(id: String, label: String, help: String, example: String)

    var id: String {
        switch self {
        case let .folder(id, _, _), let .secret(id, _, _, _, _, _, _), let .text(id, _, _, _): id
        }
    }

    var label: String {
        switch self {
        case let .folder(_, label, _), let .secret(_, label, _, _, _, _, _),
             let .text(_, label, _, _): label
        }
    }
}

/// What a connection needs installed before it can run at all.
enum McpRuntime: String, Sendable {
    case node
    case python
    /// Nothing. A remote connection starts no program.
    case none

    var executable: String? {
        switch self {
        case .node: "npx"
        case .python: "uvx"
        case .none: nil
        }
    }

    /// What is missing, said as a thing rather than as a command.
    var productName: String? {
        switch self {
        case .node: "Node.js"
        case .python: "uv"
        case .none: nil
        }
    }

    var installPage: URL? {
        switch self {
        case .node: URL(string: "https://nodejs.org/en/download")
        case .python: URL(string: "https://docs.astral.sh/uv/getting-started/installation/")
        case .none: nil
        }
    }
}

/// A promise about what a connection will be able to do, written by us, shown
/// before anything starts.
///
/// A server only names its tools once it is running, which is after the moment
/// consent is worth asking for — and `ToolDescriptor.summary` is the server
/// describing itself, which ADR-0028 refuses as evidence. So the catalogue
/// carries sentences for the servers zer0 ships a recipe for, and for anything
/// else the review screen says plainly that it cannot say.
struct McpExpectation: Identifiable, Sendable {
    let id: String
    /// What it lets the assistant do, in the second person.
    let title: String
    let detail: String
    let risk: PermissionRisk
}

/// A connection zer0 knows how to set up, so adding it is a click and two
/// answers rather than a command line.
struct McpCatalogueEntry: Identifiable, Sendable {
    let id: String
    /// Named for what it gives the assistant, not for the package that
    /// implements it. "Your files", not "server-filesystem".
    let name: String
    let summary: String
    let symbol: String
    let runtime: McpRuntime
    let inputs: [McpInput]
    /// What actually runs, named. Somebody is about to let code start on their
    /// Mac and hiding which code is not a kindness.
    let packageName: String
    let expects: [McpExpectation]
    /// Fixed part of the command line. The variable part comes from the
    /// answers, through `arguments`.
    let command: String
    let fixedArguments: [String]
    /// Which answers become positional arguments, in order.
    let argumentInputs: [String]

    /// The entry as the config file will hold it.
    ///
    /// Secrets do not appear: an input of kind `.secret` becomes a
    /// `SecretEnvVar` naming a Keychain credential, and the value goes to the
    /// Keychain separately. That is what makes the file safe to commit, and it
    /// is the core's design rather than a convention this file follows.
    func server(from answers: [String: String]) -> McpServerConfig {
        var config = McpServerConfig(
            id: id,
            name: name,
            transport: TransportKind.stdio,
            command: command,
            args: fixedArguments + argumentInputs.compactMap { answers[$0] },
            env: [],
            secretEnv: [],
            url: nil,
            credential: nil,
            enabled: true
        )
        for input in inputs {
            if case let .secret(_, _, _, variable, credential, _, _) = input {
                config.secretEnv.append(SecretEnvVar(name: variable, credential: credential))
            }
        }
        return config
    }
}

/// The connections zer0 ships a recipe for.
///
/// Deliberately short. A catalogue of forty is a catalogue nobody reads, and
/// every entry is a promise that the recipe still works.
enum McpCatalogue {
    static let entries: [McpCatalogueEntry] = [files, github, web]

    static let files = McpCatalogueEntry(
        id: "files",
        name: "Your files",
        summary: "Let the assistant read and write files in one folder you choose. "
            + "Nothing outside that folder is reachable.",
        symbol: "folder",
        runtime: .node,
        inputs: [
            .folder(
                id: "root",
                label: "Folder",
                help: "The assistant can see everything in here, including what is in "
                    + "subfolders. Pick the narrowest folder that still does the job."
            ),
        ],
        packageName: "@modelcontextprotocol/server-filesystem",
        expects: [
            McpExpectation(
                id: "read_file",
                title: "Read any file in the folder you chose",
                detail: "Including everything under it. If that folder holds documents you "
                    + "would not paste into a chat, choose a narrower one.",
                risk: .high
            ),
            McpExpectation(
                id: "write_file",
                title: "Create and overwrite files in that folder",
                detail: "An overwrite replaces what was there, and there is no undo on the "
                    + "assistant's side.",
                risk: .critical
            ),
            McpExpectation(
                id: "list_directory",
                title: "List what is in the folder",
                detail: "Names and sizes, not contents.",
                risk: .moderate
            ),
        ],
        command: "npx",
        fixedArguments: ["-y", "@modelcontextprotocol/server-filesystem"],
        argumentInputs: ["root"]
    )

    static let github = McpCatalogueEntry(
        id: "github",
        name: "GitHub",
        summary: "Let the assistant read your repositories, issues and pull requests, "
            + "and open new ones.",
        symbol: "chevron.left.forwardslash.chevron.right",
        runtime: .node,
        inputs: [
            .secret(
                id: "token",
                label: "GitHub token",
                help: "A personal access token. Give it only the repositories you want the "
                    + "assistant to see — GitHub lets you scope one to a single repo.",
                variable: "GITHUB_PERSONAL_ACCESS_TOKEN",
                credential: "github",
                from: URL(string: "https://github.com/settings/tokens?type=beta"),
                fromName: "github.com"
            ),
        ],
        packageName: "@modelcontextprotocol/server-github",
        expects: [
            McpExpectation(
                id: "search_repositories",
                title: "Read the repositories your token reaches",
                detail: "Private ones too, if the token you give it covers them.",
                risk: .high
            ),
            McpExpectation(
                id: "create_issue",
                title: "Open issues and pull requests as you",
                detail: "Anything it opens carries your name and notifies whoever is "
                    + "watching the repository.",
                risk: .critical
            ),
        ],
        command: "npx",
        fixedArguments: ["-y", "@modelcontextprotocol/server-github"],
        argumentInputs: []
    )

    static let web = McpCatalogueEntry(
        id: "web",
        name: "Pages on the web",
        summary: "Let the assistant fetch a page you name and read it as text. "
            + "It reaches nothing on this Mac.",
        symbol: "globe",
        runtime: .python,
        inputs: [],
        packageName: "mcp-server-fetch",
        expects: [
            McpExpectation(
                id: "fetch",
                title: "Open a web address and read what comes back",
                detail: "Only addresses it is given. It cannot see the pages you have open "
                    + "here or anything you are signed into.",
                risk: .moderate
            ),
        ],
        command: "uvx",
        fixedArguments: ["mcp-server-fetch"],
        argumentInputs: []
    )

    static func entry(_ id: String?) -> McpCatalogueEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }
}

// MARK: - Is the runtime even here

/// Whether the program a catalogue entry needs exists on this Mac.
///
/// Checked before the review step rather than after the connection fails,
/// because `npx: command not found` three screens later is the single most
/// likely way somebody who did everything right gets stuck — and it is not
/// their mistake, it is a missing dependency nobody told them about.
enum McpRuntimeCheck {
    /// Where a Mac actually keeps these, plus whatever `PATH` says. No login
    /// shell is spawned: running one from a settings pane to find out whether
    /// Node is installed is a lot of machinery, and Homebrew, the Node
    /// installer and uv all land in these four.
    static func isAvailable(_ runtime: McpRuntime) -> Bool {
        guard let executable = runtime.executable else { return true }
        var directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        return directories.contains { directory in
            FileManager.default.isExecutableFile(
                atPath: (directory as NSString).appendingPathComponent(executable)
            )
        }
    }
}

// MARK: - Reading what the instructions gave you

/// The `mcpServers` block every MCP server's README ships.
///
/// This is the honest middle door. Nobody non-technical is going to compose a
/// command line, but a great many people can copy a block of text out of a page
/// and paste it — and that block is, in practice, how these servers are
/// distributed. Reading it here means the paste lands on the same review screen
/// the catalogue produces, in the same words, before anything runs.
///
/// **A literal secret in a pasted block is moved, not kept.** READMEs routinely
/// show `"env": { "GITHUB_TOKEN": "ghp_…" }`, and writing that straight into the
/// file would put a token in something built to be committed. Anything the core
/// calls a secret comes back in `secrets`, for the sheet to route into the
/// Keychain under a name.
enum McpConfigPaste {
    enum Failure: Error, Equatable {
        case notJson
        case noServers
        case unsupported(String)
    }

    struct Reading: Equatable {
        var servers: [McpServerConfig]
        /// Credential name to the value that was pasted, for the Keychain.
        /// Never written to the file.
        var secrets: [String: String]
    }

    static func read(_ text: String) throws -> Reading {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.notJson }

        // Both shapes turn up: the whole file, and just the inner object with
        // one server in it. Somebody copying out of a README gets whichever the
        // README showed, and being strict about which is a rule that exists
        // only to punish.
        let block = (root["mcpServers"] as? [String: Any])
            ?? (root["servers"] as? [String: Any])
            ?? root
        guard !block.isEmpty else { throw Failure.noServers }

        var reading = Reading(servers: [], secrets: [:])
        for name in block.keys.sorted() {
            guard let entry = block[name] as? [String: Any] else { continue }
            try append(named: name, from: entry, into: &reading)
        }
        guard !reading.servers.isEmpty else { throw Failure.noServers }
        return reading
    }

    private static func append(
        named name: String,
        from entry: [String: Any],
        into reading: inout Reading
    ) throws {
        let id = identifier(from: name)

        if let command = entry["command"] as? String, !command.isEmpty {
            var server = McpServerConfig(
                id: id,
                name: name,
                transport: TransportKind.stdio,
                command: command,
                args: (entry["args"] as? [Any])?.compactMap { $0 as? String } ?? [],
                env: [],
                secretEnv: [],
                url: nil,
                credential: nil,
                enabled: true
            )

            let environment = (entry["env"] as? [String: Any])?
                .compactMapValues { $0 as? String } ?? [:]
            for variable in environment.keys.sorted() {
                let value = environment[variable] ?? ""
                // The core's rule, not a second copy of it.
                if looksLikeASecret(value: value) {
                    let credential = "\(id)-\(identifier(from: variable))"
                    server.secretEnv.append(
                        SecretEnvVar(name: variable, credential: credential)
                    )
                    reading.secrets[credential] = value
                } else {
                    server.env.append(EnvVar(name: variable, value: value))
                }
            }
            reading.servers.append(server)
            return
        }

        if let url = entry["url"] as? String, !url.isEmpty {
            reading.servers.append(McpServerConfig(
                id: id,
                name: name,
                transport: TransportKind.http,
                command: nil,
                args: [],
                env: [],
                secretEnv: [],
                url: url,
                credential: nil,
                enabled: true
            ))
            return
        }

        throw Failure.unsupported(name)
    }

    /// An id the core will accept, from whatever the block called it.
    ///
    /// The rule is `mcpIsValidServerId`, and it is not a style preference: an
    /// id containing the qualifier that joins a server to a tool would let one
    /// server produce a name that reads as if it came from another. So this
    /// keeps ASCII lowercase, digits and hyphens and nothing else — an accented
    /// letter is a letter, and would have passed a check written here. The
    /// original spelling survives as the name.
    static func identifier(from name: String) -> String {
        let mapped = name.lowercased().map { character -> Character in
            character.isASCII && (character.isLowercase || character.isNumber) ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let bounded = String(collapsed.prefix(64))
        return mcpIsValidServerId(id: bounded) ? bounded : "server"
    }
}
