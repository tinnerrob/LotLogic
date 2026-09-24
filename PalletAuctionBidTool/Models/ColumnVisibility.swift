//
//  ColumnVisibility.swift
//  PalletAuctionBidTool
//
//  Which of the table's data columns are drawn.
//
//  Deliberately free of SwiftUI *and* of Foundation — nothing here needs either — so the rule that
//  decides whether a column may be hidden, and the encoding the choice survives a relaunch through,
//  are compiled into the offline harness: see `Tools/free-tier-harness`.
//

/// The operator's column choice: which of `LotColumnKey`'s data columns the table draws.
///
/// The *hidden* set is what gets stored, not the visible one, and that direction is deliberate: a
/// column added in a later version then arrives visible instead of invisible-until-someone-finds-it,
/// which is how a new column should behave. An empty set — draw everything — is the shipped state.
///
/// The fixed chrome is not in `LotColumnKey` at all, so it can never be hidden: the disclosure
/// chevron and the **Eval** / **Price** / **Open** buttons are how a lot gets priced and looked at,
/// and a table without them would have no way to ask for a figure.
struct ColumnVisibility: Equatable, Sendable {

    /// The columns the table does not draw. Never all of them: see `set(_:visible:)`.
    private(set) var hiddenColumns: Set<LotColumnKey>

    /// Every column drawn: the shipped state, and what **Show all columns** restores.
    static let all = ColumnVisibility()

    init(hiddenColumns: Set<LotColumnKey> = []) {
        // A stored choice that hides *every* data column is not a layout, it is an empty table under
        // a header nothing in the UI could climb back out of. Read as "never configured" instead.
        self.hiddenColumns = hiddenColumns.count < LotColumnKey.allCases.count ? hiddenColumns : []
    }

    /// Reads the persisted names.
    ///
    /// Unknown names are dropped rather than rejected: a stored choice outlives the code that wrote
    /// it, so a renamed or removed column leaves a stale name behind, and a preference file should
    /// never be able to wedge the table.
    init(storedNames: [String]?) {
        self.init(hiddenColumns: Set((storedNames ?? []).compactMap(LotColumnKey.init(rawValue:))))
    }

    /// The persisted form: raw names in table order, so the stored value stays readable in
    /// `defaults read` and a diff between two choices is legible.
    var storedNames: [String] {
        LotColumnKey.allCases.filter { hiddenColumns.contains($0) }.map(\.rawValue)
    }

    /// Whether this column is drawn.
    func isVisible(_ key: LotColumnKey) -> Bool { !hiddenColumns.contains(key) }

    /// The columns being drawn, in table order.
    var visibleColumns: [LotColumnKey] { LotColumnKey.allCases.filter { isVisible($0) } }

    /// How many columns are drawn.
    var visibleCount: Int { LotColumnKey.allCases.count - hiddenColumns.count }

    /// How many are hidden — what the toolbar's gear counts back to the operator.
    var hiddenCount: Int { hiddenColumns.count }

    /// `true` while the table is not showing everything.
    var isHidingAnything: Bool { !hiddenColumns.isEmpty }

    /// Whether this column's switch may be moved: bringing a hidden column back always works, taking
    /// a visible one away does not when it is the last. Every column is individually optional, but a
    /// table of no columns is not a view of the data.
    ///
    /// One rule, used twice: the menu disables the switch with it, and `set(_:visible:)` enforces it
    /// for any other caller.
    func canToggle(_ key: LotColumnKey) -> Bool {
        !isVisible(key) || visibleCount > 1
    }

    /// Hides or shows one column, subject to `canToggle(_:)`.
    mutating func set(_ key: LotColumnKey, visible: Bool) {
        guard canToggle(key) else { return }
        if visible {
            hiddenColumns.remove(key)
        } else {
            hiddenColumns.insert(key)
        }
    }

    /// Draws every column again.
    mutating func showAll() {
        hiddenColumns.removeAll()
    }
}
