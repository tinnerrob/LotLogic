//
//  GeminiValuationService.swift
//  PalletAuctionBidTool
//
//  Multimodal valuation of scraped lots through the Gemini REST API.
//

import Foundation

// The valuation vocabulary shared with `DeepSeekValuationService` — `ValuationError`,
// `ValuationOutcome`, `ValuationService`, `RequestPacer`, the prompt/schema, image loading and the
// retry policy — lives in `LotValuation.swift`. This file is only the Gemini transport.

/// Drives the multimodal valuation of scraped lots through the Gemini REST API.
///
/// ## Why REST instead of an SDK
/// The brief asked for a `GoogleGenAI`-style Swift SDK. No such Swift package exists on the
/// public registry (Google ships Python, JS, Java, Go and .NET SDKs), so this type talks to the
/// documented `v1beta` REST endpoint directly. The current Flash model is used — `1.5-flash` and then
/// the whole 2.5 series have been retired — see `defaultModelID`.
///
/// ## Free tier
/// No billing account is needed: an AI Studio key on the free tier drives this exact endpoint.
/// `RequestPacer` spaces calls so a run stays inside a per-minute quota, and `send(_:)` retries
/// quota/gateway failures using the API's own `Retry-After` hint. Driving a *web* front end
/// (google.com's AI Mode, gemini.google.com) is deliberately not supported; the README explains
/// why.
///
/// ## Two providers, one contract
/// `ValuationProvider` selects between this transport and `DeepSeekValuationService`. Everything
/// that is not wire format — the prompt, the output schema, the tolerant decode, image downloads,
/// pacing and the retry policy — is shared from `LotValuation.swift`, so the two back ends can
/// only differ in the shape of their requests.
///
/// This endpoint is the only one with a free tier, which is why it is the default.
///
/// ## One photograph at a time
/// When `photoScan` is enabled, `value(subject:)` does not send the gallery in one request: it sends
/// **one request per photograph** — the single-image question in `LotPhotoScanPrompt`, with that
/// frame's own barcode reading attached — stores each reading, and then sends one text-only
/// reconciliation over the readings (`LotPhotoScan`). It costs *n* + 1 requests instead of 1 and buys
/// line items that name where in the pallet each product was, how it was packed and how many units
/// were visible; readings already on this machine are reused rather than re-bought
/// (`PhotoReadingStore`). The single pass over the whole gallery remains the default and the fallback,
/// so nothing that does not opt in behaves differently.
///
/// ## The manifest role (Tier 4)
/// This transport also fills the **identity** half of the batched route when the operator points it
/// there (`ManifestService`, `AppSettings.photoProvider`): `manifestBatch(_:)` asks the batch
/// question about a run of frames and answers with manifest items, which another transport then
/// prices. That is not a third route — the pricing half stays on whichever provider was armed — and
/// it is worth having for one structural reason: a `:generateContent` call carries
/// `LotManifestPrompt.manifestSchema` as `responseSchema`, so a batch that leaves `views` out is
/// refused by the API rather than decoded around, where JSON mode can only ask for the shape in
/// prose.
///
/// ## Why `@unchecked Sendable`
/// All stored properties are immutable value/`let` references, and the only shared mutable
/// object is `URLSession`, which is documented as safe to use from multiple threads. The
/// annotation papers over the fact that the SDK's `Sendable` conformance for `URLSession`
/// depends on the toolchain in use.
struct GeminiValuationService: ValuationService, ManifestService, @unchecked Sendable {

    /// The current multimodal Flash model.
    ///
    /// The default moves with the current release rather than pinning a season that has ended, which is
    /// the same rule that took `gemini-1.5-flash` out: the 2.5 series — flash, flash-lite *and* the pro
    /// model the identity role used — is retired, so this points at `gemini-3.8-flash`.
    static let defaultModelID = "gemini-3.8-flash"

    /// The models offered in the UI.
    ///
    /// One entry, because one series is current. There were four while 2.5 was: a cheaper `flash-lite` for
    /// appraisal, `2.0-flash`, and `gemini-2.5-pro` for the **identity** half of the split (Tier 4 of
    /// `docs/manifest-identity-plan.md` — reading a carton's printed model number, barcode digits and count
    /// off a photograph is the job a stronger model earns its price at). All of them retired together with
    /// the series they belonged to, and nothing needs replacing: the identity role still buys its own model,
    /// whichever one this section names (`AppSettings.manifestModelID`), and the win the split was built for
    /// survives the retirement intact — the reader's half is paid for on the free Gemini key while the
    /// prices stay on the appraiser's balance.
    static let availableModelIDs = [
        "gemini-3.8-flash"
    ]

    static let endpointBase = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!

    /// The `:generateContent` endpoint for a model.
    ///
    /// The colon belongs to the method name in `models/{model}:generateContent` — it is part of the
    /// path segment, not a separator, so it has to survive into the URL. Building this with
    /// `appendingPathComponent(_:)` produces `/generateContent`, which the API answers with a bare
    /// **HTTP 404 and an empty body** (verified against the live endpoint), and that reads like a
    /// wrong model ID rather than a malformed URL.
    static func endpoint(for modelID: String) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/:")
        let model = modelID.addingPercentEncoding(withAllowedCharacters: allowed) ?? modelID
        return URL(string: "\(endpointBase.absoluteString)/\(model):generateContent")!
    }

    let apiKey: String
    let modelID: String
    let session: URLSession

    /// Largest single image that will be inlined, in bytes. Base64 inflates by ~33%, and the
    /// request must stay comfortably under the API's payload ceiling.
    let maxImageBytes: Int

    /// Ceiling on *all* the images one request carries. A lot's own page decides how many that is,
    /// so this is what stops a forty-photograph gallery from being sent in a single payload the API
    /// would refuse — see `LotImageLoader.defaultTotalBytes`.
    let maxTotalImageBytes: Int

    /// Spacing enforced between outbound requests; `nil` when the operator set no ceiling.
    private let pacer: RequestPacer?

    /// Attempts per request: the first try plus retries for quota and gateway errors.
    private let maxAttempts: Int

    /// How this service reads a lot's photographs.
    ///
    /// Defaults to the single pass over the whole gallery, so a caller that has said nothing about it
    /// gets exactly the behaviour this service had before the thorough path existed; the app passes
    /// `PhotoScanPlan.thorough(...)` in (`AppSettings.photoScanPlan`).
    let photoScan: PhotoScanPlan

    /// How many photographs one **manifest batch** request carries. `0` — the default here — means this
    /// transport is not running the batched route at all, and leaves `photoScan` to decide how the gallery
    /// is read.
    ///
    /// The app sets this from **Photos / request** (`AppSettings.photosPerRequest`), and only while the run
    /// really does batch (`AppSettings.batchesPhotographs`): a width the route would not use is worse than no
    /// width, because it would send this transport looking for a manifest to price with nothing to read it.
    let photosPerRequest: Int

    /// The service that reads this transport's manifest batches, when the photograph half belongs to another
    /// provider (`ManifestService`, `AppSettings.photoProvider`).
    ///
    /// `nil` — the default — means this transport reads its own gallery, which is every install that has not
    /// asked for a split. Given a service, the batches go there and the manifest it returns is priced here,
    /// so the vision half can be bought from the model that reads a carton best while the prices stay on
    /// whichever key the operator appraises with.
    let manifestReader: (any ManifestService)?

    /// Where per-photograph readings are remembered between scans (`PhotoReadingStore`).
    let store: PhotoReadingStore

    /// Progress for a caller with somewhere to print it — the coordinator turns these into console
    /// lines and into the live note on the row being scanned.
    private let report: @Sendable (PhotoScanReport) -> Void

    init(
        apiKey: String,
        modelID: String = GeminiValuationService.defaultModelID,
        session: URLSession = .shared,
        maxImageBytes: Int = 6_000_000,
        maxTotalImageBytes: Int = LotImageLoader.defaultTotalBytes,
        requestsPerMinute: Int = 0,
        maxAttempts: Int = 4,
        photoScan: PhotoScanPlan = .disabled,
        photosPerRequest: Int = 0,
        manifestReader: (any ManifestService)? = nil,
        store: PhotoReadingStore = .shared,
        report: @escaping @Sendable (PhotoScanReport) -> Void = { _ in }
    ) {
        self.apiKey = apiKey
        self.modelID = modelID.isEmpty ? Self.defaultModelID : modelID
        self.session = session
        self.maxImageBytes = maxImageBytes
        self.maxTotalImageBytes = maxTotalImageBytes
        self.maxAttempts = max(1, maxAttempts)
        self.photoScan = photoScan
        self.photosPerRequest = max(0, photosPerRequest)
        self.manifestReader = manifestReader
        self.store = store
        self.report = report
        self.pacer = requestsPerMinute > 0 ? RequestPacer(requestsPerMinute: requestsPerMinute) : nil
    }

    // MARK: - Valuation

    func value(subject: ValuationSubject) async throws -> ValuationOutcome {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValuationError.missingAPIKey
        }

        // Every photograph the lot carries: the count came off the lot's own page, so there is
        // nothing to trim for and nothing to configure — only the inline budget can hold any back.
        let candidates = subject.imageURLs
        // The download ceiling depends on the route: the batched route sends the gallery in several
        // requests, so it may hold more of it than a single request could carry; every other route puts the
        // whole set in one request and stays inside the one-request budget.
        var download = await LotImageLoader.download(
            candidates,
            maxBytes: maxImageBytes,
            totalBytes: photosPerRequest > 0 ? LotManifestScan.downloadBytes : maxTotalImageBytes,
            session: session
        )
        let description = LotValuationPrompt.listingText(for: subject)

        guard !download.images.isEmpty || !description.isEmpty else {
            throw ValuationError.noUsableImages(attempted: candidates.count, reason: download.failures.first)
        }

        // Read the photographs here first. Barcodes and label identifiers are the two things a
        // general vision model reads worst off a photograph and the two things this machine reads
        // natively, so the reading becomes literal text in the prompt (see `LotImageDigest`). Read per
        // photograph, so the thorough path can quote each frame's own digits and the single pass can
        // roll them up exactly as it always did.
        let labels = download.images.isEmpty ? [] : await LotImageDigest.readEach(download.images)
        let evidence = LotImageDigest.merge(labels)

        // The batched route, when the operator pointed the photograph half somewhere (`AppSettings
        // .photoProvider`): the batches are read by `manifestReader` — DeepSeek, unless somebody named this
        // transport, in which case this is the shape it reads a gallery in when the width is set — and the
        // inventory they add up to is priced here. A lot the route cannot read falls through to the passes
        // below rather than failing; the console is told why.
        if photosPerRequest > 0, !download.images.isEmpty {
            if let outcome = try await manifestRoute(
                subject: subject,
                description: description,
                download: download,
                labels: labels,
                evidence: evidence
            ) {
                return outcome
            }

            // Out of the batched route and into one that puts the whole set in a *single* request, so the
            // set is trimmed back to what one request may carry (`LotManifestScan.downloadBytes` was what
            // let the download hold more). Whatever the trim drops is counted as skipped, exactly as a frame
            // the download itself could not take is, so the row and the console keep saying `40 of 46`
            // rather than quietly reporting fewer.
            let sendable = LotManifestScan.withinOneRequest(download.images, budget: maxTotalImageBytes)
            if sendable.count < download.images.count {
                let dropped = Array(download.images.dropFirst(sendable.count))
                download.images = sendable
                download.overBudget.append(contentsOf: dropped.map(\.sourceURL))
            }
        }

        // One request per photograph, then a reconciliation, when the operator asked for it.
        if photoScan.isEnabled, !download.images.isEmpty {
            switch await photoScanResult(
                subject: subject,
                description: description,
                download: download,
                labels: labels,
                evidence: evidence
            ) {
            case .completed(let outcome):
                return outcome
            case .unavailable(let error):
                // A stopped run has to stay stopped: falling back to a gallery pass here would send a
                // request nobody is waiting for any more.
                if ValuationCancellation.isCancellation(error) { throw error }
                report(
                    PhotoScanReport(
                        lotNumber: subject.lotNumber,
                        event: .fallingBack(reason: ValuationError.describe(error))
                    )
                )
            case .off:
                break
            }
        }

        let body = try requestBody(
            subject: subject,
            description: description,
            images: download.images,
            evidence: evidence
        )
        let answer = try await send(body)
        let items = try decodeItems(from: answer)
        return ValuationOutcome(
            items: items,
            imagesAvailable: candidates.count,
            imagesSent: download.images.count,
            imagesSkipped: download.overBudget.count,
            modelID: modelID,
            evidence: evidence
        )
    }

    /// Cheap first look: the same endpoint with no photographs attached and the whole-pallet
    /// schema, so a lot can be pre-priced for a fraction of a photographed pass.
    func prePrice(subject: ValuationSubject) async throws -> PrePriceEstimate {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValuationError.missingAPIKey
        }

        let body = try prePriceRequestBody(description: LotValuationPrompt.listingText(for: subject))
        let answer = try await send(body)
        return try decodePrePrice(from: answer)
    }

    /// The thorough path: one request per photograph, then one reconciliation.
    ///
    /// - Returns: `.completed` when the readings produced a valuation; `.unavailable` with the reason
    ///   when they did not, so `value(subject:)` can decide whether a single pass over the gallery is
    ///   still worth paying for.
    private func photoScanResult(
        subject: ValuationSubject,
        description: String,
        download: LotImageDownload,
        labels: [LotImageEvidence],
        evidence: LotImageEvidence
    ) async -> LotPhotoScan.RunResult<ValuationOutcome> {
        let result = await LotPhotoScan.run(
            subject: subject,
            description: description,
            images: download.images,
            labels: labels,
            plan: photoScan,
            store: store,
            read: { [self] request in try await readPhoto(request) },
            aggregate: { [self] request in try await aggregate(request) },
            report: report
        )

        switch result {
        case .off:
            return .off
        case .unavailable(let error):
            return .unavailable(error)
        case .completed(let scan):
            return .completed(
                ValuationOutcome(
                    items: scan.items,
                    imagesAvailable: subject.imageURLs.count,
                    imagesSent: download.images.count,
                    imagesSkipped: download.overBudget.count,
                    modelID: modelID,
                    // Every photograph read, plus the reconciliation: the number of model requests the
                    // figures rest on.
                    passes: scan.requests + 1,
                    evidence: evidence,
                    readings: scan.readings,
                    readingsFromStore: scan.reused,
                    scanRequests: scan.requests,
                    reconciliationFailure: scan.aggregationFailure,
                    groupedViews: scan.groupedViews
                )
            )
        }
    }

    /// Reads **one** photograph: a single-image `:generateContent` call carrying the per-photograph
    /// question, the per-photograph reader output and the per-photograph schema.
    ///
    /// The answer describes that frame alone, which is what makes a reconciliation possible later: a
    /// reading that had already averaged in its neighbours would give the reconciliation nothing to
    /// weigh.
    func readPhoto(_ request: PhotoReadingRequest) async throws -> PhotoReading {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValuationError.missingAPIKey
        }
        let body = try photoReadingRequestBody(request)
        let answer = try await send(body)
        let (text, finishReason) = try answerText(from: answer)
        return try LotPhotoScanAnswer.reading(
            fromAnswerText: text,
            finishReason: finishReason,
            request: request,
            modelID: modelID
        )
    }

    /// Reconciles a lot's readings into its line items: a text-only call over the readings, plus any
    /// photographs a ceiling kept out of the per-image path.
    ///
    /// The answer is decoded as a normal item list, because the reconciliation is asked for exactly
    /// the schema a single pass is (`LotValuationPrompt.itemsSchema`) — which is why a thorough scan's
    /// rows and a single-pass one's are the same shape.
    func aggregate(_ request: PhotoAggregationRequest) async throws -> [DiscoveredItem] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValuationError.missingAPIKey
        }
        let body = try aggregationRequestBody(request)
        let answer = try await send(body)
        return try decodeItems(from: answer)
    }

    // MARK: - Manifest

    /// Reads one batch of a lot's photographs into manifest items (`ManifestService`).
    ///
    /// The identity half of a batched appraisal, run on *this* transport because the operator pointed
    /// the identity role here (`AppSettings.photoProvider`): the same question a DeepSeek batch is
    /// asked, answered by a `:generateContent` call whose answer shape is *enforced* rather than
    /// requested — `LotManifestPrompt.manifestSchema` travels as `responseSchema`, so the keys the
    /// fold reads are the API's business rather than the prompt's, which is the one structural
    /// advantage this transport has over JSON mode.
    ///
    /// The prompt therefore carries no schema *text*, exactly as every other pass here, and the
    /// temperature is `LotManifestPrompt.manifestTemperature` rather than this transport's usual
    /// warmth: what comes back is extraction, and a pallet read twice has to count the same twice.
    func manifestBatch(_ request: ManifestBatchRequest) async throws -> ManifestBatchAnswer {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValuationError.missingAPIKey
        }
        let body = try manifestBatchRequestBody(request)
        let answer = try await send(body)
        let (text, finishReason) = try answerText(from: answer)
        return try LotManifestAnswer.answer(fromAnswerText: text, finishReason: finishReason)
    }

    /// Prices a piece of a settled manifest, in a text-only `:generateContent` call held to
    /// `LotValuationPrompt.itemsSchema` as `responseSchema`.
    ///
    /// This transport's answer to the `ManifestPricingService` question, and the reason the photograph half
    /// is symmetric: a manifest DeepSeek read is priced *here* whenever this transport is the appraiser, so
    /// the batches can be bought from whichever model reads a carton best while the prices stay on this key.
    /// No photographs travel: the goods have been identified and counted, and what is left is a lookup —
    /// brand, model number, printed size, barcode digits — which pixels cannot improve.
    func priceManifest(_ request: ManifestPriceRequest) async throws -> [DiscoveredItem] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValuationError.missingAPIKey
        }
        let body = try manifestPriceRequestBody(request)
        let answer = try await send(body)
        return try decodeItems(from: answer)
    }

    /// Runs the batched route for one lot: one **manifest batch** per chunk of the gallery, then the pricing
    /// requests over the inventory they add up to (one per dozen lines, so ordinarily one).
    ///
    /// Everything that decides *what happens* — the grouping, the batches, the fold, the accounting, the
    /// fallback — is `LotManifestScan`'s, and is the same code the DeepSeek transport runs: this method
    /// supplies the two halves the route is handed, and neither half has to be DeepSeek's for the route to
    /// run. It is reached only when the app hands this transport a width (`photosPerRequest`), which it does
    /// only while the operator has pointed the photograph half away from the appraiser — so this is the
    /// Gemini-priced, DeepSeek-read run.
    ///
    /// Returns `nil` when the route could not produce a valuation, with the reason already reported to the
    /// console, so the caller's fallback is free to take over. A cancelled run is *thrown* instead: a stopped
    /// run must not fall back into a request nobody is waiting for.
    private func manifestRoute(
        subject: ValuationSubject,
        description: String,
        download: LotImageDownload,
        labels: [LotImageEvidence],
        evidence: LotImageEvidence
    ) async throws -> ValuationOutcome? {
        // Whoever the operator named — and with nobody named, this transport, which is the state a run is in
        // when the app has not been told to point the photograph half anywhere else.
        let reader: any ManifestService = manifestReader ?? self

        guard let scan = try await LotManifestScan.run(
            subject: subject,
            description: description,
            images: download.images,
            labels: labels,
            evidence: evidence,
            width: photosPerRequest,
            perRequestBytes: maxTotalImageBytes,
            read: { request in try await reader.manifestBatch(request) },
            price: { [self] request in try await priceManifest(request) },
            report: report
        ) else { return nil }

        return ValuationOutcome(
            items: scan.items,
            imagesAvailable: subject.imageURLs.count,
            imagesSent: download.images.count,
            imagesSkipped: download.overBudget.count,
            modelID: modelID,
            // Named only when the identity pass was another service's: `nil` says the model above read the
            // manifest too, which is what every other route in the app does.
            identityModelID: manifestReader?.modelID,
            // Every batch, plus the requests that priced them.
            passes: scan.batches + scan.prices,
            evidence: evidence,
            scanRequests: scan.batches + scan.prices,
            manifest: scan.manifest
        )
    }
}

// MARK: - Request model

/// One part of a `generateContent` message: either text or an inlined image.
private enum RequestPart: Encodable {
    case text(String)
    case image(mimeType: String, base64: String)

    private enum Keys: String, CodingKey {
        case text
        case inlineData = "inline_data"
    }

    private enum InlineKeys: String, CodingKey {
        case mimeType = "mime_type"
        case data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let value):
            try container.encode(value, forKey: .text)
        case .image(let mimeType, let base64):
            var inline = container.nestedContainer(keyedBy: InlineKeys.self, forKey: .inlineData)
            try inline.encode(mimeType, forKey: .mimeType)
            try inline.encode(base64, forKey: .data)
        }
    }
}

/// `POST /v1beta/models/{model}:generateContent` body.
private struct GenerateContentRequest: Encodable {

    struct SystemInstruction: Encodable {
        var parts: [TextPart]
    }

    struct TextPart: Encodable {
        var text: String
    }

    struct Content: Encodable {
        var role: String
        var parts: [RequestPart]
    }

    struct GenerationConfig: Encodable {
        var temperature: Double
        var responseMimeType: String
        var responseSchema: ResponseSchemaNode

        private enum CodingKeys: String, CodingKey {
            case temperature
            case responseMimeType = "response_mime_type"
            case responseSchema = "response_schema"
        }
    }

    var systemInstruction: SystemInstruction
    var contents: [Content]
    var generationConfig: GenerationConfig

    private enum CodingKeys: String, CodingKey {
        case systemInstruction = "system_instruction"
        case contents
        case generationConfig = "generation_config"
    }
}

/// Response envelope from `:generateContent` (only the fields this tool consumes).
private struct GenerateContentResponse: Decodable {

    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                var text: String?
            }
            var parts: [Part]?
        }
        var content: Content?
        var finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case content
            case finishReason = "finish_reason"
        }
    }

    struct PromptFeedback: Decodable {
        var blockReason: String?

        private enum CodingKeys: String, CodingKey {
            case blockReason = "block_reason"
        }
    }

    var candidates: [Candidate]?
    var promptFeedback: PromptFeedback?

    private enum CodingKeys: String, CodingKey {
        case candidates
        case promptFeedback = "prompt_feedback"
    }
}

/// Google's error envelope, used to turn an HTTP failure into a readable message.
private struct APIErrorEnvelope: Decodable {

    struct APIError: Decodable {
        /// One entry of `error.details`. The `@type` discriminator is ignored; the only field
        /// worth reading is `RetryInfo.retryDelay`, which a quota error carries as `"17s"`.
        struct Detail: Decodable {
            var retryDelay: String?
        }

        var code: Int?
        var message: String?
        var status: String?
        var details: [Detail]?

        /// Server-provided wait hint, if this failure carried one.
        var retryDelay: String? {
            details?.compactMap(\.retryDelay).first
        }
    }

    var error: APIError?
}

// MARK: - Transport

extension GeminiValuationService {

    /// Builds the JSON body for `:generateContent`.
    ///
    /// Gemini is one of the few providers that takes the output shape out-of-band, so the prompt
    /// carries no schema text — `responseSchema` is doing that work. What the prompt *does* carry is
    /// the app's own reading of the photographs (`evidence`), so the model can price the product the
    /// barcode names instead of guessing at a carton.
    private func requestBody(
        subject: ValuationSubject,
        description: String,
        images: [LotImage],
        evidence: LotImageEvidence? = nil
    ) throws -> Data {
        var parts: [RequestPart] = [
            .text(
                LotValuationPrompt.userPrompt(
                    description: description,
                    imageCount: images.count,
                    evidence: evidence
                )
            )
        ]
        parts.append(contentsOf: images.map { .image(mimeType: $0.mimeType, base64: $0.base64) })

        let request = GenerateContentRequest(
            systemInstruction: GenerateContentRequest.SystemInstruction(
                parts: [GenerateContentRequest.TextPart(text: LotValuationPrompt.systemInstruction)]
            ),
            contents: [GenerateContentRequest.Content(role: "user", parts: parts)],
            generationConfig: GenerateContentRequest.GenerationConfig(
                temperature: LotValuationPrompt.standardTemperature,
                responseMimeType: "application/json",
                responseSchema: LotValuationPrompt.itemsSchema
            )
        )
        return try JSONEncoder().encode(request)
    }

    /// Builds the text-only `:generateContent` body for the cheap pre-price.
    ///
    /// No image parts at all: the savings come from what is *not* sent, so this must never grow a
    /// photograph if the pre-price is to stay cheap enough to run ahead of every lot.
    private func prePriceRequestBody(description: String) throws -> Data {
        let request = GenerateContentRequest(
            systemInstruction: GenerateContentRequest.SystemInstruction(
                parts: [GenerateContentRequest.TextPart(text: LotValuationPrompt.prePriceSystemInstruction)]
            ),
            contents: [
                GenerateContentRequest.Content(
                    role: "user",
                    parts: [.text(LotValuationPrompt.prePricePrompt(description: description))]
                )
            ],
            generationConfig: GenerateContentRequest.GenerationConfig(
                temperature: LotValuationPrompt.standardTemperature,
                responseMimeType: "application/json",
                responseSchema: LotValuationPrompt.prePriceSchema
            )
        )
        return try JSONEncoder().encode(request)
    }

    /// Builds the single-photograph `:generateContent` body.
    ///
    /// One image part, always: this request answers a question about one frame, and the reading that
    /// comes back says which frame it was — so the reconciliation can weigh it against the others
    /// rather than averaging them together.
    private func photoReadingRequestBody(_ request: PhotoReadingRequest) throws -> Data {
        let body = GenerateContentRequest(
            systemInstruction: GenerateContentRequest.SystemInstruction(
                parts: [GenerateContentRequest.TextPart(text: LotPhotoScanPrompt.readingSystemInstruction)]
            ),
            contents: [
                GenerateContentRequest.Content(
                    role: "user",
                    parts: [
                        .text(LotPhotoScanPrompt.userPrompt(request)),
                        .image(mimeType: request.image.mimeType, base64: request.image.base64)
                    ]
                )
            ],
            generationConfig: GenerateContentRequest.GenerationConfig(
                temperature: LotValuationPrompt.standardTemperature,
                responseMimeType: "application/json",
                responseSchema: LotPhotoScanPrompt.readingSchema
            )
        )
        return try JSONEncoder().encode(body)
    }

    /// Builds the reconciliation `:generateContent` body.
    ///
    /// Text-only in the default configuration, where every photograph was read on its own: the
    /// readings already carry what the photographs showed. A ceiling on the per-image path leaves
    /// photographs unread, and those travel here as image parts, so a scan never sees less of a lot
    /// than a single pass would have. The output shape is the ordinary item schema, which is what
    /// makes a reconciled valuation indistinguishable downstream.
    private func aggregationRequestBody(_ request: PhotoAggregationRequest) throws -> Data {
        var parts: [RequestPart] = [.text(LotPhotoScanPrompt.aggregationPrompt(request))]
        parts.append(contentsOf: request.leftoverImages.map { .image(mimeType: $0.mimeType, base64: $0.base64) })

        let body = GenerateContentRequest(
            systemInstruction: GenerateContentRequest.SystemInstruction(
                parts: [GenerateContentRequest.TextPart(text: LotPhotoScanPrompt.aggregationSystemInstruction)]
            ),
            contents: [GenerateContentRequest.Content(role: "user", parts: parts)],
            generationConfig: GenerateContentRequest.GenerationConfig(
                temperature: LotValuationPrompt.standardTemperature,
                responseMimeType: "application/json",
                responseSchema: LotValuationPrompt.itemsSchema
            )
        )
        return try JSONEncoder().encode(body)
    }

    /// Builds the single-batch `:generateContent` body for the manifest route's identity pass.
    ///
    /// No schema text in the prompt, unlike the same request on the batching transport: the shape is
    /// `responseSchema` here, and prose describing a schema on top of an enforced one only gives the
    /// model two things to reconcile. The frames travel as `inline_data` parts in the same user
    /// message as the question — the batch question is written to be answered with several
    /// photographs in hand, which is the whole point of the batch.
    private func manifestBatchRequestBody(_ request: ManifestBatchRequest) throws -> Data {
        var parts: [RequestPart] = [
            .text(
                LotManifestPrompt.manifestPrompt(
                    description: request.description,
                    batch: request.batch,
                    batchCount: request.batchCount,
                    positions: request.positions,
                    imageCount: request.imageCount,
                    evidence: request.evidence
                )
            )
        ]
        parts.append(contentsOf: request.images.map { .image(mimeType: $0.mimeType, base64: $0.base64) })

        let body = GenerateContentRequest(
            systemInstruction: GenerateContentRequest.SystemInstruction(
                parts: [GenerateContentRequest.TextPart(text: LotManifestPrompt.manifestSystemInstruction)]
            ),
            contents: [GenerateContentRequest.Content(role: "user", parts: parts)],
            generationConfig: GenerateContentRequest.GenerationConfig(
                // Zero, unlike every other pass here: an extraction, not a judgement
                // (`LotManifestPrompt.manifestTemperature`).
                temperature: LotManifestPrompt.manifestTemperature,
                responseMimeType: "application/json",
                responseSchema: LotManifestPrompt.manifestSchema
            )
        )
        return try JSONEncoder().encode(body)
    }

    /// Builds the text-only `:generateContent` body for a **manifest pricing** pass.
    ///
    /// The same shape as the aggregation pass — one prompt, no images, `itemsSchema` as `responseSchema` —
    /// and for the same reason: a priced manifest has to decode exactly like any other valuation, so the
    /// shape is enforced by the API rather than asked for in prose and the prompt carries no schema text.
    ///
    /// The manifest travels as the JSON slab `LotManifestPrompt.render(_:)` produced from the *decoded*
    /// inventory, never as a batch's raw answer, so nothing chatty a batch said can reach the request that
    /// prices it.
    private func manifestPriceRequestBody(_ request: ManifestPriceRequest) throws -> Data {
        let rendered = LotManifestPrompt.render(request.manifest)
        let body = GenerateContentRequest(
            systemInstruction: GenerateContentRequest.SystemInstruction(
                parts: [GenerateContentRequest.TextPart(text: LotManifestPrompt.pricingSystemInstruction)]
            ),
            contents: [
                GenerateContentRequest.Content(
                    role: "user",
                    parts: [
                        .text(
                            LotManifestPrompt.pricingPrompt(
                                description: request.description,
                                manifestText: rendered.text,
                                itemCount: request.manifest.count,
                                unitCount: request.manifest.unitCount,
                                omitted: rendered.omitted,
                                evidence: request.evidence
                            )
                        )
                    ]
                )
            ],
            generationConfig: GenerateContentRequest.GenerationConfig(
                temperature: LotValuationPrompt.standardTemperature,
                responseMimeType: "application/json",
                responseSchema: LotValuationPrompt.itemsSchema
            )
        )
        return try JSONEncoder().encode(body)
    }


    /// POSTs the request and decodes the envelope.
    private func send(_ body: Data) async throws -> GenerateContentResponse {
        let url = Self.endpoint(for: modelID)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header auth keeps the key out of URLs, proxies and any retained request logs.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        var attempt = 1
        while true {
            if let pacer { try await pacer.waitForTurn() }

            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200..<300).contains(status) {
                return try JSONDecoder().decode(GenerateContentResponse.self, from: data)
            }

            let message = Self.errorMessage(from: data)
            let hint = Self.retryDelay(from: http, data: data)
            guard ValuationRetry.isRetryable(status: status), attempt < maxAttempts else {
                throw ValuationRetry.failure(status: status, message: message, retryDelay: hint)
            }

            // Quota and gateway errors are expected on the free tier, so wait the server's own
            // hint when it gave one and otherwise back off with jitter.
            let pause = ValuationRetry.delay(attempt: attempt, serverHint: hint)
            try await Task.sleep(for: .seconds(pause))
            attempt += 1
        }
    }

    /// Waits suggested by the API: the `Retry-After` header (seconds or HTTP-date) or the
    /// `RetryInfo.retryDelay` Google embeds in a 429 body as `"17s"`. Everything else about the
    /// retry policy is shared with the DeepSeek transport (`ValuationRetry`).
    private static func retryDelay(from response: HTTPURLResponse?, data: Data) -> TimeInterval? {
        if let header = ValuationRetry.retryAfterHeader(response) { return header }
        guard let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data),
              let raw = envelope.error?.retryDelay else { return nil }
        return ValuationRetry.parseDuration(raw)
    }

    private static func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data),
           let message = envelope.error?.message,
           !message.isEmpty {
            return message
        }
        let text = String(decoding: data, as: UTF8.self).condensedWhitespace
        return text.isEmpty ? "no details" : String(text.prefix(300))
    }

    /// Turns the model's strict-JSON answer into row models.
    private func decodeItems(from answer: GenerateContentResponse) throws -> [DiscoveredItem] {
        let (text, finishReason) = try answerText(from: answer)
        return try LotValuationAnswer.items(fromAnswerText: text, finishReason: finishReason)
    }

    /// Turns the model's strict-JSON pre-price answer into whole-pallet figures.
    private func decodePrePrice(from answer: GenerateContentResponse) throws -> PrePriceEstimate {
        let (text, finishReason) = try answerText(from: answer)
        return try LotValuationAnswer.prePrice(fromAnswerText: text, finishReason: finishReason)
    }

    /// The safety checks and unwrapping both decoders share: a blocked prompt, a missing candidate
    /// and a blocking finish reason are failures whatever was asked for.
    private func answerText(from answer: GenerateContentResponse) throws -> (text: String, finishReason: String?) {
        if let block = answer.promptFeedback?.blockReason {
            throw ValuationError.blocked(reason: block)
        }
        guard let candidate = answer.candidates?.first else {
            throw ValuationError.malformedResponse("the response contained no candidates")
        }
        if let finish = candidate.finishReason, Self.blockingFinishReasons.contains(finish) {
            throw ValuationError.blocked(reason: finish)
        }
        return ((candidate.content?.parts ?? []).compactMap(\.text).joined(), candidate.finishReason)
    }

    private static let blockingFinishReasons: Set<String> = [
        "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "IMAGE_SAFETY"
    ]
}
