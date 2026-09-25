//
//  PhotoReading.swift
//  PalletAuctionBidTool
//
//  What the model saw in ONE photograph — the unit of work a thorough scan is built from.
//
//  A single-pass valuation asks one question about a whole gallery ("what is in this pallet?") and
//  the answer has to average over every frame at once. A thorough scan asks a smaller question once
//  per photograph instead — "what does *this* frame show?" — keeps each answer as one of these, and
//  only then asks the aggregation pass to reconcile them into the pallet's line items (see
//  `LotPhotoScan`). The reason for the split is that a reading is *evidence*: it names the product
//  groups in a specific frame, with where in that frame each one sits, its packaging and condition,
//  the number of units visible **from that angle**, and the label wording that was legible in it. A
//  line item built that way can be checked against a picture; an average over forty frames cannot.
//

import Foundation

/// One product group as a single photograph shows it.
///
/// Every field is a literal observation rather than a conclusion about the pallet: `quantity` is what
/// is visible in this frame (three photographs of the same six cartons each report six, and the
/// aggregation pass is the one that decides six is the pallet's count), and the prices are per unit
/// so that a stack seen from two sides cannot be paid for twice.
struct PhotoObject: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity so the reading list can diff its rows.
    var id: UUID

    /// The product, named as precisely as the photograph supports: brand, product line, size and
    /// pack count when they are legible, e.g. `Energizer MAX AA alkaline batteries, 24-pack`.
    var name: String

    /// Brand on the goods, when it could be read. Kept apart from `name` because it is the field the
    /// cross-photograph merge uses to decide that two sightings are the same product.
    var brand: String

    /// What kind of goods this is (`household`, `tools`, `toys`) — the fallback the aggregation pass
    /// prices from when the name is all the photograph supports.
    var category: String

    /// Units of this product visible **in this photograph**. `0` when the photograph shows the
    /// product but no countable units; a stack of six cartons is `6`, and a sealed case whose own
    /// label says `12` is `12` only when the case is the thing being sold.
    var quantity: Int

    /// In-store retail of ONE unit, USD.
    var unitRetail: Double

    /// Realistic resale of ONE unit, USD.
    var unitResale: Double

    /// `new`, `shelf wear`, `opened`, `damaged`, `untested`, as the photograph shows it.
    var condition: String

    /// `sealed retail`, `open box`, `shrink-wrapped case`, `loose`, `no packaging`.
    var packaging: String

    /// Where in the frame the group sits — `front left, four high`, `top shelf`. Read by the
    /// aggregation pass when it has to decide whether two readings are the same carton or two
    /// different stacks of it.
    var location: String

    /// Barcodes, model or SKU numbers read **in this photograph**, as printed.
    var identifiers: [String]

    /// The label wording this reading rests on, copied as read and short enough to quote.
    var labelText: String

    /// Identification confidence for this object: `High`, `Med` or `Low`.
    var confidence: String

    /// What the price rests on — the same idea as `DiscoveredItem.evidence`, one photograph down.
    var evidence: String

    /// Anything the reading wants to flag: a partly legible label, a product the photograph only
    /// half shows, an item it could not price.
    var notes: String

    init(
        id: UUID = UUID(),
        name: String,
        brand: String = "",
        category: String = "",
        quantity: Int = 0,
        unitRetail: Double = 0,
        unitResale: Double = 0,
        condition: String = "",
        packaging: String = "",
        location: String = "",
        identifiers: [String] = [],
        labelText: String = "",
        confidence: String = DiscoveredItem.Confidence.low.rawValue,
        evidence: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.category = category
        self.quantity = quantity
        self.unitRetail = unitRetail
        self.unitResale = unitResale
        self.condition = condition
        self.packaging = packaging
        self.location = location
        self.identifiers = identifiers
        self.labelText = labelText
        self.confidence = confidence
        self.evidence = evidence
        self.notes = notes
    }

    /// Typed view of `confidence`, for sorting and colouring.
    var confidenceLevel: DiscoveredItem.Confidence { DiscoveredItem.Confidence(rawText: confidence) }

    /// Units to price with: what the frame shows, and at least one — a photograph that proves a
    /// product is present without a countable stack is still evidence the product is present.
    var units: Int { max(quantity, 1) }

    /// Retail for the units this frame shows.
    var retailValue: Double { unitRetail * Double(units) }

    /// Resale for the units this frame shows.
    var resaleValue: Double { unitResale * Double(units) }

    /// `true` when the reading put a number on it.
    var isPriced: Bool { unitRetail > 0 || unitResale > 0 }

    /// Name with the count this frame showed, e.g. `Energizer MAX AA ×6`.
    var displayName: String { quantity > 1 ? "\(name) ×\(quantity)" : name }

    /// The one-line summary the reading list draws under a product's name: count, unit price,
    /// packaging, condition and where it was.
    var detailPhrase: String {
        var parts: [String] = []
        if quantity > 1 { parts.append("\(quantity) visible") }
        if unitRetail > 0 { parts.append("\(unitRetail.currencyText) ea retail") }
        if unitResale > 0 { parts.append("\(unitResale.currencyText) ea resale") }
        if !packaging.isEmpty { parts.append(packaging) }
        if !condition.isEmpty { parts.append(condition) }
        if !location.isEmpty { parts.append(location) }
        return parts.joined(separator: " · ")
    }

    /// What this reading can be checked against in the picture.
    var evidencePhrase: String {
        var parts: [String] = []
        if !identifiers.isEmpty { parts.append(identifiers.joined(separator: ", ")) }
        if !labelText.isEmpty { parts.append("label reads \"\(labelText)\"") }
        if !evidence.isEmpty { parts.append(evidence) }
        return parts.joined(separator: " · ")
    }
}

/// Everything one photograph was found to show.
///
/// Stored on the lot (`LotItem.readings`) and on disk (`PhotoReadingStore`), so both the row and the
/// next run work from the same value: the store's whole purpose is that photograph 7 of a lot priced
/// yesterday does not have to be paid for again today.
struct PhotoReading: Codable, Hashable, Sendable, Identifiable {

    /// Address the photograph was downloaded from — the store's key, together with the model.
    var imageURL: URL

    /// 1-based position in the lot's gallery, which is the number the prompt and the row both use.
    var imageIndex: Int

    /// Size of the gallery this reading was taken from, so a stored reading can still say
    /// "photograph 3 of 12" after the fact.
    var imageCount: Int

    /// One sentence on what this frame shows as a whole — including when the answer is "the pallet
    /// from three metres away" or "shrink wrap and no label".
    var summary: String

    /// The product groups visible in this frame, most valuable first.
    var objects: [PhotoObject]

    /// Whatever the reading wanted to flag about this photograph: blur, glare, an out-of-frame edge.
    var notes: String

    /// Model that produced the reading. Part of the reuse decision, because a reading from a
    /// different model is a different opinion and must not be silently mixed in.
    var modelID: String

    /// When it was read, so the store can say how fresh a reused reading is.
    var readAt: Date

    init(
        imageURL: URL,
        imageIndex: Int,
        imageCount: Int,
        summary: String = "",
        objects: [PhotoObject] = [],
        notes: String = "",
        modelID: String = "",
        readAt: Date = .now
    ) {
        self.imageURL = imageURL
        self.imageIndex = imageIndex
        self.imageCount = imageCount
        self.summary = summary
        self.objects = objects
        self.notes = notes
        self.modelID = modelID
        self.readAt = readAt
    }

    /// Identity for SwiftUI diffing: one slot per photograph per gallery.
    var id: String { "\(imageIndex)@\(imageURL.absoluteString)" }

    /// `photograph 3 of 12` — the label this reading is shown under everywhere.
    var positionText: String { "photograph \(imageIndex) of \(imageCount)" }

    /// Everything this one frame showed, as one line: each group's count, unit price, packaging,
    /// condition and where it sat (`PhotoObject.detailPhrase`), in the order the reading listed them.
    ///
    /// Empty for a frame that held nothing worth pricing — a photograph of the pallet's side is a
    /// normal frame, and the empty line is how the card says so rather than looking unfinished.
    var detailPhrase: String {
        objects.map(\.detailPhrase).filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    /// Barcodes, model numbers and SKU numbers this photograph was read for.
    var identifiers: [String] { objects.flatMap(\.identifiers) }

    /// `true` when the photograph was read but had nothing sellable in it. Not a failure: a
    /// photograph of a pallet's side, a shipping label or the floor is a normal frame in a gallery.
    var isEmpty: Bool { objects.isEmpty }

    /// The reading's headline: its own summary, or the objects it found when there was none.
    var displayName: String {
        let head = summary.condensedWhitespace
        if !head.isEmpty { return head }
        return objects.map(\.displayName).joined(separator: ", ")
    }
}

/// A lot's readings rolled up into the numbers the row and the console quote.
struct PhotoReadingSummary: Sendable, Equatable {

    /// Photographs read on their own.
    var photographs: Int = 0

    /// Product groups those readings found, counting a group once per photograph it appears in.
    var objects: Int = 0

    /// Groups whose reading carried no price at all.
    var unpricedObjects: Int = 0

    /// Distinct barcodes, model numbers and SKU numbers the readings quoted.
    var identifiers: [String] = []

    /// `true` when there is nothing to show.
    var isEmpty: Bool { photographs == 0 && objects == 0 }

    /// The console phrase: `12 photograph(s) read one by one — 34 product group(s), 9 identifier(s)`.
    var logPhrase: String {
        var parts = [
            "\(photographs) photograph(s) read one by one",
            "\(objects) product group(s)"
        ]
        if !identifiers.isEmpty { parts.append("\(identifiers.count) identifier(s)") }
        if unpricedObjects > 0 { parts.append("\(unpricedObjects) unpriced") }
        return parts.joined(separator: " — ")
    }

    /// The row's shorter form: `12 photo(s) · 34 group(s) · 9 id(s)`.
    var compactPhrase: String {
        var parts = ["\(photographs) photo(s)", "\(objects) group(s)"]
        if !identifiers.isEmpty { parts.append("\(identifiers.count) id(s)") }
        return parts.joined(separator: " · ")
    }
}

extension Array where Element == PhotoReading {

    /// Roll-up used by the row, the detail card and the console line.
    var photoSummary: PhotoReadingSummary {
        var summary = PhotoReadingSummary()
        summary.photographs = count
        for reading in self {
            summary.objects += reading.objects.count
            summary.unpricedObjects += reading.objects.count { !$0.isPriced }
            for identifier in reading.identifiers where !summary.identifiers.contains(where: {
                $0.caseInsensitiveCompare(identifier) == .orderedSame
            }) {
                summary.identifiers.append(identifier)
            }
        }
        return summary
    }

    /// In gallery order — the order the readings were taken in, and the order the aggregation prompt
    /// hands them to the model.
    var inGalleryOrder: [PhotoReading] { sorted { $0.imageIndex < $1.imageIndex } }
}
