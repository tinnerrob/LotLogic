//
//  LotManifestPrompt.swift
//  PalletAuctionBidTool
//
//  The two questions the batched route asks: *what is in this pallet*, then *what is it worth*.
//
//  Every other appraisal in this app asks one question about a pallet and pays for the answer once
//  (`LotValuationPrompt`) or asks about each photograph in turn and reconciles the answers
//  (`LotPhotoScanPrompt`). This file is the third shape, and it exists because the two halves of an
//  appraisal want different things from a model:
//
//  * **Identity** wants pixels, and wants *several views at once*. A carton at the front and the same
//    carton at the side are one carton only if one request can see both — which is what a batch is
//    (`manifestPrompt`), and it is also why a batch is cheap next to reading frames one at a time: ten
//    frames in one request instead of ten requests.
//  * **Price** wants a product and a marketplace. Once the goods are named and counted, a barcode, a
//    model number and a printed size pin a shelf price, and no photograph improves that — so the
//    pricing pass carries no images at all (`pricingPrompt`), and one request prices a whole manifest.
//
//  The two answers meet on this machine: `PalletManifest.absorb(_:)` folds the batches into one
//  inventory, and the pricing pass is handed that manifest as JSON. Its answer is held to
//  `LotValuationPrompt.itemsSchema` — the shape every other pass's answer uses — so nothing downstream
//  of it knows or cares which route produced a line item.
//

import Foundation

/// The prompts and output contracts for the manifest route (`PalletManifest`).
enum LotManifestPrompt {

    /// The sampling temperature a **manifest batch** is sent at: **zero**.
    ///
    /// Every other pass samples at `LotValuationPrompt.standardTemperature`, because a valuation is an
    /// opinion and two runs over one pallet may reasonably differ in wording or in what they notice.
    /// This pass is not an opinion: it is an extraction — which products are visible in these frames,
    /// and how many — and its answer is folded into a pallet-wide inventory that is then priced and bid
    /// on. The same pallet read twice must not come back with two different counts, so the batch is
    /// asked the one question there is an answer to, and asked for it the same way every time.
    static let manifestTemperature = 0.0

    /// Ground rules for reading a **batch** of one pallet's photographs into a manifest.
    ///
    /// The batch is what makes the deduplication possible: several views of the same goods travel in
    /// one request, so "the carton at the front" and "the carton at the side" can be recognised as one
    /// carton inside one context rather than reconciled afterwards from two reports that each knew
    /// only their own frame. Nothing here asks what anything is worth — pricing is the next pass's
    /// whole job (`pricingSystemInstruction`) — so these rules spend themselves on identity, count and
    /// legibility, and on the two mistakes a batch invites: counting a product once per view (rule 1,
    /// and the cue list in rule 2 that decides whether two sightings are one product), and answering
    /// about some of the frames it was handed and not the rest (rule 8, which makes every photograph
    /// the batch's business either through an item's `views` or through `unreadPhotos`).
    static let manifestSystemInstruction = """
    You are cataloguing ONE liquidation-auction pallet from a batch of its photographs. The batch \
    holds several views of the same goods — a carton at the front, the same carton from the side, a \
    shelf seen from both ends — and later batches cover the rest of the pallet. Your only job is the \
    inventory: what this pallet holds, named and counted. You are not asked what any of it is worth.

    Rules:
    1. Every photograph in this batch shows the SAME pallet, so the same goods appear in more than one \
    of them. Identify each distinct product ONCE: if a case is visible at the front and again at the \
    side, the pallet holds one case and not two. Never add together quantities that more than one \
    photograph reports — count a product the largest number of times a single view supports it, and \
    raise that only when the views genuinely show separate stacks.
    2. Judge "one product or two" by what the views agree on, strongest cue first: the same barcode \
    digits; the same model, part or SKU number; the same brand with the same product line and pack \
    count; the same wording on the label; the same size, weight or printed count; the same kind of \
    goods in the same place in the stack with the same neighbours around it; and the same damage, \
    repacking or price sticker. One cue agreeing is enough to call it ONE product. A disagreement \
    where it counts — a different model number, a different pack count or printed size, a different \
    product line on the label — means TWO products, however alike the two views look otherwise.
    3. When the cues do not settle it, return ONE entry and say what is uncertain in its `notes`: one \
    entry with a note beats two entries. A duplicate the operator can see and merge costs a glance; a \
    phantom second product is counted, priced and bid on as though the pallet really held two. Two \
    sides of one 24-pack of batteries — the label wording in one frame, the pack count and the barcode \
    in another — is ONE entry ("Energizer MAX AA alkaline batteries, 24-pack", quantity 1) naming both \
    frames in `views`, not two entries, and not a count of 2.
    4. Read the goods before you judge them, and read them closely. Goods may be shrink-wrapped, \
    stacked, in open boxes or half hidden, and a partly legible label is still worth reading: report \
    what you could make out. Brand and product names, model and part numbers, the digits printed \
    under a barcode (UPC/EAN/GTIN), size, weight and count wording, case codes, condition wording and \
    any price sticker are all evidence — copy them into the fields below exactly as printed.
    5. `itemName` names the exact product you identified: brand, product line, size and pack count as \
    the label gives them, for example "Energizer MAX AA alkaline batteries, 24-pack". Group identical \
    or near-identical goods into ONE entry rather than one entry per unit, and leave the name at the \
    category only when nothing more specific could be read.
    6. `quantity` is how many units of that product this batch supports. Do not extrapolate to the \
    rest of the pallet: other batches are read separately, and the pallet's own count is settled \
    later, from every batch together. A sealed case whose own label says "12" is 12 when the case is \
    the thing being sold, and 1 when it is one case in a stack of cases.
    7. `views` lists the 1-based gallery numbers of the photographs you saw this item in, taken from \
    the numbering given in the question. It is required, and it is the batch's evidence that the item \
    was really there: a product you saw in three frames lists three numbers.
    8. Every attached photograph must be accounted for: it appears in the `views` of at least one \
    item, or its gallery number is listed in `unreadPhotos` because it shows nothing sellable — the \
    pallet's own side, the floor, an empty shelf, a shipping label and nothing else. Never both for \
    one frame: a photograph an item was seen in is not unread. Use an empty `unreadPhotos` list when \
    every frame in the batch held something, and never leave a frame unmentioned.
    9. When the app's own text and barcode reader has already reported what it read, treat that as \
    verified: it is the digits a camera can misread and a decoder cannot. Match each entry to the \
    product it belongs to, and never contradict a decoded barcode by naming a different product. Do \
    not assume a barcode stapled to the outside of a pallet belongs to the goods inside — a freight \
    or tracking label is not a product identifier.
    10. Never invent an item or an identifier: a model number or barcode you quote must be one you can \
    read in a photograph or one the reader listed. Use an empty string or an empty list for anything \
    you could not read rather than a guess.
    11. `confidence` must be exactly one of: High, Med, Low. Use High when something legible on the \
    goods — a label, a model number, a barcode — identifies the product; Med for a reasonable \
    inference from partial clues; Low for speculation.
    12. An empty `manifest` is the honest answer for a batch that shows nothing sellable — the pallet's \
    side, the floor, a shipping label and nothing else — but a photograph of goods is never that. \
    Name the frames that made it empty in `unreadPhotos`.
    """

    /// The batch question: the listing text, which frames of the gallery travel with this request, and
    /// the app's own reading of them.
    ///
    /// - Parameters:
    ///   - batch: 1-based batch number, so an answer can be read against the gallery it came from.
    ///   - batchCount: how many batches this pallet's gallery was split into.
    ///   - positions: the gallery numbers of the frames attached to this request, in gallery order.
    ///   - imageCount: how many photographs the lot's gallery holds, so `views` can speak in gallery
    ///     numbers rather than in the positions of a batch.
    ///   - schemaText: JSON Schema text to embed in the prompt. DeepSeek's `json_object` mode requires
    ///     the word *json* **and** a format example, so its caller passes
    ///     `manifestSchema.jsonSchemaText` here (see `LotValuationPrompt.outputContractLines`).
    static func manifestPrompt(
        description: String,
        batch: Int,
        batchCount: Int,
        positions: [Int],
        imageCount: Int,
        evidence: LotImageEvidence? = nil,
        schemaText: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("Read this batch of photographs into a manifest of the distinct products the pallet holds.")
        if description.isEmpty {
            lines.append("No listing text was captured for this lot.")
        } else {
            lines.append("Auction listing details:")
            lines.append(description)
        }
        lines.append(contentsOf: evidence?.promptLines ?? [])
        lines.append(
            framePhrase(batch: batch, batchCount: batchCount, positions: positions, imageCount: imageCount)
        )
        lines.append(
            "Anything shown in more than one of them is ONE item, and a product you saw in an earlier "
                + "batch is named again at most — never counted again from a different angle."
        )
        lines.append(
            "Account for every photograph attached: either it appears in some item's `views`, or it is "
                + "listed in `unreadPhotos` because it shows nothing sellable."
        )
        lines.append(contentsOf: LotValuationPrompt.outputContractLines(schemaText: schemaText))
        return lines.joined(separator: "\n")
    }

    /// `Batch 2 of 4: photographs 7-12 of 24 are attached, in gallery order.`
    ///
    /// The gallery numbering is stated in every batch on purpose: `views` is answered in gallery
    /// numbers, and a batch that only knew "photograph 1" would have each batch name its own frames as
    /// if they were the pallet's first — which is exactly the duplicate count the manifest exists to
    /// prevent.
    static func framePhrase(batch: Int, batchCount: Int, positions: [Int], imageCount: Int) -> String {
        let span = positions.count == 1
            ? "photograph \(positions.first ?? 1)"
            : "photographs \(runPhrase(positions))"
        let verb = positions.count == 1 ? "is" : "are"
        let lead = batchCount > 1 ? "Batch \(batch) of \(batchCount): " : ""
        return "\(lead)\(span) of \(imageCount) \(verb) attached, in gallery order."
    }

    /// A run of gallery numbers as they read: `7-12` when they are consecutive, `1, 3 and 4` when they
    /// are not.
    ///
    /// Consecutive is the ordinary case — a gallery is split into batches in order and nothing is left
    /// out — but a batch that skips a frame does exist: a photograph the gallery lists twice travels once
    /// (`PhotoFrameGrouping`), and the frames the batch is asked about are then not a run. Naming those
    /// as a range would tell the model about a photograph that is not attached, and it answers `views`
    /// from exactly this numbering.
    ///
    /// - Parameter positions: distinct gallery numbers, in ascending order.
    static func runPhrase(_ positions: [Int]) -> String {
        guard let first = positions.first, let last = positions.last else { return "" }
        guard positions.count != last - first + 1 else { return "\(first)-\(last)" }
        var parts = positions.map(String.init)
        let tail = parts.removeLast()
        return parts.joined(separator: ", ") + " and " + tail
    }

    /// Strict output shape for one batch's answer — mirrors `ManifestItem`.
    ///
    /// Deliberately its own schema rather than `LotValuationPrompt.itemsSchema`: a manifest line has no
    /// price, and it carries two things a line item does not need — `modelNumber`, which is what the
    /// pricing pass looks the product up by, and `views`, which keeps the gallery numbering attached to
    /// the goods. Asking for money here would invite the model to price a product it has not finished
    /// identifying, which is the mistake the two-pass split exists to avoid.
    ///
    /// `views` is **required** on a line, because a line with no photograph behind it is a line the
    /// model invented, and identity is this pass's entire job. `unreadPhotos` is asked for at the top
    /// level — the other half of that contract: a frame is either named by an item or declared
    /// goods-free, so a batch cannot quietly answer about some of what it was handed — but it is left
    /// out of `required`, because a provider that enforces the schema strictly
    /// (`GeminiValuationService`, whose `responseSchema` this same value will be) would fail a whole
    /// batch over an accounting list, and because JSON mode is advisory anyway: the prompt insists on
    /// it and the decode tolerates its absence (`LotManifestAnswer.answer(fromAnswerText:finishReason:)`).
    static var manifestSchema: ResponseSchemaNode {
        .object(
            description: "The distinct products a batch of one auction pallet's photographs shows.",
            properties: [
                (
                    "manifest",
                    .array(
                        description: "Distinct products the photographs show, most valuable first.",
                        items: .object(
                            description: "One product, counted once across every view in this batch.",
                            properties: manifestItemProperties,
                            required: ["itemName", "quantity", "confidence", "views"]
                        )
                    )
                ),
                (
                    "unreadPhotos",
                    .array(
                        description: "Gallery numbers (1-based) of this batch's photographs that show no sellable goods. Empty when every frame held something.",
                        items: .number(description: "Gallery position of one photograph.")
                    )
                )
            ],
            required: ["manifest"]
        )
    }

    /// The properties of one manifest line (`ManifestItem`).
    private static var manifestItemProperties: [(String, ResponseSchemaNode)] {
        [
            ("itemName", .string(description: "Product name with brand, size and pack count as the label gives them.")),
            ("brand", .string(description: "Brand on the goods, when it could be read. Empty string otherwise.")),
            ("modelNumber", .string(description: "Printed model, part or SKU number. Empty string when none was legible.")),
            ("category", .string(description: "What kind of goods this is, e.g. 'household', 'tools', 'toys'.")),
            ("quantity", .number(description: "Units of this product this batch supports, counted once per product.")),
            ("condition", .string(description: "New, shelf wear, opened, damaged or untested, as the photographs show it.")),
            ("packaging", .string(description: "Sealed retail, open box, shrink-wrapped case, loose, no packaging.")),
            (
                "identifiers",
                .array(
                    description: "Barcode digits and model / part / SKU numbers read in this batch, exactly as printed.",
                    items: .string(description: "One identifier.")
                )
            ),
            ("labelText", .string(description: "What the label says, copied as read, 20 words at most. Empty when nothing was legible.")),
            (
                "confidence",
                .string(
                    description: "Identification confidence for this item.",
                    values: DiscoveredItem.Confidence.allCases.map(\.rawValue)
                )
            ),
            (
                "views",
                .array(
                    description: "Gallery numbers (1-based) of the photographs this item was seen in.",
                    items: .number(description: "Gallery position of one photograph.")
                )
            ),
            ("notes", .string(description: "Anything this batch wants to flag about this item."))
        ]
    }

    /// Ground rules for the **pricing** pass: a settled inventory, turned into priced line items.
    ///
    /// This is the half of the route that carries no photographs, and the rules say what that means:
    /// the manifest is the pallet (rule 1), the figures are line totals for the quantity the manifest
    /// already settled (rule 3), and the price comes off the product's identity rather than off pixels
    /// (rule 2). It interpolates `LotValuationPrompt.valuationRules` rather than restating them, so the
    /// shared pricing vocabulary — retail versus resale, the confidence words, what `evidence` is for —
    /// is spelled once for every pass. Only that block's twelve-line cap needs overruling, because an
    /// inventory is not allowed to shrink to fit a prompt.
    static let pricingSystemInstruction = """
    You are pricing a liquidation-auction pallet whose contents have already been read off its \
    photographs and settled into a manifest. The manifest below lists the distinct products the pallet \
    holds, each counted once across every view the batches carried. No photographs are attached: this \
    pass turns names and counts into money.

    Rules:
    1. Price every line of the manifest and price nothing else. The inventory is settled — do not add a \
    line, drop a line or re-count one — and the pallet's value is the sum of the lines you return.
    2. Look each line up from what identifies it, in this order: the brand with the model, part or SKU \
    number; the brand with the printed size, weight and pack count; the barcode digits; and only then \
    the category. A price for the exact product beats a price for something that looks similar, and the \
    manifest's `modelNumber`, `identifiers`, `labelText` and `category` are the evidence you have to \
    work from.
    3. `retailValue` and `resaleValue` are totals for the LINE: the unit price multiplied by the \
    manifest's `quantity`. Twelve units at $9.99 retail is $119.88 for the line, not $9.99. A line that \
    carries a `countConflict` is one the batches read different counts for, and the manifest already \
    holds the count the better sighting supported: price the `quantity` you were given and do not \
    re-count it, average it or adjust it.
    4. Copy the manifest's wording into `itemName`, its `quantity` into `quantity`, and its `views` \
    into `photos`, so the table can still say which photographs a figure came off and how many units \
    the line covers.
    \\(valuationRules)
    10. This pass is the exception to rule 9 above: return one line item for every line of the manifest, \
    however many there are, most valuable first. An inventory that does not fit in twelve lines is \
    still an inventory.
    """

    /// The pricing question: the listing text, the manifest as JSON, and the contract every other pass
    /// is held to.
    ///
    /// - Parameters:
    ///   - manifestText: the manifest rendered by `render(_:limit:)`.
    ///   - omitted: how many manifest lines did not fit the prompt's budget. Stated in the prompt when
    ///     it is not zero, because a pricing pass that silently prices part of a pallet would report a
    ///     value for a pallet that is not there.
    ///   - schemaText: JSON Schema text to embed, for a provider whose JSON mode wants a format example
    ///     in the prompt (DeepSeek). The shape is always `LotValuationPrompt.itemsSchema`, so a priced
    ///     manifest decodes exactly like any other valuation.
    static func pricingPrompt(
        description: String,
        manifestText: String,
        itemCount: Int,
        unitCount: Int,
        omitted: Int = 0,
        evidence: LotImageEvidence? = nil,
        schemaText: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append(
            "Price this pallet's inventory: \(itemCount) distinct item(s), \(unitCount) unit(s) in "
                + "total, read off its photographs and counted once each. Return one line item per "
                + "manifest line, with retail and resale totals for the whole line."
        )
        if description.isEmpty {
            lines.append("No listing text was captured.")
        } else {
            lines.append("Auction listing details:")
            lines.append(description)
        }
        lines.append(contentsOf: evidence?.promptLines ?? [])
        lines.append("The manifest, as json — its lines are the pallet:")
        lines.append(manifestText)
        if omitted > 0 {
            lines.append(
                "\(omitted) further manifest line(s) did not fit this prompt: price what is listed "
                    + "above and say in `notes` that the pallet is longer than the manifest you were given."
            )
        }
        lines.append(contentsOf: LotValuationPrompt.outputContractLines(schemaText: schemaText))
        return lines.joined(separator: "\n")
    }

    /// Longest manifest slab one pricing prompt carries, in characters.
    ///
    /// The same bound, for the same reason, as `PhotoReadingPromptText.maximumLength`: a slab longer
    /// than this is billed as input tokens without improving an answer, and what did not fit is
    /// *reported* (in the prompt, and in the run log) rather than silently dropped. A manifest built
    /// from six-frame batches is far inside it — a forty-item inventory is a few thousand characters —
    /// so this is the guard for a warehouse rather than a bound a pallet meets.
    static let maximumLength = 16_000

    /// Renders a manifest as the JSON slab the pricing prompt carries.
    ///
    /// Re-encoding the *decoded* manifest, rather than quoting a batch's raw answer, keeps the prompt's
    /// example in exactly the shape `ManifestPayload` decodes — a fenced or chatty answer can never
    /// smuggle prose into the request that prices it (the same reason `ValuationPayload.from(items:)`
    /// and `PhotoReadingPromptText` exist).
    ///
    /// - Returns: the JSON array text, and how many items were left out of it.
    static func render(_ manifest: PalletManifest, limit: Int = maximumLength) -> (text: String, omitted: Int) {
        let encoder = JSONEncoder()
        var pieces: [String] = []
        var used = 2
        var omitted = 0

        for item in manifest.items {
            guard let data = try? encoder.encode(ManifestPayload.Item(item)),
                  let piece = String(data: data, encoding: .utf8) else {
                omitted += 1
                continue
            }
            // The first item always travels, however long it is: a manifest with nothing in it asks
            // the model to price nothing.
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

// MARK: - Answer decoding

/// The JSON one batch's answer is expected to produce.
///
/// Every field is optional and defaulted on the way into `ManifestItem`, for the same reason
/// `ValuationPayload`'s are: DeepSeek offers `json_object` mode and nothing stricter, so a decode must
/// never fail over a key the prompt asked for. `quantity` is read as a `Double` because JSON has one
/// number type, and models write `6` and `6.0` alike — and so are `views`, for the same reason.
///
/// `Encodable` as well as `Decodable` because the pricing pass is handed the *decoded* manifest
/// re-encoded in exactly this shape (`render(_:limit:)`), which is what stops a chatty or fenced batch
/// answer from smuggling prose into the request that prices it.
struct ManifestPayload: Codable {

    /// One manifest line as a batch reported it.
    struct Item: Codable {
        var itemName: String?
        var brand: String?
        var modelNumber: String?
        var category: String?
        var quantity: Double?
        var condition: String?
        var packaging: String?
        var identifiers: [String]?
        var labelText: String?
        var confidence: String?
        var views: [Double]?
        var notes: String?

        /// What the *fold* found rather than what a batch said: two of them read different counts for this
        /// product, and which count the inventory kept (`ManifestItem.countConflictNote`). Absent when the
        /// batches agreed, which is the ordinary case.
        ///
        /// Written here and never read back — `item(from:)` ignores it, because a conflict is a conclusion
        /// about two batches rather than something a batch can report about itself, and no schema asks a
        /// batch for one. It travels because the pricing pass is the only place a count becomes money: the
        /// model is multiplying out a number the fold had to *resolve*, and rule 3 tells it what to do
        /// about that.
        var countConflict: String?

        /// The wire form of a manifest line, for the prompt that prices it. Empty fields are left out
        /// rather than sent as empty strings, the way `ValuationPayload.from(items:)` renders a line
        /// item: the model then sees the shape a batch actually produces.
        init(_ item: ManifestItem) {
            itemName = item.itemName.isEmpty ? nil : item.itemName
            brand = item.brand.isEmpty ? nil : item.brand
            modelNumber = item.modelNumber.isEmpty ? nil : item.modelNumber
            category = item.category.isEmpty ? nil : item.category
            quantity = Double(item.quantity)
            condition = item.condition.isEmpty ? nil : item.condition
            packaging = item.packaging.isEmpty ? nil : item.packaging
            identifiers = item.identifiers.isEmpty ? nil : item.identifiers
            labelText = item.labelText.isEmpty ? nil : item.labelText
            confidence = item.confidence.isEmpty ? nil : item.confidence
            views = item.views.isEmpty ? nil : item.views.map(Double.init)
            notes = item.notes.isEmpty ? nil : item.notes
            countConflict = item.countConflictNote
        }
    }

    var manifest: [Item]?

    /// Gallery numbers of this batch's photographs that show nothing sellable.
    ///
    /// Read as `Double` for the same reason `views` is, and optional because a batch that answers in
    /// JSON mode can leave the key out — an answer that names its goods but never mentions the frames
    /// it found empty is *reported* by the route rather than rejected here
    /// (`ManifestBatchAnswer.unaccountedFrames(among:)`).
    var unreadPhotos: [Double]?
}

/// One batch's answer, decoded: the items it read and the frames it declared goods-free.
///
/// The two halves are what the batch contract asks of every attached photograph — it is named in some
/// item's `views`, or it is listed in `unreadPhotos` — so this is the unit the route folds
/// (`PalletManifest.absorb(_:)`) and the unit that can be asked what it accounted for.
struct ManifestBatchAnswer: Sendable {

    /// The distinct products the batch read, in the order it listed them.
    var items: [ManifestItem] = []

    /// Gallery numbers the batch read and found nothing sellable in, in gallery order and once each.
    var unreadPhotos: [Int] = []

    /// The frames of a batch this answer accounts for neither by naming them in an item's `views` nor
    /// by declaring them in `unreadPhotos`.
    ///
    /// Named rather than resolved: a frame in no list is a frame the model looked at and said nothing
    /// about — the inventory may be short the product it showed — whereas a frame it *did* name is
    /// accounted for however the two lists disagree about it. What the caller does with the difference
    /// is the caller's business; the contract it is measured against is stated here.
    ///
    /// - Parameter positions: the gallery numbers of the frames that travelled with the batch, in
    ///   gallery order, which is what the batch was told to answer about.
    func unaccountedFrames(among positions: [Int]) -> [Int] {
        let named = Set(items.flatMap(\.views))
        let declared = Set(unreadPhotos)
        return positions.filter { !named.contains($0) && !declared.contains($0) }
    }
}

/// Turns one batch's answer into manifest items.
enum LotManifestAnswer {

    /// Longest label wording kept per item, so a wall of label text cannot crowd out the pallet.
    static let maximumLabelLength = 160

    /// Longest `notes` kept per item.
    static let maximumProseLength = 240

    /// Decodes one batch's answer.
    ///
    /// An **empty manifest is not an error**: a batch that showed the pallet's side or the floor is a
    /// batch that was read, and the honest answer for it is no items. This throws only when the answer
    /// carried no manifest at all — and the *route* is what decides that a pallet whose every batch came
    /// back empty needs its gallery pass instead (see `DeepSeekValuationService.value(subject:)`).
    ///
    /// `unreadPhotos` is read when it is there and reads as an empty list when it is not, because the
    /// key is the batch's *accounting* rather than its findings: an answer that named its goods has
    /// told the app what the frames held, and a missing list is a hole the route reports rather than a
    /// reason to throw an inventory away.
    static func answer(fromAnswerText text: String, finishReason: String?) throws -> ManifestBatchAnswer {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValuationError.noContent(finishReason: finishReason)
        }
        guard let data = LotValuationAnswer.extractJSONObject(from: text).data(using: .utf8) else {
            throw ValuationError.malformedResponse("the manifest was not valid UTF-8")
        }

        let payload: ManifestPayload
        do {
            payload = try JSONDecoder().decode(ManifestPayload.self, from: data)
        } catch {
            throw ValuationError.malformedResponse(error.localizedDescription)
        }
        guard let reported = payload.manifest else {
            throw ValuationError.malformedResponse("the answer carried no manifest key")
        }
        return ManifestBatchAnswer(
            items: reported.compactMap(item(from:)),
            unreadPhotos: positions(from: payload.unreadPhotos)
        )
    }

    /// Normalises one reported line, or drops it when it names nothing at all.
    ///
    /// Shares `LotPhotoScanAnswer`'s clamping — a quantity of `-3` or `999999` is the model slipping,
    /// not a reason to throw away a line that names a barcode — so a count means the same thing on
    /// either route.
    static func item(from reported: ManifestPayload.Item) -> ManifestItem? {
        let name = (reported.itemName ?? "").condensedWhitespace
        guard !name.isEmpty else { return nil }

        return ManifestItem(
            itemName: name,
            brand: (reported.brand ?? "").condensedWhitespace,
            modelNumber: (reported.modelNumber ?? "").condensedWhitespace,
            category: (reported.category ?? "").condensedWhitespace,
            quantity: LotPhotoScanAnswer.quantity(from: reported.quantity),
            condition: (reported.condition ?? "").condensedWhitespace,
            packaging: (reported.packaging ?? "").condensedWhitespace,
            identifiers: LotPhotoScanAnswer.identifiers(from: reported.identifiers),
            labelText: (reported.labelText ?? "").condensedWhitespace.truncated(to: maximumLabelLength),
            confidence: DiscoveredItem.Confidence(rawText: reported.confidence ?? "").rawValue,
            views: positions(from: reported.views),
            notes: (reported.notes ?? "").condensedWhitespace.truncated(to: maximumProseLength)
        )
    }

    /// Distinct, positive gallery positions, in order — the reading both `views` and `unreadPhotos` are
    /// held to, since they answer in the same numbering.
    ///
    /// Clamped rather than rejected, like the count: a `views` list naming photograph 0 or 900 is the
    /// model slipping, and the item's identity is worth more than the slip. The same applies to a frame
    /// declared unread, which is why one function serves both rather than two that could drift.
    static func positions(from raw: [Double]?) -> [Int] {
        var positions: [Int] = []
        for entry in raw ?? [] {
            guard entry.isFinite else { continue }
            let position = Int(entry.rounded())
            guard position > 0, !positions.contains(position) else { continue }
            positions.append(position)
        }
        return positions.sorted()
    }
}
