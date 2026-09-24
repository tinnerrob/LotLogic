//
//  DiscoveredItem.swift
//  PalletAuctionBidTool
//
//  Leaf node of the valuation hierarchy: LotItem (pallet) -> DiscoveredItem (product).
//

import Foundation

/// A single physical product that the valuation engine believes is inside a lot.
///
/// This is a value type on purpose: a completed valuation pass can be copied into the
/// UI, exported to CSV or cached without aliasing surprises, and it crosses actor
/// boundaries (network tasks -> `@MainActor` UI) as a `Sendable` value.
struct DiscoveredItem: Identifiable, Codable, Hashable, Sendable {

    /// Stable identity so SwiftUI can diff the nested table rows.
    var id: UUID

    /// Human readable product name inferred from the image and/or the lot description.
    var itemName: String

    /// Self-reported model confidence. Constrained by the shared response schema to `High`, `Med` or `Low`.
    var confidence: String

    /// Estimated in-store retail price of the item when new.
    var retailValue: Double

    /// Estimated realistic resale price a reseller can achieve for the item.
    var resaleValue: Double

    /// Short justification of the market logic behind the two numbers above.
    var notes: String

    /// What the identification and the price actually rest on, quoted from the lot's photographs:
    /// the label wording, the digits under a barcode, the model or part number, a printed price.
    ///
    /// This is the difference between "candles, 24-pack — $180" and "candles, 24-pack — $180
    /// (label reads 'Yankee Candle 22 oz · UPC 609032993551')": the first is a guess a category
    /// average cannot be argued with, the second is a product the operator can check against the
    /// photograph, and re-price by hand if the model read a digit wrong. Empty when nothing legible
    /// was found, which is itself information — the row then says the price rests on the shape of
    /// the goods alone.
    var evidence: String

    init(
        id: UUID = UUID(),
        itemName: String,
        confidence: String = Confidence.medium.rawValue,
        retailValue: Double = 0,
        resaleValue: Double = 0,
        notes: String = "",
        evidence: String = ""
    ) {
        self.id = id
        self.itemName = itemName
        self.confidence = confidence
        self.retailValue = retailValue
        self.resaleValue = resaleValue
        self.notes = notes
        self.evidence = evidence
    }

    /// The confidence vocabulary the model is constrained to (mirrored in
    /// `LotValuationPrompt.itemsSchema`).
    enum Confidence: String, Codable, CaseIterable, Sendable {
        case high = "High"
        case medium = "Med"
        case low = "Low"

        /// Normalises whatever the model (or a cache) produced into a known value.
        init(rawText: String) {
            switch rawText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "high", "h", "very high", "certain", "confident":
                self = .high
            case "low", "l", "very low", "guess", "uncertain", "speculative":
                self = .low
            default:
                self = .medium
            }
        }

        /// Sorts strongest confidence first in the nested table.
        var sortRank: Int {
            switch self {
            case .high: 0
            case .medium: 1
            case .low: 2
            }
        }
    }

    /// Typed view of `confidence` for sorting / colouring.
    var confidenceLevel: Confidence { Confidence(rawText: confidence) }

    /// `true` when the engine returned usable numbers for this line item.
    var isPriced: Bool { retailValue > 0 || resaleValue > 0 }

    /// Resale expressed as a fraction of retail. `nil` when retail is unknown.
    var resaleRatio: Double? {
        guard retailValue > 0 else { return nil }
        return resaleValue / retailValue
    }
}
