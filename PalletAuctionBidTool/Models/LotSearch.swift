//
//  LotSearch.swift
//  PalletAuctionBidTool
//
//  Filter behind the lot table's search field.
//
//  Deliberately SwiftUI-free so the matching rules are compiled into the offline harness and
//  checked without a window: see `Tools/free-tier-harness`.
//

import Foundation

/// The lot table's search: the lot number first, the listing copy second.
///
/// A number is what an operator has in hand — a bid sheet, a printed page — so the query is
/// compared against the lot number with case and punctuation removed ("lot #142", "142" and "L142"
/// all find lot 142), and only then against the title and the scraped text. A row that matches
/// neither is hidden, which is what makes the field a finder rather than a highlighter.
///
/// `@MainActor` because `LotItem` is: the table is the only caller and it already runs there.
@MainActor
enum LotSearch {

    /// `true` when `lot` matches `query`. An empty query matches everything, so the field's default
    /// state is "no filter" rather than "nothing found".
    static func matches(_ lot: LotItem, query: String) -> Bool {
        let needle = normalize(query)
        guard !needle.isEmpty else { return true }
        if normalize(lot.lotNumber).contains(needle) { return true }
        return normalize("\(lot.displayName) \(lot.rawDescription)").contains(needle)
    }

    /// Applies a query to the table's rows, preserving their order.
    static func filter(_ lots: [LotItem], query: String) -> [LotItem] {
        guard isFiltering(query) else { return lots }
        return lots.filter { matches($0, query: query) }
    }

    /// `true` when the query actually narrows the table. The toolbar uses this to decide whether to
    /// show a match count and a clear button.
    static func isFiltering(_ query: String) -> Bool { !normalize(query).isEmpty }

    /// Lowercased with everything that is not a letter or a digit dropped, so "Lot 142" and
    /// "lot#142" compare equal.
    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
