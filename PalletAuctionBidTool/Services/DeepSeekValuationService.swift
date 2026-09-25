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
/// ## Two passes, deliberately
/// `value(subject:)` spends **two** requests on a lot that has both listing text and
/// photographs: the first reads the listing text alone, the second reads the photographs *and* the
/// first pass's draft, and is asked to correct it. That is a real cost increase (roughly 2×), paid
/// for a reason: `deepseek-flash` is measurably better at reading a product from a photograph when
/// it already knows what the listing claims is in the pallet, and separating the two keeps a
/// mis-read label or a bad quantity in the text from being copied straight into the answer. A lot
/// with no text uses the photograph pass only, and a lot with no photographs uses the text pass
/// only; if the photograph pass fails outright, the text pass's answer is used rather than failing
/// the lot.
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

    /// How this service reads a lot's photographs.
    ///
    /// Defaults to the single pass over the whole gallery, so a caller that has said nothing about it
    /// gets exactly the behaviour this service had before the thorough path existed; the app passes
    /// `PhotoScanPlan.thorough(...)` in (`AppSettings.photoScanPlan`). DeepSeek's limit is concurrency
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

        let download = await LotImageLoader.download(
            candidates,
            maxBytes: maxImageBytes,
            totalBytes: maxTotalImageBytes,
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
                    reconciliationFailure: scan.aggregationFailure
                )
            )
        }
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
    private func requestBody(
        systemInstruction: String,
        prompt: String,
        images: [LotImage]
    ) throws -> Data {
        var parts: [ChatContentPart] = [.text(prompt)]
        parts.append(contentsOf: images.map { .imageDataURL(mimeType: $0.mimeType, base64: $0.base64) })

        let request = ChatCompletionRequest(
            model: modelID,
            messages: [.system(systemInstruction), .user(parts)],
            responseFormat: ChatCompletionRequest.ResponseFormat(type: "json_object"),
            temperature: 0.2,
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
