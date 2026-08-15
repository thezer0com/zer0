import SwiftUI
import Zer0Core

/// One row of the sidebar's tab list, as it is laid out on screen.
struct TabRowFrame: Equatable {
    let tab: TabId
    let kind: TabKind
    let space: SpaceId
    let minY: CGFloat
    let maxY: CGFloat

    var midY: CGFloat { (minY + maxY) / 2 }
}

/// The rows of one section, as a band. The header is deliberately not part of
/// it: a pointer in the gap between two sections belongs to whichever is
/// nearer, and pretending the gap belongs to one of them would make the top of
/// a list unreachable.
struct TabSectionFrame: Equatable {
    let kind: TabKind
    let minY: CGFloat
    let maxY: CGFloat
}

/// Where a drag lands if it is let go right now.
struct TabDropSlot: Equatable {
    let kind: TabKind
    let space: SpaceId
    /// The row the tab goes above. `nil` is the end of the section.
    let before: TabId?
    /// Where the insertion line is drawn.
    let y: CGFloat
    /// Whether this takes the tab out of the space it is in. Per ADR-0007 a
    /// web view cannot change data store, so the page is rebuilt and its
    /// back/forward history goes with it — which is worth saying before the
    /// pointer is released, not after.
    let crossesSpace: Bool
}

/// Turning a pointer position into a drop target.
///
/// Geometry, so it is the shell's job. What the order *becomes* is not: the
/// slot is handed to the core as "this group, above this row", and the core
/// answers with the order.
enum TabDrop {
    static func slot(
        at y: CGFloat,
        dragging tab: BrowserTab,
        rows: [TabRowFrame],
        sections: [TabSectionFrame],
        activeSpace: SpaceId
    ) -> TabDropSlot? {
        guard let section = section(at: y, in: sections) else { return nil }

        // The dragged row is excluded: it is the hole being moved, not a
        // landmark to aim at.
        let candidates = rows
            .filter { $0.kind == section.kind && $0.tab != tab.id }
            .sorted { $0.minY < $1.minY }

        let anchor = candidates.first { y < $0.midY }

        // Favorites is the one list that spans spaces, so the row a tab lands
        // above is also what decides which space it lands in. Pinned and Today
        // only ever show the space you are in, so they answer for themselves.
        let space: SpaceId = switch section.kind {
        case .favorite: anchor?.space ?? tab.space
        case .pinned, .today: activeSpace
        }

        return TabDropSlot(
            kind: section.kind,
            space: space,
            before: anchor?.tab,
            y: anchor?.minY ?? candidates.last?.maxY ?? section.minY,
            crossesSpace: space != tab.space
        )
    }

    /// The section a position belongs to: the one holding it, else the nearest.
    ///
    /// Nearest rather than nothing, because the pointer spends real time in the
    /// gaps — over a heading, above the first row, past the last one — and a
    /// drag that loses its target there reads as broken.
    private static func section(
        at y: CGFloat,
        in sections: [TabSectionFrame]
    ) -> TabSectionFrame? {
        if let hit = sections.first(where: { y >= $0.minY && y < $0.maxY }) { return hit }
        return sections.min { distance(from: y, to: $0) < distance(from: y, to: $1) }
    }

    private static func distance(from y: CGFloat, to section: TabSectionFrame) -> CGFloat {
        if y < section.minY { return section.minY - y }
        if y > section.maxY { return y - section.maxY }
        return 0
    }
}

/// What a drag looks like at this instant.
///
/// Preview, all of it. The order it implies is never applied here; on release
/// the slot is handed to the core and the answer is rendered.
///
/// One object rather than five `@State` flags because they are one fact and
/// always change together — and because a `Sidebar` handed one can be drawn
/// mid-drag without a pointer, which is the only way to look at a gesture
/// without performing it.
@MainActor
@Observable
final class TabDragState {
    var tab: BrowserTab?
    /// In the sidebar's coordinate space.
    var pointer: CGPoint = .zero
    /// Where it lands in the list. `nil` while the space bar has the drop.
    var slot: TabDropSlot?
    /// The space chip under the pointer.
    var space: SpaceId?
    /// Set by Esc, so the gesture does not start over while the button is
    /// still down.
    var cancelled = false

    var isActive: Bool { tab != nil }

    func clear() {
        tab = nil
        slot = nil
        space = nil
    }
}

/// The line drawn where the tab will land.
///
/// A line rather than a highlight on the row underneath the pointer, because a
/// highlighted row leaves the person guessing between "above this" and "below
/// this" — which is exactly the question a drop has to answer before they
/// commit to it.
struct TabInsertionLine: View {
    /// Set when the drop leaves the space the tab is in. The line says where it
    /// is going by name, because that move costs the page its history and a
    /// bare line would not have warned anyone.
    var destination: String?

    var body: some View {
        Capsule()
            .fill(.tint)
            .frame(height: Design.Stroke.insertion)
            .shadow(color: .accentColor.opacity(0.5), radius: Design.Space.hair)
            // The pill rides on the line as an overlay rather than beside it in
            // a stack. In a stack the pill is the taller view, so the stack is
            // as tall as the pill and the line ends up centred against *it* —
            // half a row below where it was asked to be, drawn across the first
            // row of the section instead of in the seam above it. An overlay
            // does not contribute height, so the line stays on the seam whether
            // it is carrying a name or not.
            .overlay(alignment: .trailing) {
                if let destination {
                    Text(destination)
                        .font(Design.Text.micro.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, Design.Space.tight)
                        .padding(.vertical, Design.Space.hair / 2)
                        .background(Capsule().fill(.tint))
                        .fixedSize()
                }
            }
    }
}

/// What an empty section offers a drag: somewhere to aim.
///
/// It only exists mid-drag. Dropping a tab under "Pinned" is how anyone would
/// expect to pin one, and a heading that is not on screen cannot be aimed at.
struct TabDropWell: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
            .strokeBorder(
                .tint.opacity(0.35),
                style: StrokeStyle(
                    lineWidth: Design.Stroke.hairline,
                    dash: [Design.Space.hair, Design.Space.hair]
                )
            )
            .frame(height: Design.Space.loose)
    }
}
