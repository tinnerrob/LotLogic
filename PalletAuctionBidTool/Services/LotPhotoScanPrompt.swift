//
//  LotPhotoScanPrompt.swift
//  PalletAuctionBidTool
//
//  The two questions a thorough scan asks, and the tolerant decode of the first one's answer.
//
//  A two-pass *scan* (one request per photograph, then one reconciliation) needs two prompts that
//  agree about what a reading is: the photograph pass has to record what a frame shows without
//  pretending to know the pallet, and the aggregation pass has to turn several such records into one
//  set of line items without paying twice for a carton that three photographs happen to show. The
//  wording lives here, next to the `responseSchema` Gemini is pinned to and the JSON Schema text
//  DeepSeek is asked for, so the two providers cannot drift apart (see `LotValuationPrompt`).
//

import Foundation

/// The prompt and output contract shared by both providers for a photograph-by-photograph scan.
enum LotPhotoScanPrompt {

    /// Ground rules for reading **one** photograph, with no knowledge of the others.
    ///
    /// Deliberately self-contained rather than reusing `LotValuationPrompt.valuationRules`: those
    /// rules price a whole line item ("both values are for the WHOLE line item, quantity included"),
    /// and this pass prices a single unit, because the pallet's quantity is what the aggregation pass
    /// is for. Two asks, two rule sets, one place each.
    static let readingSystemInstruction = """
    You are cataloguing ONE photograph from a single liquidation-auction lot. The lot's other \
    photographs are being read separately, and a later step reconciles every reading into one \
    valuation, so your only job here is to record what THIS frame shows — accurately, literally and \
    completely.

    Rules:
    1. `summary` is one sentence on what this photograph shows as a whole. Say when it shows the \
    pallet from a distance, one carton close up, a shelf, or shrink wrap with nothing legible on it.
    2. `objects` lists every distinct product group visible in this frame, most valuable first. Be \
    exhaustive: a photograph of a mixed pallet usually shows four to twelve groups, and a group \
    you leave out is a group the pallet is not paid for. Group identical or near-identical goods \
    into one entry (for example "16 oz scented candles, 24-pack") rather than one entry per unit.
    3. `quantity` is the number of units of that product VISIBLE IN THIS PHOTOGRAPH. A stack four \
    cartons high is 4; a shrink-wrapped case whose own label says "12" counts as 12 only when the \
    case is the thing being sold. Count what you can see and do not extrapolate to the rest of the \
    pallet: another photograph is read separately, and the pallet's own quantity is worked out once, \
    later, from every reading.
    4. `unitRetail` is the normal in-store price of ONE unit when new, and `unitResale` is what a \
    reseller could realistically get for ONE unit — typically 40-70% of retail for liquidation \
    merchandise, less for opened, damaged or untested goods. Both are US dollars for a single item, \
    never for the stack and never for the whole pallet.
    5. Read the goods before you judge them: brand, product name, model and part numbers, the digits \
    printed under a barcode (UPC/EAN/GTIN), size, weight and count wording, case codes, condition \
    wording, and any price sticker. Zoom into packaging and shelf tickets. When the app's own text \
    and barcode reader has already reported what it read on this photograph, treat that as verified \
    and price the model and size it names. Price the *most exactly identified* thing you can: a \
    barcode or model number beats a brand with a product name and size, which beats a brand and a \
    category, which beats the category alone. A generic price for a specific product is the wrong \
    price, so name what you identified in `name` and record how you identified it in `evidence`.
    6. `labelText` is what the label says, copied as read and no longer than 20 words — brand, \
    product, size, count. Copy it rather than paraphrasing it, and leave it empty when nothing was \
    legible.
    7. `identifiers` lists only the barcode digits and model / part / SKU numbers you can actually \
    read in this frame, exactly as printed. Never invent one, and do not repeat an identifier on a \
    product it does not belong to.
    8. `evidence` says what the identification and the price rest on — the label wording, barcode \
    digits, model number, printed size or count — quoting what you read rather than describing it. \
    Use an empty string only when the price rests on the shape of the goods alone.
    9. `location` says where in the frame the group sits ("front left, four high", "top shelf"), \
    `packaging` says how it is packed ("sealed retail", "open box", "shrink-wrapped case", "loose"), \
    and `condition` says how it looks ("new", "shelf wear", "opened", "damaged", "untested").
    10. `confidence` must be exactly one of: High, Med, Low. High when something legible on the \
    goods — a label, a model number, a barcode — identifies the product; Med for a reasonable \
    inference from partial clues; Low for speculation.
    11. `notes` is where you flag what this photograph could not settle: glare, blur, a partly \
    legible label, a product only half in frame, a price you could not determine.
    12. Never invent a product, a count or an identifier that this photograph does not support. A \
    frame with nothing sellable in it — the pallet's side, the floor, a shipping label, a wall of \
    shrink wrap — is a normal photograph, not a failure: say so in `summary` and return an empty \
    `objects` list.
    """

    /// The question that accompanies **one** photograph.
    ///
    /// - Parameters:
    ///   - request: the photograph, its position in the gallery, the lot's listing text and what the
    ///     app's own reader made of this frame.
    ///   - schemaText: JSON Schema text to embed in the prompt, for providers whose JSON mode wants a
    ///     format example in the prompt (DeepSeek). Gemini is handed `readingSchema` out of band.
    static func userPrompt(_ request: PhotoReadingRequest, schemaText: String? = nil) -> String {
        var lines: [String] = []
        lines.append("This is \(request.positionPhrase). Read this frame on its own.")
        if request.description.isEmpty {
            lines.append("No listing text was captured for this lot, so work from what the photograph shows.")
        } else {
            lines.append("Auction listing details:")
            lines.append(request.description)
        }
        lines.append(contentsOf: request.localReading.singlePhotographPromptLines)
        lines.append(
            "Record what this photograph shows: its `summary`, then every product group it holds in "
                + "`objects`, with what you can read off each one and what you can see of its count, "
                + "packaging and condition."
        )
        lines.append(contentsOf: LotValuationPrompt.outputContractLines(schemaText: schemaText))
        return lines.joined(separator: "\n")
    }

    /// Ground rules for the reconciliation pass: several readings of one pallet, one set of line
    /// items.
    ///
    /// Rules 3-9 are `LotValuationPrompt.valuationRules` — the pricing and confidence vocabulary
    /// every pass shares — which is why this instruction supplies exactly two rules of its own before
    /// interpolating them.
    static let aggregationSystemInstruction = """
    You are finishing a liquidation-auction valuation. Every photograph of one pallet has already \
    been read on its own, and each reading lists the product groups visible in that single frame. \
    Reconcile those readings into the pallet's line items and price them.

    Rules:
    1. The readings are views of ONE pallet, so the same goods appear in several of them — another \
    angle, the same case seen twice, one shelf photographed from both sides. Count each distinct \
    product ONCE, merging the readings that describe it, and never add up a quantity that more than \
    one of them reports: if six cartons are visible in three readings, the pallet holds six.
    2. `quantity` is your best estimate of how many units of that product the pallet actually holds: \
    the largest count a single reading supports, raised when the readings, their `location` notes or \
    the listing text genuinely show separate stacks, lowered when one reading counted the same stack \
    twice. The readings price single units, so a line's totals are that unit price multiplied by the \
    quantity you conclude.
    \(LotValuationPrompt.valuationRules)
    10. `photos` lists the 1-based numbers of the photographs this line item was read from, and \
    `evidence` should name the photograph its digits came from — `photograph 3: UPC 039800011324` — \
    whenever the reading they came from is known.
    11. The readings are the pallet's evidence, so treat them as the source of truth for names, \
    quantities and condition — not the listing text, which is only a hint about what may be inside. \
    Where a reading priced something it could not identify, say so in `notes` and price it from its \
    category with a Low confidence rather than dropping it.
    """

    /// The reconciliation question: the listing text, every reading as JSON, and the hint that stops
    /// the model paying twice for the same carton.
    ///
    /// - Parameter schemaText: JSON Schema text to embed, for providers without out-of-band schema
    ///   support (DeepSeek). The shape is always `LotValuationPrompt.itemsSchema`, so a reconciled
    ///   answer decodes exactly like a single-pass one.
    static func aggregationPrompt(_ request: PhotoAggregationRequest, schemaText: String? = nil) -> String {
        var lines: [String] = []
        lines.append(
            "Reconcile this pallet's per-photograph readings into one line-item valuation: one entry "
                + "per distinct product in the whole pallet, with the quantity you conclude it holds."
        )
        if request.description.isEmpty {
            lines.append("No listing text was captured for this lot.")
        } else {
            lines.append("Auction listing details:")
            lines.append(request.description)
        }
        lines.append(contentsOf: request.evidence?.promptLines ?? [])

        let rendered = PhotoReadingPromptText.render(request.readings)
        lines.append(
            "\(request.readings.count) photograph(s) of this lot were read one at a time, in gallery "
                + "order. Each reading is what that single frame showed — a product seen in two of "
                + "them is one product, not two. The readings, as json:"
        )
        lines.append(rendered.text)
        if rendered.omitted > 0 {
            lines.append(
                "\(rendered.omitted) further reading(s) did not fit this prompt and are not shown. "
                    + "Where that leaves a product's quantity uncertain, say so in `notes`."
            )
        }
        let repeated = PhotoReadingMerge.repeatedPhrases(from: request.readings)
        if !repeated.isEmpty {
            lines.append(
                "These product groups were seen in more than one photograph — count each one once, "
                    + "and do not add the counts together:"
            )
            lines.append(contentsOf: repeated)
        }
        if request.leftoverImages.isEmpty {
            lines.append("Every photograph the lot carries was read this way, and nothing else is attached.")
        } else {
            lines.append(
                "\(request.leftoverImages.count) more photograph(s) of the same pallet are attached: "
                    + "they were not read on their own, so check them for anything the readings missed "
                    + "and fit what they show into the same line items."
            )
        }
        lines.append(contentsOf: LotValuationPrompt.outputContractLines(schemaText: schemaText))
        return lines.joined(separator: "\n")
    }

    /// Strict output shape for **one photograph** — mirrors `PhotoReading`, so decoding can never
    /// drift from what the model was asked for.
    ///
    /// Every `PhotoObject` field is here because every field is a question the single-pass prompt
    /// cannot ask: where in the frame, how it is packed, how it looks, and how many units were
    /// visible *from this angle*.
    static var readingSchema: ResponseSchemaNode {
        .object(
            description: "What one photograph of a single auction pallet shows.",
            properties: [
                ("summary", .string(description: "One sentence on what this photograph shows as a whole.")),
                (
                    "objects",
                    .array(
                        description: "Distinct product groups visible in this photograph, most valuable first.",
                        items: .object(
                            description: "One product group as this photograph shows it.",
                            properties: photoObjectProperties,
                            required: ["name", "quantity", "unitRetail", "unitResale", "confidence", "evidence"]
                        )
                    )
                ),
                ("notes", .string(description: "What this photograph could not settle: blur, glare, a half-visible product."))
            ],
            required: ["summary", "objects"]
        )
    }

    /// The properties of one object in a reading.
    private static var photoObjectProperties: [(String, ResponseSchemaNode)] {
        [
            ("name", .string(description: "Product name with brand, size and pack count as the label gives them.")),
            ("brand", .string(description: "Brand on the goods, when it could be read. Empty string otherwise.")),
            ("category", .string(description: "What kind of goods this is, e.g. 'household', 'tools', 'toys'.")),
            ("quantity", .number(description: "Units of this product visible in THIS photograph.")),
            ("unitRetail", .number(description: "Normal in-store price of ONE unit, in USD.")),
            ("unitResale", .number(description: "Realistic resale price of ONE unit, in USD.")),
            ("condition", .string(description: "New, shelf wear, opened, damaged or untested, as the photograph shows it.")),
            ("packaging", .string(description: "Sealed retail, open box, shrink-wrapped case, loose, no packaging.")),
            ("location", .string(description: "Where in the frame the group sits, e.g. 'front left, four high'.")),
            (
                "identifiers",
                .array(
                    description: "Barcode digits and model / part / SKU numbers read in this photograph, exactly as printed.",
                    items: .string(description: "One identifier.")
                )
            ),
            ("labelText", .string(description: "What the label says, copied as read, 20 words at most. Empty when nothing was legible.")),
            (
                "confidence",
                .string(
                    description: "Identification confidence for this object.",
                    values: DiscoveredItem.Confidence.allCases.map(\.rawValue)
                )
            ),
            ("evidence", .string(description: "What the price rests on: label wording, barcode digits, model number or printed size and count.")),
            ("notes", .string(description: "Anything this reading wants to flag about this object."))
        ]
    }
}

// MARK: - Answer decoding

/// The JSON one photograph's answer is expected to produce.
///
/// Every field is optional and defaulted on the way into `PhotoObject`, for the same reason
/// `ValuationPayload`'s are: Gemini is constrained by `responseSchema`, but DeepSeek only offers
/// `json_object` mode, so a decode must never fail over a key the prompt asked for. `quantity` is
/// read as a `Double` because JSON has one number type, and models write `6` and `6.0` alike.
struct PhotoReadingPayload: Codable {

    /// One product group as the model reported it.
    struct Object: Codable {
        var name: String?
        var brand: String?
        var category: String?
        var quantity: Double?
        var unitRetail: Double?
        var unitResale: Double?
        var condition: String?
        var packaging: String?
        var location: String?
        var identifiers: [String]?
        var labelText: String?
        var confidence: String?
        var evidence: String?
        var notes: String?
    }

    var summary: String?
    var objects: [Object]?
    var notes: String?
}

/// One reading as the aggregation prompt shows it: the same object shape the decode above reads,
/// plus which photograph the reading came from.
///
/// Encoding the *decoded* reading, rather than forwarding the raw answer, keeps the prompt's example
/// in exactly the shape this file decodes — a fenced or chatty answer can never smuggle prose into
/// the reconciliation question (the same reason `ValuationPayload.from(items:)` exists).
struct PhotoReadingDigest: Codable {

    var photograph: Int
    var of: Int
    var summary: String
    var objects: [PhotoReadingPayload.Object]
    var notes: String?

    init(_ reading: PhotoReading) {
        photograph = reading.imageIndex
        of = reading.imageCount
        summary = reading.summary
        objects = reading.objects.map { object in
            PhotoReadingPayload.Object(
                name: object.name,
                brand: object.brand.isEmpty ? nil : object.brand,
                category: object.category.isEmpty ? nil : object.category,
                quantity: Double(object.quantity),
                unitRetail: object.unitRetail,
                unitResale: object.unitResale,
                condition: object.condition.isEmpty ? nil : object.condition,
                packaging: object.packaging.isEmpty ? nil : object.packaging,
                location: object.location.isEmpty ? nil : object.location,
                identifiers: object.identifiers.isEmpty ? nil : object.identifiers,
                labelText: object.labelText.isEmpty ? nil : object.labelText,
                confidence: object.confidence,
                evidence: object.evidence.isEmpty ? nil : object.evidence,
                notes: object.notes.isEmpty ? nil : object.notes
            )
        }
        notes = reading.notes.isEmpty ? nil : reading.notes
    }
}

/// Renders readings as the JSON slab the aggregation prompt carries.
enum PhotoReadingPromptText {

    /// Longest slab of readings one reconciliation prompt carries, in characters.
    ///
    /// A forty-photograph lot's readings are longer than the useful part of a prompt, so the slab is
    /// bounded the way `LotValuationPrompt.maxPriorAnalysisLength` bounds a DeepSeek draft: readings
    /// are taken in gallery order until the budget is spent, and the number that did not fit is
    /// *reported* (in the prompt and in the run log) rather than silently dropped.
    static let maximumLength = 16_000

    /// - Returns: the JSON array text, and how many readings were left out of it.
    static func render(
        _ readings: [PhotoReading],
        limit: Int = maximumLength
    ) -> (text: String, omitted: Int) {
        let encoder = JSONEncoder()
        var pieces: [String] = []
        var used = 2
        var omitted = 0

        for reading in readings.inGalleryOrder {
            guard let data = try? encoder.encode(PhotoReadingDigest(reading)),
                  let piece = String(data: data, encoding: .utf8) else {
                omitted += 1
                continue
            }
            // The first reading always travels, however long it is: a prompt whose readings are all
            // missing asks the model to reconcile nothing.
            guard pieces.isEmpty || used + piece.count + 1 <= limit else {
                omitted += 1
                continue
            }
            pieces.append(piece)
            used += piece.count + 1
        }

        return ("[" + pieces.joined(separator: ",") + "]", omitted)
    }
}

/// Turns one photograph's answer into a `PhotoReading`.
enum LotPhotoScanAnswer {

    /// Identifiers kept per object. A photograph with more codes than this on it is a shelf of cases,
    /// and the extras are the same product's siblings.
    static let maximumIdentifiersPerObject = 8

    /// Longest label wording kept per object, so a wall of label text cannot crowd out the pallet.
    static let maximumLabelLength = 160

    /// Longest `evidence` / `notes` kept per object.
    static let maximumProseLength = 240

    /// Decodes one reading.
    ///
    /// - Parameters:
    ///   - request: the question that produced this answer, which is where the reading's identity
    ///     (which photograph, of how many) comes from — the model is never asked to report it.
    ///   - modelID: the model being driven, stamped on the reading for the store's reuse check.
    static func reading(
        fromAnswerText text: String,
        finishReason: String?,
        request: PhotoReadingRequest,
        modelID: String
    ) throws -> PhotoReading {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValuationError.noContent(finishReason: finishReason)
        }
        guard let data = LotValuationAnswer.extractJSONObject(from: text).data(using: .utf8) else {
            throw ValuationError.malformedResponse("the reading was not valid UTF-8")
        }

        let payload: PhotoReadingPayload
        do {
            payload = try JSONDecoder().decode(PhotoReadingPayload.self, from: data)
        } catch {
            throw ValuationError.malformedResponse(error.localizedDescription)
        }

        let summary = (payload.summary ?? "").condensedWhitespace
        let objects = (payload.objects ?? []).compactMap(object(from:))
        let notes = (payload.notes ?? "").condensedWhitespace
        guard !objects.isEmpty || !summary.isEmpty || !notes.isEmpty else {
            throw ValuationError.malformedResponse("the reading named neither a summary nor a product")
        }

        return PhotoReading(
            imageURL: request.image.sourceURL,
            imageIndex: request.index,
            imageCount: request.imageCount,
            summary: summary,
            objects: objects,
            notes: notes,
            modelID: modelID
        )
    }

    /// Normalises one reported object, or drops it when it names nothing at all.
    static func object(from reported: PhotoReadingPayload.Object) -> PhotoObject? {
        let name = (reported.name ?? "").condensedWhitespace
        guard !name.isEmpty else { return nil }

        return PhotoObject(
            name: name,
            brand: (reported.brand ?? "").condensedWhitespace,
            category: (reported.category ?? "").condensedWhitespace,
            quantity: quantity(from: reported.quantity),
            unitRetail: price(reported.unitRetail),
            unitResale: price(reported.unitResale),
            condition: (reported.condition ?? "").condensedWhitespace,
            packaging: (reported.packaging ?? "").condensedWhitespace,
            location: (reported.location ?? "").condensedWhitespace,
            identifiers: identifiers(from: reported.identifiers),
            labelText: (reported.labelText ?? "").condensedWhitespace.truncated(to: maximumLabelLength),
            confidence: DiscoveredItem.Confidence(rawText: reported.confidence ?? "").rawValue,
            evidence: (reported.evidence ?? "").condensedWhitespace.truncated(to: maximumProseLength),
            notes: (reported.notes ?? "").condensedWhitespace.truncated(to: maximumProseLength)
        )
    }

    /// Rounds a reported count into a sane number of units.
    ///
    /// Clamped rather than rejected, on the same rule as the prices: a count that is slightly wrong is
    /// still evidence the product is there, and a `-3` or a `999999` is the model slipping, not a
    /// reason to throw away a reading that names a barcode.
    static func quantity(from raw: Double?) -> Int {
        guard let raw, raw.isFinite else { return 0 }
        return Int(min(max(raw.rounded(), 0), 10_000))
    }

    /// Clamps a reported price: a negative price is a typo, and a nine-figure one a hallucination.
    static func price(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite else { return 0 }
        return min(max(raw, 0), 1_000_000)
    }

    /// Distinct identifiers, condensed and capped.
    static func identifiers(from raw: [String]?) -> [String] {
        var found: [String] = []
        for entry in raw ?? [] {
            let value = entry.condensedWhitespace
            guard !value.isEmpty, found.count < maximumIdentifiersPerObject else { continue }
            guard !found.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { continue }
            found.append(value)
        }
        return found
    }
}


