//
//  ScrapedLot.swift
//  PalletAuctionBidTool
//
//  Transport entity exchanged with the injected JavaScript and the valuation service.
//

import Foundation

/// Raw entity produced by `AuctionScraperService` before it becomes a `LotItem`.
///
/// The JSON keys match exactly what the injected script emits from the DOM, so the
/// decoder here *is* the contract between JavaScript and Swift.
struct ScrapedLot: Identifiable, Codable, Hashable, Sendable {

    var lotNumber: String
    var title: String
    var rawDescription: String

    /// Untouched bid string scraped from the card, e.g. `"Current Bid: $1,275.50"`.
    /// Kept verbatim so `PriceParsing` can handle the many shapes auction sites use.
    var bidText: String

    var imageURLStrings: [String]
    var detailURLString: String?
    var sourcePage: Int

    /// `true` when the card carried the site's own sold marker (see `soldTextPattern` in
    /// `ScrapeProfile`). A sold lot is still scraped — it is what the auction's history looks like —
    /// but it is not biddable, so the table flags it and the bulk passes skip it.
    var isSold: Bool = false

    /// The site's own short status label (`"SOLD"`, `"Closed"`, …) when the card exposed one.
    var statusText: String = ""

    var id: String { resolvedLotNumber }

    /// `true` while the lot is still open for bidding: everything the operator can act on.
    var isActive: Bool { !isSold }

    /// First amount found in `bidText`, or `0` when the card showed no price yet.
    var currentBid: Double { PriceParsing.firstNumber(in: bidText) ?? 0 }

    var imageURLs: [URL] { imageURLStrings.compactMap { URL(string: $0) } }

    var detailURL: URL? { detailURLString.flatMap { URL(string: $0) } }

    /// Text the model is allowed to reason about, in descending order of usefulness.
    var titleOrDescription: String {
        let title = title.condensedWhitespace
        let description = rawDescription.condensedWhitespace
        if !title.isEmpty, title != description { return "\(title) — \(description)" }
        return title.isEmpty ? description : title
    }

    /// The lot number everything downstream should show and reason about.
    ///
    /// Three sources, best first: what the card exposed (cleaned of the site's label or DOM
    /// wrapper — see `LotNumber`), then the number in the detail page's own address, and only last
    /// a content hash. Without the middle step a card whose `id` was all the page offered would
    /// reach the table as an element address (`ItemMain19002`) or as an opaque `AUTO-…` tag, and the
    /// operator would have no way to tie the row back to the lot they are bidding on.
    var resolvedLotNumber: String {
        let cleaned = LotNumber.normalize(lotNumber)
        if !cleaned.isEmpty { return cleaned }
        if let fromPage = LotNumber.fromURL(detailURL) { return fromPage }
        return shortFallbackIdentifier
    }

    /// Identifier used when the page never exposed a lot number.
    var shortFallbackIdentifier: String {
        let seed = imageURLStrings.first ?? titleOrDescription
        guard !seed.isEmpty else { return "unknown-lot" }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "AUTO-%08X", UInt32(truncatingIfNeeded: hash))
    }

    /// What makes two cards the same lot: the lot's own page when the card exposed one, and only
    /// otherwise the number.
    ///
    /// The address is the better key because it is the thing that is actually unique. Two cards that
    /// print the same number but link to *different* pages are two lots — a number the site reuses, or
    /// one the extractor inferred — and keying on the number alone retired the second, which is how a
    /// hundred-lot board came back holding ninety-nine. The duplication this exists to catch is one
    /// lot read twice as the walk crosses pages, and that lot has one page: walking a listing that
    /// repeats a tile across a page boundary still yields one row. The query and the fragment are
    /// dropped, so the same page linked two ways is still one page.
    var dedupeKey: String {
        guard let detailURLString, !detailURLString.isEmpty else { return "number:\(resolvedLotNumber)" }
        guard let url = URL(string: detailURLString) else { return detailURLString }
        let address = (url.host() ?? "") + url.path
        return address.isEmpty ? detailURLString : address
    }

    /// `true` when the card carried enough signal to be worth a Gemini call.
    var isAnalyzable: Bool {
        !imageURLStrings.isEmpty || !titleOrDescription.isEmpty
    }

    var subject: ValuationSubject {
        ValuationSubject(
            lotNumber: resolvedLotNumber,
            title: title,
            rawDescription: rawDescription,
            currentBid: currentBid,
            imageURLs: imageURLs,
            detailURL: detailURL
        )
    }
}

/// Immutable, `Sendable` description of what should be appraised.
///
/// Keeps the valuation services decoupled from the `@MainActor` UI model: services take
/// this snapshot instead of touching `LotItem`.
struct ValuationSubject: Hashable, Sendable {
    var lotNumber: String
    var title: String
    var rawDescription: String
    var currentBid: Double
    var imageURLs: [URL]
    var detailURL: URL?
}

extension ValuationSubject {
    /// The same lot with a different set of photographs.
    ///
    /// Used when a lot's own page has been read: the page's gallery replaces the card's thumbnails,
    /// which are only ever a preview of it. An empty list is read as "nothing was found" and leaves
    /// the subject untouched, so a failed page read degrades to the card rather than to no images.
    func withImages(_ urls: [URL]) -> ValuationSubject {
        guard !urls.isEmpty else { return self }
        var copy = self
        copy.imageURLs = urls
        return copy
    }

    /// The same lot with the listing's own description text.
    ///
    /// Used when a lot's own page has been read: a card carries a teaser ("Pallet of General
    /// Merchandise") while the page's description column carries what the lot actually holds — brands,
    /// model numbers, counts, condition wording — which is the text a prompt should be built from.
    /// Empty text is read as "the page had none" and leaves the card's copy alone.
    func withDescription(_ text: String) -> ValuationSubject {
        let cleaned = text.condensedWhitespace
        guard !cleaned.isEmpty else { return self }
        var copy = self
        copy.rawDescription = cleaned
        return copy
    }
}
