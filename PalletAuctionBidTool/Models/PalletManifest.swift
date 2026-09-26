//
//  PalletManifest.swift
//  PalletAuctionBidTool
//
//  What the photographs of one pallet show, before any of it is priced.
//
//  A manifest is the unit of work the batched route is built from: a *batch* of a pallet's photographs
//  goes to the model in one request, the model answers with the distinct products that batch shows,
//  and every batch's answer is folded into one inventory here (`absorb(_:)`) which a second, text-only
//  request then prices (`LotManifestPrompt.pricingPrompt`). Splitting identity from price is what the
//  batching needs rather than a stylistic choice:
//
//  * Identity needs *pixels and neighbours*. Whether the carton at the front is the carton at the side
//    is a question only a request that carries several views can answer, and it is the question that
//    keeps a pallet from being paid for twice — `absorb(_:)` is the same rule the per-photograph
//    reconciliation applies to its readings (see `LotPhotoScanPrompt.aggregationSystemInstruction`).
//  * Price needs *a product and a marketplace*, not a photograph: once the goods are named, a barcode,
//    a model number and a printed size pin a shelf price, and extra resolution does not improve it. So
//    the pricing pass carries no images at all, which is what makes it cheap next to what it replaces.
//
//  Nothing here is authoritative and nothing here is a price. A manifest says what the pallet holds;
//  the line items the pricing pass returns are what the table draws, and they decode through exactly
//  the shape every other pass's answer does (`LotValuationPrompt.itemsSchema`).
//

import Foundation

/// One distinct product a pallet's photographs showed, counted once across every view they carried.
struct ManifestItem: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity so the manifest list can diff its rows.
    ///
    /// Deliberately not part of `CodingKeys`: what travels is `ManifestPayload` — the shape a batch is
    /// asked for, and the slab the pricing prompt quotes back (`LotManifestPrompt.render(_:limit:)`) —
    /// and an id the model never produced would be noise there. The conformance is for this machine's sake
    /// (a manifest is an `Encodable` value like every other model here), not for the wire.
    var id: UUID = UUID()

    /// The product, named as precisely as the batch supports: brand, product line, size and pack count
    /// when they were legible, e.g. `Energizer MAX AA alkaline batteries, 24-pack`.
    var itemName: String

    /// Brand on the goods, when it could be read. Kept apart from `itemName` because it is one of the
    /// fields `isSameProduct(as:)` leans on to decide that two sightings are one product.
    var brand: String = ""

    /// Model, part or SKU number as printed, or empty when none was legible. The strongest claim a
    /// pallet's packing makes about its contents, and therefore the first thing `isSameProduct(as:)`
    /// looks for.
    var modelNumber: String = ""

    /// What kind of goods this is (`household`, `tools`, `toys`) — what the pricing pass falls back to
    /// when the name is all the photographs supported.
    var category: String = ""

    /// Units of this product the pallet holds, as the batches that showed it support. Never a sum of
    /// the batches' counts: they are views of one pallet, not lots of goods (`merge(_:)`).
    var quantity: Int = 0

    /// `new`, `shelf wear`, `opened`, `damaged`, `untested`, as the photographs showed it.
    var condition: String = ""

    /// `sealed retail`, `open box`, `shrink-wrapped case`, `loose`, `no packaging`.
    var packaging: String = ""

    /// Barcodes, model numbers and SKU numbers read off the goods, exactly as printed.
    var identifiers: [String] = []

    /// The label wording this item rests on, copied as read and short enough to quote.
    var labelText: String = ""

    /// Identification confidence for this item: `High`, `Med` or `Low`.
    var confidence: String = ""

    /// 1-based gallery positions this item was seen in — which photograph a figure came off, one step
    /// earlier than the line items' own `photos`.
    var views: [Int] = []

    /// Anything the batch wanted to flag about this item.
    var notes: String = ""

    init(
        id: UUID = UUID(),
        itemName: String,
        brand: String = "",
        modelNumber: String = "",
        category: String = "",
        quantity: Int = 0,
        condition: String = "",
        packaging: String = "",
        identifiers: [String] = [],
        labelText: String = "",
        confidence: String = "",
        views: [Int] = [],
        notes: String = ""
    ) {
        self.id = id
        self.itemName = itemName
        self.brand = brand
        self.modelNumber = modelNumber
        self.category = category
        self.quantity = quantity
        self.condition = condition
        self.packaging = packaging
        self.identifiers = identifiers
        self.labelText = labelText
        self.confidence = confidence
        self.views = views
        self.notes = notes
    }

    /// Every key but `id`.
    private enum CodingKeys: String, CodingKey {
        case itemName, brand, modelNumber, category, quantity, condition, packaging
        case identifiers, labelText, confidence, views, notes
    }
}

extension ManifestItem {

    /// Typed view of `confidence` for the merge and for the row.
    var confidenceLevel: DiscoveredItem.Confidence { DiscoveredItem.Confidence(rawText: confidence) }

    /// `Energizer MAX AA alkaline batteries · Energizer · E91BP-24` — the one-line form the detail card
    /// and the console quote. The brand is left out when the name already says it.
    var displayName: String {
        var parts = [itemName]
        if !brand.isEmpty, !itemName.localizedCaseInsensitiveContains(brand) { parts.append(brand) }
        if !modelNumber.isEmpty { parts.append(modelNumber) }
        return parts.joined(separator: " · ")
    }

    /// `photographs 2, 5` — where this item was seen, when the batch said.
    var viewsPhrase: String? {
        guard !views.isEmpty else { return nil }
        let positions = views.sorted().map(String.init).joined(separator: ", ")
        return views.count == 1 ? "photograph \(positions)" : "photographs \(positions)"
    }

    /// `High · photographs 2, 5 · UPC 609032993551` — the confidence, the frames this item was seen in
    /// and the codes read off it, as the one line the detail card prints under the name. The mirror of
    /// `PhotoObject.detailPhrase`, one route over.
    var detailPhrase: String {
        var parts = [confidenceLevel.rawValue]
        if let viewsPhrase { parts.append(viewsPhrase) }
        parts.append(contentsOf: identifiers)
        return parts.joined(separator: "  ·  ")
    }

    /// What makes two sightings one product.
    ///
    /// Three questions, strongest evidence first, because a batch may have read more on one sighting than
    /// on another and because the fold has to land the same way whichever batch answered first
    /// (`absorb(_:)`), which is the whole point of it: a carton two batches saw once each is one carton,
    /// and a pallet paid for twice is the mistake this exists to stop.
    ///
    /// * **A shared product code** (`productCodes`). A UPC/EAN/GTIN read off the goods that both
    ///   sightings carry is the goods' own name for themselves, and it outranks everything either batch
    ///   wrote around it: two batches that decoded the same barcode photographed one product, whatever
    ///   each of them called it. This is the question a barcode visible in only one batch's photographs
    ///   used to fail, and the app's own reading of every frame is what makes it answerable anyway
    ///   (`DeepSeekValuationService` folds the reader's decodes into the items it returns).
    /// * **Model numbers, when both batches read one.** Two different model numbers are two products
    ///   however alike they are named. Asked after the codes because a code is read off the goods while a
    ///   model number is read off a label, and a label can be misread.
    /// * **Otherwise the names themselves** (`namesDescribeSameProduct`), compared as the product-shaped
    ///   words they are made of, because a barcode one batch could not read does not make its candles
    ///   somebody else's candles: `Yankee Candle 22 oz jar` and `yankee candles, 22oz` are one item, while
    ///   a pack count or a size that disagrees keeps two (`Energizer MAX AA` is not `Energizer MAX AAA`).
    ///
    /// The brand has to be *compatible* for the name question — equal, or one a prefix of the other,
    /// which is what a partly obscured label reads as (`Yankee` for `Yankee Candle`) — and is not
    /// consulted for the code questions: a batch that never read the brand, or misread it, must not stop
    /// a decoded barcode from folding two sightings.
    func isSameProduct(as other: ManifestItem) -> Bool {
        if !productCodes.isDisjoint(with: other.productCodes) { return true }

        let mine = Self.normalised(modelNumber)
        let theirs = Self.normalised(other.modelNumber)
        if !mine.isEmpty, !theirs.isEmpty { return mine == theirs }

        guard Self.compatible(Self.normalised(brand), Self.normalised(other.brand)) else { return false }
        return Self.namesDescribeSameProduct(itemName, other.itemName)
    }

    /// Folds a second sighting of this product into the first.
    ///
    /// The rules are the ones the per-photograph reconciliation applies to readings, for the same
    /// reason — two batches are views of one pallet, not two pallets — and they are written to be
    /// **order-independent**, because the batches answer a few at a time and whichever landed first is
    /// not a fact about the pallet:
    ///
    /// * **Quantity is the larger count, never the sum.** Six cartons visible in two batches is six.
    /// * **Every other field keeps the more informative reading** — the longer string, which is the batch
    ///   that read more of the label — so a model number one batch found survives the other's blank, and
    ///   a partial brand cannot overwrite a complete one. Equal-length readings keep the one already
    ///   held.
    /// * **Views and identifiers accumulate**, so the priced line can still name every photograph it
    ///   rests on.
    /// * **Confidence keeps the strongest** of the two: one legible label identifies the goods for the
    ///   pallet as a whole.
    mutating func merge(_ other: ManifestItem) {
        quantity = max(quantity, other.quantity)
        itemName = Self.moreInformative(itemName, other.itemName)
        brand = Self.moreInformative(brand, other.brand)
        modelNumber = Self.moreInformative(modelNumber, other.modelNumber)
        category = Self.moreInformative(category, other.category)
        condition = Self.moreInformative(condition, other.condition)
        packaging = Self.moreInformative(packaging, other.packaging)
        labelText = Self.moreInformative(labelText, other.labelText)
        notes = Self.moreInformative(notes, other.notes)
        if confidenceLevel.sortRank > other.confidenceLevel.sortRank {
            confidence = other.confidenceLevel.rawValue
        }
        for identifier in other.identifiers where !identifiers.contains(where: {
            $0.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            identifiers.append(identifier)
        }
        for position in other.views where !views.contains(position) {
            views.append(position)
        }
        views.sort()
    }

    /// Every reading on this item that is *shaped* like the goods' own catalogue number.
    ///
    /// `identifiers` is what the app's reader and the batches put there — barcodes, printed SKUs, and
    /// whatever else on the packing looked like a code — and `modelNumber` is the same kind of fact kept
    /// in its own field, because a batch that reads `0123456789012` under a barcode may report it as an
    /// identifier where the next puts the same digits in `modelNumber`. Both are reduced through
    /// `productCode(from:)` so that "do these two sightings carry the same code" is asked of comparable
    /// strings, and so that the noise on a pallet's labels cannot answer it.
    var productCodes: Set<String> {
        Set(
            (identifiers + (modelNumber.isEmpty ? [] : [modelNumber]))
                .compactMap(Self.productCode(from:))
        )
    }

    /// One reading reduced to the form two batches can be compared in, or `nil` when it is not shaped
    /// like a catalogue code at all.
    ///
    /// The two shapes are the ones `LotImageDigest` keeps when it reads a label: a bare GTIN — 8 to 14
    /// digits, the lengths EAN-8, UPC-A, EAN-13 and ITF-14 run to — and a mixed code of letters and
    /// digits (`E91BP-24`, `DCS620D`), which is what a model or part number looks like. Everything else
    /// is rejected on purpose: a word with no digit in it is not a code, and a short run of digits is as
    /// likely to be a price, a weight, a quantity or a tracking number as a catalogue number. Erring
    /// this way costs a fold the name question may still make; erring the other way folds two products
    /// into one line and quietly loses one of them.
    static func productCode(from raw: String) -> String? {
        let code = normalised(raw)
        let digits = code.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        if digits.count == code.count { return (8...14).contains(code.count) ? code : nil }
        return code.count >= 5 ? code : nil
    }

    /// `true` when two product names describe the same goods.
    ///
    /// Names are compared as words rather than as strings, because two batches rarely punctuate one
    /// label the same way — one writes `Yankee Candle 22 oz jar` and the next `yankee candles, 22oz` —
    /// and because a barcode the second batch could not read is not a reason for its candles to become
    /// somebody else's candles. `nameTokens(_:)` reduces each name to the words that say what the goods
    /// *are*, and the rule is then the one this file already applies to a single field: the shorter
    /// naming has to be accounted for by the longer one.
    ///
    /// A size or pack count both names carry has to agree first. That is the difference between two
    /// products that read alike — `24-pack` and `48-pack` of the same batteries are two different cases
    /// — and requiring it is what keeps the word comparison from merging them.
    static func namesDescribeSameProduct(_ mine: String, _ theirs: String) -> Bool {
        let left = nameTokens(mine)
        let right = nameTokens(theirs)
        guard !left.isEmpty, !right.isEmpty else { return false }

        // A name carrying no size at all is not held to this: the batch may simply not have read one.
        let mySizes = left.filter(Self.isSizeToken)
        let theirSizes = right.filter(Self.isSizeToken)
        guard mySizes.isEmpty || theirSizes.isEmpty || !mySizes.isDisjoint(with: theirSizes) else {
            return false
        }

        let smaller = left.count <= right.count ? left : right
        let larger = left.count <= right.count ? right : left
        // One shared word is not a naming — `Candles` says too little to identify anything — so a name
        // of one word has to read exactly like the other. Beyond that every word of the shorter name has
        // to appear in the longer one, which is what makes `Yankee Candle 22 oz jar` and
        // `yankee candles, 22oz` one product and leaves `MAX AA, 24-pack` beside `MAX AAA, 24-pack` two.
        if smaller.count == 1 { return left == right }
        return smaller.isSubset(of: larger)
    }

    /// A product name reduced to the words that say what the goods *are*.
    ///
    /// Case, punctuation and word order are what two readings of one label disagree about, so they are
    /// what this drops. Two things are kept, in one canonical form each, because both decide whether two
    /// sightings are two products:
    ///
    /// * **Sizes and pack counts.** `22 oz`, `22oz` and `22-ounce` all become `22oz`, and `24 pk` and
    ///   `24-pack` become `24ct`, so a size written two ways still agrees while `24` and `48` do not.
    /// * **The words themselves**, singularised (`candles` and `candle` are one word) and stripped of
    ///   the vocabulary that says how goods are sold rather than what they are (`pack`, `case`,
    ///   `assorted`, `new`), so one carton described at two lengths of breath still matches.
    static func nameTokens(_ text: String) -> Set<String> {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        var tokens: Set<String> = []
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1

            if word.allSatisfy(\.isNumber) {
                // The number and the unit it is written with are one fact about the product, so they
                // become one token — and the walk steps past the unit to prove it did.
                if let measured = measuredSize(number: word, after: index, in: words) {
                    tokens.insert(measured.token)
                    index = measured.next
                } else {
                    tokens.insert(word)
                }
                continue
            }

            // A unit with no number in front of it (`oz`, `count`) is the tail of a size whose number
            // went unread, and a filler word carries no product meaning at all: neither can tell two
            // products apart, so neither becomes a token.
            guard measureUnits[word] == nil, !fillerWords.contains(word) else { continue }
            tokens.insert(singular(word))
        }
        return tokens
    }

    /// `true` for a token that is a number with a unit on it — a size or a pack count, which is a fact
    /// about the product rather than a description of it.
    private static func isSizeToken(_ token: String) -> Bool {
        let digits = token.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < token.count else { return false }
        return measureUnitNames.contains(String(token.dropFirst(digits.count)))
    }

    /// A number and the unit written after it, as one canonical token, and where the walk resumes.
    ///
    /// `nil` when the words after the number are not a unit at all, which is what keeps `24 batteries`
    /// from reading as a size. Filler words are stepped over first, so that the one size with two
    /// spellings in common use — `12 fl oz` — reduces to the same `12oz` that `12oz` does.
    private static func measuredSize(
        number: String,
        after index: Int,
        in words: [String]
    ) -> (token: String, next: Int)? {
        var cursor = index
        while cursor < words.count {
            if let unit = measureUnits[words[cursor]] { return (number + unit, cursor + 1) }
            guard fillerWords.contains(words[cursor]) else { return nil }
            cursor += 1
        }
        return nil
    }

    /// A word reduced to its singular, so a name that pluralised one noun and a name that did not are
    /// still the same name. Deliberately crude: a stemmer that got `candles` wrong would be worse than
    /// one that leaves `glass` alone.
    private static func singular(_ word: String) -> String {
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("ss") { return word }
        if ["ches", "shes", "sses", "xes", "zes"].contains(where: { word.hasSuffix($0) }) {
            return String(word.dropLast(2))
        }
        guard word.hasSuffix("s"), word.count > 3 else { return word }
        return String(word.dropLast())
    }

    /// The units a name's numbers may be written with, and the one form each is kept in. The values are
    /// what a size token ends with (`isSizeToken(_:)`), so the two halves of a size cannot drift apart.
    private static let measureUnits: [String: String] = [
        "oz": "oz", "ounce": "oz", "ounces": "oz",
        "ml": "ml", "milliliter": "ml", "milliliters": "ml",
        "millilitre": "ml", "millilitres": "ml",
        "l": "l", "liter": "l", "liters": "l", "litre": "l", "litres": "l",
        "gal": "gal", "gallon": "gal", "gallons": "gal",
        "lb": "lb", "lbs": "lb", "pound": "lb", "pounds": "lb",
        "g": "g", "gram": "g", "grams": "g",
        "kg": "kg", "kilogram": "kg", "kilograms": "kg",
        "ct": "ct", "cts": "ct", "count": "ct", "counts": "ct",
        "pk": "ct", "pks": "ct", "pack": "ct", "packs": "ct",
        "package": "ct", "packages": "ct",
        "pc": "ct", "pcs": "ct", "piece": "ct", "pieces": "ct",
        "set": "ct", "sets": "ct",
        "roll": "roll", "rolls": "roll", "sheet": "sheet", "sheets": "sheet",
        "bag": "bag", "bags": "bag", "can": "can", "cans": "can",
        "bottle": "bottle", "bottles": "bottle",
        "box": "box", "boxes": "box", "case": "case", "cases": "case",
        "x": "x"
    ]

    /// The forms a size token may end with. Derived from `measureUnits`, so a unit added there is
    /// recognised here without a second list to keep in step.
    private static let measureUnitNames = Set(measureUnits.values)

    /// Words that say how goods are sold rather than what they are. Dropping them is what lets one
    /// carton described at two lengths of breath read as one product, and not one of them tells two
    /// products apart.
    private static let fillerWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "with", "without", "for", "in", "on", "to", "from", "by",
        "new", "sealed", "open", "opened", "assorted", "mixed", "various", "item", "items", "each",
        "per", "size", "style", "styles", "type", "brand", "fl", "carton"
    ]

    /// The longer of two readings of the same field — the one that said more about the goods.
    private static func moreInformative(_ mine: String, _ theirs: String) -> String {
        theirs.count > mine.count ? theirs : mine
    }

    /// `true` when two brand readings could be the same brand: equal, one blank, or one a prefix of the
    /// other.
    private static func compatible(_ mine: String, _ theirs: String) -> Bool {
        if mine.isEmpty || theirs.isEmpty { return true }
        return mine == theirs || mine.hasPrefix(theirs) || theirs.hasPrefix(mine)
    }

    /// Letters and digits only, lowercased: what makes two namings comparable without pretending to
    /// understand them.
    private static func normalised(_ text: String) -> String {
        String(
            text.lowercased().unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(Character.init)
        )
    }
}

/// The distinct products one pallet's photographs showed, as one value.
///
/// Built by folding every batch's answer in (`absorb(_:)`) and then handed to the pricing pass. Empty
/// is a legitimate state rather than a failure: a batch that showed nothing but the pallet's side
/// returns no items, and a pallet whose *every* batch did is a pallet the route falls back from
/// (`DeepSeekValuationService.value(subject:)`) instead of failing.
///
/// An inventory is also a claim about the gallery, so what the batches found *nothing* in is held here
/// too (`unreadFrames`): the frames a batch declared goods-free are as much part of its answer as the
/// items it named, and the two together are what the route can measure the batches' accounting against.
struct PalletManifest: Codable, Hashable, Sendable {

    var items: [ManifestItem] = []

    /// Gallery numbers the batches read and found nothing sellable in (`ManifestBatchAnswer.unreadPhotos`).
    ///
    /// The other half of what the batches were asked for: every photograph a batch was handed is either
    /// named in some item's `views` or declared here, so `photographCount` plus this list is what the
    /// inventory says it accounted for out of the gallery. Unioned and sorted as the batches are folded,
    /// in whatever order they answered.
    ///
    /// A frame one batch declared unread and another named in an item is a contradiction between two
    /// batches, and both facts are kept: the fold's job is to hold what the batches said, not to pick a
    /// winner between them (the route reports a frame that *neither* list mentions —
    /// `ManifestBatchAnswer.unaccountedFrames(among:)`).
    var unreadFrames: [Int] = []

    var isEmpty: Bool { items.isEmpty }

    var count: Int { items.count }

    /// Units the manifest accounts for — what the pricing pass multiplies a unit price by.
    var unitCount: Int { items.reduce(0) { $0 + max($1.quantity, 0) } }

    /// How many of the gallery's photographs at least one item was seen in.
    ///
    /// Reported rather than assumed: a batch that read a frame and found nothing in it is a fact about
    /// the pallet, and this is the number that says how much of the gallery the manifest speaks for.
    var photographCount: Int {
        var seen = Set<Int>()
        for item in items { seen.formUnion(item.views.filter { $0 > 0 }) }
        return seen.count
    }

    /// Folds one batch's answer in, counting a product once however many batches saw it.
    mutating func absorb(_ batch: [ManifestItem]) {
        for item in batch {
            guard let index = items.firstIndex(where: { $0.isSameProduct(as: item) }) else {
                items.append(item)
                continue
            }
            items[index].merge(item)
        }
    }

    /// Folds one batch's whole answer in: its items (`absorb(_:)`) and the frames it declared goods-free
    /// (`noteUnread(_:)`), which together are everything the batch said about the frames it was handed.
    mutating func absorb(_ answer: ManifestBatchAnswer) {
        absorb(answer.items)
        noteUnread(answer.unreadPhotos)
    }

    /// Records frames a batch read and found nothing sellable in, in gallery order and once each.
    ///
    /// Clamped like `views` (`LotManifestAnswer.positions(from:)`): a batch can only answer for frames
    /// the gallery has, and nothing outside it belongs in an account of this pallet.
    mutating func noteUnread(_ frames: [Int]) {
        guard !frames.isEmpty else { return }
        unreadFrames = Set((unreadFrames + frames).filter { $0 > 0 }).sorted()
    }

    /// The inventory split into reply-sized pieces, in the order it holds them.
    ///
    /// Pricing asks for one line item per manifest line, and what a model can enumerate in a single reply
    /// is bounded — the app's own single-pass prompt caps itself at twelve for the same reason, and a
    /// truncated answer is a decode failure rather than a partial valuation. So the pricing pass walks
    /// these rather than the whole manifest: a pallet's inventory is usually one piece, and a warehouse's
    /// is priced in a few complete replies. The order is arbitrary within a piece (the model is asked for
    /// "most valuable first" of what it is given) and stable across them.
    func batches(ofSize limit: Int) -> [PalletManifest] {
        let size = max(1, limit)
        guard items.count > size else { return [self] }
        return stride(from: 0, to: items.count, by: size).map { start in
            PalletManifest(items: Array(items[start..<min(start + size, items.count)]))
        }
    }

    /// The console phrase: `18 distinct item(s) — 41 unit(s) — read from 24 photograph(s)`.
    ///
    /// A batch that declared frames goods-free adds its own clause, because those frames are the
    /// inventory's answer for them — without it the line reads as though the pallet's other photographs
    /// were never looked at.
    var logPhrase: String {
        var parts = [
            "\(count) distinct item(s)",
            "\(unitCount) unit(s)",
            "read from \(photographCount) photograph(s)"
        ]
        if !unreadFrames.isEmpty {
            parts.append("\(unreadFrames.count) of the rest declared empty")
        }
        return parts.joined(separator: " — ")
    }

    /// The row's shorter form: `18 item(s) · 41 unit(s)`.
    var compactPhrase: String { "\(count) item(s) · \(unitCount) unit(s)" }
}
