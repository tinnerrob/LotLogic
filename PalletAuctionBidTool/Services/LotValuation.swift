//
//  LotValuation.swift
//  PalletAuctionBidTool
//
//  Provider-independent half of the valuation layer.
//
//  Two back ends drive the same pipeline (`GeminiValuationService`, `DeepSeekValuationService`), so
//  everything that is not wire format lives here: the error vocabulary, the `ValuationService`
//  seam, the prompt and output schema the models are asked for, the tolerant decode of their
//  answers, image loading, request pacing and the shared retry policy.
//

import Foundation

// MARK: - Errors

/// Everything that can go wrong between "lot scraped" and "lot valued".
///
/// The wording is deliberately provider-neutral: both services raise these, and each one names
/// itself when it wraps a transport failure of its own.
enum ValuationError: LocalizedError, Equatable {
    case missingAPIKey
    case noUsableImages(attempted: Int, reason: String?)
    case imageUnavailable(url: String, reason: String)
    case http(status: Int, message: String)
    /// Rate-limit refusal (HTTP 429): a free-tier per-minute quota, or a concurrency ceiling.
    case rateLimited(status: Int, retryAfter: TimeInterval?, message: String)
    case blocked(reason: String)
    case noContent(finishReason: String?)
    case malformedResponse(String)
    /// Every per-photograph read failed, so a thorough scan had nothing to reconcile. The reason is
    /// the first failure's own text, which is what the operator needs to see (a quota refusal, a
    /// key that is wrong, a gallery of images the provider would not accept).
    case photographReadsFailed(count: Int, reason: String)
    /// The selected provider has no way to read one photograph on its own, so the thorough scan cannot
    /// run against it. Only ever raised by the protocol's default implementations.
    case photoScanUnsupported

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No API key is configured for the selected provider. Paste one into the key field and try again."
        case .noUsableImages(let attempted, let reason):
            "Nothing could be analysed: \(attempted) image(s) were listed but none could be read\(reason.map { " (\($0))" } ?? "") and the card had no text."
        case .imageUnavailable(let url, let reason):
            "Image download failed (\(reason)): \(url)"
        case .http(let status, let message):
            "The valuation API returned HTTP \(status): \(message)"
        case .rateLimited(_, let retryAfter, let message):
            "The valuation API refused the request because the quota or rate limit is used up (\(message)). "
                + (retryAfter.map { "The API asked for a \(Int($0.rounded()))s pause." }
                   ?? "Lower “Requests / min” to match your quota, or wait and re-run.")
        case .blocked(let reason):
            "The request was refused (\(reason)). The lot content may have tripped a safety filter."
        case .noContent(let finishReason):
            "The model returned no text (finish reason: \(finishReason ?? "unknown"))."
        case .malformedResponse(let detail):
            "The model's answer could not be parsed: \(detail)"
        case .photographReadsFailed(let count, let reason):
            "None of the lot's \(count) photograph(s) could be read on its own (\(reason))."
        case .photoScanUnsupported:
            "The selected provider cannot read a lot's photographs one at a time."
        }
    }

    /// Short tag used in per-lot status text.
    var shortReason: String {
        switch self {
        case .missingAPIKey: "missing API key"
        case .noUsableImages: "no readable images"
        case .imageUnavailable: "image unavailable"
        case .http(let status, _): "HTTP \(status)"
        case .rateLimited: "rate limited"
        case .blocked: "blocked by safety filter"
        case .noContent: "empty model answer"
        case .malformedResponse: "unreadable model answer"
        case .photographReadsFailed: "no readable photographs"
        case .photoScanUnsupported: "one-photograph reads unsupported"
        }
    }

    /// The human text for any error, for the places that only want a description.
    ///
    /// A `LocalizedError`'s own `errorDescription` when it has one, and `localizedDescription`
    /// otherwise, so a `URLError` and a `ValuationError` can be logged in the same sentence.
    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Tells a stopped run from a failed one.
///
/// `URLSession` reports a cancelled request as `URLError.cancelled` rather than as
/// `CancellationError`, so both shapes have to be recognized — and the difference matters out loud:
/// a lot whose scan was stopped goes back to "not valued" and stays scannable, while one that failed
/// keeps the reason.
enum ValuationCancellation {

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
        return false
    }
}

/// Result of one lot's appraisal.
struct ValuationOutcome: Sendable {
    var items: [DiscoveredItem]
    /// Photographs the lot offered — what its own page carried, or the card's thumbnails when the
    /// page could not be read.
    var imagesAvailable: Int = 0
    /// Photographs actually attached to the final request. `0` for a text-only answer.
    var imagesSent: Int
    /// Photographs dropped because the set did not fit one request's inline budget — the one number
    /// that keeps "every image" honest. Reported, never silently swallowed (see `LotImageLoader`).
    var imagesSkipped: Int = 0
    var modelID: String
    /// How many model passes produced `items`: `1` for a single multimodal request (Gemini, or a
    /// DeepSeek lot with no photographs), `2` for DeepSeek's text-then-images pipeline.
    var passes: Int = 1
    /// What the app's own barcode-and-label reader found on the photographs before the model saw
    /// them (`LotImageDigest`). `nil` for a text-only pass — an eval never pays for a reading — and
    /// empty-but-present when the photographs were read and had nothing legible on them, which the
    /// console and the row say differently from "no photographs were read".
    var evidence: LotImageEvidence?
    /// What the model made of each photograph, one entry per frame, when the scan read the lot
    /// photograph by photograph (`LotPhotoScan`). Empty for a single-pass appraisal, which is every
    /// scan that predates the thorough path — and the difference is visible: nothing else in this
    /// value says *which picture* a price was read from.
    var readings: [PhotoReading] = []
    /// How many of `readings` came back from this machine's store rather than from a request
    /// (`PhotoReadingStore`). Reported because one is free and the other is not.
    var readingsFromStore: Int = 0
    /// How many requests the thorough scan spent: one per photograph read, plus the reconciliation.
    /// `0` for the single-pass path, whose one request is not a scan step of its own.
    var scanRequests: Int = 0
    /// Why the reconciliation had to be done on this machine, when it did — the readings were folded
    /// into line items by `PhotoReadingMerge` rather than by the model.
    var reconciliationFailure: String?
}

/// Whole-pallet figures guessed from the listing text alone.
///
/// This is the *cheap* pass: no photographs are fetched or billed, so it runs before the expensive
/// imaged scan and gives the table something honest to show while that scan is still queued. It
/// carries no line items on purpose — the row keeps saying "not scanned" until a real valuation
/// lands, and `LotItem.applyValuation(_:imagesAnalyzed:passes:)` retires these numbers when it does.
struct PrePriceEstimate: Equatable, Sendable {

    /// Whole-pallet retail, USD.
    var retail: Double

    /// Whole-pallet resale, USD.
    var resale: Double

    /// How well the listing text supported the guess. Drives the provisional bid ceiling.
    var confidence: DiscoveredItem.Confidence

    /// One short sentence of reasoning, quoted back in the expanded row.
    var rationale: String
}

/// The seam between the pipeline and whatever appraises a lot.
///
/// `AnalysisCoordinator` depends only on this protocol, so a fixture implementation can be
/// injected for previews/tests without touching the network, and the operator can switch between
/// providers without the coordinator knowing. Implementations must be safe to call from any task
/// (see `GeminiValuationService`).
protocol ValuationService: Sendable {
    /// Appraises one lot, attaching **every image the subject carries**.
    ///
    /// There is no image count to configure. How many photographs a lot has is the lot's business —
    /// its own page answers the question, read in full (see
    /// `AuctionScraperService.lotPageImages(for:)`) — so the subject arrives with the complete set
    /// and all of it is sent. What still bounds a request is technical rather than editorial: one
    /// image larger than `maxImageBytes`, or the whole set over the inline budget, is reported as
    /// skipped instead of being smuggled in or silently dropped.
    func value(subject: ValuationSubject) async throws -> ValuationOutcome

    /// Cheap, text-only, whole-pallet first look at one lot: no photographs, no line items.
    ///
    /// Called before `value(subject:)` so the table can show a provisional figure
    /// immediately. Implementations must not send images here — the whole point is that it costs a
    /// fraction of a photographed pass.
    func prePrice(subject: ValuationSubject) async throws -> PrePriceEstimate

    /// Reads **one** photograph, on its own.
    ///
    /// The thorough path's unit of work (`LotPhotoScan`): a single frame, a single question, and a
    /// `PhotoReading` of what that frame shows. Splitting a gallery this way is what makes the
    /// detailed questions possible at all — a prompt that has to describe forty photographs at once
    /// cannot also report where in the frame each product sat, how it is packed and how many units
    /// were visible *from that angle*.
    ///
    /// Implementations must not aggregate across photographs here: the reconciliation is a separate
    /// request with its own prompt, and a reading that has already averaged in another frame is
    /// worthless to it.
    func readPhoto(_ request: PhotoReadingRequest) async throws -> PhotoReading

    /// Reconciles a lot's per-photograph readings into its line items, in one request.
    ///
    /// Receives every reading the scan produced plus any photographs a ceiling kept out of the
    /// per-image path, and returns the same shape a single-pass appraisal returns
    /// (`LotValuationPrompt.itemsSchema`), so nothing downstream can tell the two apart.
    func aggregate(_ request: PhotoAggregationRequest) async throws -> [DiscoveredItem]
}

extension ValuationService {

    /// Default: this provider cannot read photographs one at a time.
    ///
    /// A default implementation rather than two more requirements, so a provider that only ever does
    /// single-pass appraisals — a fixture in a check, a future text-only back end — still conforms, and
    /// the failure is a real error rather than a silent downgrade. `value(subject:)` is what decides
    /// whether the thorough path runs at all, so this is only reachable if a provider claims to support
    /// it and does not.
    func readPhoto(_ request: PhotoReadingRequest) async throws -> PhotoReading {
        throw ValuationError.photoScanUnsupported
    }

    /// Default: this provider cannot reconcile readings.
    func aggregate(_ request: PhotoAggregationRequest) async throws -> [DiscoveredItem] {
        throw ValuationError.photoScanUnsupported
    }
}

// MARK: - Pacing

/// Spaces outbound requests so a run cannot out-run the project's quota.
///
/// Free-tier keys are limited in requests *per minute*, and the coordinator appraises several
/// lots concurrently, so a sleep inside each lot would not be enough on its own: overlapping
/// calls would still bunch up. Each caller therefore reserves the next slot *before* it
/// suspends. The actor serialises that reservation, so concurrent callers queue up behind one
/// another instead of waking together.
actor RequestPacer {

    private let minimumInterval: Duration
    private var nextSlot: ContinuousClock.Instant?

    /// - Parameter requestsPerMinute: `0` or less disables pacing entirely.
    init(requestsPerMinute: Int) {
        minimumInterval = requestsPerMinute > 0
            ? .seconds(60.0 / Double(requestsPerMinute))
            : .zero
    }

    /// Suspends until this caller's turn arrives. Call immediately before each POST.
    ///
    /// Throws `CancellationError` if the run is stopped while waiting, so a cancelled run never
    /// issues another request.
    func waitForTurn() async throws {
        guard minimumInterval > .zero else { return }
        let clock = ContinuousClock()
        let now = clock.now
        let slot = nextSlot.map { Swift.max($0, now) } ?? now
        nextSlot = slot.advanced(by: minimumInterval)
        let delay = now.duration(to: slot)
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
    }
}

// MARK: - Output schema

/// The slice of Google's OpenAPI-schema dialect that `responseSchema` accepts.
///
/// Hand-rolled as an `Encodable` enum (rather than a `[String: Any]` literal) so the schema is
/// compiler-checked and lands in the request with the exact key names the API expects.
///
/// The same value is also rendered as standard JSON Schema text by `jsonSchemaText`, which is how
/// a provider without out-of-band schema support (DeepSeek) is told the shape to produce. One
/// definition, two renderings, so the two back ends cannot drift apart.
indirect enum ResponseSchemaNode: Encodable {
    case string(description: String, values: [String]? = nil)
    case number(description: String)
    case array(description: String, items: ResponseSchemaNode)
    case object(description: String, properties: [(String, ResponseSchemaNode)], required: [String])

    private enum Keys: String, CodingKey {
        case type
        case description
        case items
        case properties
        case required
        case `enum`
    }

    private struct PropertyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .string(let description, let values):
            try container.encode("STRING", forKey: .type)
            try container.encode(description, forKey: .description)
            if let values { try container.encode(values, forKey: .enum) }
        case .number(let description):
            try container.encode("NUMBER", forKey: .type)
            try container.encode(description, forKey: .description)
        case .array(let description, let items):
            try container.encode("ARRAY", forKey: .type)
            try container.encode(description, forKey: .description)
            try container.encode(items, forKey: .items)
        case .object(let description, let properties, let required):
            try container.encode("OBJECT", forKey: .type)
            try container.encode(description, forKey: .description)
            var nested = container.nestedContainer(keyedBy: PropertyKey.self, forKey: .properties)
            for (name, schema) in properties {
                try nested.encode(schema, forKey: PropertyKey(name))
            }
            try container.encode(required, forKey: .required)
        }
    }
}

extension ResponseSchemaNode {

    /// The same shape as plain JSON Schema (lower-case type names), pretty-printed for a prompt.
    ///
    /// `additionalProperties: false` on objects is the closest a prompt-embedded schema gets to
    /// `responseSchema`'s enforcement: the model is told not to invent keys.
    var jsonSchemaText: String {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .prettyPrinted]
        guard let data = try? JSONSerialization.data(withJSONObject: jsonSchemaObject, options: options) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private var jsonSchemaObject: [String: Any] {
        switch self {
        case .string(let description, let values):
            var object: [String: Any] = ["type": "string", "description": description]
            if let values { object["enum"] = values }
            return object
        case .number(let description):
            return ["type": "number", "description": description]
        case .array(let description, let items):
            return ["type": "array", "description": description, "items": items.jsonSchemaObject]
        case .object(let description, let properties, let required):
            var nested: [String: Any] = [:]
            for (name, schema) in properties {
                nested[name] = schema.jsonSchemaObject
            }
            return [
                "type": "object",
                "description": description,
                "properties": nested,
                "required": required,
                "additionalProperties": false
            ]
        }
    }
}

// MARK: - Images

/// A downloaded image ready to be inlined into a request.
struct LotImage: Sendable {
    var mimeType: String
    var base64: String
    var byteCount: Int
    var sourceURL: URL
}

/// What one lot's image download produced.
struct LotImageDownload: Sendable {
    /// Photographs ready to be inlined, in the order the lot's page listed them.
    var images: [LotImage] = []
    /// Addresses that could not be read at all (404, not an image, too large on its own), with the
    /// reason the loader gave — the first of these is what a "no usable images" failure quotes.
    var failures: [String] = []
    /// Photographs that *are* readable but did not fit one request's inline budget. Counted rather
    /// than quietly dropped, so a row can say "40 of 46".
    var overBudget: [URL] = []
}

/// Downloads the images a valuation request will carry.
enum LotImageLoader {

    /// Total inline budget for one request's images, in bytes.
    ///
    /// The only thing that may bound "all of a lot's photographs" is the provider's payload
    /// ceiling, and base64 inflates the encoded form by about a third: Gemini's documented inline
    /// limit is a 20 MB request, DeepSeek caps its body at 48 MiB. Twelve megabytes of image bytes
    /// is ~16 MB once encoded, which leaves both comfortable room for the prompt. Photographs are
    /// taken in page order until the budget is reached, and whatever does not fit is reported
    /// through `LotImageDownload.overBudget`.
    static let defaultTotalBytes = 12_000_000

    /// Downloads the lot images concurrently, preserving the order they appeared on the page.
    ///
    /// Individual failures never abort the valuation: a lot with forty photos where one 404s is
    /// still worth appraising from the other thirty-nine. `totalBytes` is the one bound on how much
    /// of the set can travel in a single request.
    static func download(
        _ urls: [URL],
        maxBytes: Int,
        totalBytes: Int = defaultTotalBytes,
        session: URLSession
    ) async -> LotImageDownload {
        guard !urls.isEmpty else { return LotImageDownload() }

        let collected: [(Int, LotImage?, String?)] = await withTaskGroup(
            of: (Int, LotImage?, String?).self
        ) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    do {
                        let attachment = try await fetch(url, maxBytes: maxBytes, session: session)
                        return (index, attachment, nil)
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        return (index, nil, message)
                    }
                }
            }

            var results: [(Int, LotImage?, String?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        var download = LotImageDownload()
        var runningTotal = 0
        for (_, image, failure) in collected {
            guard let image else {
                if let failure { download.failures.append(failure) }
                continue
            }
            guard runningTotal + image.byteCount <= totalBytes else {
                download.overBudget.append(image.sourceURL)
                continue
            }
            runningTotal += image.byteCount
            download.images.append(image)
        }
        return download
    }

    /// Fetches a single image and turns it into an inline-able candidate.
    private static func fetch(_ url: URL, maxBytes: Int, session: URLSession) async throws -> LotImage {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ValuationError.imageUnavailable(url: url.absoluteString, reason: "unsupported URL scheme")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ValuationError.imageUnavailable(url: url.absoluteString, reason: "HTTP \(http.statusCode)")
        }
        guard !data.isEmpty else {
            throw ValuationError.imageUnavailable(url: url.absoluteString, reason: "empty response body")
        }
        guard data.count <= maxBytes else {
            let megabytes = Double(data.count) / 1_000_000
            throw ValuationError.imageUnavailable(
                url: url.absoluteString,
                reason: String(format: "%.1f MB exceeds the inline limit", megabytes)
            )
        }

        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let mimeType = self.mimeType(declared: header, url: url)
        guard mimeType.hasPrefix("image/") else {
            throw ValuationError.imageUnavailable(
                url: url.absoluteString,
                reason: "not an image (\(header.isEmpty ? "no content type" : header))"
            )
        }

        return LotImage(
            mimeType: mimeType,
            base64: data.base64EncodedString(),
            byteCount: data.count,
            sourceURL: url
        )
    }

    /// Normalises the declared `Content-Type`, falling back to the URL extension.
    ///
    /// CDNs routinely serve `application/octet-stream` for perfectly good JPEGs, so the
    /// extension is the better signal in that case.
    private static func mimeType(declared header: String, url: URL) -> String {
        let declared = header
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if declared.hasPrefix("image/") {
            return declared == "image/jpg" ? "image/jpeg" : declared
        }
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "bmp": return "image/bmp"
        default: return "image/jpeg"
        }
    }
}

// MARK: - Answer decoding

/// The JSON both providers are asked to produce.
///
/// Every field is optional and defaulted on the way into `DiscoveredItem`: Gemini is constrained
/// by `responseSchema`, but DeepSeek only offers `json_object` mode, so a decode must never fail
/// on a missing key that the prompt asked for.
///
/// `Encodable` as well as `Decodable` because a multi-pass provider hands one pass's answer to the
/// next (`ValuationPayload.from(items:)`): re-encoding the *decoded* rows, rather than forwarding
/// the raw answer, keeps the draft in exactly the shape this type decodes — a fenced or chatty
/// reply can never smuggle prose into the follow-up prompt's example.
struct ValuationPayload: Codable {

    struct Item: Codable {
        var itemName: String?
        var confidence: String?
        var retailValue: Double?
        var resaleValue: Double?
        var notes: String?
        /// What the numbers rest on, quoted off the photographs (see `DiscoveredItem.evidence`).
        var evidence: String?
        /// Units of the product in the pallet, when the answer said (see `DiscoveredItem.quantity`).
        var quantity: Double?
        /// Photographs the line was read from (see `DiscoveredItem.photos`). Only a thorough scan's
        /// reconciliation can fill this.
        var photos: [Int]?
    }

    var items: [Item]?

    /// Renders rows back into the wire shape.
    static func from(items: [DiscoveredItem]) -> ValuationPayload {
        ValuationPayload(
            items: items.map { item in
                Item(
                    itemName: item.itemName,
                    confidence: item.confidenceLevel.rawValue,
                    retailValue: item.retailValue,
                    resaleValue: item.resaleValue,
                    notes: item.notes,
                    evidence: item.evidence,
                    quantity: Double(item.quantity),
                    photos: item.photos.isEmpty ? nil : item.photos
                )
            }
        )
    }
}

/// The JSON the cheap pre-price is asked to produce: whole-pallet figures and one line of
/// reasoning, nothing else.
///
/// Every field is optional for the same reason `ValuationPayload`'s are — a decode must not fail on
/// a key the prompt asked for. Values are clamped and defaulted in
/// `LotValuationAnswer.prePrice(fromAnswerText:finishReason:)`.
struct PrePricePayload: Codable {

    /// Whole-pallet retail, USD.
    var retailValue: Double?

    /// Whole-pallet resale, USD.
    var resaleValue: Double?

    /// `High` / `Med` / `Low`.
    var confidence: String?

    /// One short sentence explaining the basis for the numbers.
    var rationale: String?
}

/// Turns a model's answer text into row models.
enum LotValuationAnswer {

    /// - Parameters:
    ///   - text: the answer with any provider wrapper (candidates/choices) already unwrapped.
    ///   - finishReason: the provider's stop reason, echoed in the error when the text is empty.
    static func items(fromAnswerText text: String, finishReason: String?) throws -> [DiscoveredItem] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValuationError.noContent(finishReason: finishReason)
        }
        guard let data = extractJSONObject(from: text).data(using: .utf8) else {
            throw ValuationError.malformedResponse("the answer was not valid UTF-8")
        }

        let payload: ValuationPayload
        do {
            payload = try JSONDecoder().decode(ValuationPayload.self, from: data)
        } catch {
            throw ValuationError.malformedResponse(error.localizedDescription)
        }

        let items = (payload.items ?? [])
            .map { item in
                DiscoveredItem(
                    itemName: (item.itemName ?? "").condensedWhitespace,
                    confidence: DiscoveredItem.Confidence(rawText: item.confidence ?? "").rawValue,
                    retailValue: max(0, item.retailValue ?? 0),
                    resaleValue: max(0, item.resaleValue ?? 0),
                    notes: (item.notes ?? "").condensedWhitespace,
                    evidence: (item.evidence ?? "").condensedWhitespace,
                    quantity: LotPhotoScanAnswer.quantity(from: item.quantity),
                    photos: (item.photos ?? [])
                        .filter { $0 > 0 }
                        .reduce(into: [Int]()) { positions, position in
                            if !positions.contains(position) { positions.append(position) }
                        }
                        .sorted()
                )
            }
            .filter { !$0.itemName.isEmpty }

        guard !items.isEmpty else {
            throw ValuationError.malformedResponse("the model returned no usable line items")
        }
        return items
    }

    /// The models are asked for bare JSON, but occasionally wrap it in a fence — recover.
    static func extractJSONObject(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end {
            return String(trimmed[start...end])
        }
        return trimmed
    }

    /// Turns a cheap pre-price answer into whole-pallet figures.
    ///
    /// Stricter than `items(fromAnswerText:finishReason:)` in one way: a pre-price with no resale
    /// figure is worthless (it would produce a `$0` ceiling), so that is an error rather than an
    /// empty estimate. Retail is allowed to be zero — plenty of liquidation listings only support a
    /// resale number.
    static func prePrice(fromAnswerText text: String, finishReason: String?) throws -> PrePriceEstimate {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValuationError.noContent(finishReason: finishReason)
        }
        guard let data = extractJSONObject(from: text).data(using: .utf8) else {
            throw ValuationError.malformedResponse("the answer was not valid UTF-8")
        }

        let payload: PrePricePayload
        do {
            payload = try JSONDecoder().decode(PrePricePayload.self, from: data)
        } catch {
            throw ValuationError.malformedResponse(error.localizedDescription)
        }

        let resale = max(0, payload.resaleValue ?? 0)
        guard resale > 0 else {
            throw ValuationError.malformedResponse("the pre-price returned no resale figure")
        }

        return PrePriceEstimate(
            retail: max(0, payload.retailValue ?? 0),
            resale: resale,
            confidence: DiscoveredItem.Confidence(rawText: payload.confidence ?? ""),
            rationale: (payload.rationale ?? "").condensedWhitespace
        )
    }
}

// MARK: - Prompt & response schema

/// The prompt and output contract shared by both providers.
enum LotValuationPrompt {

    /// Pricing and formatting rules every pass shares, so the text pass and the photograph pass
    /// cannot drift apart.
    ///
    /// Numbered from 3 on purpose: every instruction that interpolates them supplies rules 1 and 2 of
    /// its own (what to look at, how to group it), and the numbering is what keeps a prompt's rules
    /// reading as one list. `LotPhotoScanPrompt` uses the same block for the reconciliation pass.
    static let valuationRules = """
    3. `retailValue` is the item's normal in-store price when new. `resaleValue` is what a \
    reseller could realistically get for it (typically 40-70% of retail for liquidation \
    merchandise, less for opened, damaged or untested goods).
    4. Price the specific product you identified rather than its category: a model number, the \
    digits under a barcode, or a brand-plus-size on the label pins a market price, and that \
    price beats an average over everything that looks similar.
    5. Both values are US dollars for the WHOLE line item, quantity included — never per unit.
    6. `confidence` must be exactly one of: High, Med, Low. Use High when something legible on \
    the goods — a label, a model number, a barcode — identifies the product; Med for a \
    reasonable inference from partial clues; Low for speculation.
    7. `evidence` says what the identification and the price actually rest on: the label wording, \
    the barcode digits, the model or SKU number, the printed size, weight or count. Copy it as \
    read, put nothing in there you did not see, and keep it to 20 words — for example `label \
    reads "Yankee Candle 22 oz" · UPC 609032993551`. Use an empty string only when you could \
    read nothing at all.
    8. `notes` is one short sentence (20 words maximum) explaining the basis for the numbers, and \
    it is where you say that a figure had to be extrapolated from the category because no label \
    was legible.
    9. Return at most 12 line items, most valuable first. Never return an empty list: when in \
    doubt, estimate and mark it Low.
    """

    /// Ground rules for a single multimodal pass over the photographs (Gemini, and DeepSeek's
    /// second pass).
    static let systemInstruction = """
    You are a liquidation-auction valuation analyst. You are shown photographs of the contents \
    of a single pallet/lot and, optionally, the auction listing text.

    Rules:
    1. Identify the distinct product groups visible in the photographs. Group identical or \
    near-identical goods into ONE line item (for example "16 oz scented candles, 24-pack") \
    rather than one row per unit.
    2. Read the goods before you judge them, and read them closely: brand and product names, \
    model and part numbers, the digits printed under a barcode (UPC/EAN/GTIN), size, weight and \
    count wording, case codes and any price sticker. This text is the strongest evidence in the \
    photographs — it names an exact product in an exact size, which is a market price rather \
    than a guess — so zoom in on packaging and shelf tickets, and record in `evidence` which of \
    the reads the figure rests on. A partly legible label is still worth reading: report what \
    you could make out and mark the line Med.
    3. When the app has already run its own text and barcode reader over these same photographs, \
    its output is a verified reading rather than a hint. Match each entry to the product it \
    belongs to, price that exact model and size, and raise the line to High confidence when one \
    of them identifies it. Do not contradict a decoded barcode by naming a different product, \
    and do not assume a barcode stapled to the outside of a pallet belongs to the goods inside — \
    a freight or tracking label is not a product identifier.
    4. Never invent items you cannot see or reasonably infer from the listing text, and never \
    invent an identifier: a model number or barcode you quote must be one you can read in a \
    photograph or one the reader listed. If a photograph is unreadable, say so in `notes` and use \
    a Low confidence.
    \(valuationRules)
    """

    /// Ground rules for the **text** pass (DeepSeek's first pass): the listing wording, no
    /// photographs. Its answer is handed to the photograph pass as a draft to confirm or correct.
    static let textPassSystemInstruction = """
    You are a liquidation-auction valuation analyst working on a pallet that will be appraised in \
    two passes. This first pass sees the auction listing text only; the second pass re-checks your \
    draft against the photographs.

    Rules:
    1. Split the listing text into the distinct sellable product groups it describes. Group \
    identical or near-identical goods into ONE line item (for example "16 oz scented candles, \
    24-pack") rather than one row per unit, and take quantities from the text.
    2. Claim only what the listing supports. Liquidation listings name brands, model numbers and \
    counts — use them, carry the identifiers you priced from into `evidence`, and mark anything \
    the wording leaves vague as Low confidence.
    \(valuationRules)
    """

    /// Ground rules for the **cheap pre-price**: one whole-pallet estimate from the listing text
    /// alone, no photographs and no line items.
    ///
    /// Kept separate from `textPassSystemInstruction` (DeepSeek's first valuation pass) because the
    /// two asks are different in kind: that pass drafts line items to be corrected against
    /// photographs, this one only has to be honest about a whole-pallet range.
    static let prePriceSystemInstruction = """
    You are a liquidation-auction valuation analyst giving a pallet a fast first-price estimate \
    from its auction listing text alone. You are not shown any photographs.

    Rules:
    1. Estimate the pallet as a whole: one retail figure and one resale figure for everything in \
    the lot, in US dollars.
    2. Work from the brands, model numbers, counts and condition wording the listing gives you. \
    Extrapolate from the category when the wording is thin, and never invent a figure without a \
    reason you can state in one sentence.
    3. `resaleValue` is what a reseller could realistically get, typically 40-70% of retail for \
    liquidation merchandise and less for opened, damaged or untested goods.
    4. `confidence` must be exactly one of: High, Med, Low. High only when the listing names \
    recognizable products with quantities; Low when you are extrapolating from a category alone.
    5. `rationale` is one short sentence (20 words maximum) stating what the estimate rests on.
    6. This is a first look that photographs will later correct, so a defensible range beats a \
    precise-looking guess.
    """

    /// The listing text the model is handed for a lot: lot number, title, description, bid and page
    /// address, one field per line.
    ///
    /// Shared by both asks and both providers, so a cheap pre-price always reasons from exactly the
    /// same words the photographed valuation will later see.
    static func listingText(for subject: ValuationSubject) -> String {
        var lines: [String] = []
        let lot = subject.lotNumber.condensedWhitespace
        let title = subject.title.condensedWhitespace
        let detail = subject.rawDescription.condensedWhitespace

        if !lot.isEmpty { lines.append("Lot number: \(lot)") }
        if !title.isEmpty { lines.append("Listing title: \(title)") }
        if !detail.isEmpty { lines.append("Listing description: \(detail)") }
        if subject.currentBid > 0 { lines.append("Current bid: \(subject.currentBid.currencyText)") }
        if let detailURL = subject.detailURL { lines.append("Lot page: \(detailURL.absoluteString)") }
        return lines.joined(separator: "\n")
    }

    /// The per-lot question that accompanies the images.
    ///
    /// - Parameters:
    ///   - evidence: what the app's own reader already made of these photographs
    ///     (`LotImageDigest`), echoed in full so the model works from the literal digits instead of
    ///     re-guessing a label from pixels. `nil` or empty adds nothing.
    ///   - schemaText: JSON Schema text to embed in the prompt. Gemini is handed the schema
    ///     out-of-band via `responseSchema`; DeepSeek only offers `json_object` mode, which requires
    ///     the word "json" *and* a format example in the prompt, so its caller passes
    ///     `itemsSchema.jsonSchemaText` here.
    static func userPrompt(
        description: String,
        imageCount: Int,
        evidence: LotImageEvidence? = nil,
        schemaText: String? = nil
    ) -> String {
        var lines: [String] = []
        if description.isEmpty {
            lines.append("No listing text was captured — work from the photographs alone.")
        } else {
            lines.append("Auction listing details:")
            lines.append(description)
        }
        lines.append(contentsOf: evidence?.promptLines ?? [])
        if imageCount == 0 {
            lines.append("No photographs are available for this lot; estimate from the listing text and mark every confidence Low.")
        } else {
            lines.append("\(imageCount) photograph(s) of the lot follow. Break the pallet down into its distinct sellable products.")
        }
        lines.append(contentsOf: outputContractLines(schemaText: schemaText))
        return lines.joined(separator: "\n")
    }

    /// The **text** pass question: the listing wording, no photographs.
    ///
    /// Used by the providers that split a valuation into a text pass and a photograph pass
    /// (DeepSeek), where this answer becomes the draft handed to `imagePassPrompt`.
    static func textPassPrompt(description: String, schemaText: String? = nil) -> String {
        var lines: [String] = []
        lines.append("First pass — read the auction listing below and propose the pallet's line items with retail and resale estimates.")
        if description.isEmpty {
            lines.append("The page exposed no listing text, so return your single best guess and mark it Low confidence.")
        } else {
            lines.append("Auction listing details:")
            lines.append(description)
            lines.append("The lot's photographs follow in the next pass, so stay with the product families and quantities the wording supports instead of inventing detail.")
        }
        lines.append(contentsOf: outputContractLines(schemaText: schemaText))
        return lines.joined(separator: "\n")
    }

    /// The **photograph** pass question: the images, plus the text pass's draft to confirm or correct.
    ///
    /// - Parameters:
    ///   - priorAnalysis: the text pass's raw JSON answer, or `nil` when that pass was skipped (no
    ///     listing text) or failed.
    ///   - evidence: what the app's own reader already made of these photographs, echoed so the
    ///     photograph pass works from the literal digits (see `LotImageDigest`).
    static func imagePassPrompt(
        description: String,
        imageCount: Int,
        priorAnalysis: String?,
        evidence: LotImageEvidence? = nil,
        schemaText: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("Second pass — the photographs below are the source of truth for names, quantities and condition.")
        if description.isEmpty {
            lines.append("No listing text was captured.")
        } else {
            lines.append("Auction listing details:")
            lines.append(description)
        }
        lines.append(contentsOf: evidence?.promptLines ?? [])
        if let priorAnalysis, !priorAnalysis.isEmpty {
            lines.append("The earlier text pass proposed this json breakdown:")
            lines.append(String(priorAnalysis.prefix(maxPriorAnalysisLength)))
            lines.append("Treat that draft as a starting point: fix the names and quantities, add what the text missed, drop anything the photographs do not support, and re-price whatever they contradict.")
        }
        lines.append("\(imageCount) photograph(s) of the lot follow. Break the pallet down into its distinct sellable products.")
        lines.append(contentsOf: outputContractLines(schemaText: schemaText))
        return lines.joined(separator: "\n")
    }

    /// The **pre-price** question: one whole-pallet estimate from the listing text, no photographs.
    ///
    /// - Parameter schemaText: JSON Schema text to embed in the prompt, for providers whose JSON
    ///   mode wants a format example in the prompt (DeepSeek). Gemini is handed `prePriceSchema`
    ///   out of band instead.
    static func prePricePrompt(description: String, schemaText: String? = nil) -> String {
        var lines: [String] = []
        lines.append("Pre-price this pallet from the auction listing text alone — no photographs are attached, and no line items are wanted.")
        if description.isEmpty {
            lines.append("The page exposed no listing text at all, so return your most conservative single guess and mark it Low confidence.")
        } else {
            lines.append("Auction listing details:")
            lines.append(description)
            lines.append("Give one retail total and one resale total for the whole pallet, plus your confidence and a one-sentence rationale.")
        }
        lines.append(contentsOf: outputContractLines(schemaText: schemaText))
        return lines.joined(separator: "\n")
    }

    /// Longest slab of a previous pass's answer that is echoed back into a follow-up prompt. The
    /// draft only has to convey the product families and quantities; the tail is rarely useful and
    /// is billed as input tokens.
    static let maxPriorAnalysisLength = 3_000

    /// The closing "answer with JSON shaped like this" lines.
    ///
    /// DeepSeek's `json_object` mode requires the word *json* **and** a format example to be
    /// present in the prompt, which is why the schema is inlined rather than sent out of band.
    /// Internal rather than private because `LotPhotoScanPrompt`'s two asks need the same contract.
    static func outputContractLines(schemaText: String?) -> [String] {
        guard let schemaText else {
            return ["Respond only with JSON matching the provided schema."]
        }
        return [
            "Respond with a single json object and nothing else: no prose, no code fence.",
            "It must validate against this JSON Schema:",
            schemaText
        ]
    }

    /// Strict output shape — mirrors `DiscoveredItem`, so decoding can never drift from the model.
    static var itemsSchema: ResponseSchemaNode {
        .object(
            description: "Line items discovered inside a single auction lot.",
            properties: [
                (
                    "items",
                    .array(
                        description: "Distinct sellable product groups found in the lot, most valuable first.",
                        items: .object(
                            description: "One product group.",
                            properties: [
                                ("itemName", .string(description: "Product name including quantity, e.g. 'AA batteries, 12x 2-pack'.")),
                                (
                                    "confidence",
                                    .string(
                                        description: "Identification confidence.",
                                        values: DiscoveredItem.Confidence.allCases.map(\.rawValue)
                                    )
                                ),
                                ("retailValue", .number(description: "Total in-store retail value of the group, in USD.")),
                                ("resaleValue", .number(description: "Total realistic resale value of the group, in USD.")),
                                (
                                    "quantity",
                                    .number(
                                        description: "Units of this product the lot holds. Optional: 0 when the "
                                            + "listing or the readings do not support a count."
                                    )
                                ),
                                (
                                    "photos",
                                    .array(
                                        description: "1-based numbers of the photographs this line was read from. "
                                            + "Empty for an appraisal that did not read the lot photograph by "
                                            + "photograph.",
                                        items: .number(description: "Gallery position of one photograph.")
                                    )
                                ),
                                ("notes", .string(description: "One short sentence explaining the estimate.")),
                                (
                                    "evidence",
                                    .string(
                                        description: "What the estimate rests on, quoted off the photographs: "
                                            + "label wording, barcode digits, model/SKU number, printed size or "
                                            + "count. Empty string when nothing legible was found."
                                    )
                                )
                            ],
                            required: ["itemName", "confidence", "retailValue", "resaleValue", "notes"]
                        )
                    )
                )
            ],
            required: ["items"]
        )
    }

    /// Strict output shape for the cheap pre-price — mirrors `PrePriceEstimate`.
    static var prePriceSchema: ResponseSchemaNode {
        .object(
            description: "Whole-pallet valuation estimated from an auction listing's text alone.",
            properties: [
                ("retailValue", .number(description: "Total in-store retail value of everything in the pallet, in USD.")),
                ("resaleValue", .number(description: "Total realistic resale value of the pallet, in USD.")),
                (
                    "confidence",
                    .string(
                        description: "How well the listing text supports the estimate.",
                        values: DiscoveredItem.Confidence.allCases.map(\.rawValue)
                    )
                ),
                ("rationale", .string(description: "One short sentence stating what the estimate rests on."))
            ],
            required: ["retailValue", "resaleValue", "confidence", "rationale"]
        )
    }
}

// MARK: - Retry policy

/// The retry/back-off policy both transports apply to a single request.
///
/// Rate limits and transient gateway failures are expected on a throttled key, so a refusal is
/// waited out rather than failed — up to the caller's attempt budget.
enum ValuationRetry {

    /// Only failures that another attempt could plausibly fix.
    static func isRetryable(status: Int) -> Bool {
        status == 429 || (500...504).contains(status)
    }

    static func failure(status: Int, message: String, retryDelay: TimeInterval?) -> ValuationError {
        status == 429
            ? .rateLimited(status: status, retryAfter: retryDelay, message: message)
            : .http(status: status, message: message)
    }

    /// Exponential back-off with full jitter, capped at a minute, unless the server said how
    /// long to wait.
    static func delay(attempt: Int, serverHint: TimeInterval?) -> TimeInterval {
        if let serverHint, serverHint > 0 { return min(serverHint + 1, 65) }
        let ceiling = min(pow(2, Double(attempt)) * 2, 60)
        return Double.random(in: (ceiling / 2)...ceiling)
    }

    /// The `Retry-After` header, as seconds or as an HTTP-date.
    static func retryAfterHeader(_ response: HTTPURLResponse?) -> TimeInterval? {
        response?.value(forHTTPHeaderField: "Retry-After").flatMap { parseRetryAfter($0) }
    }

    static func parseRetryAfter(_ header: String) -> TimeInterval? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    /// Parses protobuf duration text such as `"17s"` or `"1.5s"`.
    static func parseDuration(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasSuffix("s") ? String(trimmed.dropLast()) : trimmed
        guard let value = TimeInterval(digits), value >= 0 else { return nil }
        return value
    }
}
