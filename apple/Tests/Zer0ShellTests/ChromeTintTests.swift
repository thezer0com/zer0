import AppKit
import Testing
import Zer0Core

@testable import Zer0Shell

/// The strip at the top of the window wears the page's colour (ADR-0047).
///
/// The rule about *which* colour is the core's and is tested there. What is
/// tested here is the half that only exists on this side: that the ink this
/// shell actually paints stays readable on every colour the core is willing to
/// hand it, and that what the host reports is something the core can read.
///
/// The first of those is the one that rots. The core guarantees a margin
/// against the *extreme* ink — pure white or pure black — because it cannot
/// know what a palette is. The palette then has to stay inside that margin, and
/// nothing but this test notices the day it stops.
@Suite("chrome tint")
struct ChromeTintTests {
    /// WCAG AA for text people read, the same floor `PaletteContrastTests`
    /// holds the rest of the shell to.
    private let readable = 4.5

    /// A core with one tab, ready to be told what colour its page is.
    private func core() -> (Zer0, TabId) {
        let core = Zer0.inMemory(
            firstSpaceName: "Personal",
            dataStoreId: UUID().uuidString,
            capabilities: HostCapabilities(extensionRuntime: false)
        )
        _ = core.dispatch(action: .openTab(space: nil, url: nil, parent: nil))
        return (core, core.snapshot().activeTab!)
    }

    private func tint(
        _ core: Zer0,
        _ tab: TabId,
        theme: [DeclaredColor] = [],
        backgrounds: [String] = [],
        canvas: String? = nil
    ) -> PageTint? {
        _ = core.dispatch(action: .colorsDeclared(
            tab: tab,
            themeColors: theme,
            elementBackgrounds: backgrounds,
            canvasBackground: canvas
        ))
        return core.snapshot().tabs.first { $0.id == tab }?.tint
    }

    private func stated(_ value: String) -> DeclaredColor {
        DeclaredColor(value: value, matchesAppearance: true)
    }

    // MARK: - The ink stays readable

    /// The one that decides whether any of this may ship: a page may declare
    /// any colour at all, including one picked so that our controls vanish.
    ///
    /// Every colour is put through the real core and the resulting tint is
    /// measured against the ink `WindowChrome` would actually paint on it —
    /// the half of the palette the core's `prefersDarkInk` names.
    @Test("the strip's ink is readable on any colour a page can state")
    func theStripsInkIsReadableOnAnyColourAPageCanState() {
        let (core, tab) = self.core()

        // Greys first, and every one of them: a colour the core had to move
        // lands exactly on the edge of what is legible, and a grey is the case
        // where nothing else is helping.
        var swatches: [UInt32] = (0...255).map { UInt32($0) << 16 | UInt32($0) << 8 | UInt32($0) }
        for red in stride(from: 0, through: 255, by: 51) {
            for green in stride(from: 0, through: 255, by: 51) {
                for blue in stride(from: 0, through: 255, by: 51) {
                    swatches.append(UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue))
                }
            }
        }

        for value in swatches {
            let hex = String(format: "#%06x", value)
            guard let tint = tint(core, tab, theme: [stated(hex)]) else {
                Issue.record("\(hex) produced no tint at all")
                continue
            }

            let surface = Swatch(hex: tint.rgb)
            let ink = tint.prefersDarkInk
                ? Design.Palette.light.ink
                : Design.Palette.dark.ink

            let ratio = ink.contrast(against: surface)
            #expect(
                ratio >= readable,
                "\(hex) became \(surface.hex); ink \(ink.hex) reads at \(ratio)"
            )
        }
    }

    /// Both ends, named, because "it works in the middle" is not the claim.
    @Test("a page that declares near-white takes dark ink and near-black takes light")
    func bothExtremesChooseTheirInk() {
        let (core, tab) = self.core()

        #expect(tint(core, tab, theme: [stated("#ffffff")])?.prefersDarkInk == true)
        #expect(tint(core, tab, theme: [stated("#fbfbfd")])?.prefersDarkInk == true)
        #expect(tint(core, tab, theme: [stated("#000000")])?.prefersDarkInk == false)
        #expect(tint(core, tab, theme: [stated("#0d0d12")])?.prefersDarkInk == false)
    }

    // MARK: - The chain, through the real FFI

    @Test("the colour reaches the tab, and each rung answers when the one above it does not")
    func theFallbackChainHoldsEndToEnd() {
        let (core, tab) = self.core()

        #expect(
            tint(core, tab,
                 theme: [stated("#0b3d91")],
                 backgrounds: ["rgb(255, 255, 255)"],
                 canvas: "rgba(255, 255, 255, 1.0000)")?.rgb == 0x0b_3d91
        )
        #expect(
            tint(core, tab,
                 backgrounds: ["rgb(18, 18, 24)"],
                 canvas: "rgba(255, 255, 255, 1.0000)")?.rgb == 0x12_1218
        )
        // The rung that answers for most of the web: neither element declares a
        // background, and only the engine knows the page is nevertheless white.
        #expect(
            tint(core, tab,
                 backgrounds: ["rgba(0, 0, 0, 0)", "rgba(0, 0, 0, 0)"],
                 canvas: "rgba(255, 255, 255, 1.0000)")?.rgb == 0xff_ffff
        )
        #expect(tint(core, tab) == nil)
    }

    /// A tab whose page failed is drawn by us, on our own surface.
    @Test("a page that failed carries no colour")
    func aFailedPageCarriesNoColour() {
        let (core, tab) = self.core()
        _ = tint(core, tab, theme: [stated("#0b3d91")])

        _ = core.dispatch(action: .navigationFailed(
            tab: tab, kind: .hostNotFound, message: "no such host"
        ))

        #expect(core.snapshot().tabs.first { $0.id == tab }?.tint == nil)
    }

    // MARK: - What the host reports

    /// The engine hands back an `NSColor`; the core reads CSS. If those two
    /// ever stop meeting, the rung that answers for most of the web goes quiet
    /// and nothing else says so.
    @Test("what the host serialises is what the core reads back")
    @MainActor
    func theHostsColourSurvivesTheTrip() {
        let (core, tab) = self.core()

        #expect(
            tint(core, tab, canvas: HostedWebView.cssColor(.white))?.rgb == 0xff_ffff
        )
        #expect(
            tint(core, tab, canvas: HostedWebView.cssColor(.black))?.rgb == 0x00_0000
        )
        #expect(
            tint(core, tab, canvas: HostedWebView.cssColor(
                NSColor(srgbRed: 11.0 / 255, green: 61.0 / 255, blue: 145.0 / 255, alpha: 1)
            ))?.rgb == 0x0b_3d91
        )
        // A canvas we could not read is not a colour, and must not become one.
        #expect(HostedWebView.cssColor(nil) == nil)
        #expect(tint(core, tab, canvas: HostedWebView.cssColor(.clear)) == nil)
    }

    /// Everything the script returns came out of a page (ADR-0024). A page that
    /// answers with the wrong shapes should cost us an empty list.
    @Test("a page that answers with nonsense declares nothing")
    @MainActor
    func nonsenseFromAPageIsNotADeclaration() {
        #expect(HostedWebView.themeColors(in: nil).isEmpty)
        #expect(HostedWebView.themeColors(in: "not a list").isEmpty)
        #expect(HostedWebView.themeColors(in: [["value": 42]]).isEmpty)
        #expect(HostedWebView.themeColors(in: [["value": ""]]).isEmpty)
        #expect(HostedWebView.strings(in: [1, 2, 3]).isEmpty)

        // A declaration whose media query could not be evaluated is not one we
        // may claim applies to the appearance we are in.
        let unevaluable = HostedWebView.themeColors(in: [["value": "#fff"]])
        #expect(unevaluable.count == 1)
        #expect(unevaluable[0].matchesAppearance == false)

        // Capped, so a page declaring thousands costs a truncated list.
        let flood = (0..<500).map { _ in ["value": "#fff", "matches": true] as [String: Any] }
        #expect(HostedWebView.themeColors(in: flood).count == 8)
    }
}
