//
//  DeepSeekValuationService.swift
//  PalletAuctionBidTool
//
//  Multimodal valuation of scraped lots through DeepSeek's OpenAI-compatible chat completions.
//

import Foundation

/// Drives the multimodal valuation of scraped lots through DeepSeek's REST API.
///
/// ## Why `deepseek-flash` and nothing else
/// `deepseek-flash` (DeepSeek-V4.1-Flash) is the only model DeepSeek serves that declares image
/// input (`input_modalities: ["text","image"]`); `deepseek-v4-pro` is text-only. Since valuation
/// depends on the photographs, offering the text-only model would silently degrade every lot to a
/// listing-text guess, so `availableModelIDs` lists just the one.
///
/// ## Not a free tier
/// Unlike the Gemini route, DeepSeek bills from a prepaid balance. What it does not have is a
/// requests-per-minute quota: the documented limit is concurrency (2500 in-flight requests for
/// `deepseek-flash`), so **Requests / min** exists here as a brake rather than a requirement.
///
/// ## The batched route, and why it is the default here
/// `value(subject:)` reads a lot's photographs **in batches**, one request per `photosPerRequest`
/// frames, each request answering with the distinct products that batch showed
/// (`LotManifestPrompt.manifestPrompt`). The batches are folded into one inventory on this machine
/// (`PalletManifest.absorb(_:)`) and that inventory is then priced in **text-only** requests
/// (`pricingPrompt`) — one per dozen inventory lines, so ordinarily one, and no photographs at all,
/// because a price is a fact about a product rather than about a picture.
///
/// That split is what makes the route both cheaper and better than the two alternatives it replaces on
/// this transport:
///
/// * **Cheaper**, because a ten-frame lot costs three requests rather than eleven, and pricing an inventory
///   of twenty items costs two text-only requests instead of twenty.
/// * **Better at counting**, because the frames that show the same carton travel *together*: a model
///   that can see the front and the side in one context recognises one carton where two separate
///   per-frame readings can only be reconciled after the fact.
/// * **Better at pricing**, because the pricing pass is not distracted by pixels: it looks a named
///   product up from its brand, model number, printed size and barcode digits — the fields the manifest
///   spent its rules collecting.
///
/// ## Who reads the batches is a choice (Tier 4)
/// The route's two halves are separable, and this service only owns the second by right. Given a
/// `manifestService` (`AppSettings.photoProvider`, `ManifestService`), the batches are read by
/// *that* transport's model and the manifest it returns is priced here — so the vision half can be
/// bought from the model that reads a carton best while the text half stays on the cheaper key. With
/// none given — the default — this transport reads its own batches, exactly as it did before the
/// split existed, and `ManifestService` is what the route has always been doing in one file.
///
/// ## The other two routes, and when they run
/// * **The thorough path** (`LotPhotoScan`, `photoScan`) reads **one photograph per request** and
///   reconciles the readings. It is opt-out here rather than removed: a lot whose small items hide in
///   corners is what it is for, and `AppSettings` hands DeepSeek a `.disabled` plan while a batch width
///   is set — one place decides which route a run takes. A lot with no photographs, or a manifest route
///   that produced nothing usable, falls through to the passes below.
/// * **The two-pass route** (the fallback): the listing text first, then the whole gallery in one
///   request, with the text pass's draft handed forward. That is still roughly 2× the cost of one
///   request and is what a lot with no text or no usable manifest falls back to, so a lot is never
///   failed for want of a fallback.
///
/// ## Weaker output contract, compensated for
/// DeepSeek offers `json_object` mode but no `json_schema`/strict mode. Two things make up for it:
/// the exact shape Gemini enforces is rendered to JSON Schema text
/// (`LotValuationPrompt.itemsSchema.jsonSchemaText`) and embedded in the prompt — the docs require
/// the word "json" *and* a format example — and an empty answer is retried, because DeepSeek
/// documents that JSON mode "may occasionally return empty content".
///
/// ## Why `@unchecked Sendable`
/// As with `GeminiValuationService`: every stored property is an immutable value or a `let`
/// reference, and the only shared mutable object is `URLSession`, which is documented as safe to
/// use from multiple threads.
struct DeepSeekValuationService: ValuationService, ManifestService, @unchecked Sendable {

    /// The only image-capable model DeepSeek serves.
    static let defaultModelID = "deepseek-flash"

    /// Offered in the UI. See the type doc comment for why the text-only model is absent.
    static let availableModelIDs = [
        "deepseek-flash"
    ]

    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    /// Caps the answer so a runaway JSON object cannot be billed in full.
    static let maxOutputTokens = 3_000

    /// Brief pause before re-asking after an empty answer. Short on purpose: that failure is a
    /// coin flip rather than a server telling us to back off.
    static let emptyAnswerPause: ClosedRange<Double> = 0.3...0.8

    let apiKey: String
    let modelID: String
    let session: URLSession

    /// Largest single image that will be inlined, in bytes. Base64 inflates by ~33%, and DeepSeek
    /// caps the whole request body at 48 MiB.
    let maxImageBytes: Int

    /// Ceiling on *all* the images one request carries — see `LotImageLoader.defaultTotalBytes`.
    let maxTotalImageBytes: Int

    /// Spacing enforced between outbound requests; `nil` when the operator set no ceiling.
    private let pacer: RequestPacer?

    /// Attempts per request: the first try plus retries for rate limits, gateway errors and the
    /// empty answers JSON mode occasionally produces.
    private let maxAttempts: Int

    /// `"none"` turns DeepSeek's thinking mode off, which is what an extraction task wants: the
    /// documented default is `"high"`, and reasoning tokens are billed as output tokens.
    private let reasoningEffort: String?

    /// How many photographs one **manifest batch** request carries. `0` — the default here, so a caller
    /// that has said nothing gets the transport's older routes — switches the batched route off and
    /// leaves `photoScan` to decide how the gallery is read.
    ///
    /// The app sets this from **Photos / request** (`AppSettings.photosPerRequest`), and the count is a
    /// trade rather than a limit: a batch has to be small enough that a billed conversation stays
    /// proportionate to the pallet, and large enough that the same carton seen from two angles is inside
    /// one context — which is the whole reason the batch exists. Past a dozen frames the answer stops
    /// improving and the request starts costing.
    let photosPerRequest: Int

    /// How this service reads a lot's photographs.
    ///
    /// Defaults to the single pass over the whole gallery, so a caller that has said nothing about it
    /// gets exactly the behaviour this service had before the thorough path existed; the app passes
    /// `PhotoScanPlan.thorough(...)` in (`AppSettings.photoScanPlan`), which is `.disabled` while the
    /// batched route is on — see that method for why one place decides. DeepSeek's limit is concurrency
    /// rather than requests per minute, so the thorough path's *n* + 1 requests cost latency here
    /// rather than quota — which is why the plan's concurrency matters most on this transport.
    let photoScan: PhotoScanPlan

    /// Where per-photograph readings are remembered between scans (`PhotoReadingStore`).
    let store: PhotoReadingStore

    /// The service that reads this service's manifest batches, when the identity role belongs to
    /// another provider (`ManifestService`, `AppSettings.photoProvider`).
    ///
    /// `nil` — the default — means this transport batches itself: a run's own key reads the gallery
    /// and prices what it read, which is every install that has not asked for a split. Given a
    /// service, the batches go there instead and `manifestRoute` is the only thing that changes: the
    /// fold, the accounting, the console and the pricing pass are this transport's either way, so a
    /// split run is not a second route to keep in step.
    let manifestService: ManifestService?

    /// Progress for a caller with somewhere to print it.
    private let report: @Sendable (PhotoScanReport) -> Void

    init(
        apiKey: String,
        modelID: String = DeepSeekValuationService.defaultModelID,
        session: URLSession = .shared,
        maxImageBytes: Int = 6_000_000,
        maxTotalImageBytes: Int = LotImageLoader.defaultTotalBytes,
        requestsPerMinute: Int = 0,
        maxAttempts: Int = 4,
        reasoningEffort: String? = "none",
        photoScan: PhotoScanPlan = .disabled,
        photosPerRequest: Int = 0,
        manifestService: ManifestService? = nil,
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
        self.manifestService = manifestService
        self.store = store
        self.report = report
        self.reasoningEffort = reasoningEffort
        self.pacer = requestsPerMinute > 0 ? RequestPacer(requestsPerMinute: requestsPerMinute) : nil
    }

    // MARK: - Valuation

    /// Appraises one lot in two passes: the listing text first, then the photographs, with the
    /// text pass's draft handed forward as context. See "Two passes, deliberately" above for why,
    /// and for the degrade paths that keep a lot from failing when only one pass can run.
    func value(subject: ValuationSubject) async throws -> ValuationOutcome {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValuationError.missingAPIKey
        }

        let description = LotValuationPrompt.listingText(for: subject)
        // Every photograph the lot carries, as read off its own page.
        let candidates = subject.imageURLs

        // The download ceiling depends on the route: the batched route sends the gallery in several
        // requests, so it may hold more of it than a single request could carry; every other route puts
        // the whole set in one request and stays inside the one-request budget.
        var download = await LotImageLoader.download(
            candidates,
            maxBytes: maxImageBytes,
            totalBytes: photosPerRequest > 0 ? LotManifestScan.downloadBytes : maxTotalImageBytes,
            session: session
        )

        // Nothing to reason about at all: neither text nor a single readable photograph.
        guard !download.images.isEmpty || !description.isEmpty else {
            throw ValuationError.noUsableImages(attempted: candidates.count, reason: download.failures.first)
        }

        // Read the photographs here first: a decoded UPC or a printed model number is the strongest
        // pricing evidence a pallet photograph can hold, and it is the one thing the provider's own
        // vision pass is least reliable at (see `LotImageDigest`). Read per photograph, so the thorough
        // path can quote each frame's own digits and the passes below can roll them up exactly as they
        // always did.
        let labels = download.images.isEmpty ? [] : await LotImageDigest.readEach(download.images)
        let evidence = LotImageDigest.merge(labels)

        // The batched route — the one this transport is optimised for. It answers whole-pallet questions
        // (`photosPerRequest` frames per request, an inventory, then one pricing request), so a lot it
        // cannot appraise falls through to the thorough path or the two-pass route below rather than
        // failing; the console is told why.
        if photosPerRequest > 0, !download.images.isEmpty {
            let outcome = try await manifestRoute(
                subject: subject,
                description: description,
                download: download,
                labels: labels,
                evidence: evidence
            )
            if let outcome { return outcome }

            // Out of the batched route and into one that puts the whole set in a *single* request, so the
            // set is trimmed back to what one request may carry (`LotImageLoader.batches` was what let the
            // download hold more). Whatever the trim drops is counted as skipped, exactly as a frame the
            // download itself could not take is, so the row and the console keep saying `40 of 46` rather
            // than quietly reporting fewer.
            let sendable = LotManifestScan.withinOneRequest(download.images, budget: maxTotalImageBytes)
            if sendable.count < download.images.count {
                let dropped = Array(download.images.dropFirst(sendable.count))
                download.images = sendable
                download.overBudget.append(contentsOf: dropped.map(\.sourceURL))
            }
        }

        // One request per photograph, then a reconciliation, when the operator asked for it. The
        // listing text rides along in every one of those asks, so the two-pass split below is not
        // needed — and not paid for either.
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
                // A stopped run has to stay stopped: falling back here would send a request nobody is
                // waiting for any more.
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

        // Pass 1 — the listing text, on its own. A failure here is remembered rather than thrown:
        // the photographs may still be able to answer.
        var textItems: [DiscoveredItem]?
        var textFailure: Error?
        if !description.isEmpty {
            do {
                textItems = try await textPass(description: description)
            } catch {
                textFailure = error
            }
        }

        // No usable photograph: the text pass's answer is the whole valuation.
        guard !download.images.isEmpty else {
            if let textItems {
                return ValuationOutcome(
                    items: textItems,
                    imagesAvailable: candidates.count,
                    imagesSent: 0,
                    modelID: modelID,
                    passes: 1
                )
            }
            throw textFailure ?? ValuationError.noContent(finishReason: nil)
        }

        // Pass 2 — the photographs, seeded with pass 1's draft.
        do {
            let items = try await imagePass(
                description: description,
                images: download.images,
                priorAnalysis: textItems.map(Self.answerJSON),
                evidence: evidence
            )
            return ValuationOutcome(
                items: items,
                imagesAvailable: candidates.count,
                imagesSent: download.images.count,
                imagesSkipped: download.overBudget.count,
                modelID: modelID,
                // The photograph pass stands alone when the text pass had nothing to read (or
                // failed), and is the second of two passes when it was seeded with a draft.
                passes: textItems == nil ? 1 : 2,
                evidence: evidence
            )
        } catch {
            // The photograph pass is the authoritative one, but a text-only answer beats failing
            // the lot outright — that is exactly the lot's listing text being useful for once.
            if let textItems {
                return ValuationOutcome(
                    items: textItems,
                    imagesAvailable: candidates.count,
                    imagesSent: 0,
                    modelID: modelID,
                    passes: 1
                )
            }
            throw error
        }
    }

    /// The thorough path: one request per photograph, then one reconciliation.
    ///
    /// - Returns: `.completed` when the readings produced a valuation; `.unavailable` with the reason
    ///   when they did not, so `value(subject:)` can decide whether the two passes below are still
    ///   worth paying for.
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
                    // Every photograph read, plus the reconciliation: the number of requests the
                    // figures rest on, which on this transport is what the concurrency note above is
                    // about.
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

    /// Runs the batched route for one lot: one **manifest batch** per chunk of the gallery, then the
    /// pricing requests over the inventory they add up to (one per dozen lines, so ordinarily one).
    ///
    /// The route itself — the grouping, the batches, the fold, the accounting and the two passes — is
    /// `LotManifestScan`'s, and is written once for both transports. What this method decides is *who reads
    /// the batches*: with a `manifestService` injected the photographs go to that provider and the prices
    /// stay here (`AppSettings.photoProvider`), and with none this transport reads its own gallery exactly as
    /// it did before the role existed.
    ///
    /// Returns `nil` when the route could not produce a valuation — every batch failed, the batches found
    /// nothing sellable, or the pricing pass failed — with the reason already reported to the console, so the
    /// caller's fallback is free to take over. A cancelled run is *thrown* instead, as everywhere else in
    /// this file: a stopped run must not fall back into a request nobody is waiting for.
    private func manifestRoute(
        subject: ValuationSubject,
        description: String,
        download: LotImageDownload,
        labels: [LotImageEvidence],
        evidence: LotImageEvidence
    ) async throws -> ValuationOutcome? {
        // The identity half, handed to whichever service the operator pointed it at
        // (`AppSettings.photoProvider`); with none named this is `self`, which is the route exactly as it
        // always was.
        let reader: any ManifestService = manifestService ?? self

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
            identityModelID: manifestService?.modelID,
            // Every batch, plus the requests that priced them.
            passes: scan.batches + scan.prices,
            evidence: evidence,
            scanRequests: scan.batches + scan.prices,
            manifest: scan.manifest
        )
    }


    /// Reads one batch of a lot's photographs into manifest items: one `/chat/completions` call carrying
    /// several frames, the batch question and the manifest schema.
    ///
    /// This transport's own answer to the `ManifestService` question, and the default one: the route
    /// calls it directly while the identity role is unfilled (`manifestService`), and the operator can
    /// name it explicitly as well (`PhotoProvider.deepSeek`).
    ///
    /// The frames travel as `image_url` data URLs in the same user message as the question, exactly as
    /// the single-pass photograph pass sends its gallery — the difference between the two is the
    /// question, the schema, and how many frames one request is asked to reconcile against each other.
    ///
    /// Sent at `temperature: 0` (`LotManifestPrompt.manifestTemperature`), which is this route's
    /// deliberate departure from the app's own sampling warmth: what comes back is extraction, and a
    /// pallet read twice has to count the same twice. The answer carries the batch's *accounting* as well
    /// as its goods (`ManifestBatchAnswer`), because a frame the batch says nothing about is a product
    /// the inventory may be short of and only the route can see that. No strict mode exists here, so the
    /// schema travels as JSON Schema *text* inside the prompt (`Self.embeddedManifestSchema`) — which is
    /// the whole difference between this conformance and Gemini's.
    func manifestBatch(_ request: ManifestBatchRequest) async throws -> ManifestBatchAnswer {
        let body = try requestBody(
            systemInstruction: LotManifestPrompt.manifestSystemInstruction,
            prompt: LotManifestPrompt.manifestPrompt(
                description: request.description,
                batch: request.batch,
                batchCount: request.batchCount,
                positions: request.positions,
                imageCount: request.imageCount,
                evidence: request.evidence,
                schemaText: Self.embeddedManifestSchema
            ),
            images: request.images,
            // Zero, unlike every other pass on this transport: this is an extraction, and the same pallet
            // read twice must not come back with two different counts (`LotManifestPrompt.manifestTemperature`).
            temperature: LotManifestPrompt.manifestTemperature
        )
        let answer = try await send(body)
        guard let choice = answer.choices?.first else {
            throw ValuationError.malformedResponse("the response contained no choices")
        }
        return try LotManifestAnswer.answer(
            fromAnswerText: Self.answerText(of: answer),
            finishReason: choice.finishReason
        )
    }

    /// Prices a piece of a settled manifest, in a text-only request over the inventory, held to the same
    /// schema every other pass's answer is (`LotValuationPrompt.itemsSchema`), so a priced manifest is
    /// indistinguishable downstream from any other valuation.
    ///
    /// No photographs, deliberately: the goods have been identified and counted by the batches, and what is
    /// left is a lookup — brand, model number, printed size, barcode digits — which pixels cannot improve and
    /// which costs a fraction of what an image request does. How much of an inventory one request may price
    /// is the route's business (`LotManifestScan.itemsPerPriceRequest`), so this is handed one reply-sized
    /// piece at a time.
    ///
    /// This transport's answer to the `ManifestPricingService` question, and the default one: the route calls
    /// it directly while the appraiser prices its own manifest — which is every run whose photographs were
    /// read here — and it is what prices a manifest another provider read.
    func priceManifest(_ request: ManifestPriceRequest) async throws -> [DiscoveredItem] {
        let rendered = LotManifestPrompt.render(request.manifest)
        let body = try requestBody(
            systemInstruction: LotManifestPrompt.pricingSystemInstruction,
            prompt: LotManifestPrompt.pricingPrompt(
                description: request.description,
                manifestText: rendered.text,
                itemCount: request.manifest.count,
                unitCount: request.manifest.unitCount,
                omitted: rendered.omitted,
                evidence: request.evidence,
                schemaText: Self.embeddedSchema
            ),
            images: []
        )
        return try decodeItems(from: try await send(body))
    }


    /// Reads **one** photograph: one `/chat/completions` call carrying the single-image question, the
    /// single-image reader output and the per-photograph schema.
    func readPhoto(_ request: PhotoReadingRequest) async throws -> PhotoReading {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValuationError.missingAPIKey
        }
        let body = try requestBody(
            systemInstruction: LotPhotoScanPrompt.readingSystemInstruction,
            prompt: LotPhotoScanPrompt.userPrompt(request, schemaText: Self.embeddedReadingSchema),
            images: [request.image]
        )
        let answer = try await send(body)
        guard let choice = answer.choices?.first else {
            throw ValuationError.malformedResponse("the response contained no choices")
        }
        return try LotPhotoScanAnswer.reading(
            fromAnswerText: Self.answerText(of: answer),
            finishReason: choice.finishReason,
            request: request,
            modelID: modelID
        )
    }

    /// Reconciles a lot's readings into its line items, in one request — text-only, plus any
    /// photographs a ceiling kept out of the per-image path.
    func aggregate(_ request: PhotoAggregationRequest) async throws -> [DiscoveredItem] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValuationError.missingAPIKey
        }
        let body = try requestBody(
            systemInstruction: LotPhotoScanPrompt.aggregationSystemInstruction,
            prompt: LotPhotoScanPrompt.aggregationPrompt(request, schemaText: Self.embeddedSchema),
            images: request.leftoverImages
        )
        return try decodeItems(from: try await send(body))
    }

    /// Cheap first look: a single text-only request for whole-pallet figures, run ahead of the
    /// two-pass valuation.
    ///
    /// Deliberately its own request rather than a by-product of `textPass(description:)`: the two
    /// ask for different things (whole-pallet totals versus a line-item draft), and keeping them
    /// apart means the pre-price can be switched off without perturbing the valuation pipeline.
    func prePrice(subject: ValuationSubject) async throws -> PrePriceEstimate {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValuationError.missingAPIKey
        }

        let body = try requestBody(
            systemInstruction: LotValuationPrompt.prePriceSystemInstruction,
            prompt: LotValuationPrompt.prePricePrompt(
                description: LotValuationPrompt.listingText(for: subject),
                schemaText: Self.embeddedPrePriceSchema
            ),
            images: []
        )
        return try decodePrePrice(from: try await send(body))
    }

    /// Pass 1: the listing text, no photographs.
    private func textPass(description: String) async throws -> [DiscoveredItem] {
        let body = try requestBody(
            systemInstruction: LotValuationPrompt.textPassSystemInstruction,
            prompt: LotValuationPrompt.textPassPrompt(
                description: description,
                schemaText: Self.embeddedSchema
            ),
            images: []
        )
        return try decodeItems(from: try await send(body))
    }

    /// Pass 2: the photographs, seeded with pass 1's draft and with this machine's own reading of
    /// them.
    private func imagePass(
        description: String,
        images: [LotImage],
        priorAnalysis: String?,
        evidence: LotImageEvidence? = nil
    ) async throws -> [DiscoveredItem] {
        let body = try requestBody(
            systemInstruction: LotValuationPrompt.systemInstruction,
            prompt: LotValuationPrompt.imagePassPrompt(
                description: description,
                imageCount: images.count,
                priorAnalysis: priorAnalysis,
                evidence: evidence,
                schemaText: Self.embeddedSchema
            ),
            images: images
        )
        return try decodeItems(from: try await send(body))
    }

    /// Builds the JSON body for `/chat/completions`.
    ///
    /// Images travel as base64 `image_url` data URLs in the **user** message: DeepSeek rejects an
    /// image anywhere else with a 400. No `detail` level is sent, so the provider's own default
    /// applies (passing `"low"` would downsample to 512×512 and cut cost at the price of legibility
    /// on small labels). The text pass passes an empty `images` array, which is a valid
    /// text-only user message.
    ///
    /// `temperature` is a parameter rather than a constant because exactly one caller wants a different
    /// one: every pass samples at `LotValuationPrompt.standardTemperature`, and the manifest batch sends
    /// zero (`LotManifestPrompt.manifestTemperature`).
    private func requestBody(
        systemInstruction: String,
        prompt: String,
        images: [LotImage],
        temperature: Double = LotValuationPrompt.standardTemperature
    ) throws -> Data {
        var parts: [ChatContentPart] = [.text(prompt)]
        parts.append(contentsOf: images.map { .imageDataURL(mimeType: $0.mimeType, base64: $0.base64) })

        let request = ChatCompletionRequest(
            model: modelID,
            messages: [.system(systemInstruction), .user(parts)],
            responseFormat: ChatCompletionRequest.ResponseFormat(type: "json_object"),
            temperature: temperature,
            maxTokens: Self.maxOutputTokens,
            reasoningEffort: reasoningEffort
        )
        return try JSONEncoder().encode(request)
    }

    /// Re-renders a pass's decoded items as the JSON the next pass is handed. Re-encoding (rather
    /// than threading the raw answer through) keeps the draft in the exact shape `ValuationPayload`
    /// decodes, so a chatty or fenced answer can never confuse the follow-up prompt.
    private static func answerJSON(_ items: [DiscoveredItem]) -> String {
        let payload = ValuationPayload.from(items: items)
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Schema text embedded in every prompt, rendered once for the process.
    private static let embeddedSchema = LotValuationPrompt.itemsSchema.jsonSchemaText

    /// The pre-price's own rendered schema, kept apart from `embeddedSchema` so neither ask can
    /// start describing the other's shape.
    private static let embeddedPrePriceSchema = LotValuationPrompt.prePriceSchema.jsonSchemaText

    /// The per-photograph reading's rendered schema. Its own constant for the same reason: JSON mode
    /// wants the shape in the prompt, and the shape of a reading is nothing like the shape of a
    /// valuation.
    private static let embeddedReadingSchema = LotPhotoScanPrompt.readingSchema.jsonSchemaText

    /// The manifest batch's rendered schema. Its own constant for the same reason the reading's is: a
    /// manifest line has no price and carries the model number a line item does not, so the shape the
    /// batches are asked for is nothing like the shape the pricing pass is asked for.
    private static let embeddedManifestSchema = LotManifestPrompt.manifestSchema.jsonSchemaText
}

// MARK: - Request model

/// `POST /chat/completions` body (OpenAI format, as documented by DeepSeek).
private struct ChatCompletionRequest: Encodable {

    struct ResponseFormat: Encodable {
        var type: String
    }

    var model: String
    var messages: [ChatMessage]
    var responseFormat: ResponseFormat
    var temperature: Double
    var maxTokens: Int
    var reasoningEffort: String?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
    }
}

/// One entry of `messages`: `content` is a plain string for the system role and an array of parts
/// for the user role, so one `Encodable` has to be able to emit either shape.
private enum ChatMessage: Encodable {
    case system(String)
    case user([ChatContentPart])

    private enum Keys: String, CodingKey {
        case role
        case content
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .system(let text):
            try container.encode("system", forKey: .role)
            try container.encode(text, forKey: .content)
        case .user(let parts):
            try container.encode("user", forKey: .role)
            try container.encode(parts, forKey: .content)
        }
    }
}

/// One block of a user message: text, or an inlined image as a base64 data URL.
private enum ChatContentPart: Encodable {
    case text(String)
    case imageDataURL(mimeType: String, base64: String)

    private struct ImageURL: Encodable {
        var url: String
    }

    private enum Keys: String, CodingKey {
        case type
        case text
        case imageUrl = "image_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .imageDataURL(let mimeType, let base64):
            try container.encode("image_url", forKey: .type)
            try container.encode(
                ImageURL(url: "data:\(mimeType);base64,\(base64)"),
                forKey: .imageUrl
            )
        }
    }
}

// MARK: - Response model

/// Response envelope from `/chat/completions` (only the fields this tool consumes).
private struct ChatCompletionResponse: Decodable {

    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String?
        }

        var message: Message?
        var finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    var choices: [Choice]?
}

/// DeepSeek's error envelope, used to turn an HTTP failure into a readable message.
private struct ChatCompletionErrorEnvelope: Decodable {

    struct APIError: Decodable {
        var message: String?
        var type: String?
    }

    var error: APIError?
}

// MARK: - Transport

extension DeepSeekValuationService {

    /// POSTs the request and decodes the envelope, retrying whatever is worth retrying.
    private func send(_ body: Data) async throws -> ChatCompletionResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Bearer auth keeps the key out of URLs, proxies and any retained request logs.
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var attempt = 1
        while true {
            if let pacer { try await pacer.waitForTurn() }

            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0

            if (200..<300).contains(status) {
                let answer = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
                // JSON mode "may occasionally return empty content": re-ask rather than fail the
                // lot, which is the documented mitigation. A short pause, not a back-off — this is
                // a coin flip, not a server telling us to wait.
                if Self.answerText(of: answer).isEmpty, attempt < maxAttempts {
                    try await Task.sleep(for: .seconds(Double.random(in: Self.emptyAnswerPause)))
                    attempt += 1
                    continue
                }
                return answer
            }

            let message = Self.errorMessage(from: data)
            let hint = ValuationRetry.retryAfterHeader(http)
            guard ValuationRetry.isRetryable(status: status), attempt < maxAttempts else {
                throw ValuationRetry.failure(status: status, message: message, retryDelay: hint)
            }

            // A concurrency refusal is expected under load, so wait the server's own hint when it
            // gave one and otherwise back off with jitter.
            let pause = ValuationRetry.delay(attempt: attempt, serverHint: hint)
            try await Task.sleep(for: .seconds(pause))
            attempt += 1
        }
    }

    /// Turns the model's JSON answer into row models.
    private func decodeItems(from answer: ChatCompletionResponse) throws -> [DiscoveredItem] {
        guard let choice = answer.choices?.first else {
            throw ValuationError.malformedResponse("the response contained no choices")
        }
        return try LotValuationAnswer.items(
            fromAnswerText: Self.answerText(of: answer),
            finishReason: choice.finishReason
        )
    }

    /// Turns the model's JSON pre-price answer into whole-pallet figures.
    private func decodePrePrice(from answer: ChatCompletionResponse) throws -> PrePriceEstimate {
        guard let choice = answer.choices?.first else {
            throw ValuationError.malformedResponse("the response contained no choices")
        }
        return try LotValuationAnswer.prePrice(
            fromAnswerText: Self.answerText(of: answer),
            finishReason: choice.finishReason
        )
    }

    /// The assistant's text for the first choice, trimmed.
    private static func answerText(of answer: ChatCompletionResponse) -> String {
        (answer.choices?.first?.message?.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ChatCompletionErrorEnvelope.self, from: data),
           let message = envelope.error?.message,
           !message.isEmpty {
            return message
        }
        let text = String(decoding: data, as: UTF8.self).condensedWhitespace
        return text.isEmpty ? "no details" : String(text.prefix(300))
    }
}
