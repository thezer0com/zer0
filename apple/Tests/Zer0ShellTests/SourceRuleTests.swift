import Foundation
import Testing

@testable import Zer0Shell

// MARK: - Reading the shell as text

/// Rules this project holds that no compiler can see.
///
/// Most decisions here are locked by a test that exercises behaviour, which is
/// the better kind of lock. These four cannot be: the absence of a `default:`,
/// the absence of a toolbar, and the absence of a hand-written curve are all
/// absences, and an assertion cannot observe something that is not there.
/// `PaletteContrastTests.noViewSpellsAStatusColourForItself` established the
/// answer — read the sources and fail on the shape — and this file is that
/// scanner applied to the three other rules that were still wishes.
///
/// The thing that kills a scanner like this is a false positive: a lint that
/// fires on correct code is disabled within a week, and then the rule is gone
/// for good. So the source is read rather than grepped. Comments and string
/// literals are blanked out first, `case` patterns are told apart from `case`
/// bodies, and the vocabulary the wildcard rule applies to is read out of the
/// generated bindings instead of being listed here where it would go stale.
///
/// Every scanner below is itself under test, further down this file, against
/// snippets that contain the forbidden shape on purpose. A check nobody has
/// seen fail is a check nobody should trust.
enum SourceScan {
    /// The repo root, found from this file rather than from the working
    /// directory, so the scans work under `swift test` from anywhere.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Zer0ShellTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // apple
            .deletingLastPathComponent()  // the repo root
    }

    /// Every Swift file the shell is built from: the views and the model, plus
    /// the thin executable target, which owns the menu bar and so is a real
    /// consumer of `UiCommand`.
    ///
    /// Deliberately not the generated bindings under `Sources/Zer0Core`: that
    /// file is uniffi's output, its wildcards are over wire tags read off the
    /// FFI buffer, and rewriting it is not a thing anyone does.
    static func shellSources() throws -> [Source] {
        let directories = [
            repoRoot.appending(path: "apple/Sources/Zer0Shell"),
            repoRoot.appending(path: "apple/Sources/Zer0"),
        ]

        var sources: [Source] = []
        for directory in directories {
            let files = try FileManager.default
                .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            for file in files {
                sources.append(Source(file: file, text: try String(contentsOf: file, encoding: .utf8)))
            }
        }

        // An empty sweep passes every check in this file while checking
        // nothing, which is the one way a scanner fails silently.
        #expect(!sources.isEmpty, "found no shell sources under \(directories)")
        return sources.sorted { $0.name < $1.name }
    }

    /// Every Swift file in this suite, including the screenshot harnesses.
    ///
    /// The harnesses are in on purpose: they do not run by default, so a defect
    /// in one waits for whoever next sets `ZER0_SHOT=1` rather than being caught
    /// on the run that introduced it. A rule a scanner can read costs nothing to
    /// apply to a file nobody executes.
    static func testSources() throws -> [Source] {
        let directory = repoRoot.appending(path: "apple/Tests/Zer0ShellTests")
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        var sources: [Source] = []
        for file in files {
            sources.append(Source(file: file, text: try String(contentsOf: file, encoding: .utf8)))
        }

        #expect(!sources.isEmpty, "found no test sources under \(directory)")
        return sources.sorted { $0.name < $1.name }
    }

    /// One file, with everything that is not code taken out of it.
    struct Source {
        let file: URL
        /// The bytes on disk, kept so a failure can quote the real line.
        let text: String
        /// The same characters with every comment and every string literal
        /// replaced by spaces. Same length, same newlines — so an offset into
        /// this is an offset into the file, and a line number is a line number.
        let code: [Character]
        /// The same again, but with the string literals left in place.
        ///
        /// A name reached through the Objective-C runtime *is* a string
        /// literal, so the SPI containment scan has to be able to see one.
        /// Comments still go, because the comment explaining why an SPI was
        /// refused is the first thing a scan over raw text gets wrong.
        let codeAndStrings: [Character]

        var name: String { file.lastPathComponent }
        /// Relative to the repo root, because that is what a person types.
        var path: String {
            file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
        }

        init(file: URL, text: String) {
            self.file = file
            self.text = text
            self.code = SourceScan.blanked(text)
            self.codeAndStrings = SourceScan.blanked(text, keepingStrings: true)
        }

        /// One-based, counted the way an editor counts.
        func line(at offset: Int) -> Int {
            var line = 1
            for index in 0..<min(offset, code.count) where code[index] == "\n" {
                line += 1
            }
            return line
        }
    }

    // MARK: Blanking

    /// Replace comments and string literals with spaces, keeping every newline
    /// where it was.
    ///
    /// This is the whole difference between a scanner people keep and one they
    /// switch off. `BrowserModel` carries the sentence "Listed rather than
    /// caught by `default:`" in a comment directly above the arm it is
    /// describing; a grep would report that comment as the violation it exists
    /// to say was avoided.
    ///
    /// String interpolation is blanked along with its string. Code inside
    /// `\(...)` is real code, but no switch has ever been written inside one,
    /// and the alternative — a scanner that reopens for interpolation — is more
    /// machinery than the risk is worth.
    ///
    /// With `keepingStrings`, literals are walked over but left where they are.
    /// That is for the one rule whose subject lives *inside* a literal: a
    /// selector or a class reached through the Objective-C runtime is spelled
    /// as a string, and a scan that blanks strings cannot see it.
    static func blanked(_ source: String, keepingStrings: Bool = false) -> [Character] {
        var characters = Array(source)
        var index = 0

        func blank(_ from: Int, _ to: Int) {
            for position in from..<min(to, characters.count) where characters[position] != "\n" {
                characters[position] = " "
            }
        }

        /// Blank a literal, or step over it and leave it alone.
        func blankLiteral(_ from: Int, _ to: Int) {
            guard !keepingStrings else { return }
            blank(from, to)
        }

        func matches(_ literal: String, at position: Int) -> Bool {
            let needle = Array(literal)
            guard position + needle.count <= characters.count else { return false }
            for (offset, character) in needle.enumerated() where characters[position + offset] != character {
                return false
            }
            return true
        }

        /// The end of a delimited run, or the end of the file.
        func findEnd(of terminator: String, from position: Int) -> Int {
            var scan = position
            while scan < characters.count {
                if matches(terminator, at: scan) { return scan + terminator.count }
                scan += 1
            }
            return characters.count
        }

        while index < characters.count {
            let character = characters[index]

            if matches("//", at: index) {
                var end = index
                while end < characters.count, characters[end] != "\n" { end += 1 }
                blank(index, end)
                index = end
                continue
            }

            if matches("/*", at: index) {
                // Swift's block comments nest, so a `/*` inside one does not
                // end at the first `*/`.
                var depth = 1
                var scan = index + 2
                while scan < characters.count, depth > 0 {
                    if matches("/*", at: scan) {
                        depth += 1
                        scan += 2
                    } else if matches("*/", at: scan) {
                        depth -= 1
                        scan += 2
                    } else {
                        scan += 1
                    }
                }
                blank(index, scan)
                index = scan
                continue
            }

            // A raw string: any number of `#`, then a quote. The escape rules
            // change inside one, so it is closed on the quote-plus-hashes and
            // nothing in between is interpreted.
            if character == "#" {
                var hashes = 0
                while index + hashes < characters.count, characters[index + hashes] == "#" { hashes += 1 }
                let fence = String(repeating: "#", count: hashes)
                if matches("\"\"\"", at: index + hashes) {
                    let end = findEnd(of: "\"\"\"" + fence, from: index + hashes + 3)
                    blankLiteral(index, end)
                    index = end
                    continue
                }
                if matches("\"", at: index + hashes), hashes > 0 {
                    let end = findEnd(of: "\"" + fence, from: index + hashes + 1)
                    blankLiteral(index, end)
                    index = end
                    continue
                }
            }

            if matches("\"\"\"", at: index) {
                let end = findEnd(of: "\"\"\"", from: index + 3)
                blankLiteral(index, end)
                index = end
                continue
            }

            if character == "\"" {
                var scan = index + 1
                while scan < characters.count {
                    if characters[scan] == "\\" {
                        scan += 2
                        continue
                    }
                    if characters[scan] == "\"" {
                        scan += 1
                        break
                    }
                    // An unterminated literal is a syntax error the compiler
                    // will report; stopping at the newline keeps this scanner
                    // from swallowing the rest of the file on the way there.
                    if characters[scan] == "\n" { break }
                    scan += 1
                }
                blankLiteral(index, scan)
                index = scan
                continue
            }

            index += 1
        }

        return characters
    }

    // MARK: Words, braces and arms

    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Whether `word` starts at `offset` as a word rather than as part of one.
    ///
    /// The leading `.` matters: `.default` is a property on somebody's type and
    /// `.switchToTab` is a `Suggestion`, and neither is the keyword.
    static func isWord(_ word: String, in code: [Character], at offset: Int) -> Bool {
        let needle = Array(word)
        guard offset + needle.count <= code.count else { return false }
        for (index, character) in needle.enumerated() where code[offset + index] != character {
            return false
        }
        if offset > 0, isIdentifierCharacter(code[offset - 1]) || code[offset - 1] == "." {
            return false
        }
        let after = offset + needle.count
        return after >= code.count || !isIdentifierCharacter(code[after])
    }

    /// A `switch` and the half-open range of its body, braces excluded.
    struct SwitchStatement {
        let keyword: Int
        let bodyStart: Int
        let bodyEnd: Int
    }

    static func switches(in code: [Character]) -> [SwitchStatement] {
        var found: [SwitchStatement] = []
        var index = 0

        while index < code.count {
            guard isWord("switch", in: code, at: index) else {
                index += 1
                continue
            }

            // The subject runs to the opening brace. It can contain calls and
            // subscripts, so only a brace at nesting zero opens the body.
            var scan = index + 6
            var nesting = 0
            while scan < code.count {
                let character = code[scan]
                if character == "(" || character == "[" { nesting += 1 }
                if character == ")" || character == "]" { nesting -= 1 }
                if character == "{", nesting == 0 { break }
                scan += 1
            }
            guard scan < code.count else { break }

            var depth = 0
            var end = scan
            while end < code.count {
                if code[end] == "{" { depth += 1 }
                if code[end] == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                end += 1
            }

            found.append(SwitchStatement(keyword: index, bodyStart: scan + 1, bodyEnd: min(end, code.count)))
            index = scan + 1
        }

        return found
    }

    /// The arms of one switch: the text of each `case` *pattern*, and where
    /// each `default` is.
    ///
    /// Only the arms of this switch — a nested switch, a closure and a
    /// dictionary subscript all sit inside brackets, so tracking depth is what
    /// keeps `chords[binding.command, default: []]` from reading as an arm.
    ///
    /// Splitting the pattern off at its colon is what keeps `case 36: .enter`
    /// out of the vocabulary check: the pattern is an integer, and `.enter` is
    /// the value the arm produces.
    static func arms(of statement: SwitchStatement, in code: [Character]) -> (patterns: [String], defaults: [Int]) {
        var patterns: [String] = []
        var defaults: [Int] = []
        var depth = 0
        var index = statement.bodyStart

        while index < statement.bodyEnd {
            let character = code[index]
            if character == "{" || character == "(" || character == "[" {
                depth += 1
                index += 1
                continue
            }
            if character == "}" || character == ")" || character == "]" {
                depth -= 1
                index += 1
                continue
            }
            if depth == 0, isWord("case", in: code, at: index) {
                var scan = index + 4
                var inner = 0
                while scan < statement.bodyEnd {
                    let ahead = code[scan]
                    if ahead == "{" || ahead == "(" || ahead == "[" { inner += 1 }
                    if ahead == "}" || ahead == ")" || ahead == "]" { inner -= 1 }
                    if ahead == ":", inner == 0 { break }
                    scan += 1
                }
                patterns.append(String(code[(index + 4)..<min(scan, statement.bodyEnd)]))
                index = scan
                continue
            }
            if depth == 0, isWord("default", in: code, at: index) {
                defaults.append(index)
                index += 7
                continue
            }
            index += 1
        }

        return (patterns, defaults)
    }

    /// The argument list of a call, `(` and `)` excluded, or nil if `offset`
    /// is not followed by one.
    static func arguments(after offset: Int, in code: [Character]) -> String? {
        var index = offset
        while index < code.count, code[index] == " " || code[index] == "\n" { index += 1 }
        guard index < code.count, code[index] == "(" else { return nil }

        var depth = 0
        var end = index
        while end < code.count {
            if code[end] == "(" { depth += 1 }
            if code[end] == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            end += 1
        }
        guard end < code.count else { return nil }
        return String(code[(index + 1)..<end])
    }

    /// Every offset at which `needle` appears.
    static func occurrences(of needle: String, in code: [Character]) -> [Int] {
        let characters = Array(needle)
        guard !characters.isEmpty, code.count >= characters.count else { return [] }
        var found: [Int] = []
        for start in 0...(code.count - characters.count) {
            var matched = true
            for (offset, character) in characters.enumerated() where code[start + offset] != character {
                matched = false
                break
            }
            if matched { found.append(start) }
        }
        return found
    }

    /// Every offset at which `.name` is called as a member — `.toolbar` but
    /// not `.toolbarBackground`, `.shadow` but not `.shadowRadius`.
    ///
    /// Without the boundary the scan reports every longer name that starts
    /// with a shorter one, and a lint that reports `.toolbarBackground` as a
    /// toolbar is a lint somebody turns off.
    static func callSites(of name: String, in code: [Character]) -> [Int] {
        occurrences(of: ".\(name)", in: code).filter { offset in
            let after = offset + name.count + 1
            return after >= code.count || !isIdentifierCharacter(code[after])
        }
    }

    // MARK: The shared vocabulary

    /// The variants of `Action`, `EngineCommand`, `UiCommand` and `Suggestion`,
    /// read out of the bindings uniffi generates from the Rust definitions.
    ///
    /// Read rather than listed, and that is the point. A list written here
    /// would be a second copy of the vocabulary, and a second copy is a thing
    /// that goes stale — which would leave the rule silently unenforced for
    /// exactly the new variant it exists to protect.
    static func vocabulary() throws -> [String: Set<String>] {
        let generated = repoRoot.appending(path: "apple/Sources/Zer0Core/zer0_core.swift")
        guard let text = try? String(contentsOf: generated, encoding: .utf8) else {
            Issue.record("""
                the generated bindings are not at \(generated.path).
                  This scan reads the command vocabulary out of them, so it cannot run without
                  them. Build the core first: ./apple/scripts/build-core.sh
                """)
            return [:]
        }

        var found: [String: Set<String>] = [:]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        // `ProseKind` joined the list with ADR-0071. It is the same kind of
        // thing: a closed set the core defines and the shell must draw all of,
        // where a wildcard means a new block kind renders as nothing at all and
        // no test anywhere goes red.
        for name in ["Action", "EngineCommand", "UiCommand", "Suggestion", "ProseKind"] {
            guard let start = lines.firstIndex(where: { $0.hasPrefix("public enum \(name):") }) else {
                Issue.record("""
                    \(generated.lastPathComponent) has no `public enum \(name)`.
                      Either the type was renamed in crates/zer0-core, or uniffi stopped exporting
                      it. Update the list of vocabulary types in SourceRuleTests.vocabulary().
                    """)
                continue
            }

            var variants: Set<String> = []
            var depth = 0
            for (offset, line) in lines[start...].enumerated() {
                depth += line.filter { $0 == "{" }.count
                depth -= line.filter { $0 == "}" }.count
                if let variant = caseName(in: String(line)) { variants.insert(variant) }
                if depth == 0, offset > 0 { break }
            }
            found[name] = variants
        }

        return found
    }

    /// `    case openTab(space: UInt32?, ...)` → `openTab`.
    static func caseName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("case ") else { return nil }
        let rest = trimmed.dropFirst(5).drop(while: { $0 == " " })
        let name = rest.prefix(while: { isIdentifierCharacter($0) })
        return name.isEmpty ? nil : String(name)
    }

    /// The `.foo` members named in a case pattern.
    static func membersNamed(in pattern: String) -> Set<String> {
        var members: Set<String> = []
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            if characters[index] == ".",
               index == 0 || !isIdentifierCharacter(characters[index - 1]) {
                var end = index + 1
                while end < characters.count, isIdentifierCharacter(characters[end]) { end += 1 }
                if end > index + 1 { members.insert(String(characters[(index + 1)..<end])) }
                index = end
                continue
            }
            index += 1
        }
        return members
    }
}

// MARK: - ADR-0031: no wildcard over a command or an action

/// A `default:` in a switch over the shared vocabulary is the one failure this
/// codebase has no runtime symptom for: the command is bound, it appears in the
/// menu, and pressing it does nothing.
///
/// ADR-0031 recorded that as unenforceable and said what the enforcement would
/// have to be — *"a lint, not a test: something that walks the switches over
/// these types and fails on a wildcard arm"*. This is that lint. It is a test
/// only in the sense that `swift test` is what runs it.
///
/// The Rust half of the same rule is `clippy::wildcard_enum_match_arm`, denied
/// in the workspace `Cargo.toml`.
@Suite("the shared vocabulary stays exhaustive")
struct VocabularyExhaustivenessTests {
    /// **Scope is the type being matched, not the syntax.** ADR-0031 is
    /// explicit that `Int`, an AppKit selector, an `NSError` domain and an
    /// `OSStatus` are open sets where a wildcard is the only correct answer —
    /// and the shell has eleven of those today, every one of them right. So the
    /// switch is identified by its arms: a switch whose patterns name a variant
    /// of `Action`, `EngineCommand`, `UiCommand`, `Suggestion` or `ProseKind`
    /// is a switch over the vocabulary, and that is the one that may not carry
    /// a wildcard.
    @Test("no switch over a command or an action carries a default")
    func noSwitchOverTheVocabularyCarriesADefault() throws {
        let vocabulary = try SourceScan.vocabulary()
        try #require(!vocabulary.isEmpty)

        var failures: [String] = []

        for source in try SourceScan.shellSources() {
            for statement in SourceScan.switches(in: source.code) {
                let (patterns, defaults) = SourceScan.arms(of: statement, in: source.code)
                guard let wildcard = defaults.first else { continue }

                var named: Set<String> = []
                for pattern in patterns { named.formUnion(SourceScan.membersNamed(in: pattern)) }

                for (type, variants) in vocabulary.sorted(by: { $0.key < $1.key }) {
                    let matched = named.intersection(variants).sorted()
                    guard !matched.isEmpty else { continue }
                    // Enough to identify the switch, not the whole enum. A
                    // failure quoting sixty variant names is a failure people
                    // scroll past to find the line number.
                    let evidence = matched.prefix(3).joined(separator: ", ")
                        + (matched.count > 3 ? " and \(matched.count - 3) more" : "")
                    failures.append("""
                        \(source.path):\(source.line(at: wildcard)): `default:` in a switch over \(type).
                          The arms name \(evidence), so this switch is over the vocabulary the core
                          and the shell share, and a variant added tomorrow would compile straight
                          into this wildcard and never arrive. Replace `default:` with the variants
                          that have nothing to do, listed by name — the way
                          BrowserModel.notifyExtensions(of:) does it (ADR-0031).
                        """)
                    break
                }
            }
        }

        #expect(failures.isEmpty, "\n\(failures.joined(separator: "\n\n"))")
    }
}

// MARK: - ADR-0076: a conversation stacks up from the composer

/// The one modifier that decides where a short transcript sits, and it regresses
/// by deletion like every other absence in this file.
///
/// A `ScrollView` top-aligns content shorter than its viewport. On the window
/// this browser is actually used in — around sixteen hundred by two thousand —
/// that put the newest reply about fifteen hundred points above the field you
/// answer it with, and every other window size hid it: at nine hundred by six
/// hundred and twenty, where this page was photographed for a day, a two-turn
/// exchange nearly fills the viewport and there is no void to see.
///
/// `.defaultScrollAnchor(.bottom)` is what puts the empty room above the first
/// message instead of below the last. It reads as redundant next to the explicit
/// `scrollTo(last, anchor: .bottom)` a few lines above it — they do different
/// jobs, and only one of them does anything when there is nothing to scroll.
@Suite("a conversation stacks up from the composer")
struct TranscriptAnchorTests {
    /// This checks that the line is *there*, not that the pixels ended up where
    /// they should. Nothing in `swift test` can see the second thing: it is
    /// layout, and layout is looked at by `ZZChatPageShots`, which is gated
    /// behind `ZER0_SHOT=1` and so cannot be a lock. Stated rather than implied,
    /// because a lock that is trusted for more than it asks is the failure
    /// AGENTS.md names.
    @Test("the transcript keeps its bottom anchor")
    func theTranscriptKeepsItsBottomAnchor() throws {
        let file = SourceScan.repoRoot.appending(path: "apple/Sources/Zer0Shell/ChatPage.swift")
        let source = SourceScan.Source(file: file, text: try String(contentsOf: file, encoding: .utf8))
        let anchors = SourceScan.occurrences(of: ".defaultScrollAnchor(.bottom)", in: source.code)

        #expect(!anchors.isEmpty, """

            \(source.path): `.defaultScrollAnchor(.bottom)` is gone from the transcript.
              Without it a scroll view top-aligns content shorter than its viewport, so a short
              thread sits against the top of the window and the composer stays at the bottom with
              everything between them empty — about fifteen hundred points of it on a two-thousand
              point window. The explicit scrollTo above does not cover this: it moves a scroll
              offset, and a transcript shorter than the viewport has no offset to move (ADR-0076).
            """)
    }
}

// MARK: - ADR-0010 and ADR-0014: nothing sits over the page

/// Two decisions about the top of the window, both of which regress by
/// deletion, and neither of which had anything watching.
///
/// ADR-0014 says outright that the native toggle staying removed *"has no
/// lock: a deleted `.toolbar(removing: .sidebarToggle)` compiles and passes
/// everything"*. ADR-0010 says the same about the toolbar it forbids: *"today
/// a `.toolbar { ... }` added to `BrowserView` compiles, runs and passes the
/// whole suite"*. Both are absences, and this is the only shape of check that
/// can see one.
@Suite("nothing sits over the page")
struct PageChromeTests {
    private var browserView: SourceScan.Source {
        get throws {
            let file = SourceScan.repoRoot.appending(path: "apple/Sources/Zer0Shell/BrowserView.swift")
            return SourceScan.Source(file: file, text: try String(contentsOf: file, encoding: .utf8))
        }
    }

    /// The system button expects a title bar to sit in. Without one it floats
    /// loose over the page — on top of the Gmail logo, in the example ADR-0014
    /// gives. Ours lives in `WindowChrome`.
    @Test("the system's sidebar toggle stays removed")
    func theSystemSidebarToggleStaysRemoved() throws {
        let source = try browserView
        let removals = SourceScan.occurrences(of: ".toolbar(removing: .sidebarToggle)", in: source.code)

        #expect(!removals.isEmpty, """

            \(source.path): `.toolbar(removing: .sidebarToggle)` is gone.
              With no title bar the system's toggle has nowhere to sit and floats over the page
              content. Put the line back on the NavigationSplitView (ADR-0014). If the button is
              genuinely wanted back, that is a change to ADR-0014, not to this file.
            """)
    }

    /// The whole of ADR-0010 is that the strip other browsers charge on every
    /// page does not exist here. It regresses one item at a time, and the
    /// second item always arrives a fortnight after the first.
    @Test("BrowserView grows no toolbar")
    func browserViewGrowsNoToolbar() throws {
        let source = try browserView
        var failures: [String] = []

        for offset in SourceScan.callSites(of: "toolbar", in: source.code) {
            // The removal is the one permitted spelling, and it is the
            // opposite of what this rule is against.
            let arguments = SourceScan.arguments(after: offset + 8, in: source.code) ?? ""
            if arguments.hasPrefix("removing:") { continue }
            failures.append("""
                \(source.path):\(source.line(at: offset)): BrowserView has grown a toolbar.
                  ADR-0010 is that nothing sits over the page permanently: the address is invoked
                  with ⌘L and leaves when it is done. Three things have a licence to take space —
                  WindowChrome when the sidebar is hidden, the 2pt loading bar while a page loads,
                  and overlays with a way out. A toolbar is none of them. Put the item in an
                  overlay with a condition, or in the command bar.
                """)
        }

        #expect(failures.isEmpty, "\n\(failures.joined(separator: "\n\n"))")
    }
}

// MARK: - ADR-0067: SPI lives in one file

/// ADR-0001 refused SPI and then said exactly what the enforcement would have
/// to be: *"A `grep` for `_WK` and `_features` under `apple/Sources/` inside
/// `scripts/check.sh` would cover half the risk, and it does not exist."*
///
/// ADR-0067 takes one exception — the Web Inspector, which has no public way to
/// open — and an exception is only worth taking if it stays one. So the grep
/// exists now, and it is stricter than the sentence that asked for it: one file
/// may say `_WK`, every other file may not, and the feature-flag spellings
/// ADR-0001 was actually arguing about are still refused everywhere.
///
/// This is the one scan that reads string literals. A selector reached through
/// the Objective-C runtime *is* a literal, so a scan over blanked code would
/// pass over the exact thing it exists to find.
@Suite("SPI lives in one file")
@MainActor
struct SpiContainmentTests {
    /// The file allowed to fail this rule, and the only one.
    private let home = "WebInspector.swift"

    /// Read off `WebInspector` rather than written out here, for the reason
    /// `SourceScan.vocabulary()` gives: a second copy of a name is a thing that
    /// goes stale, and a stale needle is a scan that finds nothing and says so
    /// cheerfully. `_WK` catches every underscored WebKit class, `_features`
    /// and `_WKFeature` are the experimental-flag door ADR-0001 shut and
    /// ADR-0067 leaves shut.
    private var needles: [String] {
        [
            "_WK", "_features",
            WebInspector.inspectorAccessor,
            // Not underscored, and private all the same: a `WKPreferences` key
            // that only exists to KVC. It is in the list precisely because it
            // does not look like SPI, which is how it would spread.
            WebInspector.developerExtrasKey,
            WebInspector.developerExtrasSetter,
        ]
    }

    @Test("no shell source outside WebInspector.swift spells an SPI")
    func noShellSourceOutsideTheOneFileSpellsAnSpi() throws {
        var failures: [String] = []

        for source in try SourceScan.shellSources() where source.name != home {
            for needle in needles {
                for offset in SourceScan.occurrences(of: needle, in: source.codeAndStrings) {
                    failures.append("""
                        \(source.path):\(source.line(at: offset)): `\(needle)` outside \(home).
                          Underscored WebKit is an interface Apple can delete in a point release with
                          no deprecation and no compile-time warning. ADR-0067 allows exactly one use
                          of it — opening the Web Inspector, which has no public equivalent — and
                          confines it to \(home), where it is reached by runtime lookup and degrades
                          to a message instead of a crash. Anything else goes through public API or
                          does not happen (ADR-0001).
                        """)
                }
            }
        }

        #expect(failures.isEmpty, "\n\(failures.joined(separator: "\n\n"))")
    }

    /// The scan above passes over a shell that reaches no SPI at all *and* over
    /// a shell where the needles stopped matching anything. This tells the two
    /// apart: the one permitted use has to still be there, in the one permitted
    /// file.
    @Test("the one permitted use is still where it is permitted")
    func theOnePermittedUseIsStillWhereItIsPermitted() throws {
        let source = try #require(try SourceScan.shellSources().first { $0.name == home })

        for needle in [
            WebInspector.inspectorClassName,
            WebInspector.inspectorAccessor,
            WebInspector.developerExtrasKey,
        ] {
            #expect(
                !SourceScan.occurrences(of: needle, in: source.codeAndStrings).isEmpty,
                """

                \(source.path) no longer spells `\(needle)`.
                  Either the inspector went through some other door — in which case the containment
                  scan above is now watching an empty room — or WebKit grew a public way to open it,
                  which is the trigger ADR-0067 names for withdrawing the exception. Neither is a
                  thing to leave undecided.
                """
            )
        }
    }
}

// MARK: - A test window is released by whoever holds it

/// `NSWindow.isReleasedWhenClosed` is `true` on every window built from an
/// initialiser and it predates ARC, so `close()` spends a reference the caller
/// is still holding. The second release arrives from the autorelease pool, at
/// the end of whichever main-queue job drains it — the process dies in
/// `objc_release` under `objc_autoreleasePoolPop`, with nothing of ours on the
/// stack and a different test in flight each run.
///
/// That is why this rule is a scanner and not a comment. The suite crashed for
/// two days on this: thirteen windows, six with the flag, and two of the rest
/// went on to call `close()`. Nothing in the crash named either of them, and
/// every slice anybody ran looked green.
///
/// One door — `testWindow` — and this reads the suite as text to keep it one.
@Suite("a test window is released by whoever holds it")
@MainActor
struct WindowOwnershipTests {
    /// The file allowed to say it, and the only one.
    private let home = "TestWindow.swift"

    @Test("no test builds a window of its own")
    func noTestBuildsAWindowOfItsOwn() throws {
        var failures: [String] = []

        for source in try SourceScan.testSources() where source.name != home {
            for offset in SourceScan.occurrences(of: "NSWindow(", in: source.code) {
                failures.append("""
                    \(source.path):\(source.line(at: offset)): builds its own NSWindow.
                      `isReleasedWhenClosed` is true on it, so `close()` releases a window this
                      test is still holding and the process dies later, in an autorelease pool
                      drain, on whichever test was unlucky. Use `testWindow(_:styleMask:)`.
                    """)
            }
        }

        #expect(failures.isEmpty, "\n\(failures.joined(separator: "\n\n"))")
    }

    /// The scan above is equally happy with a suite that makes no windows and
    /// with a `testWindow` that stopped setting the flag. This tells them
    /// apart: the one door has to still be closing.
    @Test("the one door still sets the flag")
    func theOneDoorStillSetsTheFlag() throws {
        let source = try #require(try SourceScan.testSources().first { $0.name == home })

        #expect(
            !SourceScan.occurrences(of: "isReleasedWhenClosed = false", in: source.code).isEmpty,
            """

            \(source.path) no longer clears `isReleasedWhenClosed`.
              Every window in this suite comes from here, so the whole suite is back to owning
              references AppKit has already spent — and the way that is noticed is a segfault in
              an unrelated test, two days later.
            """
        )
    }
}

// MARK: - ADR-0046: motion and depth come from the design system

/// ADR-0046 made `Design.entrance` and `Design.subtle` `fileprivate` so that a
/// curve written out at a call site would not compile, and the three spellings
/// that remain all read `\.accessibilityReduceMotion` on the way through. That
/// closes the door on a *named* curve. It does not close the door on
/// `.animation(.easeOut(duration: 0.2), value:)`, which compiles anywhere and
/// asks nobody anything — including someone with Reduce Motion switched on.
///
/// `Design.Elevation` is the same shape of decision for depth: three steps, so
/// a shadow is a scale rather than seven recipes.
@Suite("motion and depth come from the design system")
struct DesignVocabularyTests {
    /// `DesignSystem.swift` is where both are defined, so it is where both are
    /// spelled out. Everywhere else is a call site.
    private let home = "DesignSystem.swift"

    @Test("no view writes its own animation curve")
    func noViewWritesItsOwnAnimationCurve() throws {
        var failures: [String] = []

        for source in try SourceScan.shellSources() where source.name != home {
            for offset in SourceScan.occurrences(of: ".animation(", in: source.code) {
                failures.append("""
                    \(source.path):\(source.line(at: offset)): a curve written out at a call site.
                      A bare `.animation(...)` is a curve that never asked whether the person wants
                      motion at all. There are three spellings that do ask, and they are the only
                      three (ADR-0046):
                        .motion(.entrance, value: something)   declaring a change
                        .arrives(from: .top)                   a transition carrying a direction
                        @Curves private var motion             for withAnimation(motion.entrance)
                    """)
            }
        }

        #expect(failures.isEmpty, "\n\(failures.joined(separator: "\n\n"))")
    }

    /// **A black cast is a depth claim, and depth is a scale.**
    ///
    /// Not every shadow is: `SiteBadge` bleeds the badge's own hue a point past
    /// its edge so a saturated 16pt square does not read as a sticker dropped
    /// on the row, and `TabInsertionLine` glows in the accent so a 2pt capsule
    /// separates from whatever is under it. Both say so in their own comments,
    /// and neither is claiming the thing has left the surface. Flagging them
    /// would be a lint firing on correct code, which is how a lint gets
    /// deleted — so the rule is drawn where the decision actually is: a shadow
    /// in black, or a shadow with no colour at all (SwiftUI's default is black
    /// at 33%), is one of the three steps or it is a fourth step nobody named.
    @Test("no view invents a depth")
    func noViewInventsADepth() throws {
        var failures: [String] = []

        for source in try SourceScan.shellSources() where source.name != home {
            for offset in SourceScan.callSites(of: "shadow", in: source.code) {
                guard let arguments = SourceScan.arguments(after: offset + 7, in: source.code) else { continue }
                let colourless = !arguments.contains("color:")
                guard colourless || arguments.spells("black") else { continue }

                let cast = colourless ? "no colour, so SwiftUI's black at 33%" : "black"
                failures.append("""
                    \(source.path):\(source.line(at: offset)): a shadow in \(cast), written by hand.
                      A black cast says the thing has left the surface, and how far it left is a
                      scale with three steps on it, not a number per call site (ADR-0046):
                        .elevation(Design.Elevation.resting)   a strip on the page — find bar, banner
                        .elevation(Design.Elevation.floating)  a panel over it — shelf, session warning
                        .elevation(Design.Elevation.overlay)   over a window that dimmed for it
                      A shadow in a hue is a different thing and is not this rule: SiteBadge and
                      TabInsertionLine both cast in their own colour, and say why where they do it.
                    """)
            }
        }

        #expect(failures.isEmpty, "\n\(failures.joined(separator: "\n\n"))")
    }
}

// MARK: - The scanners, under test

/// A check nobody has seen fail is a check nobody should trust.
///
/// Every suite above passes today by finding nothing, which is exactly what a
/// scanner that silently matches nothing at all also does. These drive the same
/// functions over snippets that contain the forbidden shape on purpose, and
/// over the near-misses that would make the scanner cry wolf — the eleven
/// wildcards the shell legitimately has are all of the second kind, and one
/// false positive on them would get this whole file deleted.
@Suite("the source scanners")
struct SourceScanTests {
    private func scan(_ snippet: String) -> SourceScan.Source {
        SourceScan.Source(file: URL(fileURLWithPath: "/snippet.swift"), text: snippet)
    }

    @Test("a wildcard over an Action is found")
    func aWildcardOverAnActionIsFound() throws {
        let source = scan("""
            func notify(_ action: Action) {
                switch action {
                case let .titleChanged(tab, _): extensions.tabChanged(tab, [.title])
                default: break
                }
            }
            """)

        let statement = try #require(SourceScan.switches(in: source.code).first)
        let (patterns, defaults) = SourceScan.arms(of: statement, in: source.code)
        #expect(defaults.count == 1)
        #expect(source.line(at: defaults[0]) == 4)
        #expect(patterns.flatMap { SourceScan.membersNamed(in: $0) }.contains("titleChanged"))
    }

    /// The eleven wildcards in the shell today are all of this shape: an
    /// integer, a selector, an `NSError` domain, an `OSStatus`, a `TabId`. The
    /// trap is `case 36: .enter` — the *body* names an enum member and the
    /// pattern does not, and a scanner that read the whole arm would flag it.
    @Test("a wildcard over an open set is not")
    func aWildcardOverAnOpenSetIsNot() throws {
        let source = scan("""
            func namedKey(for keyCode: UInt16) -> Key? {
                switch keyCode {
                case 36: .enter
                case 48: .tab
                default: nil
                }
            }
            """)

        let statement = try #require(SourceScan.switches(in: source.code).first)
        let (patterns, _) = SourceScan.arms(of: statement, in: source.code)
        let named = patterns.flatMap { SourceScan.membersNamed(in: $0) }
        #expect(named.isEmpty, "the arm bodies leaked into the patterns: \(named)")
    }

    /// `BrowserModel` carries the sentence "Listed rather than caught by
    /// `default:`" in a comment above the arm that avoids it, and `SettingsView`
    /// writes `chords[binding.command, default: []]`. Either one read as an arm
    /// would put this file's first failure on correct code.
    @Test("a default in a comment, a string or a subscript is not an arm")
    func aDefaultInACommentOrAStringIsNotAnArm() throws {
        let source = scan("""
            func notify(_ action: Action) {
                var chords = [UiCommand: [Chord]]()
                chords[.newTab, default: []].append(chord)
                // Listed rather than caught by `default:`. A new Action would
                switch action {
                case .openTab, .closeTab: break
                case let .titleChanged(tab, _): say("default: break", tab)
                }
            }
            """)

        let statement = try #require(SourceScan.switches(in: source.code).first)
        let (_, defaults) = SourceScan.arms(of: statement, in: source.code)
        #expect(defaults.isEmpty, "found a wildcard at line(s) \(defaults.map(source.line(at:)))")
    }

    /// A nested switch is a different switch. Its wildcard belongs to it, and
    /// reporting it against the outer one would name the wrong line and the
    /// wrong type.
    @Test("a nested switch keeps its own arms")
    func aNestedSwitchKeepsItsOwnArms() {
        let source = scan("""
            switch action {
            case let .navigationFailed(tab, error):
                switch error.code {
                case 100: report(tab)
                default: break
                }
            case .openTab: open()
            }
            """)

        let statements = SourceScan.switches(in: source.code)
        #expect(statements.count == 2)
        #expect(SourceScan.arms(of: statements[0], in: source.code).defaults.isEmpty)
        #expect(SourceScan.arms(of: statements[1], in: source.code).defaults.count == 1)
    }

    /// The SPI scan lives or dies on this distinction. `ContentBlocking.swift`
    /// carries `_WKContentRuleListAction` in a comment, explaining the SPI it
    /// refused to use — a scan over raw text would report that comment as the
    /// violation it exists to say was avoided, which is the first failure
    /// anybody would delete this file over.
    @Test("a selector in a string is seen and the same name in a comment is not")
    func aSelectorInAStringIsSeenAndTheSameNameInACommentIsNot() {
        let source = scan("""
            // The count would have to come from _WKContentRuleListAction, so
            // there is no count.
            let selector = Selector(("_inspector"))
            """)

        #expect(SourceScan.occurrences(of: "_WK", in: source.codeAndStrings).isEmpty)
        let found = SourceScan.occurrences(of: "_inspector", in: source.codeAndStrings)
        #expect(found.count == 1)
        #expect(found.map(source.line(at:)) == [3])

        // And the older mode still blanks both, which is what keeps every other
        // scan in this file from reading a comment as code.
        #expect(SourceScan.occurrences(of: "_inspector", in: source.code).isEmpty)
    }

    @Test("a hand-written black shadow is found and a hue is not")
    func aHandWrittenBlackShadowIsFoundAndAHueIsNot() {
        let source = scan("""
            Capsule()
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                .shadow(color: palette.base.opacity(0.35), radius: 2, y: 1)
                .shadow(radius: 8)
            """)

        var flagged: [Int] = []
        for offset in SourceScan.callSites(of: "shadow", in: source.code) {
            guard let arguments = SourceScan.arguments(after: offset + 7, in: source.code) else { continue }
            if !arguments.contains("color:") || arguments.spells("black") {
                flagged.append(source.line(at: offset))
            }
        }
        #expect(flagged == [2, 4])
    }

    /// `.toolbar(removing:)` is the one spelling ADR-0014 requires and ADR-0010
    /// permits; every other shape of `.toolbar` is what ADR-0010 forbids.
    @Test("a toolbar is told from the removal of one")
    func aToolbarIsToldFromTheRemovalOfOne() {
        let source = scan("""
            NavigationSplitView { sidebar } detail: { detail }
                .toolbar(removing: .sidebarToggle)
                .toolbar { ToolbarItem { Button("Share") {} } }
            """)

        var flagged: [Int] = []
        for offset in SourceScan.callSites(of: "toolbar", in: source.code) {
            let arguments = SourceScan.arguments(after: offset + 8, in: source.code) ?? ""
            if !arguments.hasPrefix("removing:") { flagged.append(source.line(at: offset)) }
        }
        #expect(flagged == [3])
    }

    /// The window rule, both ways round. A call is found; a signature, a
    /// generic argument and a mention in a comment are not — and those three
    /// are what `TestWindow.swift` and this file are made of, so a scanner that
    /// flagged them would fire on the fix.
    @Test("a window built by hand is found, and a mention of one is not")
    func aWindowBuiltByHandIsFound() throws {
        let source = scan("""
            func hosting() -> NSWindow {
                let known = NSMapTable<NSWindow, Box>.weakToStrongObjects()
                // Not NSWindow(contentRect:) — that is the thing being avoided.
                let window = NSWindow(contentRect: .zero, styleMask: [.titled])
                return window
            }
            """)

        let found = SourceScan.occurrences(of: "NSWindow(", in: source.code)
        #expect(found.map(source.line(at:)) == [4])
    }

    /// The vocabulary is read out of generated code that changes with every
    /// core build, so the read itself is worth one assertion: an empty set here
    /// would make the wildcard check pass over everything.
    @Test("the vocabulary is read out of the generated bindings")
    func theVocabularyIsReadOutOfTheGeneratedBindings() throws {
        let vocabulary = try SourceScan.vocabulary()

        #expect(vocabulary["Action"]?.contains("titleChanged") == true)
        #expect(vocabulary["EngineCommand"]?.contains("createWebView") == true)
        #expect(vocabulary["UiCommand"]?.contains("newTab") == true)
        #expect(vocabulary["Suggestion"]?.contains("switchToTab") == true)

        for (type, variants) in vocabulary {
            #expect(variants.count > 3, "\(type) came back with \(variants.count) variants")
        }
    }
}
