//
//  LotItem.swift
//  PalletAuctionBidTool
//
//  Master entity displayed in the hierarchical lot table.
//

import Foundation
import Observation

/// A liquidation lot (pallet) under evaluation.
///
/// This is a reference type decorated with `@Observable` on purpose: a full analysis
/// run mutates one row at a time (bid scraped -> images downloaded -> items discovered),
/// and struct semantics would force a full re-diff of the master array on every single
/// mutation. With `@Observable` only the changed row re-renders.
@MainActor
@Observable
final class LotItem: Identifiable {

    /// Lifecycle of a single lot inside the "Analyze Auctions" pipeline.
    enum AnalysisState: Equatable {
        case pending
        case analyzing
        case completed
        case failed(String)
        case skipped(String)

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .skipped: true
            case .pending, .analyzing: false
            }
        }

        var label: String {
            switch self {
            case .pending: "Pending"
            case .analyzing: "Analyzing"
            case .completed: "Valuated"
            case .failed(let message): "Failed — \(message)"
            case .skipped(let reason): "Skipped — \(reason)"
            }
        }
    }

    let id: UUID

    // MARK: Scraped fields

    var lotNumber: String
    var currentBid: Double
    var rawDescription: String
    var imageUrls: [URL]

    // MARK: Valuated fields

    var totalRetail: Double
    var totalResale: Double
    var discoveredItems: [DiscoveredItem]

    // MARK: Cheap pre-price
    //
    // The text-only pre-price is a first look: whole-pallet figures from the listing copy alone,
    // no photographs and no line items. It exists so the table can show a provisional *Max bid*
    // while the expensive imaged scan is still queued, and it is superseded — not merged — the
    // moment that scan lands.

    /// Whole-pallet retail guessed from the listing text. `0` until a pre-price runs.
    var provisionalRetail: Double = 0

    /// Whole-pallet resale guessed from the listing text.
    var provisionalResale: Double = 0

    /// The pre-price's own confidence, which picks the ceiling used before a valuation exists.
    var provisionalConfidence: DiscoveredItem.Confidence = .low

    /// One line of reasoning the pre-price offered, shown in the expanded row.
    var prePriceRationale: String = ""

    /// When the pre-price ran; `nil` while the row has never been pre-priced.
    var prePricedAt: Date?

    /// `true` while a pre-price request is in flight. Lets the row say "evaluating" during the
    /// cheap pass instead of looking untouched until the answer lands.
    var isPrePricing: Bool = false

    // MARK: Provenance / bookkeeping

    /// Short title scraped from the card. Kept separate from `rawDescription` so the
    /// expanded view can show the unedited text the model was given.
    let title: String

    /// Link to the lot detail page, when the card exposed one.
    let detailURL: URL?

    /// 1-based result page the lot was scraped from (pagination provenance).
    let sourcePage: Int

    /// `true` while the auction still takes bids on this lot. A lot the site has marked **sold**
    /// stays in the table — it is part of the auction's history and an operator scanning a catalog
    /// wants to see it — but it is flagged in the **Active** column and skipped by the all-lots
    /// passes, so no tokens are spent appraising something that can no longer be won.
    var isActive: Bool

    /// The site's own short status label for the lot, when the card exposed one.
    var statusText: String

    var analysisState: AnalysisState = .pending
    var analyzedAt: Date?

    /// Number of images that were actually sent to the model for this lot.
    var imagesAnalyzed: Int = 0

    /// How many model passes produced the current valuation. DeepSeek reads the listing text first
    /// and the photographs second, so a DeepSeek lot reports `2`; Gemini answers in one pass.
    /// `0` means "never scanned".
    var passesUsed: Int = 0

    /// What the model saw in each photograph, when the scan read the lot photograph by photograph
    /// (`LotPhotoScan`). Empty for a single-pass appraisal, which is every scan that predates the
    /// thorough path.
    ///
    /// Kept on the row rather than folded into `discoveredItems` because it is *evidence*: a line
    /// item says what the pallet is worth, a reading says which photograph that came off — and that
    /// is the claim an operator checking a figure against a picture is actually checking.
    var readings: [PhotoReading] = []

    /// The step a thorough scan is on right now: `photograph 7 of 12 read: 4 product group(s)`.
    ///
    /// Set by the coordinator from the scan's own reports (see `PhotoScanReport.rowNote`) so a row
    /// being read photograph by photograph says *where* it is instead of sitting on one spinner for
    /// the whole gallery. Empty for the single-pass path, which has no steps to report.
    var photoScanNote: String = ""

    init(
        id: UUID = UUID(),
        lotNumber: String,
        currentBid: Double,
        rawDescription: String,
        imageUrls: [URL],
        title: String = "",
        detailURL: URL? = nil,
        sourcePage: Int = 1,
        isActive: Bool = true,
        statusText: String = "",
        totalRetail: Double = 0,
        totalResale: Double = 0,
        discoveredItems: [DiscoveredItem] = []
    ) {
        self.id = id
        self.lotNumber = lotNumber
        self.currentBid = currentBid
        self.rawDescription = rawDescription
        self.imageUrls = imageUrls
        self.title = title
        self.detailURL = detailURL
        self.sourcePage = sourcePage
        self.isActive = isActive
        self.statusText = statusText
        self.totalRetail = totalRetail
        self.totalResale = totalResale
        self.discoveredItems = discoveredItems
    }

    /// Builds the UI model from a scraper result.
    convenience init(scraped: ScrapedLot) {
        self.init(
            lotNumber: scraped.resolvedLotNumber,
            currentBid: scraped.currentBid,
            rawDescription: scraped.rawDescription,
            imageUrls: scraped.imageURLs,
            title: scraped.title,
            detailURL: scraped.detailURL,
            sourcePage: scraped.sourcePage,
            isActive: scraped.isActive,
            statusText: scraped.statusText
        )
    }

    // MARK: Derived values used by the table

    /// `true` once the site has marked the lot sold — the inverse of `isActive`, spelled for the
    /// call sites that read better that way (`row.isSold`).
    var isSold: Bool { !isActive }

    /// Best available short label for the row headline.
    var displayName: String { title.isEmpty ? rawDescription : title }

    /// `true` once the row has at least one imaged line item.
    var hasValuation: Bool { !discoveredItems.isEmpty }

    /// `true` once a photograph-by-photograph scan produced readings for this lot.
    var hasReadings: Bool { !readings.isEmpty }

    /// The readings rolled up for the row and the console (`12 photo(s) · 34 group(s) · 9 id(s)`).
    var readingSummary: PhotoReadingSummary { readings.photoSummary }

    /// `true` once a text-only pre-price has run.
    var isPrePriced: Bool { prePricedAt != nil }

    /// `true` when the pre-price produced a figure worth showing. These numbers are superseded by a
    /// valuation, which is why both the table and `bidTarget(using:)` prefer `hasValuation` first.
    var hasProvisionalValue: Bool { prePricedAt != nil && provisionalResale > 0 }

    /// `true` when the numbers the table is printing came from a pre-price rather than a valuation:
    /// what the row renders in italics, and what makes its **Max bid** provisional.
    var showsProvisionalNumbers: Bool { hasProvisionalValue && !hasValuation }

    /// Retail the table should print: the scanned total once a valuation exists, otherwise the
    /// pre-price's guess.
    var displayRetail: Double { hasValuation ? totalRetail : provisionalRetail }

    /// Resale the table should print, on the same rule as `displayRetail`.
    var displayResale: Double { hasValuation ? totalResale : provisionalResale }

    /// Resale value minus the live bid — the number a bidder actually cares about.
    var projectedProfit: Double { totalResale - currentBid }

    /// Profit over the current bid, e.g. `1.42` == +142%. `nil` when the bid is still $0.
    var returnOnBid: Double? {
        guard currentBid > 0 else { return nil }
        return projectedProfit / currentBid
    }

    /// Resale as a fraction of retail for the whole pallet. `nil` when retail is unknown.
    var resaleToRetailRatio: Double? {
        guard totalRetail > 0 else { return nil }
        return totalResale / totalRetail
    }

    var itemCount: Int { discoveredItems.count }

    /// Weakest confidence found in the lot — drives the row's confidence badge.
    var lowestConfidence: DiscoveredItem.Confidence {
        discoveredItems.map(\.confidenceLevel).max { $0.sortRank < $1.sortRank } ?? .low
    }

    /// Strongest confidence found in the lot.
    var highestConfidence: DiscoveredItem.Confidence {
        discoveredItems.map(\.confidenceLevel).min { $0.sortRank < $1.sortRank } ?? .high
    }

    // MARK: Pipeline mutations

    /// Records the listing's own description, read from the lot's page.
    ///
    /// A card only carries a teaser — "Pallet of General Merchandise" — so the text a prompt is built
    /// from is taken from the page's description column when the page can be read, and the card's
    /// teaser is what stands when it cannot. Empty text is read as "the page had none" and changes
    /// nothing: a page read that yields no description must not blank the copy the card *did* carry,
    /// because that text is what the expanded row shows and what a later retry starts from.
    ///
    /// - Returns: `true` when the description actually changed.
    @discardableResult
    func applyLotPageDescription(_ text: String) -> Bool {
        let cleaned = text.condensedWhitespace
        guard !cleaned.isEmpty, cleaned != rawDescription else { return false }
        rawDescription = cleaned
        return true
    }

    /// Applies a successful valuation pass, recomputing the pallet totals.
    ///
    /// The pre-price is retired here: the scanned numbers replace it outright, so nothing on the
    /// row is left looking provisional once a real valuation exists.
    ///
    /// `readings` is what a thorough scan saw photograph by photograph; the single-pass path has none
    /// and passes none, which is why it defaults to empty rather than being required. Either way the
    /// live scan note is cleared: the scan is done, so the row must not keep saying "photograph 7 of
    /// 12".
    func applyValuation(
        _ items: [DiscoveredItem],
        imagesAnalyzed: Int,
        passes: Int = 1,
        readings: [PhotoReading] = []
    ) {
        discoveredItems = items
        totalRetail = items.reduce(0) { $0 + $1.retailValue }
        totalResale = items.reduce(0) { $0 + $1.resaleValue }
        self.imagesAnalyzed = imagesAnalyzed
        passesUsed = passes
        self.readings = readings
        photoScanNote = ""
        analyzedAt = .now
        analysisState = .completed
        clearPrePrice()
    }

    /// Records a cheap text-only pre-price. Deliberately does *not* touch `discoveredItems`,
    /// `totalRetail`, `totalResale` or `analysisState`: a pre-priced lot is still unscanned, and the
    /// row's badge and profit column must keep saying so.
    func applyPrePrice(_ estimate: PrePriceEstimate) {
        provisionalRetail = estimate.retail
        provisionalResale = estimate.resale
        provisionalConfidence = estimate.confidence
        prePriceRationale = estimate.rationale
        prePricedAt = .now
        isPrePricing = false
    }

    /// Drops a stale pre-price, e.g. before re-running a lot from scratch.
    func clearPrePrice() {
        provisionalRetail = 0
        provisionalResale = 0
        provisionalConfidence = .low
        prePriceRationale = ""
        prePricedAt = nil
        isPrePricing = false
    }

    /// Flags the start of a pre-price request.
    func markPrePricing() {
        isPrePricing = true
    }

    /// Clears the in-flight flag without disturbing any pre-price already recorded.
    func clearPrePricing() {
        isPrePricing = false
    }

    func markAnalyzing() {
        analysisState = .analyzing
        // The last scan's step note is stale the moment a new scan starts, and a row that opened on
        // "photograph 12 of 12" would read as finished while its gallery was still being read.
        photoScanNote = ""
    }

    /// Records the step a thorough scan is on, so the row says where in the gallery it is.
    func markPhotoScanStep(_ note: String) {
        photoScanNote = note
    }

    func markFailed(_ message: String) {
        analysisState = .failed(message)
        photoScanNote = ""
        analyzedAt = .now
    }

    func markSkipped(_ reason: String) {
        analysisState = .skipped(reason)
        photoScanNote = ""
        analyzedAt = .now
    }

    /// Clears a previous valuation pass so a lot can be re-run on its own.
    func resetValuation() {
        discoveredItems = []
        totalRetail = 0
        totalResale = 0
        imagesAnalyzed = 0
        passesUsed = 0
        readings = []
        photoScanNote = ""
        analyzedAt = nil
        analysisState = .pending
        clearPrePrice()
    }

    /// Immutable snapshot handed to the non-isolated valuation service.
    var valuationSubject: ValuationSubject {
        ValuationSubject(
            lotNumber: lotNumber,
            title: title,
            rawDescription: rawDescription,
            currentBid: currentBid,
            imageURLs: imageUrls,
            detailURL: detailURL
        )
    }
}
