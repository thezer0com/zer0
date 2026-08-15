import AppKit
import SwiftUI
import Testing

@testable import Zer0Shell

// The machine that builds this has no screen anyone can look at, and a
// judgement about whether something is beautiful — or whether it moves at all —
// cannot be made from source. This is how a view is looked at: rasterised into
// a window that is never ordered onto a display, and, for motion, sampled across
// every layout pass so the record itself says whether anything travelled.
//
// Everything here is a harness, not a test of behaviour. `scripts/check.sh`
// refuses to let any `ZZ*.swift` case run without `ZER0_SHOT=1`, because these
// pump the run loop for seconds at a time and would starve the timing suites.

/// A view in a window, rasterisable on demand.
///
/// The window is real — borderless, off every screen, never ordered front onto
/// a display — because SwiftUI does not run an animation for a hosting view
/// that has no window to drive it. `orderFrontRegardless` is what starts the
/// clock; on a locked or headless Mac nothing is shown by it.
@MainActor
final class Shot {
    let hosting: NSHostingView<AnyView>
    private let window: NSWindow

    init(size: CGSize, @ViewBuilder content: () -> some View) {
        let frame = CGRect(origin: .zero, size: size)
        hosting = NSHostingView(rootView: AnyView(content()))
        hosting.frame = frame

        window = testWindow(frame, styleMask: [.borderless])
        window.contentView = hosting
        // Far off any real display, so a machine with a screen shows nothing.
        window.setFrameOrigin(CGPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        settle()
    }

    deinit {
        // `window` is main-actor-isolated state on a main-actor class; closing
        // it from deinit is not, so the reference is handed over first.
        let window = window
        Task { @MainActor in window.close() }
    }

    /// Let SwiftUI lay out and paint, without advancing far enough to matter to
    /// an animation.
    func settle() {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// Advance the run loop, which is what makes an animation tick.
    func advance(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The window's contents, right now.
    func frame() -> NSBitmapImageRep {
        hosting.layoutSubtreeIfNeeded()
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// One region of the window, rasterised on its own.
    ///
    /// **A probe that samples in a loop must ask for this rather than
    /// `frame()`.** `frame()` photographs the whole window: at 900 × 620 that is
    /// about a megapixel and a sample costs little enough that sixty of them fit
    /// inside a third-of-a-second animation. At 1340 × 1960 it is ten and a half
    /// million pixels, `cacheDisplay` takes longer than the curve does, and the
    /// composer's travel was recorded as two positions — start and end — which
    /// is indistinguishable from a cut. The animation was fine; the instrument
    /// had stopped being able to see it (AGENTS.md).
    ///
    /// `rect` is in the view's own points. The rep that comes back is in its own
    /// coordinates, so a `y` read off it is relative to `rect.minY`.
    func frame(in rect: CGRect) -> NSBitmapImageRep {
        hosting.layoutSubtreeIfNeeded()
        let rep = hosting.bitmapImageRepForCachingDisplay(in: rect)!
        hosting.cacheDisplay(in: rect, to: rep)
        return rep
    }

    /// Write the current contents somewhere a person can open them.
    @discardableResult
    func write(_ name: String) -> String {
        Shot.write(frame(), name)
    }

    @discardableResult
    static func write(_ rep: NSBitmapImageRep, _ name: String) -> String {
        let directory = ProcessInfo.processInfo.environment["ZER0_SHOT_DIR"]
            ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        let path = (directory as NSString).appendingPathComponent("\(name).png")
        let data = rep.representation(using: .png, properties: [:])!
        try? data.write(to: URL(fileURLWithPath: path))
        print("shot: \(path)")
        return path
    }
}

/// What a view reported about its own geometry, over time.
///
/// **What this is for, and what it is not for.** It answers questions about
/// *layout*: how tall a panel ended up, whether it is the same height with two
/// rows as with eight. It does not answer "did it travel", and that was found
/// out the hard way: a `.scale` or `.offset` transition is a render transform
/// and does not touch layout, so this recorder reported the command bar at one
/// position for the whole of its arrival — exactly as uninformative as the
/// bitmaps. `ZZMotionShots` carries the full account.
@MainActor
@Observable
final class Track {
    private(set) var samples: [CGRect] = []

    func record(_ rect: CGRect) {
        // Layout runs more often than it changes, so only a different rect is a
        // sample. Otherwise counting samples counts run-loop turns.
        if let last = samples.last, last.equalTo(rect) { return }
        samples.append(rect)
    }
}

extension View {
    /// Report this view's frame in global coordinates, every time layout says
    /// it changed.
    ///
    /// The space was a parameter, defaulted to `.global` and never passed
    /// anything else. `CoordinateSpaceProtocol` is an existential and not
    /// `Sendable`, so capturing one in the `@Sendable` closure
    /// `onGeometryChange` takes is a concurrency error under Swift 6 — one that
    /// only became visible when the package started building with
    /// `-warnings-as-errors`. A parameter with one caller and one value is not
    /// worth an existential.
    func tracked(by track: Track) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { track.record($0) }
    }
}

// There was a `slowed()` here, wrapping the view in
// `.transaction { $0.animation = $0.animation?.speed(1 / 12) }`, on the theory
// that a curve lasting a third of a second needs stretching before a run loop
// can sample it. **It did nothing**, and that is worth leaving written down:
// `.transaction` modifies the transaction on its way *down* the tree, and
// `.animation(_:value:)` — which is what every animation in this shell resolves
// to — replaces it further down. The harness was slowing a value that was then
// discarded, and the measured curves ran at full speed the whole time.
//
// Nothing needed it. `onGeometryChange` fires on every layout pass, so a
// `Track` collects the entire curve however coarsely the run loop is pumped;
// only the pixel sampling cares about rate, and it samples at 10ms.

extension NSBitmapImageRep {
    /// The colour at a point, in the bitmap's own coordinates (origin top left).
    func colour(x: Int, y: Int) -> NSColor {
        colorAt(x: x, y: y) ?? .clear
    }

    /// How far down the image the first row that is not the background colour
    /// sits, scanning at a given column. `nil` means the column is empty.
    ///
    /// The cheap way to ask "where is the top edge of that panel" without
    /// knowing anything about what is drawn inside it.
    func firstRow(inColumn x: Int, unlike background: NSColor, tolerance: CGFloat = 0.06) -> Int? {
        (0 ..< pixelsHigh).first { y in
            !colour(x: x, y: y).isNear(background, tolerance: tolerance)
        }
    }

    /// The bounding box of everything inside `region` that is not `background`.
    ///
    /// How a frame is asked "where is the thing" without being told what the
    /// thing is drawn as. Sampled on a grid rather than per pixel: a bounding
    /// box to the nearest two points is plenty to tell travel from a jump, and
    /// per-pixel over a thousand frames is minutes of nothing.
    func ink(
        in region: CGRect,
        unlike background: NSColor,
        tolerance: CGFloat = 0.05,
        step: Int = 2
    ) -> CGRect? {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        let x0 = max(0, Int(region.minX)), x1 = min(pixelsWide, Int(region.maxX))
        let y0 = max(0, Int(region.minY)), y1 = min(pixelsHigh, Int(region.maxY))

        for y in stride(from: y0, to: y1, by: step) {
            for x in stride(from: x0, to: x1, by: step) where
                !colour(x: x, y: y).isNear(background, tolerance: tolerance)
            {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension NSColor {
    func isNear(_ other: NSColor, tolerance: CGFloat) -> Bool {
        guard let a = usingColorSpace(.deviceRGB), let b = other.usingColorSpace(.deviceRGB) else {
            return false
        }
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
            && abs(a.alphaComponent - b.alphaComponent) < tolerance
    }
}
