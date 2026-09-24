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
/// documented `v1beta` REST endpoint directly. A currently-supported Flash model is used —
/// `gemini-1.5-flash` has been retired — see `defaultModelID`.
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
/// ## Why `@unchecked Sendable`
/// All stored properties are immutable value/`let` references, and the only shared mutable
/// object is `URLSession`, which is documented as safe to use from multiple threads. The
/// annotation papers over the fact that the SDK's `Sendable` conformance for `URLSession`
/// depends on the toolchain in use.
struct GeminiValuationService: ValuationService, @unchecked Sendable {

    /// Currently supported multimodal flash model.
    static let defaultModelID = "gemini-2.5-flash"

    /// Alternatives offered in the UI.
    static let availableModelIDs = [
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
        "gemini-2.0-flash"
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

    init(
        apiKey: String,
        modelID: String = GeminiValuationService.defaultModelID,
        session: URLSession = .shared,
        maxImageBytes: Int = 6_000_000,
        maxTotalImageBytes: Int = LotImageLoader.defaultTotalBytes,
        requestsPerMinute: Int = 0,
        maxAttempts: Int = 4
    ) {
        self.apiKey = apiKey
        self.modelID = modelID.isEmpty ? Self.defaultModelID : modelID
        self.session = session
        self.maxImageBytes = maxImageBytes
        self.maxTotalImageBytes = maxTotalImageBytes
        self.maxAttempts = max(1, maxAttempts)
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
        let download = await LotImageLoader.download(
            candidates,
            maxBytes: maxImageBytes,
            totalBytes: maxTotalImageBytes,
            session: session
        )
        let description = LotValuationPrompt.listingText(for: subject)

        guard !download.images.isEmpty || !description.isEmpty else {
            throw ValuationError.noUsableImages(attempted: candidates.count, reason: download.failures.first)
        }

        // Read the photographs here first. Barcodes and label identifiers are the two things a
        // general vision model reads worst off a photograph and the two things this machine reads
        // natively, so the reading becomes literal text in the prompt (see `LotImageDigest`).
        let evidence = await LotImageDigest.read(download.images)

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
                temperature: 0.2,
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
                temperature: 0.2,
                responseMimeType: "application/json",
                responseSchema: LotValuationPrompt.prePriceSchema
            )
        )
        return try JSONEncoder().encode(request)
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
