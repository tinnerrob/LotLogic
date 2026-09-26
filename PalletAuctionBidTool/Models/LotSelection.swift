//
//  LotSelection.swift
//  PalletAuctionBidTool
//
//  Which lots the operator has checked in the table, and the rules that fill and empty them.
//
//  Deliberately SwiftUI-free, like `ColumnWidths`, so the header's box, the toolbar's count and the
//  two **Eval selected** / **Price selected** buttons all read *this* rather than each keeping their
//  own set — and so the offline harness can check the rules without a window: see
//  `Tools/free-tier-harness`.
//

import Foundation

/// The checked rows, as one value.
///
/// A checkbox per row is easy; what needs deciding is everything around it — what the header's own
/// box shows while only some rows are checked, which way its next click goes, and what happens to a
/// check when the board beneath it is replaced by a new run. Those questions are about the *set* of
/// rows rather than about any one of them, so they live here, and the box in the header, the count in
/// the toolbar and the two batch buttons cannot then disagree about what is checked.
struct LotSelection: Equatable, Sendable {

    /// How much of a set of rows is checked: what the header's box is drawn from, and what decides
    /// which way its next click goes.
    enum Scope: Equatable, Sendable {

        /// Nothing checked.
        case none

        /// Some of the set, but not all of it — the header's box reads as mixed.
        case some

        /// Every row in the set.
        case all

        /// What a click on the select-all box does next: a box that is not fully on *fills*, and one
        /// that is empties. `.some` therefore reads as "not finished yet", which is the direction that
        /// loses no work — an operator who has picked three rows by hand and then reaches for the
        /// header wants the other nine, not an empty table.
        var selectsOnClick: Bool { self != .all }
    }

    private(set) var ids: Set<UUID>

    init(ids: Set<UUID> = []) { self.ids = ids }

    var isEmpty: Bool { ids.isEmpty }

    var count: Int { ids.count }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Checks one row, or unchecks it when it was already checked — what a row's own box does.
    mutating func toggle(_ id: UUID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    /// How much of `rows` is checked.
    ///
    /// `rows` is what the table is *drawing*, not the whole board: a search narrows the table, and the
    /// box over it should speak for the rows under it — clicking it while a search stands must not
    /// check rows the operator cannot see.
    func scope(of rows: [UUID]) -> Scope {
        // An empty table is not "all checked": there is nothing to be all of, and a filled box over
        // no rows would be a promise the view cannot keep.
        guard !rows.isEmpty else { return .none }
        let checked = rows.reduce(0) { $0 + (ids.contains($1) ? 1 : 0) }
        if checked == 0 { return .none }
        return checked == rows.count ? .all : .some
    }

    /// Checks every one of `rows`, leaving whatever else was checked alone — the table menu's
    /// **Select all**, which unlike the header's box always fills and never clears.
    mutating func selectAll(_ rows: [UUID]) {
        ids.formUnion(rows)
    }

    /// Clears every one of `rows` and nothing else — the table menu's **Deselect all**.
    mutating func deselectAll(_ rows: [UUID]) {
        ids.subtract(Set(rows))
    }

    /// Checks every one of `rows`, or clears them all when they were all checked already — the
    /// header's box, whose single click has to answer for both directions.
    ///
    /// Rows outside `rows` are left exactly as they were, so a selection made before a search is not
    /// thrown away by a click during it — and, from the other side, the box cannot silently reach past
    /// what is on screen.
    mutating func toggleAll(_ rows: [UUID]) {
        if scope(of: rows) == .all {
            deselectAll(rows)
        } else {
            selectAll(rows)
        }
    }

    /// Drops ids that are no longer on the board.
    ///
    /// A run replaces the table outright, and a check left behind on a lot that is gone would keep
    /// **Price selected** alive with nothing behind it — which is the shape of bug that reads as a
    /// broken button rather than as a stale selection.
    mutating func prune(to present: [UUID]) {
        ids.formIntersection(present)
    }
}
