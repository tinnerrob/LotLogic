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

    /// How many units of this product the pallet holds, when the answer said — `0` when it did not.
    ///
    /// `retailValue` and `resaleValue` stay whole-line-item totals (rule 5 of the prompt is
    /// explicit), so this is what turns a line into a per-unit price for the operator — and what
    /// makes a pallet of sixty cheap items comparable with a pallet of six expensive ones.
    var quantity: Int

    /// 1-based positions of the photographs this line was read from, in gallery order.
    ///
    /// Only ever filled by a thorough scan (`LotPhotoScan`), where the price came from specific
    /// frames rather than from a gallery as a whole. Empty is the honest answer for a single-pass
    /// appraisal: nothing there knew which picture a figure came from.
    var photos: [Int]

    init(
        id: UUID = UUID(),
        itemName: String,
        confidence: String = Confidence.medium.rawValue,
        retailValue: Double = 0,
        resaleValue: Double = 0,
        notes: String = "",
        evidence: String = "",
        quantity: Int = 0,
        photos: [Int] = []
    ) {
        self.id = id
        self.itemName = itemName
        self.confidence = confidence
        self.retailValue = retailValue
        self.resaleValue = resaleValue
        self.notes = notes
        self.evidence = evidence
        self.quantity = quantity
        self.photos = photos
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

    /// `12 unit(s)` — the quantity, when the appraisal named one.
    var quantityText: String? {
        guard quantity > 1 else { return nil }
        return "\(quantity) unit(s)"
    }

    /// Per-unit retail, when there is both a quantity and a figure to divide by.
    var unitRetailValue: Double? {
        guard quantity > 1, retailValue > 0 else { return nil }
        return retailValue / Double(quantity)
    }

    /// Per-unit resale, on the same rule as `unitRetailValue`.
    var unitResaleValue: Double? {
        guard quantity > 1, resaleValue > 0 else { return nil }
        return resaleValue / Double(quantity)
    }

    /// `$35.00 ea retail · $18.00 ea resale` — what one of them goes for, so a line's total can be
    /// argued with.
    var unitPricePhrase: String? {
        var parts: [String] = []
        if let unitRetailValue { parts.append("\(unitRetailValue.currencyText) ea retail") }
        if let unitResaleValue { parts.append("\(unitResaleValue.currencyText) ea resale") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `photograph 3, 7` — which frames this line was read from, when a thorough scan knows.
    var photoSourceText: String? {
        guard !photos.isEmpty else { return nil }
        let positions = photos.sorted().map(String.init).joined(separator: ", ")
        return photos.count == 1 ? "photograph \(positions)" : "photographs \(positions)"
    }

    /// Resale expressed as a fraction of retail. `nil` when retail is unknown.
    var resaleRatio: Double? {
        guard retailValue > 0 else { return nil }
        return resaleValue / retailValue
    }
}
