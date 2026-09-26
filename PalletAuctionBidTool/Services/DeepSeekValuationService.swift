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
struct DeepSeekValuationService: ValuationService, @unchecked Sendable {

    /// The only image-capable model DeepSeek serves.
    static let defaultModelID = "deepseek-flash"

    /// Offered in the UI. See the type doc comment for why the text-only model is absent.
    static let availableModelIDs = [
        "deepseek-flash"
    ]

    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    /// Caps the answer so a runaway JSON object cannot be billed in full.
    static let maxOutputTokens = 3_000

    /// Manifest batches in flight at once.
    ///
    /// The pacer still spaces the requests themselves, so this only decides how much of a slow
    /// provider's latency is hidden — and unlike the per-photograph path there is no store to consult
    /// first, so every batch is a real request. Three matches the batch width a run of **Price all**
    /// uses and the concurrency the thorough path defaults to, and DeepSeek's documented ceiling is
    /// 2500 requests in flight rather than a per-minute quota, so there is room for it many times over.
    static let manifestBatchesInFlight = 3

    /// Ceiling on how much of a gallery the batched route downloads at all, in bytes.
    ///
    /// Two requests' worth, rather than the single request the other routes are bounded by: the whole
    /// point of batching is that a long gallery no longer has to fit in one request, so the download
    /// ceiling is what keeps "every photograph" true for a lot with forty of them. It is not unlimited
    /// on purpose — the frames are held in memory as base64 strings while they are sent, and three lots
    /// are appraised at a time — so a gallery past this is *reported* as skipped rather than quietly
    /// dropped (`LotImageDownload.overBudget`).
    static let manifestDownloadBytes = 2 * LotImageLoader.defaultTotalBytes

    /// Manifest items one **pricing** request asks for.
    ///
    /// The batched route's second half is text-only, so the only thing bounding it is how much a model can
    /// enumerate in one reply: the app's own single-pass prompt caps itself at twelve line items for that
    /// reason, and an answer truncated mid-object decodes as a failure rather than as a partial valuation.
    /// A pallet's inventory is one request as often as not; a warehouse's is priced in a few complete
    /// replies (`PalletManifest.batches(ofSize:)`).
    static let manifestItemsPerPriceRequest = 12

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
            totalBytes: photosPerRequest > 0 ? Self.manifestDownloadBytes : maxTotalImageBytes,
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
            let sendable = Self.withinOneRequest(download.images, budget: maxTotalImageBytes)
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
    /// The gallery is grouped before anything is sent (`PhotoFrameGrouping`), and a frame that is the
    /// *same picture* as an earlier frame is left out: an auction gallery that lists one photograph twice
    /// — a re-listed lot, the same zoom image served at two addresses — is one photograph, and a batch
    /// carrying it twice would be asking the model to reconcile it against itself. Only that claim is
    /// acted on here; a frame folded on its decoded barcode is still sent, because its pixels are the only
    /// place a count of the goods can come from. The batches therefore name the gallery numbers they hold
    /// rather than a range of them (`LotManifestPrompt.runPhrase(_:)`), and each batch's own frames plus
    /// the repeated photographs they stand for are what the readout's "answered" counts.
    ///
    /// Returns `nil` when the route could not produce a valuation — every batch failed, the batches
    /// found nothing sellable, or the pricing pass failed — with the reason already reported to the
    /// console, so the caller's fallback is free to take over. A cancelled run is *thrown* instead, as
    /// everywhere else in this file: a stopped run must not fall back into a request nobody is waiting
    /// for.
    private func manifestRoute(
        subject: ValuationSubject,
        description: String,
        download: LotImageDownload,
        labels: [LotImageEvidence],
        evidence: LotImageEvidence
    ) async throws -> ValuationOutcome? {
        let lotNumber = subject.lotNumber
        let galleryCount = download.images.count

        // 0. Which of the gallery's photographs are the same picture, and so are not bought twice.
        let repeated = await Self.repeatedPictures(in: download.images, labels: labels)
        for view in repeated.views {
            report(PhotoScanReport(lotNumber: lotNumber, event: .folded(view)))
        }

        // The frames that need sending, with the gallery numbers they hold: a batch has to be able to say
        // "photographs 1, 3 and 4 of 5" for the `views` it answers to mean anything.
        let positions = galleryCount > 0
            ? (1...galleryCount).filter { !repeated.frames.contains($0) }
            : []
        guard !positions.isEmpty else { return nil }

        // The gallery, split into batches that each fit one request's inline budget.
        let batches = LotImageLoader.batches(
            of: positions.map { download.images[$0 - 1] },
            width: photosPerRequest,
            perRequestBytes: maxTotalImageBytes
        )
        guard !batches.isEmpty else { return nil }

        // Each batch with the gallery numbers it covers, and the frames it answers for.
        let chunks = Self.chunked(batches, over: positions, standing: repeated.stands)
        guard !chunks.isEmpty else { return nil }

        // Every batch's answer, by batch number — so the manifest is folded in gallery order however the
        // answers landed.
        var answers: [ManifestBatchAnswer?] = Array(repeating: nil, count: chunks.count)
        var firstFailure: Error?
        var failures: [String] = []
        // Frames with an answer behind them: read, or given up on. What the readout counts, exactly as it
        // counts the per-photograph path's answers.
        var answered = 0
        var requested = 0

        let width = min(Self.manifestBatchesInFlight, chunks.count)
        await withTaskGroup(of: (Int, Result<ManifestBatchAnswer, Error>).self) { group in
            var next = 0

            while next < chunks.count {
                if Task.isCancelled { break }
                let index = next
                next += 1
                let chunk = chunks[index]
                // The app's own reading of **this** batch's frames, not of the gallery: a barcode decoded
                // off photograph 3 is not evidence about photograph 9 (see `LotImageDigest`).
                let batchEvidence = Self.evidence(labels, at: chunk.positions)
                // Announced here, from the loop that launches the request rather than from inside the
                // task, so the console says which batch is starting and the readout gets a count the
                // caller can vouch for.
                report(
                    PhotoScanReport(
                        lotNumber: lotNumber,
                        event: .manifesting(
                            batch: index + 1,
                            of: chunks.count,
                            frames: chunk.images.count,
                            answered: answered,
                            total: galleryCount
                        )
                    )
                )
                group.addTask { [self] in
                    do {
                        let answer = try await manifestBatch(
                            description: description,
                            batch: index + 1,
                            batchCount: chunks.count,
                            positions: chunk.positions,
                            images: chunk.images,
                            imageCount: galleryCount,
                            evidence: batchEvidence
                        )
                        // The app's own reading of the frames this batch just answered about is folded into
                        // its answer: the digits the reader decoded are what joins two sightings of one
                        // carton when the batches named the goods around them differently. The batch's
                        // account of its frames travels through unchanged — enriching items cannot change
                        // which photographs it spoke for.
                        let coded = ManifestBatchAnswer(
                            items: Self.withLocalCodes(answer.items, labels: labels, positions: chunk.positions),
                            unreadPhotos: answer.unreadPhotos
                        )
                        return (index, .success(coded))
                    } catch {
                        return (index, .failure(error))
                    }
                }
                // Wait for a slot to free up once the window is full.
                if next < chunks.count, next % width == 0, let finished = await group.next() {
                    requested += 1
                    collectManifest(
                        finished,
                        into: &answers,
                        answered: &answered,
                        firstFailure: &firstFailure,
                        failures: &failures,
                        chunks: chunks,
                        galleryCount: galleryCount,
                        lotNumber: lotNumber
                    )
                }
            }

            if Task.isCancelled { group.cancelAll() }
            for await finished in group {
                requested += 1
                collectManifest(
                    finished,
                    into: &answers,
                    answered: &answered,
                    firstFailure: &firstFailure,
                    failures: &failures,
                    chunks: chunks,
                    galleryCount: galleryCount,
                    lotNumber: lotNumber
                )
            }
        }

        // A batch's failure is never fatal on its own; a *stopped* run is stopped, so the cancellation is
        // rethrown rather than turned into a fallback nobody is waiting for.
        if let firstFailure, ValuationCancellation.isCancellation(firstFailure) { throw firstFailure }

        // Folded in gallery order, so the inventory reads the same whichever batch answered first.
        var manifest = PalletManifest()
        for answer in answers.compactMap({ $0 }) { manifest.absorb(answer) }

        guard !manifest.isEmpty else {
            report(
                PhotoScanReport(
                    lotNumber: lotNumber,
                    event: .fallingBackFromManifest(
                        reason: Self.manifestFailurePhrase(failures: failures, requested: requested)
                    )
                )
            )
            return nil
        }

        // The inventory, stated before it is priced: this is the line that says what the photographs were
        // read to hold, and what the pricing pass is about to multiply. Then the pricing request itself,
        // announced with the number of lines it will be asked to price.
        report(PhotoScanReport(lotNumber: lotNumber, event: .manifestSettled(manifest)))
        report(PhotoScanReport(lotNumber: lotNumber, event: .pricing(items: manifest.count)))

        do {
            let items = try await pricingPass(
                lotNumber: lotNumber,
                description: description,
                manifest: manifest,
                evidence: evidence
            )
            return ValuationOutcome(
                items: items,
                imagesAvailable: subject.imageURLs.count,
                imagesSent: galleryCount,
                imagesSkipped: download.overBudget.count,
                modelID: modelID,
                // Every batch, plus the requests that priced them.
                passes: requested + manifest.batches(ofSize: Self.manifestItemsPerPriceRequest).count,
                evidence: evidence,
                scanRequests: requested + manifest.batches(ofSize: Self.manifestItemsPerPriceRequest).count,
                manifest: manifest
            )
        } catch {
            if ValuationCancellation.isCancellation(error) { throw error }
            report(
                PhotoScanReport(
                    lotNumber: lotNumber,
                    event: .fallingBackFromManifest(
                        reason: "the manifest was read but could not be priced "
                            + "(\(ValuationError.describe(error)))"
                    )
                )
            )
            return nil
        }
    }

    /// Reads one batch of a lot's photographs into manifest items: one `/chat/completions` call carrying
    /// several frames, the batch question and the manifest schema.
    ///
    /// The frames travel as `image_url` data URLs in the same user message as the question, exactly as
    /// the single-pass photograph pass sends its gallery — the difference between the two is the
    /// question, the schema, and how many frames one request is asked to reconcile against each other.
    ///
    /// Sent at `temperature: 0` (`LotManifestPrompt.manifestTemperature`), which is this route's
    /// deliberate departure from the app's own sampling warmth: what comes back is extraction, and a
    /// pallet read twice has to count the same twice. The answer carries the batch's *accounting* as well
    /// as its goods (`ManifestBatchAnswer`), because a frame the batch says nothing about is a product
    /// the inventory may be short of and only the route can see that.
    private func manifestBatch(
        description: String,
        batch: Int,
        batchCount: Int,
        positions: [Int],
        images: [LotImage],
        imageCount: Int,
        evidence: LotImageEvidence
    ) async throws -> ManifestBatchAnswer {
        let body = try requestBody(
            systemInstruction: LotManifestPrompt.manifestSystemInstruction,
            prompt: LotManifestPrompt.manifestPrompt(
                description: description,
                batch: batch,
                batchCount: batchCount,
                positions: positions,
                imageCount: imageCount,
                evidence: evidence,
                schemaText: Self.embeddedManifestSchema
            ),
            images: images,
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

    /// Prices a settled manifest, one **reply-sized piece** at a time: text-only requests over the
    /// inventory, held to the same schema every other pass's answer is
    /// (`LotValuationPrompt.itemsSchema`), so a priced manifest is indistinguishable downstream from any
    /// other valuation.
    ///
    /// No photographs, deliberately: the goods have been identified and counted by the batches, and what
    /// is left is a lookup — brand, model number, printed size, barcode digits — which pixels cannot
    /// improve and which costs a fraction of what an image request does.
    ///
    /// The inventory is walked in pieces (`PalletManifest.batches(ofSize:)`) because one reply can only
    /// enumerate so much: asking for forty line items in one request risks an answer truncated mid-object,
    /// which is a decode failure rather than a partial valuation. A pallet's inventory is one request as
    /// often as not; the pieces are priced in order, sequentially, because the batches that produced the
    /// manifest dominate the latency and an ordered console is worth more here than overlapping two small
    /// text requests. The merged list is then put back in the order the single-pass route returns — most
    /// valuable first — since each piece only ordered itself.
    private func pricingPass(
        lotNumber: String,
        description: String,
        manifest: PalletManifest,
        evidence: LotImageEvidence
    ) async throws -> [DiscoveredItem] {
        var priced: [DiscoveredItem] = []

        for piece in manifest.batches(ofSize: Self.manifestItemsPerPriceRequest) {
            let rendered = LotManifestPrompt.render(piece)
            let body = try requestBody(
                systemInstruction: LotManifestPrompt.pricingSystemInstruction,
                prompt: LotManifestPrompt.pricingPrompt(
                    description: description,
                    manifestText: rendered.text,
                    itemCount: piece.count,
                    unitCount: piece.unitCount,
                    omitted: rendered.omitted,
                    evidence: evidence,
                    schemaText: Self.embeddedSchema
                ),
                images: []
            )
            let items = try decodeItems(from: try await send(body))
            report(
                PhotoScanReport(lotNumber: lotNumber, event: .priced(items: items.count))
            )
            priced.append(contentsOf: items)
        }

        return priced.sorted { $0.resaleValue > $1.resaleValue }
    }
    /// Files one batch's result: an answer to be folded in, or a failure to be reported and moved past.
    ///
    /// A failed batch is a hole in the inventory rather than a failed lot — the pallet is still worth
    /// appraising from the batches that answered, and the console says which one was lost. A batch that
    /// answered but left frames out of its account gets the same treatment from the other side: its
    /// items are kept, and the frames it said nothing about are named (`PhotoScanEvent.manifestGap`),
    /// because a photograph missing from both lists is a product the inventory may be short of.
    private func collectManifest(
        _ finished: (Int, Result<ManifestBatchAnswer, Error>),
        into answers: inout [ManifestBatchAnswer?],
        answered: inout Int,
        firstFailure: inout Error?,
        failures: inout [String],
        chunks: [ManifestChunk],
        galleryCount: Int,
        lotNumber: String
    ) {
        let (index, result) = finished
        let batch = index + 1

        switch result {
        case .success(let answer):
            answers[index] = answer
            answered += chunks[index].answered
            report(
                PhotoScanReport(
                    lotNumber: lotNumber,
                    event: .manifested(
                        batch: batch,
                        of: chunks.count,
                        items: answer.items.count,
                        answered: answered,
                        total: galleryCount
                    )
                )
            )
            // What the batch did *not* account for, if anything: the frames of its own batch that it
            // named in no item and declared in no `unreadPhotos` list.
            let gap = answer.unaccountedFrames(among: chunks[index].positions)
            if !gap.isEmpty {
                report(
                    PhotoScanReport(
                        lotNumber: lotNumber,
                        event: .manifestGap(batch: batch, of: chunks.count, frames: gap)
                    )
                )
            }
        case .failure(let error):
            if firstFailure == nil { firstFailure = error }
            let reason = ValuationError.describe(error)
            failures.append(reason)
            report(
                PhotoScanReport(
                    lotNumber: lotNumber,
                    event: .manifestFailed(
                        batch: batch,
                        of: chunks.count,
                        answered: answered,
                        total: galleryCount,
                        reason: reason
                    )
                )
            )
        }
    }

    /// The leading frames of a downloaded set that fit **one** request, in gallery order.
    ///
    /// Needed only when a route falls back out of the batched one: its download ceiling is wider than a
    /// single request (`manifestDownloadBytes`) because its batches *are* separate requests, while the
    /// per-photograph plan's reconciliation and the two-pass photograph pass both put what is left in one.
    /// A frame that does not fit ends the walk rather than being stepped over — what follows it in the
    /// gallery is a later view of the same pallet, so a tail that did not travel is easier to explain than
    /// a hole in the middle — and the frames the walk leaves behind are reported as skipped, not dropped.
    private static func withinOneRequest(_ images: [LotImage], budget: Int) -> [LotImage] {
        var kept: [LotImage] = []
        var used = 0
        for image in images {
            guard used + image.byteCount <= budget else { break }
            kept.append(image)
            used += image.byteCount
        }
        return kept
    }

    /// The gallery's batches, each with the gallery numbers its frames hold.
    ///
    /// `LotImageLoader.batches(of:width:perRequestBytes:)` takes the frames in gallery order, so a batch
    /// is a run of the frames it was handed — but not necessarily a run of the *gallery*, because a
    /// photograph the gallery lists twice travels once (`PhotoFrameGrouping`). A batch therefore carries
    /// its gallery numbers instead of a range of them, and those numbers are what the prompt states and
    /// what the model's `views` come back in. Built here as one immutable value rather than assembled in
    /// the route, so the batch tasks capture a constant.
    private static func chunked(
        _ batches: [[LotImage]],
        over positions: [Int],
        standing: [Int: Int]
    ) -> [ManifestChunk] {
        var chunks: [ManifestChunk] = []
        var cursor = 0
        for batch in batches {
            let held = Array(positions[cursor..<(cursor + batch.count)])
            chunks.append(
                ManifestChunk(
                    images: batch,
                    positions: held,
                    answered: held.reduce(0) { $0 + (standing[$1] ?? 1) }
                )
            )
            cursor += batch.count
        }
        return chunks
    }

    /// The app's own reading of the frames at `positions` (`LotImageDigest`).
    ///
    /// `labels` is index-aligned with the downloaded gallery and may be shorter than it — the reader stops
    /// rather than reading a frame it cannot decode — so a missing reading is simply empty, exactly as
    /// `LotPhotoScan` treats it.
    private static func evidence(_ labels: [LotImageEvidence], at positions: [Int]) -> LotImageEvidence {
        LotImageDigest.merge(
            positions.compactMap { labels.indices.contains($0 - 1) ? labels[$0 - 1] : nil }
        )
    }

    /// One batch of the gallery as a request to send.
    private struct ManifestChunk: Sendable {

        /// The frames that travel with the request, in gallery order.
        var images: [LotImage]

        /// The gallery numbers of those frames — what the prompt states, and what `views` is answered in.
        var positions: [Int]

        /// How many of the gallery's photographs this batch answers for: its own frames, plus the
        /// repeated photographs each of them stands for. What the readout's "answered of total" counts.
        var answered: Int
    }

    /// The frames of a gallery that are provably the same photograph as an earlier frame, and so are not
    /// sent in the batches (`PhotoFrameGrouping`).
    private struct RepeatedPictures {

        /// Gallery numbers the batches leave out.
        var frames: Set<Int> = []

        /// A gallery number that *is* sent → how many frames it answers for, its own included.
        var stands: [Int: Int] = [:]

        /// One entry per frame left out, for the console — the claim, and where the frame went.
        var views: [PhotoView] = []
    }

    /// Asks `PhotoFrameGrouping` which of a gallery's frames are the same photograph, and keeps the claims
    /// this route can act on.
    ///
    /// Only `PhotoView.Reason.samePicture` is kept. A frame folded on its decoded barcode shows the same
    /// *product* from another angle, and this route's whole job is counting goods from photographs — so
    /// leaving that frame out would trade a count nothing can recover for one image's worth of request.
    /// Identical pixels carry no such risk: there is nothing in the second copy the first does not show,
    /// which is why the thorough path is willing to read a repeated frame once and carries the other into
    /// its reconciliation as an image.
    ///
    /// The grouping is asked with the whole gallery as its ceiling, because every frame on this route is
    /// read: there is no per-photograph limit for a frame to fall past here.
    private static func repeatedPictures(
        in images: [LotImage],
        labels: [LotImageEvidence]
    ) async -> RepeatedPictures {
        let grouping = await PhotoFrameGrouping.group(
            images: images,
            labels: labels,
            limit: images.count
        )

        var repeated = RepeatedPictures()
        for view in grouping.views {
            let folds = view.folds.filter { $0.reason == .samePicture }
            guard !folds.isEmpty else { continue }
            repeated.frames.formUnion(folds.map(\.frame))
            repeated.stands[view.representative, default: 1] += folds.count
            repeated.views.append(PhotoView(representative: view.representative, folds: folds))
        }
        return repeated
    }

    /// One batch's answer with the app's own reading of the frames it named folded in.
    ///
    /// This is what makes the identifier question (`ManifestItem.isSameProduct(as:)`) answerable when the
    /// digits were visible in one batch's photographs and not another's. A batch is told what the reader
    /// found on *its* frames, and the model is asked to quote a code it can see — but what the fold needs
    /// is not an answer about a code, it is the code itself, on the item, in the gallery's numbering. So
    /// the reader's decodes for each frame an item was seen in are appended to that item's identifiers
    /// here, on this machine, where they are facts rather than readings.
    ///
    /// Only frames **this batch** carried are consulted, and only the frames the item itself names: a
    /// `views` entry outside the batch is a slip by the model, and honouring it would attribute another
    /// frame's codes to this item.
    ///
    /// - Parameters:
    ///   - items: the batch's answer, as decoded.
    ///   - labels: the reader's per-frame readings, index-aligned with the downloaded gallery.
    ///   - positions: the gallery numbers of the frames the batch carried.
    private static func withLocalCodes(
        _ items: [ManifestItem],
        labels: [LotImageEvidence],
        positions: [Int]
    ) -> [ManifestItem] {
        var enriched = items
        for (index, item) in enriched.enumerated() {
            for view in item.views where positions.contains(view) {
                guard labels.indices.contains(view - 1) else { continue }
                let reading = labels[view - 1]
                for code in reading.barcodes + reading.identifiers where !enriched[index].identifiers.contains(
                    where: { $0.caseInsensitiveCompare(code) == .orderedSame }
                ) {
                    enriched[index].identifiers.append(code)
                }
                // The wording the reader made out stands in for a batch that named the goods around the
                // label rather than on it, and only ever fills a blank: a batch that read the label keeps
                // what it read (`ManifestItem.merge(_:)` makes the same choice the other way round).
                if enriched[index].labelText.isEmpty, let wording = reading.labelText.first {
                    enriched[index].labelText = wording
                }
            }
        }
        return enriched
    }

    /// Why the batched route came back with nothing, in one clause, for the console.
    private static func manifestFailurePhrase(failures: [String], requested: Int) -> String {
        guard let first = failures.first else { return "the batches read no goods" }
        guard requested > 1, failures.count < requested else {
            return "no batch could be read (\(first))"
        }
        return "\(failures.count) of \(requested) batch(es) could not be read (\(first))"
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
