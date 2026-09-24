//
//  LotNumber.swift
//  PalletAuctionBidTool
//
//  Turns whatever a scraped card exposed into the lot number an operator recognizes.
//

import Foundation

/// Cleans up the identifier a scraped card handed over.
///
/// Auction sites expose a lot's number several ways, and the one this type exists for is the worst
/// of them: the card element's own `id`. On plenty of layouts that attribute is a *DOM address*
/// rather than a number — `ItemMain19002`, `item-row-88`, `data-key="ItemMain19002"` — so a column
/// fed straight from it reads `ItemMain19002` where the printed catalogue, the bid sheet and the
/// deep link all say `19002`. Everything downstream (the table, the run log, the prompt sent to the
/// model) then repeats the element address as though it were the lot's name.
///
/// The rules are deliberately conservative: a value is only rewritten when it is *exactly* a known
/// wrapper word followed by digits, so a real SKU such as `ABC123` or `L208` is left alone.
///
/// Pure string work on purpose — no SwiftUI, no WebKit — so the free-tier harness can test every
/// rule. `ScraperScript` mirrors the same two rules in JavaScript for the values it reads in the
/// page, which keeps the page-side extraction clean before Swift ever sees it.
enum LotNumber {

    /// Words sites glue in front of the digits when they mint an element id. Only consulted when a
    /// value is exactly one of these plus digits (`ItemMain19002`), never inside a longer word.
    static let domWrappers: Set<String> = [
        "itemmain", "item", "itemrow", "itemcard", "itemlisting",
        "lot", "lotrow", "lotcard", "lotitem", "lotmain",
        "auction", "auctionitem", "pallet", "palletcard",
        "product", "productcard", "listing", "listingcard",
        "card", "row", "grid", "tile", "main", "wrapper", "container", "sku"
    ]

    /// Labels a site prints in front of the number (`Lot #142`, `Item No. 88`, `SKU: 55-2`).
    private static let labels = [
        "lot", "item", "sku", "pallet", "auction", "product", "listing", "unit", "stock", "ref"
    ]

    /// Separators that may sit between a label and the number, or between the words of a wrapper.
    private static let separators: Set<Character> = [" ", "\t", ".", ":", "#", "-", "_", "/"]

    /// Words that may sit between a label and the number (`Item No. 88`, `Lot Number 142`). Longest
    /// first, so `Number` is not consumed by the `num` alternative and left as `ber 142`.
    private static let fillers = ["number", "code", "ref", "num", "no", "id"]

    /// The value the UI, the log and the model should use: the scraped string with its label or its
    /// DOM wrapper removed. Returns `""` when nothing usable is left.
    static func normalize(_ raw: String) -> String {
        let text = raw.condensedWhitespace
        guard !text.isEmpty else { return "" }
        let labelled = strippingLabel(text)
        if let bare = unwrappingDOMId(labelled) { return bare }
        return labelled
    }

    /// Pulls the lot number out of a detail-page address, for cards whose own attributes held only
    /// an opaque id. Reads the last all-numeric token of the path or query, unwrapping a wrapper
    /// first — `…/lot/19002`, `…/item/ItemMain19002`, `?itemid=19002` all yield `19002`.
    static func fromURL(_ url: URL?) -> String? {
        guard let url else { return nil }
        var tokens = url.pathComponents
        if let query = url.query {
            tokens += query.split(separator: "&").flatMap { $0.split(separator: "=") }.map(String.init)
        }

        for token in tokens.reversed() {
            let candidate = unwrappingDOMId(normalize(token)) ?? normalize(token)
            if !candidate.isEmpty, candidate.allSatisfy(\.isNumber) { return candidate }
        }
        return nil
    }

    /// `Item No. 88` -> `88`, `Lot #142` -> `142`. Returns the input untouched when no label stands
    /// alone in front of the value — `ItemMain19002` is one word, not a label plus a number.
    private static func strippingLabel(_ text: String) -> String {
        let lowered = text.lowercased()

        for label in labels where lowered.hasPrefix(label) {
            var rest = text.dropFirst(label.count)
            let beforeSeparator = rest.count
            rest = rest.drop { separators.contains($0) }
            var wasSeparated = rest.count < beforeSeparator

            for filler in fillers where rest.lowercased().hasPrefix(filler) {
                var trimmed = rest.dropFirst(filler.count)
                let beforeFiller = trimmed.count
                trimmed = trimmed.drop { separators.contains($0) }
                if !trimmed.isEmpty, beforeFiller != trimmed.count { rest = trimmed; wasSeparated = true }
                break
            }

            guard wasSeparated else { continue }
            let candidate = String(rest).condensedWhitespace
            if !candidate.isEmpty { return candidate }
        }
        return text
    }

    /// `ItemMain19002` -> `19002`, `lot-card-88` -> `88`. `nil` for anything else, including a bare
    /// number and a genuine SKU whose prefix is not a known wrapper.
    private static func unwrappingDOMId(_ text: String) -> String? {
        guard let firstDigit = text.firstIndex(where: \.isNumber) else { return nil }
        let word = text[text.startIndex..<firstDigit]
            .filter { !separators.contains($0) }
            .lowercased()
        let digits = text[firstDigit...]

        guard domWrappers.contains(word), !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return String(digits)
    }
}
