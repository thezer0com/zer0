import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Looking at what a conversation wears.
///
/// Two claims, and neither can be settled by an assertion. **A sidebar holding
/// several threads has to be readable** — the defect this replaced was three
/// identical `C` tiles, and "the hosts differ" is not the same statement as "a
/// hand lands on the right row". And **the browser's own mark has to survive
/// badge size**: ADR-0040's first named regression is somebody scaling the
/// canonical drawing down to sixteen pixels and shipping a plain O, and nothing
/// errors when that happens. The only way to know is to look at the pixels.
///
/// Opt-in behind `ZER0_SHOT=1`, like every `ZZ*` file.
@MainActor
@Suite("conversation badge shots")
struct ZZConversationBadgeShots {
    /// The chat host does nothing, so a staged transcript stays exactly what was
    /// fed to it instead of growing a "no provider configured" notice at
    /// whatever moment the run loop is pumped.
    private final class SilentChatHost: ChatHost {
        func startReply(
            conversation _: ConversationId,
            message _: MessageId,
            transcript _: [Message],
            tools _: [ToolDescriptor]
        ) {}
        func cancelReply(message _: MessageId) {}
        func runToolCall(conversation _: ConversationId, invocation _: ToolInvocation) {}
        func cancelToolCall(call _: ToolCallId) {}
        func listTools(server _: String?) {}
    }

    private func staged() -> BrowserModel {
        let model = BrowserModel(storagePath: nil)
        model.engine.chat = SilentChatHost()
        return model
    }

    /// Chosen so the board answers the question it exists for: marks of
    /// different shapes and weights, so "does the row read" is not being decided
    /// by one lucky favicon.
    private static let sites: [(url: String, title: String)] = [
        ("https://github.com/avelino/zer0", "avelino/zer0: a WebKit browser"),
        ("https://news.ycombinator.com/item?id=1", "Show HN: zer0"),
        ("https://avelino.run/posts/", "Thiago Avelino — posts"),
    ]

    /// A tab on each page, a conversation about each, and one about nothing.
    ///
    /// Real: the page tab commits, ⌘E goes through the core, and the chat tab is
    /// whatever the reducer opened.
    private func seed(_ model: BrowserModel, icons: Bool) -> [ConversationId] {
        var threads: [ConversationId] = []
        for site in Self.sites {
            model.send(.openTab(space: nil, url: nil, parent: nil))
            let page = model.snapshot.activeTab!
            model.send(.navigationCommitted(tab: page, url: site.url))
            model.send(.titleChanged(tab: page, title: site.title))
            model.send(.navigationFinished(tab: page))
            model.perform(.openChat)
            threads.append(model.conversations.last!.id)
        }

        // And one started from the command bar, about no page in particular.
        model.send(.openTab(space: nil, url: nil, parent: nil))
        model.perform(.openChat)
        threads.append(model.conversations.last!.id)

        if icons {
            let store = model.snapshot.spaces[0].dataStoreId
            for site in Self.sites {
                guard let host = URL(string: site.url)?.host() else { continue }
                model.send(.iconFetched(dataStoreId: store, host: host, bytes: Self.icon(for: host)))
            }
        }
        return threads
    }

    /// A stand-in favicon per host: a filled square in a hue of its own, which
    /// is enough to answer "is this row distinguishable" without the board
    /// depending on the network being up.
    ///
    /// **PNG, and that is not incidental.** The core checks magic bytes and
    /// refuses anything that is not one of the eight formats it names — a board
    /// seeded with `tiffRepresentation` draws letters and looks exactly like the
    /// icon path being broken.
    private static func icon(for host: String) -> Data {
        let hue = Double(abs(host.hashValue % 360)) / 360
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(hue: hue, saturation: 0.75, brightness: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 2, y: 2, width: 28, height: 28), xRadius: 7, yRadius: 7)
            .fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - The sidebar

    /// The sidebar at the width it really has, and at two window heights.
    ///
    /// A view photographed at its own width is not a screen that has been looked
    /// at — but a sidebar's width *is* the window's, since it does not stretch.
    /// What does change with the window is how much of it is list, so the height
    /// is the author's window and the smallest the app opens at.
    @Test(
        "the sidebar with several conversations in it",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theSidebarWithConversations() {
        for icons in [false, true] {
            let model = staged()
            _ = seed(model, icons: icons)

            for window in [("tall", CGSize(width: 280, height: 1960)),
                           ("short", CGSize(width: 280, height: 520))] {
                for dark in [false, true] {
                    let shot = Shot(size: window.1) {
                        Sidebar()
                            .frame(width: window.1.width, height: window.1.height)
                            .environment(model)
                            .zer0Palette()
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.controlActiveState, .key)
                    }
                    shot.write(
                        "badge-sidebar-\(icons ? "icons" : "letters")"
                            + "-\(window.0)-\(dark ? "dark" : "light")"
                    )
                }
            }
        }
    }

    // MARK: - The subject bar

    /// Both states of the bar, because the badge replaced the glyph that used to
    /// carry the second one.
    ///
    /// A thread whose page is not open grows a line saying so, and the bar goes
    /// from one line to two around a mark that did not change height. That is
    /// the layout worth looking at: the fact is still stated, in words, and the
    /// question is whether the bar still reads as one object.
    @Test(
        "the chat page's subject bar carrying the page's own mark",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theSubjectBar() {
        for state in ["open", "closed"] {
            let icons = true
            let model = staged()
            let threads = seed(model, icons: icons)
            let thread = threads[0]
            let tab = model.snapshot.tabs.last!.id

            if state == "closed" {
                let page = model.snapshot.tabs.first { $0.url == Self.sites[0].url }!
                model.send(.closeTab(tab: page.id))
            }

            for window in [("wide", CGSize(width: 1340, height: 1960)),
                           ("narrow", CGSize(width: 600, height: 520))] {
                for dark in [false, true] {
                    let shot = Shot(size: window.1) {
                        ChatPage(tab: tab, addressed: thread)
                            .frame(width: window.1.width, height: window.1.height)
                            .environment(model)
                            .zer0Palette()
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.controlActiveState, .key)
                    }
                    shot.write(
                        "badge-subject-\(state)-\(window.0)-\(dark ? "dark" : "light")"
                    )
                }
            }
        }
    }

    // MARK: - The mark, at the sizes the badge really draws it at

    /// The two masters rasterised at exactly the pixel counts a badge uses, then
    /// magnified so a person can see what a person cannot see at 16 pixels.
    ///
    /// **Rasterised through Core Graphics rather than through the harness on
    /// purpose.** `cacheDisplay` photographs at the window's backing scale, so a
    /// SwiftUI badge asked to pretend it is on a 1x display still comes back at
    /// 2x and the question — how does this look in sixteen device pixels —
    /// would go unanswered. This draws into a bitmap of exactly that many
    /// pixels, which is the thing itself.
    ///
    /// The board is a pair, because the pair is the argument: the canonical
    /// drawing beside the hinted one at the same size. If the two look the same,
    /// the routing is not doing anything.
    @Test(
        "the mark at badge size, both masters, magnified",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theMarkAtBadgeSize() {
        for pixels in [16, 32, 64] {
            for hinted in [false, true] {
                for onWhite in [true, false] {
                    let rep = Self.raster(hinted: hinted, pixels: pixels, onWhite: onWhite)
                    Shot.write(
                        Self.magnified(rep, by: 24),
                        "mark-\(pixels)px-\(hinted ? "hinted" : "canonical")"
                            + "-\(onWhite ? "light" : "dark")"
                    )
                }
            }
        }
    }

    /// One master, filled, at exactly `pixels` square.
    private static func raster(hinted: Bool, pixels: Int, onWhite: Bool) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let box = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        (onWhite ? NSColor.white : NSColor.black).setFill()
        box.fill()
        (onWhite ? NSColor.black : NSColor.white).setFill()
        NSBezierPath(cgPath: Zer0Mark(hinted: hinted).path(in: box).cgPath).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Nearest-neighbour, so what is magnified is the pixels and not a guess at
    /// what was between them.
    private static func magnified(_ rep: NSBitmapImageRep, by factor: Int) -> NSBitmapImageRep {
        let side = rep.pixelsWide * factor
        let out = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        for y in 0 ..< side {
            for x in 0 ..< side {
                out.setColor(
                    rep.colorAt(x: x / factor, y: y / factor) ?? .clear,
                    atX: x, y: y
                )
            }
        }
        return out
    }
}
