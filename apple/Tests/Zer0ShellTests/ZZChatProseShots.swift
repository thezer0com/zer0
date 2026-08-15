import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Looking at a reply set as prose.
///
/// A harness, not a test of behaviour, and opt-in behind `ZER0_SHOT=1` like
/// every other `ZZ*` file. What it is for: rhythm, indentation and the code
/// panel are the whole job here and none of them is catchable by an assertion.
///
/// **An offscreen render is not the running application.** Accents paint grey
/// unless the environment is forced, and materials do not blur. It catches
/// layout, hierarchy and spacing.
@MainActor
@Suite("chat prose shots")
struct ZZChatProseShots {
    /// One reply carrying every block kind the renderer knows, so a change to
    /// the rhythm shows up against all of them at once.
    static let everything = """
    # A reply with every kind of block

    A paragraph with **bold**, *italic*, `inline code`, ~~struck out~~ and a \
    [link](https://avelino.run) in it, long enough to wrap so the leading of a \
    real passage can be judged rather than guessed at.

    ## A smaller heading

    - a bullet
    - another, with `code` in it
        - one level of nesting
    - back out again

    9. ninth
    10. tenth, so two-digit markers can be seen lining up under one-digit ones

    ```swift
    func greet(_ name: String) -> String {
        "hello, \\(name)"
    }
    ```

    ### The third level, which is body size carrying weight

    > A block quote, which is somebody else's words and reads as an aside.
    >
    > Two paragraphs of it, so the rail can be seen running past the gap.

    A fence with no language:

    ```
    plain, unlabelled
    ```

    ---

    And a last paragraph after the rule.
    """

    /// The same reply, cut where a stream would have got to. Each of these is a
    /// frame somebody really sees.
    static let partials = [
        "opening": "Here is what I found:\n\nThe first thing is that **the a",
        "fence-open": "Try this:\n\n```swift\nfunc greet(_ name: String) -> Str",
        "list-marker": "Three reasons:\n\n- the first one\n- ",
        "heading-empty": "Right.\n\n## ",
    ]

    @Test(
        "every block kind, light and dark",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func everyBlockKind() {
        for dark in [false, true] {
            let shot = Shot(size: CGSize(width: 620, height: 1180)) {
                ScrollView {
                    ChatProse(Self.everything)
                        .padding(Design.Space.loose)
                }
                .background(Design.Palette.background)
                .zer0Palette()
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .key)
            }
            shot.write("prose-everything-\(dark ? "dark" : "light")")
        }
    }

    /// The frames a reader really sees while an answer arrives. What is being
    /// looked for is a fence that is already a panel and a bullet that is
    /// already a bullet — nothing that will change shape under them.
    @Test(
        "a reply that has not finished arriving",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func aReplyStillArriving() {
        for (name, partial) in Self.partials {
            for dark in [false, true] {
                let shot = Shot(size: CGSize(width: 620, height: 220)) {
                    VStack {
                        ChatProse(partial)
                        Spacer()
                    }
                    .padding(Design.Space.loose)
                    .background(Design.Palette.background)
                    .zer0Palette()
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.controlActiveState, .key)
                }
                shot.write("prose-partial-\(name)-\(dark ? "dark" : "light")")
            }
        }
    }

    /// A reply inside the transcript it will really live in, because the column
    /// width and the gutter beside it are half of what the rhythm is judged
    /// against.
    @Test(
        "a reply in the message row it lives in",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func aReplyInTheRowItLivesIn() {
        let browser = BrowserModel(storagePath: nil)
        browser.perform(.openChat)
        let conversation = browser.conversations.last!.id
        browser.send(.sendChatMessage(conversation: conversation, text: "how do I set this up?"))

        for dark in [false, true] {
            let shot = Shot(size: CGSize(width: 720, height: 900)) {
                ScrollView {
                    ChatProse(Self.everything)
                        .padding(.leading, 38)
                        .padding(Design.Space.loose)
                }
                .background(Design.Palette.background)
                .environment(browser)
                .zer0Palette()
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .key)
            }
            shot.write("prose-in-row-\(dark ? "dark" : "light")")
        }
    }
}
