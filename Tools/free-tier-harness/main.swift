//
//  main.swift
//  Offline harness for the valuation transports.
//
//  Compiles the real services (Services/LotValuation.swift, GeminiValuationService.swift,
//  DeepSeekValuationService.swift) against a URLProtocol stub, so the 429 retry loop,
//  Retry-After handling, RequestPacer pacing, request shaping and the shared decode can be
//  checked without a key and without touching the network. Not part of the app target.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Stub transport

/// One request as the stub saw it, so tests can assert on the wire format.
struct SeenRequest {
    var at: Date
    var method: String
    var url: URL
    var headers: [String: String]
    var body: String

    /// The body parsed as JSON, for shape assertions.
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:] }
}

/// Scripted responses handed out in order, recording when each request was seen.
final class StubScript: @unchecked Sendable {
    struct Step {
        var status: Int
        var body: Data = Data()
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var seen: [SeenRequest] = []

    init(_ steps: [Step]) { self.steps = steps }

    func next(_ request: URLRequest) -> Step {
        lock.lock()
        defer { lock.unlock() }
        seen.append(
            SeenRequest(
                at: Date(),
                method: request.httpMethod ?? "GET",
                url: request.url ?? URL(string: "about:blank")!,
                headers: request.allHTTPHeaderFields ?? [:],
                body: StubScript.bodyText(of: request)
            )
        )
        return steps.isEmpty ? Step(status: 500) : steps.removeFirst()
    }

    var requests: [SeenRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    var requestTimes: [Date] { requests.map(\.at) }

    /// URLSession hands the body to a `URLProtocol` as a stream, not as `httpBody`.
    private static func bodyText(of request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return String(decoding: data, as: UTF8.self)
    }
}

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var script: StubScript?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let script = Self.script, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let step = script.next(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: step.status,
            httpVersion: "HTTP/1.1",
            headerFields: step.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !step.body.isEmpty { client?.urlProtocol(self, didLoad: step.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Fixtures

/// A `generateContent` success envelope whose text part is the strict JSON the app expects.
let successBody: Data = {
    let inner = #"{"items":[{"itemName":"AA batteries, 12x 2-pack","confidence":"High","retailValue":420,"resaleValue":180,"notes":"Fast mover."}]}"#
    let escaped = inner.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return Data(#"{"candidates":[{"finish_reason":"STOP","content":{"parts":[{"text":"\#(escaped)"}]}}]}"#.utf8)
}()

/// The shape Google returns when a free-tier per-minute quota is exhausted.
let quotaBody = Data(#"{"error":{"code":429,"message":"You exceeded your current quota, please check your plan and billing details.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"1s"}]}}"#.utf8)

let subject = ValuationSubject(
    lotNumber: "142",
    title: "Pallet of returned general merchandise",
    rawDescription: "Mixed lot, 60 pieces.",
    currentBid: 210,
    imageURLs: [],
    detailURL: nil
)

/// Same lot, but with a photo, so the image path through both transports can be exercised.
let imageSubject = ValuationSubject(
    lotNumber: "142",
    title: "Pallet of returned general merchandise",
    rawDescription: "Mixed lot, 60 pieces.",
    currentBid: 210,
    imageURLs: [URL(string: "https://cdn.example.test/lot-142.jpg")!],
    detailURL: URL(string: "https://cdn.example.test/lots/142")
)

/// Stand-in for a downloaded photo: the loader only sniffs the declared content type.
let jpegBytes = Data(repeating: 0xFF, count: 512)

/// A photograph that really *is* an image — a small blank PNG, encoded here with CoreGraphics rather
/// than pasted in as a base64 blob so it cannot rot.
///
/// The reader has to be exercised against decodable bytes: a blank sheet with no barcode and no text
/// on it is the honest "nothing legible" case, and it is the one that proves the reader opened the
/// image at all. Nothing is drawn on the label-like photographs below, because drawing a real barcode
/// would be a test of CoreGraphics rather than of this app.
let blankPNGBytes: Data = {
    let side = 240
    guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return Data() }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    guard let image = context.makeImage() else { return Data() }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { return Data() }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return Data() }
    return data as Data
}()

/// Same lot, but with a whole gallery behind it — what a lot's own page produces. Four photographs,
/// so "everything the lot carries" and "the inline budget" can both be told apart from the old
/// fixed count of one.
let gallerySubject = ValuationSubject(
    lotNumber: "208",
    title: "Pallet of mixed kitchen appliances",
    rawDescription: "Mixed lot, 40 pieces.",
    currentBid: 640,
    imageURLs: (1...4).map { URL(string: "https://cdn.example.test/lot-208-\($0).jpg")! },
    detailURL: URL(string: "https://example.test/auction/lot/208")
)

/// One photograph of a `gallerySubject`'s gallery, as the stub answers it.
var galleryImageSteps: [StubScript.Step] {
    gallerySubject.imageURLs.map { _ in
        StubScript.Step(status: 200, body: jpegBytes, headers: ["Content-Type": "image/jpeg"])
    }
}

func makeService(
    _ script: StubScript,
    requestsPerMinute: Int,
    maxAttempts: Int,
    maxImageBytes: Int = 6_000_000,
    maxTotalImageBytes: Int = LotImageLoader.defaultTotalBytes
) -> GeminiValuationService {
    StubProtocol.script = script
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return GeminiValuationService(
        apiKey: "test-key",
        modelID: "gemini-2.5-flash",
        session: URLSession(configuration: configuration),
        maxImageBytes: maxImageBytes,
        maxTotalImageBytes: maxTotalImageBytes,
        requestsPerMinute: requestsPerMinute,
        maxAttempts: maxAttempts
    )
}

/// A `/chat/completions` success envelope whose message content is the JSON the app expects.
let deepSeekSuccessBody: Data = {
    let inner = #"{"items":[{"itemName":"AA batteries, 12x 2-pack","confidence":"High","retailValue":420,"resaleValue":180,"notes":"Fast mover."}]}"#
    let escaped = inner.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return Data(#"{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"\#(escaped)"}}]}"#.utf8)
}()

/// JSON mode "may occasionally return empty content" — the documented failure this app retries.
let deepSeekEmptyBody = Data(#"{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":""}}]}"#.utf8)

/// DeepSeek's 429 envelope: a concurrency ceiling, not a per-minute quota.
let deepSeekRateLimitBody = Data(#"{"error":{"message":"Rate limit reached for requests","type":"rate_limit_error","code":"rate_limit_exceeded"}}"#.utf8)

func makeDeepSeekService(
    _ script: StubScript,
    requestsPerMinute: Int,
    maxAttempts: Int,
    maxImageBytes: Int = 6_000_000,
    maxTotalImageBytes: Int = LotImageLoader.defaultTotalBytes
) -> DeepSeekValuationService {
    StubProtocol.script = script
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return DeepSeekValuationService(
        apiKey: "sk-test-key",
        modelID: "deepseek-flash",
        session: URLSession(configuration: configuration),
        maxImageBytes: maxImageBytes,
        maxTotalImageBytes: maxTotalImageBytes,
        requestsPerMinute: requestsPerMinute,
        maxAttempts: maxAttempts
    )
}

// MARK: - Reading a stubbed chat request

/// The user message's content parts, as the stub saw them.
func userParts(in request: SeenRequest?) -> [[String: Any]] {
    let messages = request?.json["messages"] as? [[String: Any]] ?? []
    return messages.last?["content"] as? [[String: Any]] ?? []
}

/// The concatenated text parts of a chat request's user message.
func userText(in request: SeenRequest?) -> String {
    userParts(in: request).compactMap { part in
        part["type"] as? String == "text" ? part["text"] as? String : nil
    }.joined()
}

/// The base64 data URLs of a chat request's image parts. Empty for a text-only pass.
func imageURLs(in request: SeenRequest?) -> [String] {
    userParts(in: request).compactMap { part in
        part["type"] as? String == "image_url"
            ? (part["image_url"] as? [String: Any])?["url"] as? String
            : nil
    }
}

/// A chat request's system instruction.
func systemText(in request: SeenRequest?) -> String {
    let messages = request?.json["messages"] as? [[String: Any]] ?? []
    return messages.first?["content"] as? String ?? ""
}


// MARK: - Assertions

/// Failure counter. A lock box rather than a global `var`, because top-level state in
/// `main.swift` is `@MainActor`-isolated under Swift 6.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

let tally = Tally()

func check(_ condition: Bool, _ label: String, detail: String = "") {
    if condition {
        print("  PASS  \(label)")
    } else {
        tally.bump()
        print("  FAIL  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func seconds(_ interval: TimeInterval) -> String { String(format: "%.2fs", interval) }


// MARK: - 1. Quota then success

do {
    print("1. HTTP 429 (Retry-After: 1) followed by a 200 is retried and succeeds")
    let script = StubScript([
        .init(status: 429, body: quotaBody, headers: ["Retry-After": "1"]),
        .init(status: 200, body: successBody)
    ])
    let service = makeService(script, requestsPerMinute: 0, maxAttempts: 4)
    let started = Date()
    let outcome = try await service.value(subject: subject)
    let elapsed = Date().timeIntervalSince(started)

    check(outcome.items.count == 1, "one line item decoded", detail: "\(outcome.items.count)")
    check(outcome.items.first?.confidence == "High", "confidence preserved")
    check(script.requestTimes.count == 2, "two attempts were made", detail: "\(script.requestTimes.count)")
    check(elapsed >= 1.8, "waited the server's hint before retrying", detail: seconds(elapsed))
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 2. Quota exhausted

do {
    print("2. A quota that never clears surfaces as rateLimited, not a generic HTTP error")
    let script = StubScript([
        .init(status: 429, body: quotaBody, headers: ["Retry-After": "1"]),
        .init(status: 429, body: quotaBody, headers: ["Retry-After": "1"]),
        .init(status: 429, body: quotaBody, headers: ["Retry-After": "1"])
    ])
    let service = makeService(script, requestsPerMinute: 0, maxAttempts: 3)
    do {
        _ = try await service.value(subject: subject)
        tally.bump()
        print("  FAIL  expected a thrown error")
    } catch let error as ValuationError {
        check(error.shortReason == "rate limited", "short reason names the refusal", detail: error.shortReason)
        check(script.requestTimes.count == 3, "stopped at maxAttempts", detail: "\(script.requestTimes.count)")
        if case .rateLimited(let status, let retryAfter, let message) = error {
            check(status == 429, "carries HTTP 429", detail: "\(status)")
            check(retryAfter == 1, "carries the parsed delay", detail: "\(String(describing: retryAfter))")
            check(message.contains("quota"), "keeps the API's message", detail: message)
        } else {
            tally.bump()
            print("  FAIL  wrong case: \(error)")
        }
    } catch {
        tally.bump()
        print("  FAIL  wrong error type: \(error)")
    }
}

// MARK: - 3. RetryInfo body is honoured when the header is absent

do {
    print("3. Without a Retry-After header the body's RetryInfo.retryDelay is used")
    let script = StubScript([
        .init(status: 429, body: quotaBody),
        .init(status: 200, body: successBody)
    ])
    let service = makeService(script, requestsPerMinute: 0, maxAttempts: 4)
    let started = Date()
    _ = try await service.value(subject: subject)
    let elapsed = Date().timeIntervalSince(started)
    check(elapsed >= 1.8, "honoured the 1s hint from the error body", detail: seconds(elapsed))
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}


// MARK: - 4. Pacing

do {
    print("4. requestsPerMinute spaces outbound calls")
    let script = StubScript([.init(status: 200, body: successBody),
                             .init(status: 200, body: successBody),
                             .init(status: 200, body: successBody)])
    let service = makeService(script, requestsPerMinute: 60, maxAttempts: 1)
    for _ in 0..<3 {
        _ = try await service.value(subject: subject)
    }
    let times = script.requestTimes
    let gaps = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }
    check(times.count == 3, "three requests issued", detail: "\(times.count)")
    check(gaps.allSatisfy { $0 >= 0.9 }, "each call waited ~1s (60/min)", detail: gaps.map(seconds).joined(separator: ", "))
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 5. Pacing disabled

do {
    print("5. requestsPerMinute 0 sends immediately")
    let script = StubScript([.init(status: 200, body: successBody),
                             .init(status: 200, body: successBody),
                             .init(status: 200, body: successBody)])
    let service = makeService(script, requestsPerMinute: 0, maxAttempts: 1)
    let started = Date()
    for _ in 0..<3 {
        _ = try await service.value(subject: subject)
    }
    let elapsed = Date().timeIntervalSince(started)
    check(elapsed < 0.5, "no artificial delay", detail: seconds(elapsed))
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 6. Non-retryable failures are not retried

do {
    print("6. HTTP 400 fails fast (one request, no back-off)")
    let script = StubScript([
        .init(status: 400, body: Data(#"{"error":{"code":400,"message":"API key not valid"}}"#.utf8))
    ])
    let service = makeService(script, requestsPerMinute: 0, maxAttempts: 4)
    let started = Date()
    do {
        _ = try await service.value(subject: subject)
        tally.bump()
        print("  FAIL  expected a thrown error")
    } catch let error as ValuationError {
        let elapsed = Date().timeIntervalSince(started)
        check(error == .http(status: 400, message: "API key not valid"), "reported as HTTP 400", detail: "\(error)")
        check(script.requestTimes.count == 1, "no retry", detail: "\(script.requestTimes.count)")
        check(elapsed < 0.5, "no back-off", detail: seconds(elapsed))
    }
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 7. Pacing holds under concurrency

print("7. Concurrent lots queue behind the pacer instead of bunching")
do {
    let script = StubScript((0..<4).map { _ in .init(status: 200, body: successBody) })
    let service = makeService(script, requestsPerMinute: 120, maxAttempts: 1)
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<4 {
            group.addTask { _ = try? await service.value(subject: subject) }
        }
    }
    let times = script.requestTimes
    let gaps = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }
    check(times.count == 4, "four requests issued", detail: "\(times.count)")
    check(gaps.allSatisfy { $0 >= 0.4 }, "all four spaced ~0.5s apart (120/min)", detail: gaps.map(seconds).joined(separator: ", "))
}

// MARK: - 8. Stop during a back-off

do {
    print("8. Cancelling during a quota back-off stops at once")
    let script = StubScript([.init(status: 429, body: quotaBody, headers: ["Retry-After": "30"]),
                             .init(status: 200, body: successBody)])
    let service = makeService(script, requestsPerMinute: 0, maxAttempts: 4)
    let started = Date()
    let task = Task { try await service.value(subject: subject) }
    try? await Task.sleep(for: .milliseconds(300))
    task.cancel()
    do {
        _ = try await task.value
        tally.bump()
        print("  FAIL  expected cancellation")
    } catch {
        let elapsed = Date().timeIntervalSince(started)
        check(error is CancellationError, "threw CancellationError", detail: "\(error)")
        check(elapsed < 3, "did not wait out the 30s hint", detail: seconds(elapsed))
        check(script.requestTimes.count == 1, "no further requests after Stop", detail: "\(script.requestTimes.count)")
    }
}


// MARK: - 9. DeepSeek: quota refusal then success

do {
    print("9. DeepSeek: HTTP 429 with Retry-After is waited out and retried")
    let script = StubScript([
        .init(status: 429, body: deepSeekRateLimitBody, headers: ["Retry-After": "1"]),
        .init(status: 200, body: deepSeekSuccessBody)
    ])
    let service = makeDeepSeekService(script, requestsPerMinute: 0, maxAttempts: 4)
    let started = Date()
    let outcome = try await service.value(subject: subject)
    let elapsed = Date().timeIntervalSince(started)

    check(outcome.items.count == 1, "one line item decoded", detail: "\(outcome.items.count)")
    check(outcome.modelID == "deepseek-flash", "outcome names the model used", detail: outcome.modelID)
    check(script.requestTimes.count == 2, "two attempts were made", detail: "\(script.requestTimes.count)")
    check(elapsed >= 1.8, "waited the server's hint before retrying", detail: seconds(elapsed))
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 10. DeepSeek: refusal that never clears

do {
    print("10. DeepSeek: an exhausted rate limit surfaces as rateLimited")
    let script = StubScript([
        .init(status: 429, body: deepSeekRateLimitBody),
        .init(status: 429, body: deepSeekRateLimitBody)
    ])
    let service = makeDeepSeekService(script, requestsPerMinute: 0, maxAttempts: 2)
    do {
        _ = try await service.value(subject: subject)
        tally.bump()
        print("  FAIL  expected a thrown error")
    } catch let error as ValuationError {
        check(error.shortReason == "rate limited", "short reason is provider-neutral", detail: error.shortReason)
        check(script.requestTimes.count == 2, "stopped at maxAttempts", detail: "\(script.requestTimes.count)")
        if case .rateLimited(let status, _, let message) = error {
            check(status == 429, "carries HTTP 429", detail: "\(status)")
            check(message.contains("Rate limit"), "keeps the API's message", detail: message)
        } else {
            tally.bump()
            print("  FAIL  wrong case: \(error)")
        }
    } catch {
        tally.bump()
        print("  FAIL  wrong error type: \(error)")
    }
}

// MARK: - 11. DeepSeek: wire format

do {
    print("11. DeepSeek: pass 1 is text-only, pass 2 carries the photo, the schema and json_object mode")
    let script = StubScript([
        .init(status: 200, body: deepSeekSuccessBody),                                  // pass 1: text
        .init(status: 200, body: jpegBytes, headers: ["Content-Type": "image/jpeg"]),   // photo
        .init(status: 200, body: deepSeekSuccessBody)                                   // pass 2: photos
    ])
    let service = makeDeepSeekService(script, requestsPerMinute: 0, maxAttempts: 1)
    let outcome = try await service.value(subject: imageSubject)

    check(outcome.imagesSent == 1, "the photo reached the final request", detail: "\(outcome.imagesSent)")
    check(outcome.passes == 2, "the lot was appraised in two passes", detail: "\(outcome.passes)")

    let chats = script.requests.filter { $0.url.absoluteString == "https://api.deepseek.com/chat/completions" }
    check(chats.count == 2, "two chat completions were posted", detail: "\(chats.count)")

    // Pass 1 — listing text only.
    let firstText = userText(in: chats.first)
    check(imageURLs(in: chats.first).isEmpty, "pass 1 carries no photographs", detail: "\(imageURLs(in: chats.first).count)")
    check(firstText.contains("First pass"), "pass 1 announces itself as the text pass", detail: String(firstText.prefix(60)))
    check(firstText.contains("Pallet of returned general merchandise"), "pass 1 receives the scraped listing text")
    check(systemText(in: chats.first).contains("listing text only"), "pass 1 gets the text-pass system instruction", detail: String(systemText(in: chats.first).prefix(60)))

    // Pass 2 — photographs, seeded with pass 1's draft.
    let sent = chats.last
    let secondText = userText(in: sent)
    check(sent?.method == "POST", "posted", detail: sent?.method ?? "no request")
    check(sent?.url.absoluteString == "https://api.deepseek.com/chat/completions", "used the documented endpoint", detail: sent?.url.absoluteString ?? "—")
    check(sent?.headers["Authorization"] == "Bearer sk-test-key", "sent the key as a bearer header")

    let body = sent?.json ?? [:]
    check(body["model"] as? String == "deepseek-flash", "named the model", detail: "\(body["model"] ?? "—")")
    let format = body["response_format"] as? [String: Any]
    check(format?["type"] as? String == "json_object", "asked for JSON object mode", detail: "\(format ?? [:])")
    check(body["reasoning_effort"] as? String == "none", "turned thinking mode off", detail: "\(body["reasoning_effort"] ?? "—")")

    let messages = body["messages"] as? [[String: Any]] ?? []
    check(messages.count == 2, "one system and one user message", detail: "\(messages.count)")
    check(messages.first?["role"] as? String == "system", "system instruction first")
    check(messages.first.flatMap { $0["content"] as? String } != nil, "system content is a plain string")

    let images = imageURLs(in: sent)
    check(images.count == 1, "one image part", detail: "\(images.count)")
    check(images.allSatisfy { $0.hasPrefix("data:image/jpeg;base64,") }, "image is a base64 data URL", detail: images.first.map { String($0.prefix(40)) } ?? "—")
    check(secondText.contains("Second pass"), "pass 2 announces itself as the photograph pass", detail: String(secondText.prefix(60)))
    check(secondText.contains("earlier text pass proposed"), "pass 2 is handed pass 1's draft")
    check(secondText.contains("AA batteries"), "the draft carries pass 1's item names", detail: String(secondText.prefix(200)))
    check(secondText.contains("\"items\""), "prompt names the schema's items key")
    check(secondText.contains("additionalProperties"), "prompt embeds the full rendered schema")
    check(secondText.lowercased().contains("json"), "prompt contains the word json, which JSON mode requires")
    check(messages.first?.keys.contains("content") == true, "system message keeps its content key")
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}


// MARK: - 12. Shared schema rendering

do {
    print("12. The shared schema renders as JSON Schema for prompt-embedded use")
    let text = LotValuationPrompt.itemsSchema.jsonSchemaText
    let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]

    check(object != nil, "rendered schema parses as JSON")
    check(object?["type"] as? String == "object", "declares an object", detail: "\(object?["type"] ?? "—")")

    let items = (object?["properties"] as? [String: Any])?["items"] as? [String: Any]
    let itemObject = items?["items"] as? [String: Any]
    let fields = (itemObject?["properties"] as? [String: Any])?.keys.sorted() ?? []
    check(
        fields == ["confidence", "evidence", "itemName", "notes", "resaleValue", "retailValue"],
        "lists every field DiscoveredItem needs",
        detail: fields.joined(separator: ", ")
    )
    check(itemObject?["additionalProperties"] as? Bool == false, "forbids extra keys")
    let confidence = (itemObject?["properties"] as? [String: Any])?["confidence"] as? [String: Any]
    check(
        confidence?["enum"] as? [String] == ["High", "Med", "Low"],
        "keeps the confidence vocabulary",
        detail: "\(confidence?["enum"] ?? [])"
    )
    check(!text.contains("\"STRING\"") && !text.contains("\"OBJECT\""), "uses JSON Schema types, not Google's dialect")
}

// MARK: - 13. DeepSeek: the empty answer JSON mode sometimes returns

do {
    print("13. DeepSeek: an empty JSON-mode answer is re-asked, not failed")
    let script = StubScript([
        .init(status: 200, body: deepSeekEmptyBody),
        .init(status: 200, body: deepSeekSuccessBody)
    ])
    let service = makeDeepSeekService(script, requestsPerMinute: 0, maxAttempts: 3)
    let started = Date()
    let outcome = try await service.value(subject: subject)
    let elapsed = Date().timeIntervalSince(started)

    check(outcome.items.count == 1, "recovered on the second ask", detail: "\(outcome.items.count)")
    check(script.requestTimes.count == 2, "issued two requests", detail: "\(script.requestTimes.count)")
    check(elapsed < 3, "used a short pause, not a full back-off", detail: seconds(elapsed))
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 14. Empty answer with no attempts left

do {
    print("14. DeepSeek: an empty answer with no attempts left fails as noContent")
    let script = StubScript([.init(status: 200, body: deepSeekEmptyBody)])
    let service = makeDeepSeekService(script, requestsPerMinute: 0, maxAttempts: 1)
    do {
        _ = try await service.value(subject: subject)
        tally.bump()
        print("  FAIL  expected a thrown error")
    } catch let error as ValuationError {
        check(error == .noContent(finishReason: "stop"), "reported as noContent", detail: "\(error)")
        check(script.requestTimes.count == 1, "no retry was attempted", detail: "\(script.requestTimes.count)")
    }
} catch {
    tally.bump()
    print("  FAIL  wrong error type: \(error)")
}


// MARK: - 15. Both providers honour the same contract

do {
    print("15. Gemini and DeepSeek turn the same JSON into the same line items")
    let geminiScript = StubScript([.init(status: 200, body: successBody)])
    let deepSeekScript = StubScript([.init(status: 200, body: deepSeekSuccessBody)])

    let gemini = try await makeService(geminiScript, requestsPerMinute: 0, maxAttempts: 1)
        .value(subject: subject)
    let deepSeek = try await makeDeepSeekService(deepSeekScript, requestsPerMinute: 0, maxAttempts: 1)
        .value(subject: subject)

    func flatten(_ items: [DiscoveredItem]) -> [String] {
        items.map { "\($0.itemName)|\($0.confidence)|\($0.retailValue)|\($0.resaleValue)|\($0.notes)" }
    }
    let left = flatten(gemini.items)
    let right = flatten(deepSeek.items)
    check(!left.isEmpty, "the shared fixture produces rows", detail: "\(left.count)")
    check(left == right, "identical rows from identical JSON", detail: "\(left) vs \(right)")
}

// MARK: - 16. DeepSeek pacing

do {
    print("16. DeepSeek: requestsPerMinute paces through the same shared pacer")
    let script = StubScript([
        .init(status: 200, body: deepSeekSuccessBody),
        .init(status: 200, body: deepSeekSuccessBody),
        .init(status: 200, body: deepSeekSuccessBody)
    ])
    let service = makeDeepSeekService(script, requestsPerMinute: 60, maxAttempts: 1)
    for _ in 0..<3 {
        _ = try await service.value(subject: subject)
    }
    let times = script.requestTimes
    let gaps = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }
    check(times.count == 3, "three requests issued", detail: "\(times.count)")
    check(gaps.allSatisfy { $0 >= 0.9 }, "each call waited ~1s (60/min)", detail: gaps.map(seconds).joined(separator: ", "))
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 17. Gemini wire format (regression guard for the shared-layer refactor)

do {
    print("17. Gemini still sends inline_data and a response_schema")
    let script = StubScript([
        .init(status: 200, body: jpegBytes, headers: ["Content-Type": "image/jpeg"]),
        .init(status: 200, body: successBody)
    ])
    let service = makeService(script, requestsPerMinute: 0, maxAttempts: 1)
    let outcome = try await service.value(subject: imageSubject)

    check(outcome.imagesSent == 1, "the photo reached the request", detail: "\(outcome.imagesSent)")
    let sent = script.requests.last
    check(
        sent?.url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
        "used the documented `:generateContent` method (a slash here returns HTTP 404)",
        detail: sent?.url.absoluteString ?? "—"
    )
    check(sent?.headers["x-goog-api-key"] == "test-key", "sent the key in a header, not the URL")
    check(sent?.url.query == nil, "no key leaked into the query string", detail: sent?.url.query ?? "—")

    let body = sent?.json ?? [:]
    let system = body["system_instruction"] as? [String: Any]
    check(((system?["parts"] as? [[String: Any]])?.first?["text"]) as? String != nil, "system instruction is present")

    let contents = body["contents"] as? [[String: Any]] ?? []
    check(contents.first?["role"] as? String == "user", "one user content block")
    let parts = contents.first?["parts"] as? [[String: Any]] ?? []
    let inlined = parts.compactMap { $0["inline_data"] as? [String: Any] }
    check(inlined.count == 1, "one inline_data part", detail: "\(inlined.count)")
    check(inlined.first?["mime_type"] as? String == "image/jpeg", "carries the sniffed mime type", detail: "\(inlined.first?["mime_type"] ?? "—")")
    check((inlined.first?["data"] as? String)?.isEmpty == false, "carries base64 bytes")

    let config = body["generation_config"] as? [String: Any]
    check(config?["response_mime_type"] as? String == "application/json", "pins the response mime type")
    let schema = config?["response_schema"] as? [String: Any]
    check(schema?["type"] as? String == "OBJECT", "schema still uses Google's uppercase dialect", detail: "\(schema?["type"] ?? "—")")
    let itemsNode = (schema?["properties"] as? [String: Any])?["items"] as? [String: Any]
    let itemObject = itemsNode?["items"] as? [String: Any]
    let itemProperties = itemObject?["properties"] as? [String: Any]
    check(itemProperties?.keys.sorted() == ["confidence", "evidence", "itemName", "notes", "resaleValue", "retailValue"], "schema exposes every field", detail: "\((itemProperties?.keys.sorted() ?? []).joined(separator: ", "))")
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}


// MARK: - 18. DeepSeek: the photograph pass failing falls back to the text pass

do {
    print("18. DeepSeek: a failing photograph pass falls back to the text pass's answer")
    let script = StubScript([
        .init(status: 200, body: deepSeekSuccessBody),
        .init(status: 200, body: jpegBytes, headers: ["Content-Type": "image/jpeg"]),
        .init(status: 500, body: Data(#"{"error":{"message":"server error"}}"#.utf8))
    ])
    let service = makeDeepSeekService(script, requestsPerMinute: 0, maxAttempts: 1)
    let outcome = try await service.value(subject: imageSubject)

    check(outcome.items.count == 1, "the text pass's item survived", detail: "\(outcome.items.count)")
    check(outcome.passes == 1, "reported as a single-pass answer", detail: "\(outcome.passes)")
    check(outcome.imagesSent == 0, "and does not claim to have sent a photograph", detail: "\(outcome.imagesSent)")
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 19. DeepSeek: a lot with no text needs only one pass

/// Same lot shape as `imageSubject`, but with nothing for the text pass to read.
let textlessSubject = ValuationSubject(
    lotNumber: "",
    title: "",
    rawDescription: "   ",
    currentBid: 0,
    imageURLs: [URL(string: "https://cdn.example.test/lot-99.jpg")!],
    detailURL: nil
)

do {
    print("19. DeepSeek: a lot with no listing text skips the text pass")
    let script = StubScript([
        .init(status: 200, body: jpegBytes, headers: ["Content-Type": "image/jpeg"]),
        .init(status: 200, body: deepSeekSuccessBody)
    ])
    let service = makeDeepSeekService(script, requestsPerMinute: 0, maxAttempts: 1)
    let outcome = try await service.value(subject: textlessSubject)

    let chats = script.requests.filter { $0.url.absoluteString == "https://api.deepseek.com/chat/completions" }
    check(chats.count == 1, "exactly one chat completion", detail: "\(chats.count)")
    check(outcome.passes == 1, "reported as a single pass", detail: "\(outcome.passes)")
    check(outcome.imagesSent == 1, "used the photograph", detail: "\(outcome.imagesSent)")
    let text = userText(in: chats.first)
    check(text.contains("No listing text was captured"), "the prompt admits there is no text", detail: String(text.prefix(80)))
    check(!text.contains("earlier text pass proposed"), "and does not pretend a draft exists")
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}


// MARK: - 20. Table ordering

/// One lot for the ordering checks: priced only when it was given a valuation.
@MainActor
func makeLot(_ number: String, bid: Double, retail: Double = 0, resale: Double = 0) -> LotItem {
    let lot = LotItem(
        lotNumber: number,
        currentBid: bid,
        rawDescription: "Pallet \(number) — returned general merchandise",
        imageUrls: [],
        title: "Pallet \(number)"
    )
    if retail > 0 || resale > 0 {
        lot.applyValuation(
            [
                DiscoveredItem(
                    itemName: "Widget",
                    confidence: "High",
                    retailValue: retail,
                    resaleValue: resale,
                    notes: "Fixture."
                )
            ],
            imagesAnalyzed: 1
        )
    }
    return lot
}

do {
    print("20. Lot / SKU, description, bid, retail, resale, profit and ROI all sort both ways")
    // "Lot 1" is the unpriced one: nothing was bid, so its ROI is unknown and it must sort last in
    // *both* directions rather than parading as the best or worst return.
    let apple = makeLot("Lot 2", bid: 100, retail: 400, resale: 300)     // profit 200, ROI 2.0
    let banana = makeLot("Lot 10", bid: 50, retail: 1_000, resale: 900)  // profit 850, ROI 17.0
    let cherry = makeLot("Lot 1", bid: 0, retail: 100, resale: 40)       // profit 40, ROI unknown
    let lots = [apple, banana, cherry]

    func order(_ field: LotSort, _ direction: SortDirection) -> String {
        LotOrdering.sorted(lots, by: field, direction: direction)
            .map(\.lotNumber)
            .joined(separator: ", ")
    }

    check(order(.scrapeOrder, .ascending) == "Lot 2, Lot 10, Lot 1", "scrape order is left alone", detail: order(.scrapeOrder, .ascending))
    check(order(.identifier, .ascending) == "Lot 1, Lot 2, Lot 10", "lot numbers compare naturally, not lexically", detail: order(.identifier, .ascending))
    check(order(.identifier, .descending) == "Lot 10, Lot 2, Lot 1", "and reversed", detail: order(.identifier, .descending))
    check(order(.description, .ascending) == "Lot 1, Lot 2, Lot 10", "description uses the same natural comparison", detail: order(.description, .ascending))
    check(order(.currentBid, .ascending) == "Lot 1, Lot 10, Lot 2", "bid ascending is cheapest first", detail: order(.currentBid, .ascending))
    check(order(.currentBid, .descending) == "Lot 2, Lot 10, Lot 1", "bid descending is dearest first", detail: order(.currentBid, .descending))
    check(order(.retail, .descending) == "Lot 10, Lot 2, Lot 1", "retail descending puts the biggest pallet first", detail: order(.retail, .descending))
    check(order(.retail, .ascending) == "Lot 1, Lot 2, Lot 10", "retail ascending does the reverse", detail: order(.retail, .ascending))
    check(order(.resale, .descending) == "Lot 10, Lot 2, Lot 1", "resale descending", detail: order(.resale, .descending))
    check(order(.resale, .ascending) == "Lot 1, Lot 2, Lot 10", "resale ascending", detail: order(.resale, .ascending))
    check(order(.profit, .descending) == "Lot 10, Lot 2, Lot 1", "profit is resale minus the live bid", detail: order(.profit, .descending))
    check(order(.profit, .ascending) == "Lot 1, Lot 2, Lot 10", "profit ascending is the thinnest margin first", detail: order(.profit, .ascending))
    check(order(.roi, .descending) == "Lot 10, Lot 2, Lot 1", "ROI descending ranks the best return first", detail: order(.roi, .descending))
    check(order(.roi, .ascending) == "Lot 2, Lot 10, Lot 1", "ROI ascending still keeps the unknown bid last", detail: order(.roi, .ascending))

    check(LotSort.profit.initialDirection == .descending, "money fields default to descending")
    check(LotSort.identifier.initialDirection == .ascending, "identity fields default to ascending")
    check(!LotSort.scrapeOrder.isDirectional, "scrape order has no direction to pick")
    check(LotSort.allCases.count == 9, "every requested order is offered", detail: LotSort.allCases.map(\.label).joined(separator: ", "))

    // Equal values must keep their scrape position, so the table cannot shuffle between renders.
    let twinA = makeLot("Lot 7", bid: 10, retail: 100, resale: 50)
    let twinB = makeLot("Lot 8", bid: 20, retail: 100, resale: 60)
    let twins = LotOrdering.sorted([twinA, twinB], by: .retail, direction: .ascending).map(\.lotNumber)
    check(twins == ["Lot 7", "Lot 8"], "a tie breaks on scrape position", detail: twins.joined(separator: ", "))

    // **Max bid** sorts by the ceiling `BidTargeting` derives, and a lot nothing has priced — like an
    // unknown ROI — stays last whichever way the column is clicked.
    let date = makeLot("Lot 3", bid: 5)
    let priced = [apple, banana, cherry, date]
    func ceiling(_ direction: SortDirection) -> String {
        LotOrdering.sorted(priced, by: .maxBid, direction: direction).map(\.lotNumber).joined(separator: ", ")
    }
    check(ceiling(.descending) == "Lot 10, Lot 2, Lot 1, Lot 3", "max bid descending is the biggest ceiling first", detail: ceiling(.descending))
    check(ceiling(.ascending) == "Lot 1, Lot 2, Lot 10, Lot 3", "and an unpriced lot stays last either way", detail: ceiling(.ascending))
    check(LotSort.maxBid.initialDirection == .descending, "a bid ceiling defaults to biggest first")
}


// MARK: - 21. Bid ceiling

do {
    print("21. The Max bid ceiling is a tuned percent of resale, taken at the lot's weakest confidence")

    let policy = BidTargetPolicy()
    check(policy.highConfidencePercent == 60, "shipped: 60% of a confident resale figure", detail: "\(policy.highConfidencePercent)")
    check(policy.mediumConfidencePercent == 50, "50% of a reasonable one", detail: "\(policy.mediumConfidencePercent)")
    check(policy.lowConfidencePercent == 35, "35% of a guess", detail: "\(policy.lowConfidencePercent)")
    check(policy.maxBid(againstResale: 1_000, level: .high) == 600, "the ceiling is whole dollars", detail: "\(policy.maxBid(againstResale: 1_000, level: .high))")
    check(policy.maxBid(againstResale: 999, level: .high) == 599, "and is rounded, not truncated", detail: "\(policy.maxBid(againstResale: 999, level: .high))")
    check(policy.maxBid(againstResale: 1_000, level: .medium) == 500, "Med uses its own percent")
    check(policy.maxBid(againstResale: 1_000, level: .low) == 350, "Low uses its own percent")
    check(policy.maxBid(againstResale: 0, level: .high) == 0, "a pallet nothing is known about has no ceiling")
    check(policy.maxBid(againstResale: -50, level: .high) == 0, "nor a nonsense one")

    // Tuning is clamped rather than trusted: 0% would refuse every lot without saying why, and a
    // ceiling above 95% leaves nothing for fees, freight and the odd mis-read pallet.
    let clamped = BidTargetPolicy(highConfidencePercent: 0, mediumConfidencePercent: 120, lowConfidencePercent: 40)
    check(clamped.highConfidencePercent == 5, "a 0% ceiling is raised to the floor", detail: "\(clamped.highConfidencePercent)")
    check(clamped.mediumConfidencePercent == 95, "and a 120% one dropped to the ceiling", detail: "\(clamped.mediumConfidencePercent)")
    check(clamped.lowConfidencePercent == 40, "anything inside the range is left alone")
    check(BidTargetPolicy.percentRange == 5...95, "the range is the one the steppers offer")

    // A pallet is only as strong as its shakiest line item, so one Low row drags the lot's ceiling
    // onto the low percentage.
    let mixed = LotItem(
        lotNumber: "Lot 5",
        currentBid: 200,
        rawDescription: "Mixed pallet",
        imageUrls: [],
        title: "Mixed"
    )
    mixed.applyValuation(
        [
            DiscoveredItem(itemName: "TV", confidence: "High", retailValue: 600, resaleValue: 400, notes: "Sealed."),
            DiscoveredItem(itemName: "Kettle", confidence: "Low", retailValue: 300, resaleValue: 200, notes: "Guessed.")
        ],
        imagesAnalyzed: 2
    )
    let strong = mixed.bidTarget(using: policy)
    check(strong != nil, "a valued lot has a ceiling")
    check(strong?.confidence == .low, "the lot carries its weakest line item's confidence", detail: "\(String(describing: strong?.confidence))")
    check(strong?.percent == 35, "and is judged by that percentage", detail: "\(strong?.percent ?? -1)")
    check(strong?.resale == 600, "the resale it was derived from is quoted back", detail: "\(strong?.resale ?? -1)")
    check(strong?.maxBid == 210, "35% of the pallet's 600 resale", detail: "\(strong?.maxBid ?? -1)")
    check(strong?.isProvisional == false, "a photographed valuation is not provisional")
    check(strong?.headroom == 10, "headroom is the ceiling minus the live bid", detail: "\(strong?.headroom ?? -1)")
    check(strong?.isOverTarget == false, "a bid under the ceiling is not over target")

    let over = BidTarget(maxBid: 100, percent: 60, resale: 167, confidence: .high, isProvisional: false, currentBid: 110)
    check(over.isOverTarget, "a live bid past the ceiling is flagged in the column")
    check(over.headroom == -10, "and its headroom goes negative", detail: "\(over.headroom)")
}


// MARK: - 22. Pre-price provisional ceiling

do {
    print("22. A text-only pre-price gives the table a provisional ceiling until a scan lands")

    let policy = BidTargetPolicy()
    let sealed = LotItem(
        lotNumber: "Lot 6",
        currentBid: 40,
        rawDescription: "Sealed pallet",
        imageUrls: [],
        title: "Sealed"
    )
    check(sealed.bidTarget(using: policy) == nil, "an unread lot has no ceiling at all")
    check(!sealed.showsProvisionalNumbers, "and nothing to show provisionally")

    sealed.markPrePricing()
    check(sealed.isPrePricing, "a queued pre-price flags the row as working")
    check(sealed.bidTarget(using: policy) == nil, "but invents no numbers while it waits")

    sealed.applyPrePrice(
        PrePriceEstimate(
            retail: 900,
            resale: 500,
            confidence: .medium,
            rationale: "Two sealed electronics lots, one described as tested."
        )
    )
    check(!sealed.isPrePricing, "the in-flight flag clears when the estimate lands")
    let provisional = sealed.bidTarget(using: policy)
    check(provisional?.isProvisional == true, "the pre-price ceiling is marked provisional")
    check(provisional?.maxBid == 250, "50% of the guessed 500 resale, per its Med confidence", detail: "\(provisional?.maxBid ?? -1)")
    check(provisional?.resale == 500, "and it quotes the guess it came from")
    check(provisional?.confidence == .medium, "the guess's own confidence drives the percentage")
    check(sealed.showsProvisionalNumbers, "so the row renders the figures as provisional")
    check(sealed.discoveredItems.isEmpty, "a pre-price invents no line items")
    check(sealed.totalResale == 0, "and leaves the scanned totals at zero")
    check(sealed.displayResale == 500, "while the money columns show the guess")

    sealed.applyValuation(
        [DiscoveredItem(itemName: "Soundbar", confidence: "High", retailValue: 800, resaleValue: 500, notes: "Sealed.")],
        imagesAnalyzed: 3
    )
    let scanned = sealed.bidTarget(using: policy)
// MARK: - 23. Anchor items

do {
    print("23. A line item at or above the anchor threshold is flagged in the expanded row")

    check(AnchorItem.defaultThreshold == 100, "a fresh install flags from $100", detail: "\(AnchorItem.defaultThreshold)")
    check(AnchorItem.thresholdRange == 25...1_000, "the operator's bar is clamped into a sane range")
    check(AnchorItem.clamped(5) == 25, "a $5 bar is raised to the floor", detail: "\(AnchorItem.clamped(5))")
    check(AnchorItem.clamped(5_000) == 1_000, "and a $5,000 one dropped to the ceiling")
    check(AnchorItem.clamped(250) == 250, "anything inside the range is left alone")
    check(AnchorItem.isAnchor(retail: 100, threshold: 100), "the threshold itself counts as an anchor")
    check(!AnchorItem.isAnchor(retail: 99.99, threshold: 100), "a cent under it does not")
    check(!AnchorItem.isAnchor(retail: 0, threshold: 25), "an unpriced line is never an anchor, however low the bar")

    let pallet = LotItem(
        lotNumber: "Lot 12",
        currentBid: 75,
        rawDescription: "Returned general merchandise",
        imageUrls: [],
        title: "Pallet 12"
    )
    pallet.applyValuation(
        [
            DiscoveredItem(itemName: "Robot vacuum", confidence: "High", retailValue: 260, resaleValue: 150, notes: "Sealed."),
            DiscoveredItem(itemName: "Blender", confidence: "High", retailValue: 80, resaleValue: 45, notes: "Open box."),
            DiscoveredItem(itemName: "Towels", confidence: "Medium", retailValue: 20, resaleValue: 8, notes: "Bulk.")
        ],
        imagesAnalyzed: 2
    )
    check(pallet.anchorItemCount(threshold: 100) == 1, "one line carries the pallet", detail: "\(pallet.anchorItemCount(threshold: 100))")
    check(pallet.anchorRetailTotal(threshold: 100) == 260, "and its retail is what the flag is about", detail: "\(pallet.anchorRetailTotal(threshold: 100))")
    check(!pallet.discoveredItems[1].isAnchor(threshold: 100), "an $80 line is not an anchor at the default bar")
    check(pallet.discoveredItems[1].isAnchor(threshold: 75), "but is once the bar is lowered to $75")
    check(pallet.anchorItemCount(threshold: 20) == 3, "a low bar flags every priced line")
    check(pallet.anchorItemCount(threshold: 1_000) == 0, "a high one flags nothing at all")
    check(pallet.discoveredItems[0].maxBid(using: .standard) == 90, "a line item's own ceiling is 60% of its 150 resale", detail: "\(pallet.discoveredItems[0].maxBid(using: .standard))")
}


    check(scanned?.isProvisional == false, "a real scan retires the provisional ceiling")
    check(!sealed.showsProvisionalNumbers, "and the provisional rendering with it")
    check(scanned?.maxBid == 300, "60% of the scanned 500 resale", detail: "\(scanned?.maxBid ?? -1)")
    check(scanned?.percent == 60, "per the confidence the scan reported")
}
// MARK: - 24. Lot table search

do {
    print("24. Search matches the lot number first, the listing copy second, and preserves order")

    let numbered = makeLot("Lot 142", bid: 10, retail: 300, resale: 200)
    let titled = LotItem(
        lotNumber: "Lot 7",
        currentBid: 5,
        rawDescription: "Assorted plumbing fittings, used",
        imageUrls: [],
        title: "Plumbing fittings"
    )
    let sku = makeLot("L-1042", bid: 8, retail: 50, resale: 30)
    let rows = [numbered, titled, sku]

    func found(_ query: String) -> String {
        LotSearch.filter(rows, query: query).map(\.lotNumber).joined(separator: ", ")
    }

    check(found("") == "Lot 142, Lot 7, L-1042", "an empty query keeps every row", detail: found(""))
    check(found("   ") == "Lot 142, Lot 7, L-1042", "a whitespace-only query is not a filter", detail: found("   "))
    check(!LotSearch.isFiltering("  "), "and the toolbar keeps its match count hidden")
    check(LotSearch.isFiltering("142"), "a real query narrows the table")
    check(found("142") == "Lot 142", "punctuation and case are ignored: \"142\" finds \"Lot 142\"", detail: found("142"))
    check(found("lot 142") == "Lot 142", "a pasted \"Lot 142\" finds it too", detail: found("lot 142"))
    check(found("l1042") == "L-1042", "a SKU-shaped number is found without its dash", detail: found("l1042"))
    check(found("1042") == "L-1042", "and its digits are enough on their own", detail: found("1042"))
    check(found("plumbing") == "Lot 7", "listing copy is matched case-insensitively", detail: found("plumbing"))
    check(found("nozzle") == "", "a query matching nothing keeps nothing", detail: found("nozzle"))
    check(found("l") == "Lot 142, Lot 7, L-1042", "matches keep their scrape order", detail: found("l"))
    check(LotSearch.normalize("Lot #142-A") == "lot142a", "normalisation keeps letters and digits only", detail: LotSearch.normalize("Lot #142-A"))
}



// MARK: - 25. Resizable columns

do {
    print("25. Column widths stay inside their limits, and header and rows share one total")

    let standard = ColumnWidths.standard
    check(LotColumnKey.allCases.count == 13, "every data column can be dragged", detail: LotColumnKey.allCases.map(\.label).joined(separator: ", "))
    check(LotColumnKey.maxBid.sortField == .maxBid, "the Max bid header sorts by its own field", detail: "\(String(describing: LotColumnKey.maxBid.sortField))")
    check(LotColumnKey.allCases.filter { $0.sortField == nil }.count == 5, "the five read-only columns offer no sort", detail: LotColumnKey.allCases.filter { $0.sortField == nil }.map(\.label).joined(separator: ", "))
    check(LotColumnKey.allCases.allSatisfy { $0.defaultWidth >= ColumnWidths.minimumWidth }, "every shipped width clears the minimum")

    let shippedTotal = LotColumn.expander + LotColumn.scan
        + LotColumnKey.allCases.reduce(0) { $0 + $1.defaultWidth } + LotColumn.rowInsets
    check(standard.totalWidth == shippedTotal, "the total is every column plus the fixed chrome", detail: "\(standard.totalWidth) vs \(shippedTotal)")
    check(standard.identityWidth == LotColumn.expander + LotColumn.scan + standard.lotNumber + standard.title,
          "the nested name cell spans the identity columns", detail: "\(standard.identityWidth)")
    check(standard.width(.status) == LotColumnKey.status.defaultWidth, "a column's width comes from its key")
    check(LotColumn.scan >= 240, "the fixed actions column is wide enough for Eval, Price and Open side by side", detail: "\(LotColumn.scan)")
    check(LotColumn.scanTitle.isEmpty,
          "the actions column is untitled: the buttons say what it is, so its header cell stays empty",
          detail: "\"\(LotColumn.scanTitle)\"")

    var widths = standard
    widths.setWidth(10, for: .title)
    check(widths.title == ColumnWidths.minimumWidth, "a squeeze is clamped to the minimum", detail: "\(widths.title)")
    widths.setWidth(9_000, for: .status)
    check(widths.status == ColumnWidths.maximumWidth, "a drag past the window to the maximum", detail: "\(widths.status)")
    check(widths.width(.maxBid) == standard.maxBid, "resizing one column leaves every other alone", detail: "\(widths.width(.maxBid))")
    check(widths.totalWidth == shippedTotal - 120 + 250, "and the shared total follows both drags", detail: "\(widths.totalWidth)")
    widths.reset()
    check(widths == ColumnWidths.standard, "Reset column widths restores the shipped layout")
    check(ColumnWidths(title: 1).title == ColumnWidths.minimumWidth, "a literal width is clamped on the way in")
    check(ColumnWidths(status: 10_000).status == ColumnWidths.maximumWidth, "at both ends")

    var narrowed = ColumnWidths.standard
    let chrome = LotColumn.expander + LotColumn.scan + LotColumn.rowInsets
    for key in LotColumnKey.allCases {
        narrowed.setWidth(-1, for: key)
        check(narrowed.width(key) == ColumnWidths.minimumWidth, "\(key.label) drags down to the minimum and no further", detail: "\(narrowed.width(key))")
    }
    check(narrowed.totalWidth == chrome + 13 * ColumnWidths.minimumWidth, "and the total lands where those minimums put it", detail: "\(narrowed.totalWidth)")
}

// MARK: - 26. Filling the window

do {
    print("26. The columns stretch to fill the window, and the fixed chrome never moves")

    let standard = ColumnWidths.standard
    let chrome = ColumnWidths.chromeWidth
    check(chrome == LotColumn.expander + LotColumn.scan + LotColumn.rowInsets,
          "the chrome is the chevron, the action pair and the row insets", detail: "\(chrome)")
    check(standard.dataWidth == LotColumnKey.allCases.reduce(0) { $0 + $1.defaultWidth },
          "the data width is the thirteen draggable columns", detail: "\(standard.dataWidth)")
    check(standard.totalWidth == chrome + standard.dataWidth, "and the total is both of them", detail: "\(standard.totalWidth)")

    // Narrower than the table: the dragged layout is handed straight back, so the operator keeps
    // what they sized and the horizontal scroller does the work.
    check(standard.filling(900) == standard, "a window narrower than the table leaves the widths alone")
    check(standard.filling(standard.totalWidth) == standard, "and so does a window that is exactly the table's width")

    let wide = standard.filling(1_560)
    check(abs(wide.totalWidth - 1_560) < 0.01, "a wider window is filled exactly", detail: "\(wide.totalWidth)")

    let factor = wide.dataWidth / standard.dataWidth
    check(factor > 1, "because the data columns grew", detail: String(format: "%.3f", factor))
    check(LotColumnKey.allCases.allSatisfy { key in
        abs(wide.width(key) - standard.width(key) * factor) < 0.001
    }, "each one in proportion to its own width, so the layout's shape survives")
    check(wide.title - standard.title > wide.width(.items) - standard.items,
          "the widest column takes the largest share of the slack",
          detail: "\(wide.title - standard.title) vs \(wide.width(.items) - standard.items)")

    check(wide.width(.items) > ColumnWidths.minimumWidth, "nothing is stretched below the minimum")
    check(wide.width(.status) < ColumnWidths.maximumWidth,
          "and at a normal window nothing is stretched past the drag ceiling",
          detail: "\(wide.width(.status))")

    var squeezed = standard
    squeezed.setWidth(1_000, for: .title)
    check(squeezed.title == ColumnWidths.maximumWidth, "a drag is still clamped on the way in", detail: "\(squeezed.title)")
    check(squeezed.filling(3_000).title > ColumnWidths.maximumWidth,
          "while the stretch it then receives may exceed that ceiling",
          detail: "\(squeezed.filling(3_000).title)")

    check(standard.filling(0).totalWidth == standard.totalWidth, "a zero-width viewport is survivable")
    check(standard.filling(-100) == standard, "and so is a negative one")
    check(standard.filling(standard.totalWidth + ColumnWidths.fillTolerance / 2) == standard,
          "slack below the tolerance is left alone rather than chased")

    var restored = standard.filling(2_000)
    restored.reset()
    check(restored == ColumnWidths.standard, "Reset column widths drops the stretch too")
}

// MARK: - 27. Lot numbers

do {
    print("27. A card's DOM id is never mistaken for the lot number")

    // The reported case: a card whose own `id` is `ItemMain19002` and which exposes no lot number.
    check(LotNumber.normalize("ItemMain19002") == "19002", "a wrapped DOM id is reduced to its digits", detail: LotNumber.normalize("ItemMain19002"))
    check(LotNumber.normalize("Main19002") == "19002", "and so is the bare wrapper the label rule leaves behind", detail: LotNumber.normalize("Main19002"))
    check(LotNumber.normalize("item-row-88") == "88", "an id with separators unwraps too", detail: LotNumber.normalize("item-row-88"))
    check(LotNumber.normalize("Lot #142") == "142", "a printed label is stripped", detail: LotNumber.normalize("Lot #142"))
    check(LotNumber.normalize("lot 142") == "142", "with or without punctuation and either case", detail: LotNumber.normalize("lot 142"))
    check(LotNumber.normalize("Item No. 88") == "88", "including the word between label and digits", detail: LotNumber.normalize("Item No. 88"))
    check(LotNumber.normalize("Lot Number 142") == "142", "spelled out", detail: LotNumber.normalize("Lot Number 142"))
    check(LotNumber.normalize("ABC123") == "ABC123", "a real SKU keeps its letters", detail: LotNumber.normalize("ABC123"))
    check(LotNumber.normalize("L208") == "L208", "as does a prefixed lot number", detail: LotNumber.normalize("L208"))
    check(LotNumber.normalize("142") == "142", "a bare number is already clean")
    check(LotNumber.normalize("  ") == "", "and nothing stays nothing", detail: "\"\(LotNumber.normalize("  "))\"")
    check(LotNumber.normalize("lot") == "lot", "a label with no number behind it is left as the page wrote it", detail: LotNumber.normalize("lot"))

    check(LotNumber.fromURL(URL(string: "https://example.test/auction/lot/19002")) == "19002", "a deep link gives up its number")
    check(LotNumber.fromURL(URL(string: "https://example.test/item/ItemMain19002")) == "19002", "even when that number is wrapped in the path", detail: String(describing: LotNumber.fromURL(URL(string: "https://example.test/item/ItemMain19002"))))
    check(LotNumber.fromURL(URL(string: "https://example.test/items?itemid=19002")) == "19002", "a query parameter counts as the address too")
    check(LotNumber.fromURL(URL(string: "https://example.test/auction/spring-sale")) == nil, "a page with no number in it yields nothing")
    check(LotNumber.fromURL(nil) == nil, "and neither does a missing link")

    // What the scraper hands over, end to end: the table, the log and the prompt all read the row's
    // own `lotNumber`, so the cleaning has to happen before the row is built.
    let wrappedCard = ScrapedLot(
        lotNumber: "ItemMain19002",
        title: "Pallet of returned general merchandise",
        rawDescription: "Mixed lot, 60 pieces.",
        bidText: "Current Bid: $210.00",
        imageURLStrings: ["https://cdn.example.test/lot-19002.jpg"],
        detailURLString: "https://example.test/auction/lot/19002",
        sourcePage: 1
    )
    check(wrappedCard.resolvedLotNumber == "19002", "a wrapped card id resolves to the lot number", detail: wrappedCard.resolvedLotNumber)
    check(wrappedCard.id == "19002", "which is also the row's identity", detail: wrappedCard.id)
    check(wrappedCard.subject.lotNumber == "19002", "and what the pre-price prompt is told", detail: wrappedCard.subject.lotNumber)

    let prompt = LotValuationPrompt.listingText(for: wrappedCard.subject)
    check(prompt.contains("Lot number: 19002"), "so the model is never shown the element address", detail: prompt)
    check(!prompt.contains("ItemMain"), "at all", detail: prompt)

    let plainCard = ScrapedLot(
        lotNumber: "19002",
        title: "",
        rawDescription: "",
        bidText: "",
        imageURLStrings: [],
        detailURLString: "https://example.test/auction/lot/19002",
        sourcePage: 1
    )
    check(wrappedCard.dedupeKey == plainCard.dedupeKey, "the wrapped and plain spellings of one lot are one lot", detail: "\(wrappedCard.dedupeKey) vs \(plainCard.dedupeKey)")

    let numberlessCard = ScrapedLot(
        lotNumber: "",
        title: "Assorted plumbing fittings",
        rawDescription: "Used, 30 pieces.",
        bidText: "",
        imageURLStrings: [],
        detailURLString: "https://example.test/auction/item/778812",
        sourcePage: 2
    )
    check(numberlessCard.resolvedLotNumber == "778812", "a card with no number at all borrows the page's", detail: numberlessCard.resolvedLotNumber)

    let anonymousCard = ScrapedLot(
        lotNumber: "",
        title: "",
        rawDescription: "",
        bidText: "",
        imageURLStrings: ["https://cdn.example.test/anonymous.jpg"],
        detailURLString: nil,
        sourcePage: 3
    )
    check(anonymousCard.resolvedLotNumber.hasPrefix("AUTO-"), "and only a card with nothing at all gets a hash", detail: anonymousCard.resolvedLotNumber)

    let row = LotItem(scraped: wrappedCard)
    check(row.lotNumber == "19002", "the table row carries the cleaned number", detail: row.lotNumber)
}

// MARK: - 28. Sold lots and empty auctions

do {
    print("28. A sold lot is flagged but kept, and an empty catalogue says so")

    // The profile is what the injected script reads, so these are the rules the page actually runs.
    let profile = ScrapeProfile.genericBase()
    check(!profile.lotStatusSelectors.isEmpty, "the profile lists the selectors a sold badge hides behind")
    check(!profile.noResultsSelectors.isEmpty, "and the surfaces an empty catalogue says it in")

    // The sold rule is a JS regex, compiled here by ICU (which the harness's Foundation brings).
    // Its whole point is that a card is only retired when the *site* says sold: catalog copy such
    // as "sold as one pallet" describes the sale format, not the lot's state.
    let sold = try! NSRegularExpression(pattern: profile.soldTextPattern, options: [.caseInsensitive])
    func mentionsSold(_ text: String) -> Bool {
        sold.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    check(mentionsSold("SOLD"), "a bare badge marks the lot sold")
    check(mentionsSold("Sold - $45.00"), "so does a badge with the price beside it")
    check(mentionsSold("CLOSED: SOLD!"), "and one wrapped in other words")
    check(!mentionsSold("sold as one pallet"), "listing copy that sells the lot *as* a pallet does not")
    check(!mentionsSold("sold in two lots"), "nor does the sale format")
    check(!mentionsSold("unsold"), "unsold is not sold")
    check(!mentionsSold("resold stock"), "and neither is stock that was resold before")

    // The empty-catalogue message the target site prints: "Results: No Items Found."
    let empty = try! NSRegularExpression(pattern: profile.noResultsTextPattern, options: [.caseInsensitive])
    func saysNoResults(_ text: String) -> Bool {
        empty.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    check(saysNoResults("Results: No Items Found."), "the catalogue's own empty message is recognised")
    check(saysNoResults("No lots found"), "as are the plainer spellings")
    check(saysNoResults("0 items"), "and a zero counter")
    check(!saysNoResults("Results: 24 Items Found."), "while a populated counter is not")

    // What the scraper hands over, and what the table reads back.
    let activeCard = ScrapedLot(
        lotNumber: "142",
        title: "Pallet of mixed home goods",
        rawDescription: "Sold as one pallet, mixed departments.",
        bidText: "Current Bid: $210.00",
        imageURLStrings: [],
        detailURLString: nil,
        sourcePage: 1
    )
    check(activeCard.isActive, "a card with no sold marker is active, even if its copy says \"sold as\"")
    check(LotItem(scraped: activeCard).isActive, "and the row keeps that")

    let soldCard = ScrapedLot(
        lotNumber: "355",
        title: "Garden tools pallet",
        rawDescription: "Spades, hoses and a petrol strimmer.",
        bidText: "Sold: $640.00",
        imageURLStrings: [],
        detailURLString: nil,
        sourcePage: 2,
        isSold: true,
        statusText: "SOLD"
    )
    check(!soldCard.isActive, "a sold card is not active", detail: soldCard.statusText)
    let soldRow = LotItem(scraped: soldCard)
    check(soldRow.isSold, "and the row reports it")
    check(soldRow.statusText == "SOLD", "carrying the site's own label with it", detail: soldRow.statusText)
    check(LotItem(lotNumber: "1", currentBid: 0, rawDescription: "", imageUrls: []).isActive,
          "a hand-built row defaults to active, so the fixtures and previews stay biddable")

    // The Active column is the last one, read-only, and wide enough for its own badge.
    check(LotColumnKey.allCases.last == .active, "the Active column closes the table", detail: "\(String(describing: LotColumnKey.allCases.last))")
    check(LotColumnKey.active.sortField == nil, "it carries no sort order")
    check(LotColumnKey.active.defaultWidth >= 64, "and its shipped width clears the badge", detail: "\(LotColumnKey.active.defaultWidth)")
    check(ColumnWidths.standard.width(.active) == LotColumnKey.active.defaultWidth, "the layout sizes it from the key")
}

// MARK: - 29. The column chooser

do {
    print("29. Columns can be hidden, and the choice is the only thing that is remembered")

    // The shipped state: everything drawn, so the stored list is empty. Storing the *hidden* set is
    // what makes a column added in a later version arrive visible.
    var choice = ColumnVisibility.all
    check(choice.visibleCount == 13, "a fresh install draws every column", detail: "\(choice.visibleCount)")
    check(choice.storedNames.isEmpty, "and remembers nothing, so a new column would be drawn too")
    check(!choice.isHidingAnything, "with no dot on the gear to explain")
    check(choice.visibleColumns == LotColumnKey.allCases, "in table order")

    // Hiding one column is a change to the choice alone: its width is kept, because a column the
    // operator sized is not a column they stopped caring about.
    let shipped = ColumnWidths.standard
    let shippedStatus = shipped.storedWidth(.status)
    choice.set(.status, visible: false)
    var hidden = shipped
    hidden.visibility = choice
    check(hidden.width(.status) == 0, "a hidden column takes no width in the drawn table")
    check(hidden.storedWidth(.status) == shippedStatus, "but keeps the width it was dragged to", detail: "\(hidden.storedWidth(.status))")
    check(hidden.totalWidth == shipped.totalWidth - shippedStatus, "and the table's total closes up by exactly that much", detail: "\(hidden.totalWidth) vs \(shipped.totalWidth - shippedStatus)")
    check(hidden.dataWidth == shipped.dataWidth - shippedStatus, "the data width it shares out follows")
    check(hidden.width(.confidence) == shipped.width(.confidence), "while the column beside it does not move")

    // The rows and the header lay their cells out from the per-column shorthands (`widths.bid`), so
    // those have to be the *drawn* widths. This is the check that catches a shorthand quietly reading
    // storage instead: a hidden column would then still take its 96 points of a row.
    check(hidden.status == 0, "the shorthand a row reads is zero for a hidden column", detail: "\(hidden.status)")
    check(hidden.storedWidth(.status) == shippedStatus, "even though the stored width underneath is intact")
    check(hidden.bid == shipped.bid && hidden.bid == hidden.width(.bid),
          "and every drawn shorthand still agrees with its key", detail: "\(hidden.bid)")

    // The span a nested row's name cell is indented under comes off the drawn widths, so the product
    // lines stay under the pallet whether or not the description column is there.
    var noTitle = shipped
    noTitle.visibility = ColumnVisibility(hiddenColumns: [.title])
    check(noTitle.identityWidth == LotColumn.expander + LotColumn.scan + shipped.lotNumber,
          "hiding the Description column pulls the nested name cell in with it", detail: "\(noTitle.identityWidth)")

    // Stretch to fit: the freed width is shared by the columns that are left, exactly as the slack
    // from a wider window is — which is what stops a hidden column leaving a dead strip.
    let window: CGFloat = 1_560
    let filled = hidden.filling(window)
    check(abs(filled.totalWidth - window) < 0.01, "the hidden column's width goes to the ones still shown", detail: "\(filled.totalWidth)")
    check(filled.width(.status) == 0, "so it is still not drawn once the table has been stretched")
    check(filled.width(.lotNumber) > hidden.width(.lotNumber), "and the rest grow into the space it left")
    check(filled.storedWidth(.status) == shippedStatus, "without the stretch rewriting the hidden column's width")

    // What is written to UserDefaults, and what is read back from it.
    check(choice.storedNames == ["status"], "the stored form is a readable list of names", detail: choice.storedNames.joined(separator: ", "))
    check(ColumnVisibility(storedNames: choice.storedNames) == choice, "which round-trips")
    check(ColumnVisibility(storedNames: ["status", "goneInAFutureVersion"]) == choice,
          "a name this build does not know is dropped rather than honoured", detail: ColumnVisibility(storedNames: ["status", "goneInAFutureVersion"]).storedNames.joined(separator: ", "))
    check(ColumnVisibility(storedNames: [""]) == .all, "an empty name is not a column either")
    check(ColumnVisibility(storedNames: nil) == .all, "nothing stored means every column")
    check(ColumnVisibility(storedNames: LotColumnKey.allCases.map(\.rawValue)) == .all,
          "and a stored set that would hide every column is read as never configured")

    // The last visible column stays: every column is optional, but an empty table is not a layout,
    // and no menu could get the operator back out of it.
    var oneLeft = ColumnVisibility(hiddenColumns: Set(LotColumnKey.allCases.dropFirst()))
    check(oneLeft.visibleCount == 1, "every column can be hidden but one", detail: "\(oneLeft.visibleCount)")
    check(!oneLeft.canToggle(.lotNumber), "and the switch of the one that is left is disabled")
    oneLeft.set(.lotNumber, visible: false)
    check(oneLeft.visibleCount == 1, "so it cannot be switched off", detail: "\(oneLeft.visibleCount)")
    check(oneLeft.canToggle(.bid), "while a hidden column can always be switched back on")
    oneLeft.set(.bid, visible: true)
    check(oneLeft.visibleCount == 2, "which is what makes a hidden column recoverable")
    oneLeft.showAll()
    check(oneLeft == .all, "and Show all columns draws everything again")

    // Reset is a *width* reset: a column the operator went looking for is not a width.
    var dragged = ColumnWidths(title: 400, visibility: ColumnVisibility(hiddenColumns: [.roi]))
    dragged.reset()
    check(dragged.title == ColumnWidths.standard.title, "Reset column widths puts the widths back")
    check(dragged.visibility == ColumnVisibility(hiddenColumns: [.roi]), "and leaves the column choice alone")
}

// MARK: - 30. Every image the lot carries

do {
    print("30. A scan sends every image the lot has, and says so when it cannot")

    // What the removed `Images / lot` setting used to decide. The count now comes from the lot's own
    // page (ScraperScript's reader — its page-side twin is checked in Tools/scraper-js-check), and the
    // rule is simply "all of them". Stub order is the real order: the photographs are fetched first,
    // then the request that carries them.
    do {
        let script = StubScript(galleryImageSteps + [.init(status: 200, body: successBody)])
        let service = makeService(script, requestsPerMinute: 0, maxAttempts: 1)
        let outcome = try await service.value(subject: gallerySubject)

        check(outcome.imagesSent == 4, "all four of the lot's photographs were attached", detail: "\(outcome.imagesSent)")
        check(outcome.imagesAvailable == 4, "the row knows how many the lot offered", detail: "\(outcome.imagesAvailable)")
        check(outcome.imagesSkipped == 0, "and nothing was held back", detail: "\(outcome.imagesSkipped)")

        let sent = script.requests.last
        let parts = (sent?.json["contents"] as? [[String: Any]])?.last?["parts"] as? [[String: Any]] ?? []
        let inlined = parts.filter { $0["inline_data"] != nil }
        check(inlined.count == 4, "one inline_data part per photograph", detail: "\(inlined.count)")
    } catch {
        tally.bump()
        print("  FAIL  unexpected error: \(error)")
    }

    // The only bound left is technical: one request's payload ceiling. A gallery that does not fit is
    // trimmed in gallery order and *counted*, so the row can say "2 of 4" instead of looking like a
    // lot with two photographs.
    do {
        let script = StubScript(galleryImageSteps + [.init(status: 200, body: successBody)])
        // Each stub photograph is 512 bytes, so a 1,200-byte budget fits two of them.
        let service = makeService(script, requestsPerMinute: 0, maxAttempts: 1, maxTotalImageBytes: 1_200)
        let outcome = try await service.value(subject: gallerySubject)

        check(outcome.imagesSent == 2, "only what fits one request's budget is attached", detail: "\(outcome.imagesSent)")
        check(outcome.imagesSkipped == 2, "and the rest is reported rather than swallowed", detail: "\(outcome.imagesSkipped)")
        check(outcome.imagesAvailable == 4, "while the lot's real count is still what it is measured against", detail: "\(outcome.imagesAvailable)")
    } catch {
        tally.bump()
        print("  FAIL  unexpected error: \(error)")
    }

    // A photograph that cannot be fetched is a different thing from one that did not fit: it is a
    // failure with a reason, and it does not inflate the over-budget count.
    do {
        let script = StubScript([
            .init(status: 200, body: jpegBytes, headers: ["Content-Type": "image/jpeg"]),
            .init(status: 404, body: Data()),
            .init(status: 200, body: jpegBytes, headers: ["Content-Type": "image/jpeg"]),
            .init(status: 200, body: jpegBytes, headers: ["Content-Type": "image/jpeg"]),
            .init(status: 200, body: successBody)
        ])
        let service = makeService(script, requestsPerMinute: 0, maxAttempts: 1)
        let outcome = try await service.value(subject: gallerySubject)

        check(outcome.imagesSent == 3, "the unreadable photograph is skipped, not fatal", detail: "\(outcome.imagesSent)")
        check(outcome.imagesSkipped == 0, "and is not counted as over-budget", detail: "\(outcome.imagesSkipped)")
    } catch {
        tally.bump()
        print("  FAIL  unexpected error: \(error)")
    }

    // DeepSeek's photograph pass gets the whole gallery too, with its text pass untouched (one chat
    // request, then the photographs, then the request that carries them).
    do {
        let script = StubScript(
            [.init(status: 200, body: deepSeekSuccessBody)]
                + galleryImageSteps
                + [.init(status: 200, body: deepSeekSuccessBody)]
        )
        let service = makeDeepSeekService(script, requestsPerMinute: 0, maxAttempts: 1)
        let outcome = try await service.value(subject: gallerySubject)

        check(outcome.imagesSent == 4, "the whole gallery reached the photograph pass", detail: "\(outcome.imagesSent)")
        check(outcome.imagesAvailable == 4, "counted against the lot's own total", detail: "\(outcome.imagesAvailable)")
        check(outcome.passes == 2, "still appraised in two passes", detail: "\(outcome.passes)")
        check(imageURLs(in: script.requests.first).isEmpty, "and the text pass still carries no photographs")
    } catch {
        tally.bump()
        print("  FAIL  unexpected error: \(error)")
    }

    // What the coordinator hands the service: a page's gallery replaces the card's thumbnails, and an
    // empty list — a page that could not be read — leaves the card's own copy in place.
    check(imageSubject.withImages([]) == imageSubject, "a page that yielded nothing leaves the card's images alone")
    let enriched = imageSubject.withImages(gallerySubject.imageURLs)
    check(enriched.imageURLs.count == 4, "a page's gallery replaces the card's thumbnails", detail: "\(enriched.imageURLs.count)")
    check(enriched.lotNumber == imageSubject.lotNumber && enriched.rawDescription == imageSubject.rawDescription,
          "without touching the listing text the prompt is built from")
}

// MARK: - 31. The address a row opens

do {
    print("31. A row's Open button is given the lot's own page, or nothing at all")

    // The profile is the page-side rule (the JavaScript runs it, and Tools/scraper-js-check drives
    // it against a DOM shim); what is checked here is that the data is there, and that the regex the
    // script compiles is one ICU can compile too — a pattern only JS understands is a pattern that
    // silently stops rejecting anything.
    let profile = ScrapeProfile.genericBase()
    check(!profile.detailLinkSelectors.isEmpty, "the profile names the anchors a lot page hides behind")
    check(profile.detailLinkSelectors.contains { $0.lowercased().contains("href") },
          "including address patterns, for a site with no class of its own to name")
    check(!profile.nonLotHrefPattern.isEmpty, "and lists the addresses that are never a lot's page")

    let furniture = try! NSRegularExpression(pattern: profile.nonLotHrefPattern, options: [.caseInsensitive])
    func isFurniture(_ href: String) -> Bool {
        furniture.firstMatch(in: href, range: NSRange(href.startIndex..., in: href)) != nil
    }
    check(isFurniture("/share?url=/auction/lot/19002"), "a share button is rejected even when it carries the lot's address")
    check(isFurniture("/account/watchlist/19002"), "so is a wish-list link")
    check(isFurniture("https://example.test/login?next=/auction"), "and the sign-in link")
    check(!isFurniture("/auction/lot/19002"), "while the lot's own page is left alone")
    check(!isFurniture("/catalog/19002"), "as is a catalogue path the profile has never seen")

    // The row's rule is `lot.detailURL`, which is only ever the address the card declared: a lot the
    // listing gave no address for offers no button, rather than a control that cannot do anything.
    let linked = ScrapedLot(
        lotNumber: "19002",
        title: "Assorted plumbing fittings",
        rawDescription: "Used goods",
        bidText: "Current Bid: $210.00",
        imageURLStrings: [],
        detailURLString: "https://example.test/catalog/19002",
        sourcePage: 1
    )
    let unlinked = ScrapedLot(
        lotNumber: "19003",
        title: "Assorted home goods",
        rawDescription: "Used goods",
        bidText: "Current Bid: $45.00",
        imageURLStrings: [],
        detailURLString: nil,
        sourcePage: 1
    )
    check(LotItem(scraped: linked).detailURL == URL(string: "https://example.test/catalog/19002"),
          "a card's address reaches the row unchanged, whatever shape the site uses")
    check(LotItem(scraped: unlinked).detailURL == nil, "and a card with no address leaves the row nothing to open")
}

// MARK: - 32. The address of a later result page

// The multi-page walk is by address — `?page=1`, `?page=2`, … — because that is the shape a numbered
// pagination prints and the shape the operator types. `PaginationPlan` is the whole of that rule, and
// it is offline by construction: an address in, an address out. The bug this pins is the walk that
// stopped after one page on a catalogue whose pagination is a strip of numbers with no `rel="next"`.
do {
    print("32. Later result pages are addressed the way the listing numbers them")

    let catalog = URL(string: "https://bids.palletauctions.com/auctions/catalog/id/29?page=1")!
    let plan = PaginationPlan(baseURL: catalog)
    check(plan.parameter == "page", "the catalogue's own parameter is read from the address", detail: plan.parameter)
    check(plan.url(page: 2)?.absoluteString == "https://bids.palletauctions.com/auctions/catalog/id/29?page=2",
          "page 2 is the same listing asking for page 2",
          detail: plan.url(page: 2)?.absoluteString ?? "nil")
    check(plan.url(page: 7)?.absoluteString == "https://bids.palletauctions.com/auctions/catalog/id/29?page=7",
          "and so is every page after it",
          detail: plan.url(page: 7)?.absoluteString ?? "nil")
    check(plan.url(page: 2)?.absoluteString.split(separator: "?").last?.split(separator: "&")
            .filter { $0.hasPrefix("page=") }.count == 1,
          "the page number is replaced, not appended a second time")

    // An address that never carried a page number gains one, which is the ordinary first-run case.
    let bare = URL(string: "https://bids.palletauctions.com/auctions/catalog/id/29")!
    let barePlan = PaginationPlan(baseURL: bare)
    check(barePlan.url(page: 1)?.absoluteString == "https://bids.palletauctions.com/auctions/catalog/id/29?page=1",
          "a listing addressed without a page number gains one",
          detail: barePlan.url(page: 1)?.absoluteString ?? "nil")

    // Other parameters survive, in order, and the fragment is left alone.
    let filtered = URL(string: "https://example.test/catalog?category=all&sort=ends&page=1#lots")!
    check(PaginationPlan(baseURL: filtered).url(page: 3)?.absoluteString
            == "https://example.test/catalog?category=all&sort=ends&page=3#lots",
          "the listing's other parameters and its fragment are kept",
          detail: PaginationPlan(baseURL: filtered).url(page: 3)?.absoluteString ?? "nil")

    // A site that says `paged` is asked with `paged`, whichever way the app heard about it.
    let wordpress = URL(string: "https://example.test/blog/category/lots/paged/2/")!
    check(PaginationPlan(baseURL: wordpress, parameter: "paged").url(page: 5)?.absoluteString
            == "https://example.test/blog/category/lots/paged/2/?paged=5",
          "the name the page reported is the name the rewrite uses",
          detail: PaginationPlan(baseURL: wordpress, parameter: "paged").url(page: 5)?.absoluteString ?? "nil")
    check(PaginationPlan(baseURL: URL(string: "https://example.test/catalog?paged=3")!).parameter == "paged",
          "and an address already using it is read as that name")

    // Reading addresses back is how the walk notices a page number that was ignored or clamped.
    check(PaginationPlan.pageNumber(of: URL(string: "https://example.test/catalog?page=4")!) == 4,
          "a page number in the query string is read back")
    check(PaginationPlan.pageNumber(of: URL(string: "https://example.test/catalog?paged=12")!) == 12,
          "under any of the names sites use")
    check(PaginationPlan.pageNumber(of: URL(string: "https://example.test/catalog/page/7")!) == 7,
          "and in a path-shaped address")
    check(PaginationPlan.pageNumber(of: URL(string: "https://example.test/catalog/page-9?x=1")!) == 9,
          "including the hyphenated spelling")
    check(PaginationPlan.pageNumber(of: URL(string: "https://example.test/catalog?p=9999")!) == nil,
          "a bare \"?p=\" is a product id, not a page")
    check(PaginationPlan.pageNumber(of: URL(string: "https://example.test/catalog")!) == nil,
          "and an address with no page number in it reads as none")

    // The parameter list is shared with the page-side reader, so the two cannot drift apart.
    check(PaginationPlan.parameterNames == ["page", "paged", "pg"],
          "the names the reader and the builder agree on are the three the sites use",
          detail: "\(PaginationPlan.parameterNames)")
}

// MARK: - 33. The on-device label reader

// A valuation's strongest anchor is a barcode or a printed model number, and that is precisely the
// thing a general vision model reads worst off a photograph. So the app reads the photographs it is
// about to send, on its own machine, and hands the model the literal digits (`LotImageDigest`) — and
// the same digits come back on the row and in the console, so a price can be argued with. The rule
// that decides what counts as an identifier is a pure function, which is why it can be checked here
// with no image and no key.
do {
    print("33. The app reads labels and barcodes off the photographs before the model does")

    check(LotImageDigest.normalise(token: "DCS620D", hinted: false) == "DCS620D",
          "a model number is kept",
          detail: LotImageDigest.normalise(token: "DCS620D", hinted: false) ?? "nil")
    check(LotImageDigest.normalise(token: "SMT-290", hinted: false) == "SMT-290",
          "including one written with a hyphen")
    check(LotImageDigest.normalise(token: "609032993551", hinted: false) == "609032993551",
          "a 12-digit UPC is an identifier on its own")
    check(LotImageDigest.normalise(token: "20V", hinted: false) == nil, "a voltage is not a part number")
    check(LotImageDigest.normalise(token: "2PK", hinted: false) == nil, "nor is a pack size")
    check(LotImageDigest.normalise(token: "Yankee", hinted: false) == nil, "nor is a bare word")
    check(LotImageDigest.normalise(token: "4711", hinted: false) == nil,
          "a short bare number waits for the label to name it")
    check(LotImageDigest.normalise(token: "4711", hinted: true) == "4711", "\"SKU 4711\" does name it")

    let read = LotImageDigest.identifiers(in: [
        "Yankee Candle 22 oz SKU 4711",
        "UPC 609032993551",
        "Total $84.11"
    ])
    check(read == ["4711", "609032993551"],
          "a label reads as identifiers, and a printed total is not one",
          detail: read.joined(separator: ", "))

    let punctuated = LotImageDigest.identifiers(in: ["SKU:4711  MFR#DCS620D"])
    check(punctuated == ["4711", "DCS620D"],
          "a label that punctuates its identifiers reads the same as one that spaces them",
          detail: punctuated.joined(separator: ", "))

    check(LotImageDigest.normalise(barcode: "0123456789012") == "0123456789012", "a decoded UPC-A is kept")
    check(LotImageDigest.normalise(barcode: "12345") == nil, "a payload too short to be a code is dropped")
    check(LotImageDigest.normalise(barcode: "ABCDEF") == nil, "and so is one with no digit in it")

    let evidence = LotImageEvidence(barcodes: ["0123456789012"], identifiers: ["DCS620D"], imagesRead: 3)
    check(!evidence.isEmpty, "a reading with something in it is not empty")
    check(LotImageEvidence().isEmpty && LotImageEvidence().promptLines.isEmpty,
          "an unread gallery says nothing at all rather than saying \"nothing\"")
    let echoed = evidence.promptLines.joined(separator: "\n")
    check(echoed.contains("0123456789012") && echoed.contains("DCS620D"),
          "the reading is echoed to the model literally, digits and all")
    check(echoed.contains("price that exact model"),
          "and the model is told to price that product rather than its category")

    let imagedPrompt = LotValuationPrompt.userPrompt(description: "Mixed lot", imageCount: 3, evidence: evidence)
    check(imagedPrompt.contains("Decoded barcodes: 0123456789012"),
          "the photograph prompt carries the decoded barcode")
    check(!LotValuationPrompt.userPrompt(description: "Mixed lot", imageCount: 3).contains("Decoded barcodes"),
          "and carries no reader section when the reader found nothing")
    check(LotValuationPrompt.systemInstruction.contains("barcode")
            && LotValuationPrompt.systemInstruction.contains("`evidence`"),
          "the photograph rules tell the model to read labels and to say what it priced from")

    // The answer side: `evidence` has to survive the tolerant decode onto the row.
    do {
        let answer = """
        {"items":[{"itemName":"AA batteries, 12x 2-pack","confidence":"High","retailValue":420,\
        "resaleValue":180,"notes":"Fast mover.","evidence":"label reads \\"Energizer MAX AA\\" · UPC 039800011324"}]}
        """
        let items = try LotValuationAnswer.items(fromAnswerText: answer, finishReason: "stop")
        check(items.first?.evidence == "label reads \"Energizer MAX AA\" · UPC 039800011324",
              "a line's evidence decodes onto the row",
              detail: items.first?.evidence ?? "nil")
    } catch {
        tally.bump()
        print("  FAIL  unexpected error: \(error)")
    }

    // And the whole path once, over a photograph that really is a decodable image: the reader opens
    // it, reports honestly that a blank sheet carries nothing, and the valuation still lands.
    do {
        let script = StubScript([
            .init(status: 200, body: blankPNGBytes, headers: ["Content-Type": "image/png"]),
            .init(status: 200, body: successBody)
        ])
        let service = makeService(script, requestsPerMinute: 0, maxAttempts: 1)
        let outcome = try await service.value(subject: imageSubject)

        check(outcome.imagesSent == 1, "the photograph still travelled", detail: "\(outcome.imagesSent)")
        check(outcome.evidence != nil, "the reader's report travels with the outcome")
        check(outcome.evidence?.imagesRead == 1,
              "and counts the photographs it could open",
              detail: String(describing: outcome.evidence?.imagesRead))
        check(outcome.evidence?.isEmpty == true,
              "a photograph with nothing legible on it reads as empty, not as a failure")
        check(outcome.evidence?.logPhrase.contains("nothing legible") == true,
              "and the console line says so in words",
              detail: outcome.evidence?.logPhrase ?? "nil")
    } catch {
        tally.bump()
        print("  FAIL  unexpected error: \(error)")
    }
}

print(tally.value == 0 ? "\nALL CHECKS PASSED" : "\n\(tally.value) CHECK(S) FAILED")
exit(tally.value == 0 ? 0 : 1)
