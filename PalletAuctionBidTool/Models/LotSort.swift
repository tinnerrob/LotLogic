//
//  LotSort.swift
//  PalletAuctionBidTool
//
//  Sort orders for the master lot table.
//

import Foundation

/// The field the lot table is ordered by.
///
/// Deliberately SwiftUI-free so the ordering rules are compiled into the offline harness and
/// checked without a window: see `Tools/free-tier-harness`.
enum LotSort: String, CaseIterable, Identifiable, Sendable {

    /// The order the scraper found the lots in — the row order itself, not a value, so the only
    /// order that ignores `SortDirection`.
    case scrapeOrder

    /// Lot number / SKU, compared the way a human reads it (`Lot 2` sorts before `Lot 10`).
    case identifier

    /// Listing title, falling back to the scraped description.
    case description

    case currentBid
    case retail
    case resale
    case profit
    case roi

    /// Highest bid worth placing, derived from resale and the lot's confidence — the *Max bid*
    /// column, ordered so the richest opportunities are found without reading every row.
    case maxBid

    var id: String { rawValue }

    /// Column / menu title.
    var label: String {
        switch self {
        case .scrapeOrder: "Scrape order"
        case .identifier: "Lot / SKU"
        case .description: "Description"
        case .currentBid: "Bid"
        case .retail: "Retail"
        case .resale: "Resale"
        case .profit: "Profit"
        case .roi: "ROI"
        case .maxBid: "Max bid"
        }
    }

    /// `false` only for `scrapeOrder`, which has no direction to flip.
    var isDirectional: Bool { self != .scrapeOrder }

    /// Direction applied when the operator first picks this field: money and margins are most
    /// useful largest-first, everything else reads naturally ascending.
    var initialDirection: SortDirection {
        switch self {
        case .scrapeOrder, .identifier, .description, .currentBid: .ascending
        case .retail, .resale, .profit, .roi, .maxBid: .descending
        }
    }
}

/// Which way a `LotSort` runs.
enum SortDirection: String, CaseIterable, Identifiable, Sendable {

    case ascending
    case descending

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ascending: "Ascending"
        case .descending: "Descending"
        }
    }

    var systemImage: String {
        switch self {
        case .ascending: "arrow.up"
        case .descending: "arrow.down"
        }
    }

    var toggled: SortDirection { self == .ascending ? .descending : .ascending }
}

private extension ComparisonResult {
    /// Reverses the ordering while leaving equality alone.
    var flipped: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}

/// Applies a `LotSort` + `SortDirection` to the master list.
///
/// Two rules the table depends on:
/// * every order is a total order — ties break on the original scrape position, so two lots with
///   the same value never swap places between renders;
/// * a value the lot does not have yet (`returnOnBid` before anything is scanned and bid) sorts
///   **last in both directions**, so "no data" is never mistaken for the best or worst ROI.
///
/// `@MainActor` because `LotItem` is: the table is the only caller and it already runs there.
@MainActor
enum LotOrdering {

    static func sorted(
        _ lots: [LotItem],
        by sort: LotSort,
        direction: SortDirection,
        policy: BidTargetPolicy = .standard
    ) -> [LotItem] {
        guard sort.isDirectional else { return lots }
        return lots.enumerated()
            .sorted { left, right in
                switch compare(left.element, right.element, by: sort, direction: direction, policy: policy) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: left.offset < right.offset
                }
            }
            .map(\.element)
    }

    /// Compares one field of two lots; exposed so the harness can pin the rules above.
    static func compare(
        _ left: LotItem,
        _ right: LotItem,
        by sort: LotSort,
        direction: SortDirection,
        policy: BidTargetPolicy = .standard
    ) -> ComparisonResult {
        switch sort {
        case .scrapeOrder:
            .orderedSame
        case .identifier:
            ordered(left.lotNumber, right.lotNumber, direction: direction)
        case .description:
            ordered(left.displayName, right.displayName, direction: direction)
        case .currentBid:
            ordered(left.currentBid, right.currentBid, direction: direction)
        case .retail:
            // The *displayed* money is what is ordered, so a pre-priced row sorts by the figure the
            // operator can see rather than dropping to the bottom until it is scanned.
            ordered(left.displayRetail, right.displayRetail, direction: direction)
        case .resale:
            ordered(left.displayResale, right.displayResale, direction: direction)
        case .profit:
            ordered(left.projectedProfit, right.projectedProfit, direction: direction)
        case .roi:
            ordered(left.returnOnBid, right.returnOnBid, direction: direction)
        case .maxBid:
            ordered(
                left.bidTarget(using: policy)?.maxBid,
                right.bidTarget(using: policy)?.maxBid,
                direction: direction
            )
        }
    }

    /// `localizedStandardCompare` is the "finder-ish" comparison: case-insensitive, and numerals
    /// inside the string are compared by value.
    private static func ordered(_ left: String, _ right: String, direction: SortDirection) -> ComparisonResult {
        let result = left.localizedStandardCompare(right)
        return direction == .ascending ? result : result.flipped
    }

    private static func ordered(_ left: Double, _ right: Double, direction: SortDirection) -> ComparisonResult {
        guard left != right else { return .orderedSame }
        let isAscending = left < right
        return isAscending == (direction == .ascending) ? .orderedAscending : .orderedDescending
    }

    /// Missing values last, whichever direction is selected.
    private static func ordered(_ left: Double?, _ right: Double?, direction: SortDirection) -> ComparisonResult {
        switch (left, right) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedDescending
        case (_, nil): .orderedAscending
        case (let left?, let right?): ordered(left, right, direction: direction)
        }
    }
}
