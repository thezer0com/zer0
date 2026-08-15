import Testing
import SwiftUI
import Zer0Core

@testable import Zer0Shell

/// Dragging a tab in the sidebar.
///
/// Two halves, and only two. Where the pointer is when it lets go is geometry
/// and belongs here; what the list *becomes* belongs to the core, so these
/// check that the shell asks the right question and then renders the answer it
/// was given rather than one of its own.
@MainActor
struct TabDragTests {
    private func model() -> BrowserModel { BrowserModel(storagePath: nil) }

    /// Three tabs open in the first space, in order.
    private func threeTabs(_ m: BrowserModel) throws -> (TabId, TabId, TabId) {
        let first = try #require(m.snapshot.activeTab)
        m.send(.openTab(space: nil, url: nil, parent: nil))
        let second = try #require(m.snapshot.activeTab)
        m.send(.openTab(space: nil, url: nil, parent: nil))
        let third = try #require(m.snapshot.activeTab)
        return (first, second, third)
    }

    private func rows(_ ids: [TabId], kind: TabKind, space: SpaceId) -> [TabRowFrame] {
        ids.enumerated().map { index, id in
            TabRowFrame(
                tab: id,
                kind: kind,
                space: space,
                minY: CGFloat(index) * 24,
                maxY: CGFloat(index + 1) * 24
            )
        }
    }

    // MARK: - Where the pointer says it goes

    @Test("a drop over the top half of a row lands above that row")
    func dropsAboveTheRowUnderThePointer() throws {
        let m = model()
        let (first, second, third) = try threeTabs(m)
        let space = m.snapshot.activeSpace
        let dragged = try #require(m.snapshot.tabs.first { $0.id == third })

        let slot = try #require(TabDrop.slot(
            at: 30,
            dragging: dragged,
            rows: rows([first, second, third], kind: .today, space: space),
            sections: [TabSectionFrame(kind: .today, minY: 0, maxY: 72)],
            activeSpace: space
        ))

        // 30 is inside the second row and above its middle, so the tab lands
        // between the first and the second — never "on" the second, which is
        // the ambiguity a highlight would leave behind.
        #expect(slot.before == second)
        #expect(slot.y == 24)
        #expect(!slot.crossesSpace)
    }

    @Test("a drop past the last row lands at the end of the section")
    func dropsAtTheEnd() throws {
        let m = model()
        let (first, second, third) = try threeTabs(m)
        let space = m.snapshot.activeSpace
        let dragged = try #require(m.snapshot.tabs.first { $0.id == third })

        let slot = try #require(TabDrop.slot(
            at: 200,
            dragging: dragged,
            rows: rows([first, second, third], kind: .today, space: space),
            sections: [TabSectionFrame(kind: .today, minY: 0, maxY: 72)],
            activeSpace: space
        ))

        #expect(slot.before == nil)
        // The dragged row is discounted, so the line sits under the second and
        // not under the hole the third left behind.
        #expect(slot.y == 48)
    }

    @Test("a drop in another section is a drop in that section")
    func sectionDecidesTheKind() throws {
        let m = model()
        let (first, _, _) = try threeTabs(m)
        let space = m.snapshot.activeSpace
        let dragged = try #require(m.snapshot.tabs.first { $0.id == first })

        let slot = try #require(TabDrop.slot(
            at: 130,
            dragging: dragged,
            rows: [],
            sections: [
                TabSectionFrame(kind: .favorite, minY: 0, maxY: 60),
                TabSectionFrame(kind: .pinned, minY: 100, maxY: 160),
                TabSectionFrame(kind: .today, minY: 200, maxY: 260),
            ],
            activeSpace: space
        ))

        #expect(slot.kind == .pinned)
    }

    @Test("a pointer in the gap between two sections belongs to the nearer one")
    func gapsResolveToTheNearestSection() throws {
        let m = model()
        let (first, _, _) = try threeTabs(m)
        let space = m.snapshot.activeSpace
        let dragged = try #require(m.snapshot.tabs.first { $0.id == first })
        let sections = [
            TabSectionFrame(kind: .favorite, minY: 0, maxY: 60),
            TabSectionFrame(kind: .today, minY: 100, maxY: 160),
        ]

        // A heading sits in that gap, and a drag that loses its target while
        // crossing one reads as broken.
        let high = try #require(TabDrop.slot(
            at: 70, dragging: dragged, rows: [], sections: sections, activeSpace: space
        ))
        let low = try #require(TabDrop.slot(
            at: 95, dragging: dragged, rows: [], sections: sections, activeSpace: space
        ))

        #expect(high.kind == .favorite)
        #expect(low.kind == .today)
    }

    @Test("a favorite dropped above a favorite from another space follows it there")
    func favoritesSpanSpaces() throws {
        let m = model()
        let personal = m.snapshot.activeSpace
        let mine = try #require(m.snapshot.activeTab)
        m.createSpace(named: "Work")
        let work = m.snapshot.activeSpace
        let theirs = try #require(m.snapshot.activeTab)
        m.activate(space: personal)

        let dragged = try #require(m.snapshot.tabs.first { $0.id == mine })
        let slot = try #require(TabDrop.slot(
            at: 5,
            dragging: dragged,
            rows: [
                TabRowFrame(tab: theirs, kind: .favorite, space: work, minY: 0, maxY: 24)
            ],
            sections: [TabSectionFrame(kind: .favorite, minY: 0, maxY: 24)],
            activeSpace: personal
        ))

        // Favorites is the one list that shows more than one space at a time,
        // so landing above a row from another space is landing in that space —
        // and that has to be said before the pointer is released.
        #expect(slot.space == work)
        #expect(slot.crossesSpace)
    }

    // MARK: - What the core makes of it

    @Test("a drop reorders the list, and the order is the core's")
    func dropReorders() throws {
        let m = model()
        let (first, second, third) = try threeTabs(m)
        let space = m.snapshot.activeSpace

        m.drop(third, into: TabDropSlot(
            kind: .today, space: space, before: first, y: 0, crossesSpace: false
        ))

        #expect(m.snapshot.tabs.map(\.id) == [third, first, second])
    }

    @Test("a drop into the Pinned section pins the tab")
    func dropPins() throws {
        let m = model()
        let tab = try #require(m.snapshot.activeTab)
        let space = m.snapshot.activeSpace

        m.drop(tab, into: TabDropSlot(
            kind: .pinned, space: space, before: nil, y: 0, crossesSpace: false
        ))

        #expect(m.snapshot.tabs.first { $0.id == tab }?.kind == .pinned)
        #expect(m.pinnedTabs().map(\.id) == [tab])
        #expect(m.todayTabs().isEmpty)
    }

    @Test("a drop on another space moves the tab into it")
    func dropCrossesSpaces() throws {
        let m = model()
        let personal = m.snapshot.activeSpace
        let tab = try #require(m.snapshot.activeTab)
        m.createSpace(named: "Work")
        let work = m.snapshot.activeSpace
        m.activate(space: personal)

        m.drop(tab, into: TabDropSlot(
            kind: .today, space: work, before: nil, y: 0, crossesSpace: true
        ))

        #expect(m.snapshot.tabs.first { $0.id == tab }?.space == work)
        #expect(!m.todayTabs().contains { $0.id == tab }, "it left the space it was in")
    }

    @Test("a drop above a row that is not there still lands somewhere")
    func danglingAnchorClamps() throws {
        let m = model()
        let (first, second, third) = try threeTabs(m)
        let space = m.snapshot.activeSpace

        // The list can change underneath a drag: a tab archived mid-gesture
        // leaves the pointer aimed at a row that no longer exists. That must
        // be an ordinary drop, not a lost one.
        m.drop(first, into: TabDropSlot(
            kind: .today, space: space, before: 9999, y: 0, crossesSpace: false
        ))

        #expect(m.snapshot.tabs.map(\.id) == [second, third, first])
    }
}
