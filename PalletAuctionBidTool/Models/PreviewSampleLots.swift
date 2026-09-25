//
//  PreviewSampleLots.swift
//  PalletAuctionBidTool
//
//  Debug-only fixture rows, so the table can be looked at without scraping an auction.
//

import Foundation

#if DEBUG

extension LotItem {

    /// A handful of lots covering the states the table has to draw.
    ///
    /// The master table is built by hand out of fixed-width cells, so the things that break it —
    /// a nested product line, a provisional figure, a failed row, a description longer than its
    /// column — can only be judged by looking at real rows. Scraping a live auction to do that is
    /// not an option: it costs a network round trip, a session and somebody's patience. These
    /// fixtures cost nothing and are compiled into debug builds only (`#if DEBUG`), which is what
    /// `#Preview("Populated table")` in `LotTableView` draws.
    ///
    /// Nothing here touches the network: the image URLs are placeholders a preview never fetches,
    /// and the valuations are applied through the same methods the pipeline uses.
    static func previewSamples() -> [LotItem] {
        [
            appraised(),
            provisional(),
            scannedButWaiting(),
            unscanned(number: "19002"),
            sold(),
            unscanned(number: "L-1042"),
            failed()
        ]
    }

    // MARK: - The states

    /// A lot with a real appraisal behind it: nested line items, a mixed confidence and therefore
    /// both a Max bid and a profit figure.
    private static func appraised() -> LotItem {
        let lot = makeLot(
            number: "142",
            bid: 310,
            title: "PALLET OF MIXED HOME GOODS",
            description: """
                PALLET OF MIXED HOME GOODS - RETURNS & OVERSTOCK. Includes small kitchen \
                appliances, bedding sets, storage baskets and a sealed robot vacuum. Customer \
                returns mixed with overstock; condition sold as-is, no manifests available.
                """
        )
        lot.applyValuation(
            [
                DiscoveredItem(
                    itemName: "Robot vacuum (sealed)",
                    confidence: DiscoveredItem.Confidence.high.rawValue,
                    retailValue: 399,
                    resaleValue: 245,
                    notes: "Sealed box, one model behind current — sells fast locally.",
                    evidence: "box label reads \"Shark AV1010AE\" · UPC 622356562691"
                ),
                DiscoveredItem(
                    itemName: "Stainless kettle ×4",
                    confidence: DiscoveredItem.Confidence.medium.rawValue,
                    retailValue: 240,
                    resaleValue: 120,
                    notes: "Boxes scuffed; contents look untouched.",
                    evidence: "carton reads \"1.7L stainless · model KE4003\""
                ),
                DiscoveredItem(
                    itemName: "Bedding sets (assorted)",
                    confidence: DiscoveredItem.Confidence.low.rawValue,
                    retailValue: 180,
                    resaleValue: 70,
                    notes: "Sizes unknown from the photographs."
                )
            ],
            imagesAnalyzed: 4
        )
        return lot
    }

    /// A lot that has only had the cheap text-only pass: provisional figures, nothing discovered.
    private static func provisional() -> LotItem {
        let lot = makeLot(
            number: "208",
            bid: 95,
            title: "TOOL PALLET - CORDLESS DRILLS",
            description: """
                TOOL PALLET - CORDLESS DRILLS, IMPACT DRIVERS & BATTERY PACKS. Roughly twenty \
                pieces, several without chargers. Untested, sold as seen.
                """
        )
        lot.applyPrePrice(
            PrePriceEstimate(
                retail: 1_450,
                resale: 620,
                confidence: .low,
                rationale: "Cordless tool bundles resell around 40% of retail when untested."
            )
        )
        return lot
    }

    /// Valuated, and the row the preview opens: the nested product lines and the description card
    /// are only really judged on an expanded lot.
    ///
    /// This is also the one sample that carries readings — a lot priced photograph by photograph — so
    /// the card's reading list and the row's step note are drawn in a preview rather than only ever
    /// being looked at against a live auction (`LotPhotoScan`).
    private static func scannedButWaiting() -> LotItem {
        let lot = makeLot(
            number: "77",
            bid: 220,
            title: "OFFICE CHAIR & DESK LOT",
            description: """
                OFFICE CHAIR & DESK LOT - SIT-STAND DESKS AND MESH TASK CHAIRS, SOME ASSEMBLED. \
                Two benches show cosmetic scratches; mechanisms untested.
                """,
            imageCount: 3
        )
        lot.applyValuation(
            [
                DiscoveredItem(
                    itemName: "Electric sit-stand desk",
                    confidence: DiscoveredItem.Confidence.high.rawValue,
                    retailValue: 520,
                    resaleValue: 300,
                    notes: "Complete frame in the photograph, top edge chipped."
                ),
                DiscoveredItem(
                    itemName: "Mesh task chair",
                    confidence: DiscoveredItem.Confidence.medium.rawValue,
                    retailValue: 190,
                    resaleValue: 85,
                    notes: "Two of the four are missing arm caps."
                )
            ],
            imagesAnalyzed: 3,
            passes: 3,
            readings: [
                PhotoReading(
                    imageURL: lot.imageUrls[0],
                    imageIndex: 1,
                    imageCount: 3,
                    summary: "A sit-stand desk, assembled, seen from the aisle.",
                    objects: [
                        PhotoObject(
                            name: "Electric sit-stand desk",
                            category: "office",
                            quantity: 1,
                            unitRetail: 520,
                            unitResale: 300,
                            condition: "shelf wear",
                            packaging: "open box",
                            location: "front right, assembled",
                            identifiers: ["E7B-1200"],
                            labelText: "electric sit-stand frame, 1200 mm",
                            confidence: DiscoveredItem.Confidence.high.rawValue,
                            evidence: "label reads the frame's model number",
                            notes: "One corner of the desk top is out of frame."
                        )
                    ],
                    notes: "The desk top is partly out of frame.",
                    modelID: "preview"
                ),
                PhotoReading(
                    imageURL: lot.imageUrls[1],
                    imageIndex: 2,
                    imageCount: 3,
                    summary: "Four mesh chairs stacked, two without arm caps.",
                    objects: [
                        PhotoObject(
                            name: "Mesh task chair",
                            quantity: 4,
                            unitRetail: 190,
                            unitResale: 85,
                            condition: "shelf wear",
                            packaging: "no packaging",
                            location: "rear left, stacked four high",
                            confidence: DiscoveredItem.Confidence.medium.rawValue,
                            evidence: "mesh back and base style are recognisable",
                            notes: "Two of the four are missing arm caps."
                        )
                    ],
                    notes: "",
                    modelID: "preview"
                ),
                PhotoReading(
                    imageURL: lot.imageUrls[2],
                    imageIndex: 3,
                    imageCount: 3,
                    summary: "Shrink wrap and a shipping label — nothing sellable in this frame.",
                    notes: "Nothing legible on the label from this angle.",
                    modelID: "preview"
                )
            ]
        )
        return lot
    }

    private static func unscanned(number: String) -> LotItem {
        makeLot(
            number: number,
            bid: 0,
            title: "UNSORTED RETURNS PALLET \(number)",
            description: "UNSORTED RETURNS PALLET \(number) - categories not declared on the listing."
        )
    }

    /// A lot the site has already sold. It stays in the table as part of the auction's record — the
    /// **Active** column says so, and it is still priceable — which is why the preview needs one: the
    /// column reads as a green wall of "Active" without it.
    private static func sold() -> LotItem {
        let lot = makeLot(
            number: "355",
            bid: 640,
            title: "GARDEN TOOLS PALLET",
            description: "GARDEN TOOLS PALLET - spades, hoses, a petrol strimmer and a wheelbarrow."
        )
        lot.isActive = false
        lot.statusText = "SOLD"
        return lot
    }

    /// A row whose appraisal was rejected, so the status column's failure tint is visible.
    private static func failed() -> LotItem {
        let lot = makeLot(
            number: "311",
            bid: 140,
            title: "SEASONAL DECOR PALLET",
            description: "SEASONAL DECOR PALLET - mixed holiday stock, no manifest."
        )
        lot.markFailed("response was not valid JSON")
        return lot
    }

    // MARK: - Plain lots

    private static func makeLot(
        number: String,
        bid: Double,
        title: String,
        description: String,
        imageCount: Int = 2
    ) -> LotItem {
        LotItem(
            lotNumber: number,
            currentBid: bid,
            rawDescription: description,
            imageUrls: (1...max(imageCount, 1)).map {
                URL(string: "https://example.invalid/lots/\(number)/\($0).jpg")!
            },
            title: title,
            detailURL: URL(string: "https://example.invalid/lot/\(number)")
        )
    }
}

#endif
