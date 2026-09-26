//
//  main.swift
//  Offline harness for the valuation transports.
//
//  Compiles the real services (Services/LotValuation.swift, GeminiValuationService.swift,
//  DeepSeekValuationService.swift) against a URLProtocol stub, so the 429 retry loop,
//  Retry-After handling, RequestPacer pacing, request shaping and the shared decode can be
//  checked without a key and without touching the network. The provider list's own copy is
//  checked too (where each key comes from, what it costs), because two sheets print it and
//  neither may drift from the README. Not part of the app target.
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

/// The reports one scan sent, in the order they arrived — the same stream the app's readout is fed by
/// the coordinator, which is the only way the bar's claim can be measured against a scan that really ran.
final class ReportLog: @unchecked Sendable {

    private let lock = NSLock()
    private var entries: [PhotoScanReport] = []

    func note(_ report: PhotoScanReport) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(report)
    }

    /// Every event the reporter was handed, in the order it arrived.
    var events: [PhotoScanEvent] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.event)
    }

    /// The answered count each frame report carried, in the order the scan reported them: one entry for a
    /// frame's announcement and one for its outcome, and nothing for the reconciliation's own steps.
    var answeredCounts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return entries.compactMap { report in
            switch report.event {
            case .reading(_, _, let answered, _),
                 .read(_, _, let answered, _),
                 .failed(_, _, let answered, _),
                 .manifesting(_, _, _, let answered, _),
                 .manifested(_, _, _, let answered, _),
                 .manifestFailed(_, _, let answered, _, _):
                return answered
            case .folded, .grouped, .aggregating, .aggregated, .aggregatedLocally, .fallingBack,
                 .fallingBackFromManifest, .manifestSettled, .pricing, .priced:
                return nil
            }
        }
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

/// One frame's bytes, for a gallery whose frames are meant to be *different* photographs.
///
/// `jpegBytes` is one blob, so three downloads served with it are three copies of one file — and the
/// batched route groups a gallery before it sends it (`PhotoFrameGrouping`), so a script that answered
/// three times with the same bytes would be answering about one photograph as if it were three. The
/// bytes here are not a picture at all, so no fingerprint is computed for them and they stay distinct.
func frameBytes(_ index: Int) -> Data {
    Data(repeating: UInt8(0xF0 &+ index), count: 512)
}

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

/// A `generateContent` success envelope whose text part is `inner`, whatever shape `inner` is.
///
/// `successBody` builds the one fixture whose answer is a pallet's line items; a thorough scan asks a
/// different question per photograph, so its answers are readings (`photoReadingBody`) and the items
/// only come back at the end.
func generateContentEnvelope(_ inner: String) -> Data {
    let escaped = inner.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return Data(#"{"candidates":[{"finish_reason":"STOP","content":{"parts":[{"text":"\#(escaped)"}]}}]}"#.utf8)
}

/// One photograph's answer, in the reading schema the per-photograph prompt asks for: what this frame
/// showed, with the units visible **in that frame**.
let photoReadingJSON = #"{"summary":"a stack of sealed cartons","objects":[{"name":"NAME","brand":"Energizer","category":"household","quantity":QUANTITY,"unitRetail":15.99,"unitResale":9.5,"condition":"new","packaging":"sealed retail","location":"front left","identifiers":["039800011324"],"labelText":"Energizer MAX AA","confidence":"High","evidence":"label reads Energizer MAX AA","notes":""}],"notes":""}"#

func readingJSON(name: String, quantity: Int) -> String {
    photoReadingJSON
        .replacingOccurrences(of: "NAME", with: name)
        .replacingOccurrences(of: "QUANTITY", with: "\(quantity)")
}

func photoReadingBody(name: String, quantity: Int) -> Data {
    generateContentEnvelope(readingJSON(name: name, quantity: quantity))
}

/// The same reading in DeepSeek's chat envelope, because the two transports wrap the same JSON
/// differently and the thorough path has to work through both.
func deepSeekPhotoReadingBody(name: String, quantity: Int) -> Data {
    let inner = readingJSON(name: name, quantity: quantity)
    let escaped = inner.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return Data(#"{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"\#(escaped)"}}]}"#.utf8)
}

/// A two-photograph lot, so a thorough scan can be driven end to end without a four-frame script.
let twoPhotoSubject = ValuationSubject(
    lotNumber: "307",
    title: "Pallet of batteries",
    rawDescription: "Mixed lot, 20 pieces.",
    currentBid: 90,
    imageURLs: [
        URL(string: "https://cdn.example.test/lot-307-1.jpg")!,
        URL(string: "https://cdn.example.test/lot-307-2.jpg")!
    ],
    detailURL: nil
)

/// The same shape for the fallback checks, where the store's answer must not be involved: a different
/// lot number is a different key.
let onePhotoSubject = ValuationSubject(
    lotNumber: "308",
    title: "Pallet of batteries",
    rawDescription: "Mixed lot, 20 pieces.",
    currentBid: 90,
    imageURLs: [URL(string: "https://cdn.example.test/lot-308-1.jpg")!],
    detailURL: nil
)

/// A third lot, for the same thorough scan driven through the other transport.
let deepSeekSubject = ValuationSubject(
    lotNumber: "309",
    title: "Pallet of batteries",
    rawDescription: "Mixed lot, 20 pieces.",
    currentBid: 90,
    imageURLs: [URL(string: "https://cdn.example.test/lot-309-1.jpg")!],
    detailURL: nil
)

/// A three-photograph lot, so the batched route has to split one gallery across requests and fold what
/// comes back.
let threePhotoSubject = ValuationSubject(
    lotNumber: "310",
    title: "Pallet of candles and batteries",
    rawDescription: "Mixed lot, 40 pieces.",
    currentBid: 120,
    imageURLs: [
        URL(string: "https://cdn.example.test/lot-310-1.jpg")!,
        URL(string: "https://cdn.example.test/lot-310-2.jpg")!,
        URL(string: "https://cdn.example.test/lot-310-3.jpg")!
    ],
    detailURL: nil
)

/// A photograph step, as the loader will accept it.
func photoStep() -> StubScript.Step {
    StubScript.Step(status: 200, body: jpegBytes, headers: ["Content-Type": "image/jpeg"])
}

/// A photograph with a picture *on* it, encoded here with CoreGraphics rather than pasted in as a
/// base64 blob so it cannot rot.
///
/// The grouping pass (`PhotoFrameGrouping`) compares frames by their pixels, so a fixture for it has
/// to hold more than a flat colour: a blank sheet reduces to one gray level and is deliberately given
/// no fingerprint at all. `seed` picks which picture — the same seed is the same photograph, byte for
/// byte, and a different seed is a different one, which is what lets a gallery repeat one frame and
/// hold another.
func detailedPNGBytes(seed: Int, side: Int = 96) -> Data {
    guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return Data() }

    // A soft gradient up the frame, so the fingerprint has plenty of distinct gray levels to work
    // with — a frame below `PhotoFrameGrouping.minimumDetail` is never compared at all…
    let bands = 32
    for band in 0..<bands {
        let level = Double(band) / Double(bands - 1) * 0.6
        context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
        context.fill(
            CGRect(
                x: 0,
                y: Double(band) * Double(side) / Double(bands),
                width: Double(side),
                height: Double(side) / Double(bands)
            )
        )
    }

    // …and one white square whose corner the seed decides, which is the only thing that tells two
    // seeds apart. Moved, not redrawn: the two pictures hold the same gray levels in a different
    // order, so their fingerprints differ exactly in the square's own cells.
    let quarter = side / 4
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(
        CGRect(
            x: Double(seed % 4) * Double(quarter),
            y: Double((seed / 4) % 4) * Double(quarter),
            width: Double(quarter),
            height: Double(quarter)
        )
    )

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
}

/// One downloaded photograph, as a scan is handed it.
func lotImage(_ bytes: Data, at address: String) -> LotImage {
    LotImage(
        mimeType: "image/png",
        base64: bytes.base64EncodedString(),
        byteCount: bytes.count,
        sourceURL: URL(string: address)!
    )
}

func makeService(
    _ script: StubScript,
    requestsPerMinute: Int,
    maxAttempts: Int,
    maxImageBytes: Int = 6_000_000,
    maxTotalImageBytes: Int = LotImageLoader.defaultTotalBytes,
    photoScan: PhotoScanPlan = .disabled,
    store: PhotoReadingStore = .shared,
    report: @escaping @Sendable (PhotoScanReport) -> Void = { _ in }
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
        maxAttempts: maxAttempts,
        photoScan: photoScan,
        store: store,
        report: report
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

/// A `/chat/completions` success envelope around arbitrary JSON, which is what both the manifest route
/// and the two pricing routes are handed back.
func chatEnvelope(_ json: String) -> Data {
    let escaped = json.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return Data(#"{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"\#(escaped)"}}]}"#.utf8)
}

/// One manifest line as a batch's answer writes it.
struct StubManifestLine {
    var name: String
    var brand: String = ""
    var model: String = ""
    var quantity: Int = 1
    var views: [Int] = []
    var confidence: String = "High"
    var identifiers: [String] = []
}

/// A batch's manifest answer, in the schema the batch prompt asks for.
func manifestBody(_ lines: [StubManifestLine]) -> Data {
    let rendered = lines.map { line -> String in
        let codes = line.identifiers.map { "\"\($0)\"" }.joined(separator: ",")
        let places = line.views.map(String.init).joined(separator: ",")
        return #"{"itemName":"\#(line.name)","brand":"\#(line.brand)","modelNumber":"\#(line.model)","quantity":\#(line.quantity),"confidence":"\#(line.confidence)","identifiers":[\#(codes)],"views":[\#(places)]}"#
    }
    return chatEnvelope(#"{"manifest":[\#(rendered.joined(separator: ","))]}"#)
}

/// DeepSeek's 429 envelope: a concurrency ceiling, not a per-minute quota.
let deepSeekRateLimitBody = Data(#"{"error":{"message":"Rate limit reached for requests","type":"rate_limit_error","code":"rate_limit_exceeded"}}"#.utf8)

func makeDeepSeekService(
    _ script: StubScript,
    requestsPerMinute: Int,
    maxAttempts: Int,
    maxImageBytes: Int = 6_000_000,
    maxTotalImageBytes: Int = LotImageLoader.defaultTotalBytes,
    photoScan: PhotoScanPlan = .disabled,
    photosPerRequest: Int = 0,
    store: PhotoReadingStore = .shared,
    report: @escaping @Sendable (PhotoScanReport) -> Void = { _ in }
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
        maxAttempts: maxAttempts,
        photoScan: photoScan,
        photosPerRequest: photosPerRequest,
        store: store,
        report: report
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

/// The gallery number a batch says it holds, read off its own prompt: `photograph 3 of 5 is attached` → `3`.
///
/// Read rather than assumed, because the stub hands image bodies out in the order the downloads arrive,
/// so which frame of a gallery gets which picture is not a fact about the app. What *is* a fact is that
/// the batch names the gallery number of the frame it carries, and that is what this reads.
///
/// - Parameter count: the gallery size the batch should be speaking in, so an earlier mention of a
///   photograph in the same prompt cannot be mistaken for the batch's own numbering.
/// - Returns: `nil` for a batch that carries more than one frame, or that says nothing.
func photographNumber(in prompt: String, of count: Int) -> Int? {
    guard let marker = prompt.range(of: " of \(count) is attached") else { return nil }
    let digits = prompt[..<marker.lowerBound].reversed().prefix { $0.isNumber }.reversed()
    guard !digits.isEmpty else { return nil }
    return Int(String(digits))
}

/// A chat request's system instruction.
func systemText(in request: SeenRequest?) -> String {
    let messages = request?.json["messages"] as? [[String: Any]] ?? []
    return messages.first?["content"] as? String ?? ""
}

/// The parts of a `generateContent` request's last content block, as the stub saw them.
///
/// Gemini does not send the chat shape the three readers above speak: the parts live under
/// `contents`, and a photograph is `inline_data` — a MIME type and raw base64 — rather than an
/// `image_url` carrying a data URL. Reading one with the chat helpers would find no photograph in it
/// at all, so a check about attached frames has to ask in Gemini's own terms.
func geminiParts(in request: SeenRequest?) -> [[String: Any]] {
    let contents = request?.json["contents"] as? [[String: Any]] ?? []
    return contents.last?["parts"] as? [[String: Any]] ?? []
}

/// The concatenated text parts of a `generateContent` request.
func geminiText(in request: SeenRequest?) -> String {
    geminiParts(in: request).compactMap { $0["text"] as? String }.joined()
}

/// The base64 of every photograph a `generateContent` request inlines, in part order.
func geminiImages(in request: SeenRequest?) -> [String] {
    geminiParts(in: request).compactMap { part in
        (part["inline_data"] as? [String: Any])?["data"] as? String
    }
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
        .init(status: 200, body: jpegBytes, headers: ["Content-Type": "image/jpeg"]), // the photograph
        .init(status: 200, body: deepSeekSuccessBody),                                // pass 1: text
        .init(status: 200, body: deepSeekSuccessBody)                                 // pass 2: photos
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
        fields == [
            "confidence", "evidence", "itemName", "notes", "photos", "quantity",
            "resaleValue", "retailValue"
        ],
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
    check(itemProperties?.keys.sorted() == [
        "confidence", "evidence", "itemName", "notes", "photos", "quantity",
        "resaleValue", "retailValue"
    ], "schema exposes every field", detail: "\((itemProperties?.keys.sorted() ?? []).joined(separator: ", "))")
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}


// MARK: - 18. DeepSeek: the photograph pass failing falls back to the text pass

do {
    print("18. DeepSeek: a failing photograph pass falls back to the text pass's answer")
    let script = StubScript([
        .init(status: 200, body: jpegBytes, headers: ["Content-Type": "image/jpeg"]),
        .init(status: 200, body: deepSeekSuccessBody),
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

    let shippedTotal = LotColumn.selection + LotColumn.expander + LotColumn.scan
        + LotColumnKey.allCases.reduce(0) { $0 + $1.defaultWidth } + LotColumn.rowInsets
    check(standard.totalWidth == shippedTotal, "the total is every column plus the fixed chrome", detail: "\(standard.totalWidth) vs \(shippedTotal)")
    check(standard.identityWidth == LotColumn.selection + LotColumn.expander + LotColumn.scan + standard.lotNumber + standard.title,
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
    let chrome = LotColumn.selection + LotColumn.expander + LotColumn.scan + LotColumn.rowInsets
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
    check(chrome == LotColumn.selection + LotColumn.expander + LotColumn.scan + LotColumn.rowInsets,
          "the chrome is the row checkboxes, the chevron, the action pair and the row insets", detail: "\(chrome)")
    check(standard.dataWidth == LotColumnKey.allCases.reduce(0) { $0 + $1.defaultWidth },
          "the data width is the thirteen draggable columns", detail: "\(standard.dataWidth)")
    check(standard.totalWidth == chrome + standard.dataWidth, "and the total is both of them", detail: "\(standard.totalWidth)")

    // Narrower than the table: the dragged layout is handed straight back, so the operator keeps
    // what they sized and the horizontal scroller does the work.
    check(standard.filling(900) == standard, "a window narrower than the table leaves the widths alone")
    check(standard.filling(standard.totalWidth) == standard, "and so does a window that is exactly the table's width")

    let wide = standard.filling(1_680)
    check(abs(wide.totalWidth - 1_680) < 0.01, "a wider window is filled exactly", detail: "\(wide.totalWidth)")

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

    // The other half of the same rule, and the one that used to lose a lot. Two cards that print the
    // same number but lead to *different* pages are two lots; keying on the number alone retired the
    // second, which is how a board of 100 came back holding 99 with nothing in the log to say why.
    let twinNumberA = ScrapedLot(
        lotNumber: "19002",
        title: "First lot printed as 19002",
        rawDescription: "",
        bidText: "",
        imageURLStrings: [],
        detailURLString: "https://example.test/auction/lot/19002",
        sourcePage: 1
    )
    let twinNumberB = ScrapedLot(
        lotNumber: "19002",
        title: "Second lot printed as 19002",
        rawDescription: "",
        bidText: "",
        imageURLStrings: [],
        detailURLString: "https://example.test/auction/lot/19003",
        sourcePage: 1
    )
    check(
        twinNumberA.dedupeKey != twinNumberB.dedupeKey,
        "two lots that print the same number on different pages are two lots",
        detail: "\(twinNumberA.dedupeKey) vs \(twinNumberB.dedupeKey)"
    )

    let samePageLinkedTwoWays = ScrapedLot(
        lotNumber: "19002",
        title: "The same lot, linked again from page 2",
        rawDescription: "",
        bidText: "",
        imageURLStrings: [],
        detailURLString: "https://example.test/auction/lot/19002?ref=list&page=2",
        sourcePage: 2
    )
    check(
        twinNumberA.dedupeKey == samePageLinkedTwoWays.dedupeKey,
        "and one lot page linked two ways is still one lot",
        detail: "\(twinNumberA.dedupeKey) vs \(samePageLinkedTwoWays.dedupeKey)"
    )

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
    check(noTitle.identityWidth == LotColumn.selection + LotColumn.expander + LotColumn.scan + shipped.lotNumber,
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

    // DeepSeek's photograph pass gets the whole gallery too, with its text pass untouched (the
    // photographs are downloaded and read first, then the text pass, then the request that carries
    // them).
    do {
        let script = StubScript(
            galleryImageSteps
                + [.init(status: 200, body: deepSeekSuccessBody)]
                + [.init(status: 200, body: deepSeekSuccessBody)]
        )
        let service = makeDeepSeekService(script, requestsPerMinute: 0, maxAttempts: 1)
        let outcome = try await service.value(subject: gallerySubject)

        check(outcome.imagesSent == 4, "the whole gallery reached the photograph pass", detail: "\(outcome.imagesSent)")
        check(outcome.imagesAvailable == 4, "counted against the lot's own total", detail: "\(outcome.imagesAvailable)")
        check(outcome.passes == 2, "still appraised in two passes", detail: "\(outcome.passes)")
        let firstChat = script.requests.first {
            $0.url.absoluteString == "https://api.deepseek.com/chat/completions"
        }
        check(firstChat.map { imageURLs(in: $0).isEmpty } == true, "and the text pass still carries no photographs")
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

    // The other half of what a lot page carries: its description. A card only ever teasers it, so the
    // page's copy is what the prompt must be built from — and, exactly as with the images, an empty
    // answer leaves the card's text standing rather than blanking what the row is showing.
    check(imageSubject.withDescription("") == imageSubject,
          "a page with no description leaves the card's copy alone")
    check(imageSubject.withDescription("   \n\t ") == imageSubject,
          "and so does one that is only whitespace")
    let described = imageSubject.withDescription(
        "Pallet of 40 returned kitchen appliances,\n  6x Ninja BL610 blenders, UPC 622356528163."
    )
    check(described.rawDescription == "Pallet of 40 returned kitchen appliances, 6x Ninja BL610 blenders, UPC 622356528163.",
          "the page's description replaces the card's teaser, whitespace condensed",
          detail: described.rawDescription)
    check(described.imageURLs == imageSubject.imageURLs && described.currentBid == imageSubject.currentBid,
          "without touching the card's photographs or its bid")

    // Both asks are built from that one subject, so the page's copy has to reach the prompt the model
    // actually sees — the cheap text-only pass as much as the photographed one.
    let listingText = LotValuationPrompt.listingText(for: described)
    check(listingText.contains("Ninja BL610") && listingText.contains("622356528163"),
          "the page's description reaches the listing text both passes are built from",
          detail: listingText)
    check(!listingText.contains(imageSubject.rawDescription),
          "and the card's teaser is not left in it as well", detail: listingText)

    // The row side of the same rule: the column the expanded row shows is the page's copy once it has
    // been read, and a later read that yields nothing cannot blank it.
    let row = makeLot("208", bid: 640)
    check(row.applyLotPageDescription("Pallet of 40 returned kitchen appliances, 6x Ninja BL610 blenders."),
          "a row takes the page's description")
    check(row.rawDescription.contains("Ninja BL610"), "and the row's own copy is what changed",
          detail: row.rawDescription)
    check(!row.applyLotPageDescription(""), "an empty description changes nothing")
    check(!row.applyLotPageDescription(row.rawDescription), "and neither does the same text again")
    check(row.rawDescription.contains("Ninja BL610"), "so the page's copy is still what the row shows",
          detail: row.rawDescription)

    // The containers the page-side reader is scoped to, and the shape it can read them in. The frame is
    // named first because that is where the lot's photographs are; the strip is named as well in case a
    // layout moves it out of the column; and nothing else on the page is named at all — the site reuses
    // `auc_slide` for its own carousels, and a rail of neighbouring lots read as this lot's gallery is
    // how a lot with eight photographs became a scan of seventeen.
    let reader = ScrapeProfile.genericBase()
    check(reader.lotPageGallerySelectors.first == "div.auc_slide.left",
          "the gallery is scoped to the lot's own slide column",
          detail: reader.lotPageGallerySelectors.first ?? "none")
    check(reader.lotPageGallerySelectors.contains("ul.mediaThumbnails"),
          "and to the thumbnail strip, in case a layout puts it elsewhere")
    check(!reader.lotPageGallerySelectors.contains("div.auc_slide"),
          "while the class the site also uses for its own carousels is not a gallery rule",
          detail: reader.lotPageGallerySelectors.joined(separator: ", "))
    // The attributes a thumbnail strip hides its full-size copies in. On this catalogue a strip item is
    // `<a href="…_xl.jpg" data-image="…_l.jpg"><img src="…_s.jpg">`, so the anchor's own `href` (read by
    // the page-side script) plus these three are the whole of what carries a photograph; dropping one
    // would silently send a 56×100 crop to a vision model.
    let imageAttributes = Set(reader.imageAttributeCandidates)
    check(["src", "data-image", "data-zoom-image", "data-large_image"].allSatisfy(imageAttributes.contains),
          "the profile reads every attribute a strip uses for its full-size copy",
          detail: reader.imageAttributeCandidates.joined(separator: ", "))
    check(reader.lotPageDescriptionSelectors.first == "div.active.ins_cnt.description-info-content",
          "the description block is named ahead of the column that contains it",
          detail: reader.lotPageDescriptionSelectors.first ?? "none")
    // Compound selectors only: Tools/scraper-js-check models no descendant combinators, so a container
    // rule written as one would be a rule nothing drives.
    func isCompound(_ selector: String) -> Bool {
        let outsideBrackets = selector.replacingOccurrences(
            of: "\\[[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )
        return !outsideBrackets.contains(" ") && !outsideBrackets.contains(">")
    }
    let containerRules = reader.lotPageGallerySelectors + reader.lotPageDescriptionSelectors
    check(containerRules.allSatisfy(isCompound),
          "every container rule is a compound selector, so the page-side check can drive it",
          detail: containerRules.joined(separator: ", "))
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

    // The price a pallet is worth turns on *which* product was identified: a barcode names one model,
    // "household goods" names a category, and the two are not the same money. Both asks therefore state
    // the same preference ladder, so the cheap pass and the photographed one cannot drift apart.
    for (name, rules) in [
        ("the photographed pass", LotValuationPrompt.systemInstruction),
        ("the per-photograph reader", LotPhotoScanPrompt.readingSystemInstruction)
    ] {
        let ladder = rules.lowercased()
        check(ladder.contains("most exactly identified"),
              "\(name) prices the most exactly identified product rather than its category")
        check(ladder.contains("barcode or model") && ladder.contains("which beats a brand")
                && ladder.contains("which beats the category"),
              "\(name) states the ladder: barcode or model, then brand and size, then brand, then category")
        check(ladder.contains("wrong price"),
              "\(name) says why: a generic price for a specific product is the wrong one")
    }
    // The cheap pass has no photographs, so it can only ever price the name it is given: what the page's
    // description now supplies — brands, model numbers, counts, condition — is exactly what it is told
    // to reason from.
    let cheap = LotValuationPrompt.prePriceSystemInstruction.lowercased()
    check(cheap.contains("brands, model numbers, counts and condition"),
          "the text-only pass is told to reason from brands, model numbers, counts and condition")
    check(cheap.contains("extrapolate from the category when the wording is thin"),
          "and to fall back to the category only when that wording is thin")

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

// MARK: - 34. The thorough scan

// The thorough path is the one piece of this app that spends money per *frame*: one request for each
// photograph, then one more to reconcile the readings into the pallet's line items. Three claims about
// it are worth pinning down offline, because they are the difference between a scan that is expensive
// and a scan that is expensive *twice*:
//
//   * each photograph is asked about on its own, with the reading's own URL and position;
//   * the readings are written to this machine before the reconciliation is attempted, so re-scanning
//     the same lot with the same model costs one request rather than n+1;
//   * a reconciliation that fails still produces a valuation, from the readings that were paid for.
do {
    print("34. A thorough scan reads each photograph on its own, keeps the readings, then reconciles")

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lotlogic-readings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PhotoReadingStore(directory: directory)
    let plan = PhotoScanPlan.thorough(modelID: "gemini-2.5-flash", concurrency: 1)

    // A whole scan, in the shape the pipeline sends it: every photograph, then the reconciliation.
    do {
        let script = StubScript([
            photoStep(),
            photoStep(),
            .init(status: 200, body: photoReadingBody(name: "Energizer MAX AA batteries", quantity: 6)),
            .init(status: 200, body: photoReadingBody(name: "Energizer MAX AA batteries", quantity: 4)),
            .init(status: 200, body: successBody)
        ])
        let service = makeService(script, requestsPerMinute: 0, maxAttempts: 1, photoScan: plan, store: store)
        let outcome = try await service.value(subject: twoPhotoSubject)

        check(outcome.readings.count == 2, "one reading per photograph", detail: "\(outcome.readings.count)")
        check(Set(outcome.readings.map(\.imageURL)) == Set(twoPhotoSubject.imageURLs),
              "each reading names the photograph it came from",
              detail: outcome.readings.map(\.imageURL.lastPathComponent).joined(separator: ", "))
        check(outcome.readings.map(\.imageIndex).sorted() == [1, 2],
              "and its position in the gallery",
              detail: "\(outcome.readings.map(\.imageIndex).sorted())")
        check(outcome.readings.allSatisfy { $0.modelID == "gemini-2.5-flash" },
              "stamped with the model that read it, which is what the store reuses by")
        check(outcome.scanRequests == 3, "one request per photograph plus the reconciliation", detail: "\(outcome.scanRequests)")
        check(outcome.readingsFromStore == 0, "and nothing was reused on a first scan", detail: "\(outcome.readingsFromStore)")
        check(outcome.items.count == 1, "the reconciliation produced the line items", detail: "\(outcome.items.count)")
        check(outcome.items.first?.itemName == "AA batteries, 12x 2-pack",
              "from the reconciliation request rather than from the readings",
              detail: outcome.items.first?.itemName ?? "nil")

        let stored = await store.readings(forLot: "307", modelID: "gemini-2.5-flash")
        check(stored.count == 2, "the readings are on this machine, before the reconciliation is attempted",
              detail: "\(stored.count)")
    } catch {
        tally.bump()
        print("  FAIL  unexpected error: \(error)")
    }

    // The same lot again: the photographs are not paid for twice.
    //
    // The gallery itself is fetched again — image bytes are not what the store keeps, and a CDN read
    // costs nothing — but no *model* request is made about a photograph this machine has already read.
    do {
        let script = StubScript([
            photoStep(),
            photoStep(),
            .init(status: 200, body: successBody)
        ])
        let service = makeService(script, requestsPerMinute: 0, maxAttempts: 1, photoScan: plan, store: store)
        let outcome = try await service.value(subject: twoPhotoSubject)

        check(outcome.readingsFromStore == 2, "the second scan reused both readings", detail: "\(outcome.readingsFromStore)")
        check(outcome.readings.count == 2, "and still reports them", detail: "\(outcome.readings.count)")
        check(outcome.scanRequests == 1, "so only the reconciliation was sent", detail: "\(outcome.scanRequests)")

        let chats = script.requests.filter { $0.url.absoluteString.contains("generateContent") }
        check(chats.count == 1, "one model request, not one per photograph", detail: "\(chats.count)")
        check(chats.allSatisfy { imageURLs(in: $0).isEmpty },
              "the reconciliation carries no photographs when every frame was read",
              detail: "\(chats.map { imageURLs(in: $0).count })")
    } catch {
        tally.bump()
        print("  FAIL  unexpected error: \(error)")
    }

    // The last request is the one that fails: the readings are folded into line items here instead, so
    // the photographs that were paid for are not thrown away.
    do {
        let script = StubScript([
            photoStep(),
            .init(status: 200, body: photoReadingBody(name: "Energizer MAX AA batteries", quantity: 6)),
            .init(status: 500, body: Data(#"{"error":{"message":"server error"}}"#.utf8))
        ])
        let service = makeService(script, requestsPerMinute: 0, maxAttempts: 1, photoScan: plan, store: store)
        let outcome = try await service.value(subject: onePhotoSubject)

        check(outcome.reconciliationFailure != nil,
              "the reconciliation failure is reported rather than swallowed",
              detail: outcome.reconciliationFailure ?? "nil")
        check(outcome.items.count == 1, "the readings became line items anyway", detail: "\(outcome.items.count)")
        check(outcome.items.first?.itemName.contains("Energizer") == true,
              "named after what the photograph showed",
              detail: outcome.items.first?.itemName ?? "nil")
        check(outcome.items.first?.quantity == 6,
              "with the units the reading counted",
              detail: String(describing: outcome.items.first?.quantity))
    } catch {
        tally.bump()
        print("  FAIL  unexpected error: \(error)")
    }

    // And the identical pipeline on the other transport: DeepSeek builds the per-photograph request and
    // the reconciliation itself, and gets no say in what happens between them.
    do {
        let script = StubScript([
            photoStep(),
            .init(status: 200, body: deepSeekPhotoReadingBody(name: "Energizer MAX AA batteries", quantity: 6)),
            .init(status: 200, body: deepSeekSuccessBody)
        ])
        let deepSeekPlan = PhotoScanPlan.thorough(modelID: "deepseek-flash", concurrency: 1)
        let service = makeDeepSeekService(
            script,
            requestsPerMinute: 0,
            maxAttempts: 1,
            photoScan: deepSeekPlan,
            store: store
        )
        let outcome = try await service.value(subject: deepSeekSubject)

        check(outcome.readings.count == 1, "a reading came back through DeepSeek too", detail: "\(outcome.readings.count)")
        check(outcome.readings.first?.modelID == "deepseek-flash",
              "stamped with the model that read it",
              detail: outcome.readings.first?.modelID ?? "nil")
        check(outcome.items.count == 1, "and the reconciliation produced the line items", detail: "\(outcome.items.count)")

        let chats = script.requests.filter { $0.url.absoluteString.contains("chat/completions") }
        check(chats.count == 2, "two model requests: the photograph, then the reconciliation", detail: "\(chats.count)")
        check(imageURLs(in: chats.first).count == 1, "the first carries the photograph itself",
              detail: "\(imageURLs(in: chats.first).count)")
        check(imageURLs(in: chats.last).isEmpty, "and the reconciliation is text-only",
              detail: "\(imageURLs(in: chats.last).count)")
        let reconciliationPrompt = userText(in: chats.last)
        check(reconciliationPrompt.contains("unitRetail") && reconciliationPrompt.contains("quantity"),
              "which is handed every reading, field by field",
              detail: String(reconciliationPrompt.suffix(80)))
    } catch {
        tally.bump()
        print("  FAIL  unexpected error: \(error)")
    }
}

// MARK: - 34b. A repeated frame is one reading, and the frame still travels

/// The saving a grouping is for, and the rule it must not break.
///
/// A gallery repeats frames more often than it looks: a lot re-listed keeps the same zoom image, a
/// thumbnail strip carries the main frame again, and a carton photographed twice with its label
/// turned to the camera is one carton. A scan that reads every frame pays for each of those twice
/// over — once for the reading, and again for the reconciliation that has to work out that the
/// readings were of one thing.
///
/// So frames that are *provably* the same — identical pixels, or the same decoded barcode set — are
/// read once (`PhotoFrameGrouping`). What is pinned here is both halves of that: the request that is
/// not spent, and the photograph that is still delivered. A fold that quietly dropped the frame would
/// make the line items wrong with nothing failing, which is the one outcome this pipeline must never
/// produce (`LotPhotoScan`, rule 1).
///
/// The two signals are checked apart because they promise different things, and the difference is the
/// whole reason the barcode signal is narrow: the same pixels mean *the other frame's reading covers
/// this frame in full*, while the same barcode means it covers that one product and nothing else the
/// frame may hold.
do {
    print("34b. A repeated frame is read once, and the frame itself still travels")

    let picture = detailedPNGBytes(seed: 1)
    let otherPicture = detailedPNGBytes(seed: 9)
    check(!picture.isEmpty && !otherPicture.isEmpty,
          "the test frames encoded, so what follows is about grouping rather than about CoreGraphics",
          detail: "\(picture.count) / \(otherPicture.count) bytes")

    let gallery = [
        lotImage(picture, at: "https://cdn.example.test/lot-310-1.jpg"),
        lotImage(picture, at: "https://cdn.example.test/lot-310-2.jpg"),
        lotImage(otherPicture, at: "https://cdn.example.test/lot-310-3.jpg")
    ]

    // The same photograph twice, and a photograph of something else, as the scan is handed them.
    let samePicture = await PhotoFrameGrouping.group(images: gallery, labels: [], limit: gallery.count)
    check(samePicture.views.count == 1,
          "two frames with identical pixels are one view",
          detail: "\(samePicture.views.count) view(s) from \(gallery.count) frames")
    check(samePicture.views.first?.representative == 1,
          "and the view is the earliest frame that carried them",
          detail: "\(String(describing: samePicture.views.first?.representative))")
    check(samePicture.views.first?.folds.map(\.frame) == [2],
          "with the later frame folded into it",
          detail: "\(String(describing: samePicture.views.first?.folds.map(\.frame)))")
    check(samePicture.representative(of: 2) == 1, "so the scan is told exactly which frame it may skip")
    check(samePicture.representative(of: 1) == nil && samePicture.representative(of: 3) == nil,
          "while the frame that was read, and the frame showing something else, keep their own readings")
    check(samePicture.views.first?.phrase.contains("same picture") == true,
          "and the claim says what the two frames have in common",
          detail: samePicture.views.first?.phrase ?? "nil")

    // The ceiling bounds what is compared at all: a frame the scan was never going to read is not
    // folded, because that would save nothing and claiming it would be untrue.
    let clipped = await PhotoFrameGrouping.group(images: gallery, labels: [], limit: 2)
    check(clipped.views.first?.folds.map(\.frame) == [2] && clipped.representative(of: 3) == nil,
          "a frame past the read ceiling is left out of the comparison entirely")
    let single = await PhotoFrameGrouping.group(images: gallery, labels: [], limit: 1)
    check(single.isEmpty, "and a scan reading one frame has nothing to group")

    // The weaker signal, over frames the fingerprint cannot speak for: two blank sheets have no
    // picture to compare, so what is left is the barcode the app decoded off each of them.
    let flats = (1...3).map { lotImage(blankPNGBytes, at: "https://cdn.example.test/lot-311-\($0).jpg") }
    let codes = [
        LotImageEvidence(barcodes: ["0123456789012"], imagesRead: 1),
        LotImageEvidence(barcodes: ["0123456789012"], imagesRead: 1),
        LotImageEvidence(barcodes: ["0123456789012", "0037000123456"], imagesRead: 1)
    ]
    let sameBarcode = await PhotoFrameGrouping.group(images: flats, labels: codes, limit: flats.count)
    check(sameBarcode.views.first?.folds.map(\.frame) == [2],
          "two frames carrying the same decoded barcode are one view",
          detail: "\(String(describing: sameBarcode.views.first?.folds.map(\.frame)))")
    check(sameBarcode.representative(of: 3) == nil,
          "but a frame carrying that barcode *and* another one holds something the first does not, "
              + "so it keeps its own reading")
    let unlabelled = await PhotoFrameGrouping.group(images: flats, labels: [], limit: flats.count)
    check(unlabelled.isEmpty,
          "and two flat frames with nothing decoded off them are never claimed to be the same photograph")
}

// MARK: - 34c. A whole scan with a repeated frame spends one reading and drops no photograph

/// The same saving, driven through the pipeline rather than through the grouping alone.
///
/// Two frames that are the same photograph go up; one reading comes back; the reconciliation is handed
/// the frame that was not read, with a note saying a reading above already covers it. Three things
/// have to hold at once, and each is checked below: the request that was not spent, the photograph
/// that still travelled, and the row the operator reads afterwards.
do {
    print("34c. A scan with a repeated frame spends one reading and attaches the frame anyway")

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lotlogic-grouping-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PhotoReadingStore(directory: directory)

    /// One pallet, photographed twice from the same spot.
    let subject = ValuationSubject(
        lotNumber: "310",
        title: "Pallet of batteries",
        rawDescription: "Mixed lot, 20 pieces.",
        currentBid: 90,
        imageURLs: [
            URL(string: "https://cdn.example.test/lot-310-1.jpg")!,
            URL(string: "https://cdn.example.test/lot-310-2.jpg")!
        ],
        detailURL: nil
    )

    // Two downloads of the same photograph, one reading, one reconciliation — four steps, not five.
    let repeated = detailedPNGBytes(seed: 11)
    let script = StubScript([
        .init(status: 200, body: repeated, headers: ["Content-Type": "image/png"]),
        .init(status: 200, body: repeated, headers: ["Content-Type": "image/png"]),
        .init(status: 200, body: photoReadingBody(name: "Energizer MAX AA batteries", quantity: 6)),
        .init(status: 200, body: successBody)
    ])
    let service = makeService(
        script,
        requestsPerMinute: 0,
        maxAttempts: 1,
        photoScan: PhotoScanPlan.thorough(modelID: "gemini-2.5-flash", concurrency: 1),
        store: store
    )

    do {
        let outcome = try await service.value(subject: subject)

        check(outcome.readings.count == 1,
              "one reading covered both frames of the gallery",
              detail: "\(outcome.readings.count)")
        check(outcome.readings.first?.imageURL == subject.imageURLs[0],
              "and it names the frame it was actually read from",
              detail: outcome.readings.first?.imageURL.lastPathComponent ?? "nil")
        check(outcome.scanRequests == 2,
              "so the scan cost two requests — the reading and the reconciliation — rather than three",
              detail: "\(outcome.scanRequests)")
        check(outcome.groupedViews.first?.folds.map(\.frame) == [2],
              "and the outcome says which frame stood in for which",
              detail: "\(String(describing: outcome.groupedViews.first?.folds.map(\.frame)))")

        let chats = script.requests.filter { $0.url.absoluteString.contains("generateContent") }
        check(chats.count == 2, "one reading request and one reconciliation", detail: "\(chats.count)")
        check(geminiImages(in: chats.first).count == 1, "the reading carried the frame it read")
        check(geminiImages(in: chats.last) == [repeated.base64EncodedString()],
              "and the folded frame travelled with it — its own pixels, and no other photograph",
              detail: "\(geminiImages(in: chats.last).count) attached")
        check(geminiText(in: chats.last).contains("showed what another photograph showed"),
              "with the reconciliation told that a reading already covers it, before it counts anything",
              detail: String(geminiText(in: chats.last).suffix(120)))

        // And what the row shows for it: the frames that were read once, and nothing missing that the
        // single-pass appraisal would have seen.
        let row = LotItem(
            lotNumber: "310",
            currentBid: 90,
            rawDescription: "Mixed lot, 20 pieces.",
            imageUrls: [],
            title: "Pallet of batteries"
        )
        row.applyValuation(
            outcome.items,
            imagesAnalyzed: outcome.imagesSent,
            passes: outcome.passes,
            readings: outcome.readings,
            groupedViews: outcome.groupedViews
        )
        check(row.hasGroupedViews, "the row knows a frame was read once")
        check(row.groupedFrameCount == 1,
              "counts the request that was not spent",
              detail: "\(row.groupedFrameCount)")
        check(row.groupedViewsPhrase.contains("same picture"),
              "and its help line names the frame and the reason",
              detail: row.groupedViewsPhrase)
    } catch {
        tally.bump()
        print("  FAIL  unexpected error: \(error)")
    }
}

// MARK: - 35. The valuation reaches the row on the main actor

/// The crash this guards against: a scan's task body is written inside a `@MainActor` class, but a
/// task that is handed back to a cooperative thread after an `await` and then calls
/// `LotItem.applyValuation` *synchronously* trips that method's own main-queue check
/// (`dispatch_assert_queue`) instead of applying anything — an `EXC_BREAKPOINT` inside the app, not a
/// compile error. `AnalysisCoordinator` now hands every task's result over through `MainActor.run`
/// (see `onMainActor`), so this is the shape that has to hold: a valuation that arrives from a
/// cooperative thread still lands on the main actor, and the row keeps its figures.
do {
    print("35. A valuation reached from a cooperative thread is applied on the main actor")

    let lot = LotItem(
        lotNumber: "142",
        currentBid: 210,
        rawDescription: "Mixed lot, 60 pieces.",
        imageUrls: [],
        title: "Pallet of returned general merchandise"
    )
    let outcome = ValuationOutcome(
        items: [
            DiscoveredItem(
                itemName: "AA batteries, 12x 2-pack",
                confidence: "High",
                retailValue: 420,
                resaleValue: 180
            ),
            DiscoveredItem(
                itemName: "AA batteries, 24-pack",
                confidence: "Med",
                retailValue: 80,
                resaleValue: 40
            )
        ],
        imagesSent: 2,
        modelID: "gemini-2.5-flash",
        passes: 2
    )

    // A detached task runs on the cooperative pool — the thread a scan's task can be handed back to
    // after an `await`, and the one whose synchronous call into the row trips the row's own check.
    // (That call does not even compile under Swift 6: the runtime check that traps is the same
    // isolation the compiler enforces. The hop is what keeps the call legal *and* correct.)
    let arrivedOffMain = await Task.detached { () -> Bool in
        let wasOffMain = pthread_main_np() == 0
        await MainActor.run {
            lot.applyValuation(
                outcome.items,
                imagesAnalyzed: outcome.imagesSent,
                passes: outcome.passes,
                readings: outcome.readings
            )
        }
        return wasOffMain
    }.value

    check(arrivedOffMain, "the task applying it was on a cooperative thread, not the main thread")
    check(pthread_main_np() != 0, "the apply happened on the main actor")
    check(lot.totalRetail == 500, "both line items reached the row's retail total", detail: "\(lot.totalRetail)")
    check(lot.totalResale == 220, "and its resale total", detail: "\(lot.totalResale)")
    check(lot.analysisState == .completed, "the row is left completed rather than mid-scan")
}

// MARK: - 36. The progress readout counts the job that was asked for

/// Two numbers the modal's pill is built on, both of which were wrong in the same way: the denominator
/// was something other than the work in hand. A run told to walk **1 page** reported "page 1 of 4"
/// because the site's own pager said four, and a row's **Price** reported "0 of 100" because the board
/// held a hundred rows. Neither reads as a bug from inside the app — both look like work in progress —
/// which is why the two rules are pinned here.
///
/// The readout's *wording* is pinned with them, and its step and money types: the pill names a row
/// (`Evaluating Lot #19002`) or counts a batch (`Pricing Lot #3 of 12`), the step line and the bar move by
/// the *count* of photographs answered, and the bottom line speaks for the row in hand. All of it is
/// values in `RunProgress.swift`, which is the only reason any of it can be checked without a browser.
do {
    print("36. The progress readout counts the work that was asked for, and watches it step by step")

    // A one-page run of a four-page listing is a one-page job. This is the reported bug: the pill said
    // "page 1 of 4" for a run that would never read past page one.
    let onePageRun = PageWalkProgress.target(budget: 1, walksEveryPage: false, listingPages: 4)
    check(onePageRun == 1, "a 1-page budget against a 4-page listing is a 1-page job",
          detail: "\(onePageRun.map(String.init) ?? "nil")")
    check(PageWalkProgress.text(page: 1, target: onePageRun) == "page 1 of 1",
          "so the readout says page 1 of 1, not page 1 of 4",
          detail: PageWalkProgress.text(page: 1, target: onePageRun))

    // The other half of the same rule: a budget longer than the listing is the listing's length, because
    // the walk stops when the pagination runs out of pages.
    let longBudget = PageWalkProgress.target(budget: 10, walksEveryPage: false, listingPages: 4)
    check(longBudget == 4, "a 10-page budget against a 4-page listing is a 4-page job", detail: "\(longBudget ?? -1)")
    check(PageWalkProgress.text(page: 2, target: longBudget) == "page 2 of 4", "walking that one in order",
          detail: PageWalkProgress.text(page: 2, target: longBudget))

    // A site that has not reported a count leaves the budget alone, and **All pages** takes the site's
    // count or nothing at all.
    let unknown = PageWalkProgress.target(budget: 3, walksEveryPage: false, listingPages: nil)
    check(unknown == 3, "a 3-page budget on a listing with no count is 3 pages", detail: "\(unknown ?? -1)")
    check(PageWalkProgress.target(budget: 0, walksEveryPage: true, listingPages: 24) == 24,
          "All pages on a 24-page listing is 24 pages")
    check(PageWalkProgress.target(budget: 0, walksEveryPage: true, listingPages: nil) == nil,
          "and All pages with no count has no denominator to print")
    check(PageWalkProgress.text(page: 2, target: nil) == "page 2 — all pages",
          "which the readout says in words rather than inventing a number",
          detail: PageWalkProgress.text(page: 2, target: nil))

    // The bar counts the page being read as well as the pages already read, so a one-page run creeps as
    // the board fills instead of standing at nothing and then snapping to full.
    check(PageWalkProgress.fraction(pagesRead: 0, pageRowsLanded: 0, pageRowsOnPage: 24, target: 1) == 0,
          "a one-page walk starts at nothing")
    check(PageWalkProgress.fraction(pagesRead: 0, pageRowsLanded: 12, pageRowsOnPage: 24, target: 1) == 0.5,
          "and creeps with the page's own cards",
          detail: String(describing: PageWalkProgress.fraction(pagesRead: 0, pageRowsLanded: 12, pageRowsOnPage: 24, target: 1)))
    check(PageWalkProgress.fraction(pagesRead: 1, pageRowsLanded: 24, pageRowsOnPage: 24, target: 1) == 1,
          "so when the page is read the walk is done")
    check(PageWalkProgress.fraction(pagesRead: 1, pageRowsLanded: 0, pageRowsOnPage: 24, target: 3) == 1.0 / 3.0,
          "a three-page walk stands a third of the way along after page one",
          detail: String(describing: PageWalkProgress.fraction(pagesRead: 1, pageRowsLanded: 0, pageRowsOnPage: 24, target: 3)))
    check(PageWalkProgress.fraction(pagesRead: 1, pageRowsLanded: 12, pageRowsOnPage: 24, target: 3) == 0.5,
          "and adds the share of the page it is on to the pages it has read",
          detail: String(describing: PageWalkProgress.fraction(pagesRead: 1, pageRowsLanded: 12, pageRowsOnPage: 24, target: 3)))
    check(PageWalkProgress.fraction(pagesRead: 1, pageRowsLanded: 30, pageRowsOnPage: 24, target: 1) == 1,
          "a page that under-reported its cards cannot push the bar past full")
    check(PageWalkProgress.fraction(pagesRead: 2, pageRowsLanded: 3, pageRowsOnPage: 5, target: nil) == nil,
          "and an All pages walk with no count still has no fraction to print")

    // A row's button is a one-row job, whatever the board holds — the second half of the reported bug —
    // and the pill names the row it was pressed on rather than counting rows nobody asked about.
    let row = UUID()
    let rowPrice = AppraisalJob(kind: .price, lotIDs: [row], isBatch: false)
    let rowEval = AppraisalJob(kind: .eval, lotIDs: [row], isBatch: false)
    check(rowPrice.text(.init(lotNumber: "19002", answered: 0)) == "Pricing Lot #19002",
          "a row's Price names the lot it was pressed on",
          detail: rowPrice.text(.init(lotNumber: "19002", answered: 0)))
    check(rowEval.text(.init(lotNumber: "19002", answered: 1)) == "Evaluating Lot #19002",
          "and a row's Eval names its own verb",
          detail: rowEval.text(.init(lotNumber: "19002", answered: 1)))
    check(rowPrice.text(.init(answered: 0)) == "Pricing 0 of 1",
          "a row whose lot number is unknown still reports the job it covers",
          detail: rowPrice.text(.init(answered: 0)))

    // A batch counts its way through the rows the button was built for: the board's count is not the job
    // when the board holds lots the button has decided to leave alone.
    let batchEval = AppraisalJob(kind: .eval, lotIDs: (0..<40).map { _ in UUID() }, isBatch: true)
    let batchPrice = AppraisalJob(kind: .price, lotIDs: (0..<12).map { _ in UUID() }, isBatch: true)
    check(batchEval.text(.init(index: 4, answered: 3)) == "Evaluating Lot #4 of 40",
          "Eval all counts its way through the pending set it covers",
          detail: batchEval.text(.init(index: 4, answered: 3)))
    check(batchPrice.text(.init(index: 3, answered: 2)) == "Pricing Lot #3 of 12",
          "and so does Price all",
          detail: batchPrice.text(.init(index: 3, answered: 2)))
    check(batchPrice.text(.init(lotNumber: "19002", index: nil, answered: 2)) == "Pricing Lot #2 of 12",
          "a batch's place is a position, never some board's lot number",
          detail: batchPrice.text(.init(lotNumber: "19002", index: nil, answered: 2)))
    check(batchPrice.text(.init(answered: 12)) == "Pricing Lot #12 of 12",
          "with no row in hand the answered count is the same statement one row behind",
          detail: batchPrice.text(.init(answered: 12)))
    check(batchPrice.text(.init(index: 13, answered: 12)) == "Pricing Lot #12 of 12",
          "and a place past the job cannot print of 12 on row 13",
          detail: batchPrice.text(.init(index: 13, answered: 12)))
    check(batchEval.isBatch && !rowEval.isBatch, "the batch flag, not the count, is what names the button")

    // Clicking through several rows at once is allowed, so the second click joins the job in hand instead
    // of re-pointing the readout at itself: two rows at work must not read as 1 of 1.
    var joined = rowPrice
    let secondRow = UUID()
    joined.include(secondRow)
    check(joined.count == 2, "a second Price click joins the job in hand", detail: "\(joined.count)")
    check(joined.position(of: secondRow) == 2 && joined.position(of: row) == 1,
          "and the rows keep the order they joined in, which is what a batch's place is read off")
    check(joined.text(.init(lotNumber: "19002", index: 2, answered: 1)) == "Pricing Lot #19002",
          "a joined row job still names its lot rather than counting rows",
          detail: joined.text(.init(lotNumber: "19002", index: 2, answered: 1)))
    check(joined.text(.init(answered: 1)) == "Pricing 1 of 2",
          "while the count behind it knows there are two rows at work",
          detail: joined.text(.init(answered: 1)))
    check(joined.lotIDs.contains(secondRow) && joined.lotIDs.count == 2, "and covers both rows")
    check(joined.position(of: UUID()) == nil, "a row outside the job has no place in it")

    // The readout's step: what the modal prints while a row is mid-appraisal, and the share of that row
    // the bar counts. One update per photograph is the whole point — a scan is a dozen requests, and a bar
    // that only moved when a row landed said "nothing is happening" for minutes at a time.
    //
    // What those updates *count* is the other half of the fix. A nine-frame scan read as `1 of 9`, `7 of 9`,
    // `3 of 9` because the step named the frame in flight, and the reads run three at a time
    // (`PhotoScanPlan.defaultConcurrency`), so the numbers came back in the order the provider answered
    // them. The step is the count of frames with an answer instead — which cannot go backwards — and the
    // frame number stays on the console line (`PhotoScanEvent.message`), where it is a fact rather than an
    // order.
    check(AppraisalStep.readingPage.phrase == "reading the lot's own page",
          "a row's first step is its own page", detail: AppraisalStep.readingPage.phrase)
    check(AppraisalStep.photograph(answered: 5, of: 12).phrase == "5 of 12 photograph(s) answered",
          "a scan counts the photographs it has answered",
          detail: AppraisalStep.photograph(answered: 5, of: 12).phrase)
    check(AppraisalStep.reconciling(readings: 12).phrase == "reconciling 12 reading(s) into the line items",
          "and the reconciliation that closes it out",
          detail: AppraisalStep.reconciling(readings: 12).phrase)
    let ladder = [
        AppraisalStep.readingPage.share,
        AppraisalStep.evaluatingText.share,
        AppraisalStep.photograph(answered: 1, of: 12).share,
        AppraisalStep.photograph(answered: 12, of: 12).share,
        AppraisalStep.reconciling(readings: 12).share
    ]
    check(zip(ladder, ladder.dropFirst()).allSatisfy { $0 < $1 }, "the steps fill the bar in order",
          detail: ladder.map { String(format: "%.2f", $0) }.joined(separator: " < "))
    check(ladder.allSatisfy { $0 > 0 && $0 < 1 }, "and none of them is a whole row: only an answer is",
          detail: ladder.map { String(format: "%.2f", $0) }.joined(separator: ", "))
    check(AppraisalStep.photograph(answered: 40, of: 3).share < 1,
          "counting more frames than the gallery holds cannot claim the row either")
    // Each answered photograph is the same slice of the row, which is the "add n percent per photograph"
    // the bar is supposed to do: nine answers are nine even steps from the base to the reconciliation.
    let nineFrames = (1...9).map { AppraisalStep.photograph(answered: $0, of: 9).share }
    let slice = 0.7 / 9
    check(zip(nineFrames, nineFrames.dropFirst()).allSatisfy { abs($1 - $0 - slice) < 1e-9 },
          "each answered photograph adds the same slice of the row",
          detail: nineFrames.map { String(format: "%.3f", $0) }.joined(separator: " "))

    // The reported bug, as the reports a nine-frame scan actually sends with three reads in flight: frames
    // land as the provider answers them, so the frame numbers run 1, 2, 3, 2, 4, 5, 1, 3, 6, 8, 4, 9, 7 —
    // the old step said `photograph 7 of 9` and then `photograph 3 of 9`. Counted answers cannot do that.
    let scan: [PhotoScanEvent] = [
        .reading(index: 1, of: 9, answered: 0, reused: false),
        .reading(index: 2, of: 9, answered: 0, reused: false),
        .reading(index: 3, of: 9, answered: 0, reused: false),
        .read(index: 2, of: 9, answered: 1, objects: 3),
        .reading(index: 4, of: 9, answered: 1, reused: false),
        .read(index: 5, of: 9, answered: 2, objects: 2),
        .read(index: 1, of: 9, answered: 3, objects: 4),
        .read(index: 3, of: 9, answered: 4, objects: 1),
        .failed(index: 6, of: 9, answered: 5, reason: "no answer"),
        .read(index: 8, of: 9, answered: 6, objects: 2),
        .read(index: 4, of: 9, answered: 7, objects: 3),
        .read(index: 9, of: 9, answered: 8, objects: 5),
        .read(index: 7, of: 9, answered: 9, objects: 1),
        .aggregating(photographs: 8, leftovers: 1)
    ]
    let steps = scan.compactMap { AppraisalStep($0) }
    let shares = steps.map(\.share)
    check(zip(shares, shares.dropFirst()).allSatisfy { $0 <= $1 },
          "a scan whose frames land out of order still fills the bar forwards",
          detail: shares.map { String(format: "%.2f", $0) }.joined(separator: " "))
    let counted = steps.compactMap { step -> Int? in
        guard case .photograph(let answered, _) = step else { return nil }
        return answered
    }
    check(counted == [0, 0, 0, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9],
          "and its count grows by the answers behind it, one frame at a time",
          detail: counted.map(String.init).joined(separator: " "))
    check(
        AppraisalStep(PhotoScanEvent.read(index: 3, of: 12, answered: 4, objects: 2))
            == .photograph(answered: 4, of: 12),
        "a scan's own report maps onto the readout's step"
    )
    check(
        AppraisalStep(PhotoScanEvent.reading(index: 9, of: 12, answered: 4, reused: false))
            == AppraisalStep(PhotoScanEvent.read(index: 2, of: 12, answered: 4, objects: 1)),
        "frame 9 starting where frame 2 landed is the same step: the frame is not the bar's business"
    )
    check(
        AppraisalStep(PhotoScanEvent.failed(index: 7, of: 12, answered: 4, reason: "no answer"))
            == .photograph(answered: 4, of: 12),
        "and a frame that could not be read is an answer too"
    )
    check(
        AppraisalStep(PhotoScanEvent.reading(index: 1, of: 12, answered: 1, reused: true))
            == .photograph(answered: 1, of: 12),
        "as is one restored from this machine's store"
    )
    check(AppraisalStep(PhotoScanEvent.aggregating(photographs: 12, leftovers: 0)) == .reconciling(readings: 12),
          "and so does its reconciliation")
    check(AppraisalStep(PhotoScanEvent.aggregated(items: 4)) == nil,
          "while a reconciliation that landed starts no step of its own")
    check(AppraisalStep(PhotoScanEvent.fallingBack(reason: "no readings")) == .wholeGallery,
          "the single-pass fallback is a step too")

    // The same claim measured against a scan that really runs, rather than against a list of events typed
    // out by hand: three photographs read three at a time report `reading` before any of them lands, then
    // answers one at a time, and never a number smaller than the one before. This is the half of the fix
    // that lives in the pipeline (`LotPhotoScan`), and it is the reason the step can promise a count.
    do {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lotlogic-readout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let subject = ValuationSubject(
            lotNumber: "311",
            title: "Pallet of batteries",
            rawDescription: "Mixed lot, 20 pieces.",
            currentBid: 90,
            imageURLs: (1...3).map { URL(string: "https://cdn.example.test/lot-311-\($0).jpg")! },
            detailURL: nil
        )
        let script = StubScript([
            photoStep(),
            photoStep(),
            photoStep(),
            .init(status: 200, body: photoReadingBody(name: "Energizer MAX AA batteries", quantity: 2)),
            .init(status: 200, body: photoReadingBody(name: "Duracell AA batteries", quantity: 3)),
            .init(status: 200, body: photoReadingBody(name: "Panasonic AA batteries", quantity: 4)),
            .init(status: 200, body: successBody)
        ])
        let log = ReportLog()
        let service = makeService(
            script,
            requestsPerMinute: 0,
            maxAttempts: 1,
            photoScan: PhotoScanPlan.thorough(modelID: "gemini-2.5-flash", concurrency: 3),
            store: PhotoReadingStore(directory: directory),
            report: { log.note($0) }
        )
        do {
            let outcome = try await service.value(subject: subject)
            let counts = log.answeredCounts
            check(outcome.readings.count == 3,
                  "a three-frame gallery read three at a time is three readings",
                  detail: "\(outcome.readings.count)")
            check(counts.count == 6,
                  "and six frame reports: one announcement and one answer for each of them",
                  detail: counts.map(String.init).joined(separator: " "))
            check(zip(counts, counts.dropFirst()).allSatisfy { $0 <= $1 },
                  "the counts a real scan reports never go backwards",
                  detail: counts.map(String.init).joined(separator: " "))
            check(counts.first == 0 && counts.last == 3,
                  "running from nothing to the gallery's own size",
                  detail: counts.map(String.init).joined(separator: " "))
            check(counts.prefix(3) == [0, 0, 0],
                  "with the three frames announced before any of them had landed",
                  detail: counts.map(String.init).joined(separator: " "))
        } catch {
            tally.bump()
            print("  FAIL  unexpected error: \(error)")
        }
    }

    // The modal's bottom line speaks for the row in hand: `Retail` there is that row's own figure, and the
    // difference between what it resells for and what is bid on it is the one number the line derives.
    check(LotMoney(currentBid: 75, retail: 420, resale: 310, provisional: true).profit == 235,
          "the money line's profit is the row's own resale over its current bid")
}

// MARK: - 37. The checked rows

do {
    print("37. The checked rows: what the box over the table shows, and which way its click goes")

    let a = UUID(), b = UUID(), c = UUID()
    let drawn = [a, b, c]

    // Nothing checked is not "all checked", and the empty table is the case that matters: a filled box
    // over no rows would be a promise there is nothing behind.
    var checked = LotSelection()
    check(checked.isEmpty && checked.count == 0, "a fresh table has nothing checked")
    check(checked.scope(of: drawn) == .none, "which reads as an empty box over the rows")
    check(checked.scope(of: []).selectsOnClick, "and a click on an empty box would fill, not clear")

    // One hand-picked row: the box reads mixed, and a click there *adds* rather than clears. That
    // direction is the whole point of `.some` — a click must never throw away the picked rows.
    checked.toggle(b)
    check(checked.contains(b) && checked.count == 1, "a row's own checkbox checks that row and no other")
    check(checked.scope(of: drawn) == .some, "one of three reads as a mixed box", detail: "\(checked.scope(of: drawn))")
    check(checked.scope(of: drawn).selectsOnClick, "and the mixed box fills the table rather than emptying it")
    checked.toggle(b)
    check(checked.isEmpty, "clicking the same row again is what unchecks it")

    // The header's box, both directions, off the same click.
    checked.toggle(b)
    checked.toggleAll(drawn)
    check(checked.scope(of: drawn) == .all, "the box's click checks every row it speaks for")
    check(checked.count == 3, "and nothing else", detail: "\(checked.count)")
    check(!checked.scope(of: drawn).selectsOnClick, "a full box is the one state whose click empties")
    checked.toggleAll(drawn)
    check(checked.isEmpty, "which is what it does")

    // The box speaks for the rows *drawn*, not the board: with a search standing, a click may not
    // reach past what is on screen, and it may not disturb what it cannot see either.
    checked.selectAll([b])
    checked.toggleAll([a])
    check(checked.contains(a) && checked.contains(b) && !checked.contains(c),
          "a click during a search checks the rows shown and leaves the rest alone",
          detail: "\(checked.count) checked")
    check(checked.scope(of: [a]) == .all && checked.scope(of: drawn) == .some,
          "so the same set can be 'all' of what is drawn and 'some' of what is not")

    // The menu's two items, which name a direction instead of guessing one.
    checked.selectAll(drawn)
    check(checked.scope(of: drawn) == .all, "Select all checks the rows it is given, whatever they were")
    checked.selectAll(drawn)
    check(checked.count == 3, "and repeating it changes nothing")
    checked.deselectAll([b])
    check(!checked.contains(b) && checked.count == 2, "Deselect all clears the rows it is given")
    checked.deselectAll(drawn)
    check(checked.isEmpty, "including when every row is already clear")

    // A check belongs to a lot, so a run that replaces the board drops the ids that are gone — and
    // keeps the ones that are still there.
    checked.selectAll(drawn)
    checked.prune(to: [b, UUID()])
    check(checked.ids == [b], "pruning drops the checked lots that left the board", detail: "\(checked.count) left")
    checked.prune(to: [b])
    check(checked.contains(b), "and a check on a lot that is still there survives the run")
    checked.prune(to: [])
    check(checked.isEmpty, "an empty board clears the selection rather than keeping it alive")
}

// MARK: - 38. DeepSeek: the batched manifest route

do {
    print("38. DeepSeek reads a gallery in batches into a manifest, then prices it in one text-only request")
    let script = StubScript([
        .init(status: 200, body: frameBytes(1), headers: ["Content-Type": "image/jpeg"]), // frame 1
        .init(status: 200, body: frameBytes(2), headers: ["Content-Type": "image/jpeg"]), // frame 2
        .init(status: 200, body: frameBytes(3), headers: ["Content-Type": "image/jpeg"]), // frame 3
        // Batch 1 saw the candles twice and read the model number; batch 2 saw them again from the side.
        .init(status: 200, body: manifestBody([
            StubManifestLine(
                name: "Yankee Candle 22 oz jar", brand: "Yankee Candle", model: "1631666",
                quantity: 6, views: [1, 2], identifiers: ["609032993551"]
            )
        ])),
        .init(status: 200, body: manifestBody([
            StubManifestLine(name: "Yankee Candle 22oz jar", brand: "Yankee", quantity: 4, views: [3]),
            StubManifestLine(name: "Energizer MAX AA, 24-pack", brand: "Energizer", quantity: 2, views: [3])
        ])),
        .init(status: 200, body: deepSeekSuccessBody) // the pricing pass
    ])
    let service = makeDeepSeekService(script, requestsPerMinute: 0, maxAttempts: 1, photosPerRequest: 2)
    let outcome = try await service.value(subject: threePhotoSubject)

    check(outcome.passes == 3, "three requests produced the figures: two batches and one pricing pass", detail: "\(outcome.passes)")
    check(outcome.imagesSent == 3, "every photograph of the gallery travelled", detail: "\(outcome.imagesSent)")
    let manifest = outcome.manifest ?? PalletManifest()
    check(manifest.count == 2, "the batches folded into two distinct items, not three", detail: "\(manifest.count)")
    check(manifest.items.first?.quantity == 6, "a product seen in both batches keeps the larger count, not the sum", detail: "\(manifest.items.first?.quantity ?? -1)")
    check(manifest.items.first?.views == [1, 2, 3], "and names every photograph it was seen in", detail: "\(manifest.items.first?.views ?? [])")
    check(manifest.items.first?.brand == "Yankee Candle", "the batch that named the brand properly keeps the field")
    check(manifest.items.first?.modelNumber == "1631666", "and the model number survives from the batch that read it")
    check(manifest.unitCount == 8, "the inventory accounts for 6 candles and 2 battery packs", detail: "\(manifest.unitCount)")
    check(manifest.photographCount == 3, "read across all three photographs", detail: "\(manifest.photographCount)")
    check(outcome.items.count == 1, "the pricing pass's line items are the outcome", detail: "\(outcome.items.count)")

    let chats = script.requests.filter { $0.url.absoluteString == "https://api.deepseek.com/chat/completions" }
    check(chats.count == 3, "two manifest requests and one pricing request were posted", detail: "\(chats.count)")

    // Batches are sent a few at a time, so which one the stub answered first is not a fact about the app:
    // the requests are identified by what they carry, not by the order they arrived in.
    let firstBatchChat = chats.first { userText(in: $0).contains("Batch 1 of 2") }
    let secondBatchChat = chats.first { userText(in: $0).contains("Batch 2 of 2") }
    let pricingChat = chats.first { imageURLs(in: $0).isEmpty }
    check(imageURLs(in: firstBatchChat).count == 2, "the first batch carries two photographs", detail: "\(imageURLs(in: firstBatchChat).count)")
    check(imageURLs(in: secondBatchChat).count == 1, "the second carries the one left over", detail: "\(imageURLs(in: secondBatchChat).count)")
    check(imageURLs(in: pricingChat).isEmpty, "the pricing request carries no photographs at all")

    let firstBatch = userText(in: firstBatchChat)
    check(firstBatch.contains("Batch 1 of 2"), "the batch says which it is", detail: String(firstBatch.prefix(80)))
    check(firstBatch.contains("photographs 1-2 of 3 are attached"), "and states the gallery numbers it carries, which is what views is answered in")
    check(userText(in: secondBatchChat).contains("photograph 3 of 3 is attached"), "the last batch says its single frame is attached")
    check(systemText(in: firstBatchChat).contains("cataloguing ONE liquidation-auction pallet"), "the batch gets the manifest instruction")
    check(systemText(in: firstBatchChat).contains("SAME pallet"), "which is where the deduplication rule lives")
    check(firstBatch.contains("Pallet of candles and batteries"), "the batch receives the scraped listing text")
    check(firstBatch.contains("\"manifest\""), "and the schema it must answer in")
    check(firstBatch.contains("additionalProperties"), "rendered in full, as JSON mode requires")

    let pricing = userText(in: pricingChat)
    check(systemText(in: pricingChat).contains("No photographs are attached"), "the pricing instruction says what it is pricing from")
    check(pricing.contains("1631666"), "the pricing prompt is handed the model number the batches read")
    check(pricing.contains("609032993551"), "and the barcode digits")
    check(pricing.contains("2 distinct item(s)"), "with the inventory's own size stated", detail: String(pricing.prefix(120)))
    check(pricing.contains("8 unit(s)"), "and its unit count", detail: String(pricing.prefix(120)))
    check(pricing.lowercased().contains("json"), "and the word json, which JSON mode requires")
    check(pricing.contains("\"itemName\""), "plus the line-item schema it must answer in")

    for (index, chat) in chats.enumerated() {
        let format = chat.json["response_format"] as? [String: Any]
        check(format?["type"] as? String == "json_object", "request \(index + 1) asked for JSON object mode", detail: "\(format ?? [:])")
    }
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 39. The manifest's own fold

do {
    print("39. A product seen twice is one manifest line, and an empty manifest is not an error")
    var manifest = PalletManifest()
    manifest.absorb([
        ManifestItem(
            itemName: "Yankee Candle 22 oz jar", brand: "Yankee Candle", modelNumber: "1631666",
            category: "household", quantity: 6, condition: "new", identifiers: ["609032993551"],
            labelText: "Yankee Candle 22 oz", confidence: "High", views: [1, 2]
        )
    ])
    manifest.absorb([
        ManifestItem(itemName: "yankee candle, 22oz jar", brand: "Yankee", quantity: 9, confidence: "Low", views: [3]),
        ManifestItem(itemName: "Energizer MAX AA, 24-pack", brand: "Energizer", quantity: 2, views: [4, 5])
    ])

    check(manifest.count == 2, "two products, however many batches saw them", detail: "\(manifest.count)")
    check(manifest.items[0].quantity == 9, "the larger count wins — a second angle is not more goods", detail: "\(manifest.items[0].quantity)")
    check(manifest.items[0].views == [1, 2, 3], "views accumulate", detail: "\(manifest.items[0].views)")
    check(manifest.items[0].modelNumber == "1631666", "a field one batch read is kept when the other did not")
    check(manifest.items[0].condition == "new" && manifest.items[0].labelText == "Yankee Candle 22 oz",
          "and the same for the condition and the label wording")
    check(manifest.items[0].confidence == "High", "confidence keeps the strongest of the two sightings", detail: manifest.items[0].confidence)
    check(manifest.items[0].confidenceLevel == .high, "which normalises to the typed vocabulary")
    check(manifest.items[0].detailPhrase.contains("photographs 1, 2, 3"), "the card's line names the frames", detail: manifest.items[0].detailPhrase)
    check(manifest.unitCount == 11 && manifest.photographCount == 5, "the roll-ups count units and frames", detail: manifest.logPhrase)
    check(manifest.compactPhrase == "2 item(s) · 11 unit(s)", "and the row's shorter form reads off the same numbers", detail: manifest.compactPhrase)

    // A different model number is a different product, whatever the name says.
    var split = PalletManifest()
    split.absorb([ManifestItem(itemName: "AA batteries", modelNumber: "E91BP-24", quantity: 1)])
    split.absorb([ManifestItem(itemName: "AA batteries", modelNumber: "E91BP-48", quantity: 1)])
    check(split.count == 2, "two model numbers are two products", detail: "\(split.count)")

    // The decode, both ways: an empty inventory is an answer, garbage is a failure.
    let empty = try LotManifestAnswer.items(fromAnswerText: #"{"manifest":[]}"#, finishReason: "stop")
    check(empty.isEmpty, "an empty manifest decodes to no items rather than failing")
    let decoded = try LotManifestAnswer.items(
        fromAnswerText: #"{"manifest":[{"itemName":" Candles ","quantity":6.0,"views":[1,1,2],"confidence":"high"}]}"#,
        finishReason: "stop"
    )
    check(decoded.count == 1 && decoded[0].itemName == "Candles", "one line decodes with its wording tidied", detail: decoded.first?.itemName ?? "—")
    check(decoded[0].quantity == 6, "a JSON-mode 6.0 is six units", detail: "\(decoded[0].quantity)")
    check(decoded[0].views == [1, 2], "views are deduped and sorted", detail: "\(decoded[0].views)")
    check(decoded[0].confidence == "High", "and confidence is normalised", detail: decoded[0].confidence)

    var threw = false
    do { _ = try LotManifestAnswer.items(fromAnswerText: #"{"items":[]}"#, finishReason: "stop") } catch { threw = true }
    check(threw, "an answer with no manifest key fails rather than reading as an empty pallet")

    let rendered = LotManifestPrompt.render(manifest)
    check(rendered.omitted == 0 && rendered.text.hasPrefix("["), "the pricing prompt's manifest slab renders as a JSON array")
    check(rendered.text.contains("1631666") && !rendered.text.contains("\"id\""),
          "with the model numbers in it and no ids, because the model never produced one")

    // A reply can only enumerate so much, so a long inventory is priced in pieces.
    let thirteen = PalletManifest(items: (1...13).map { ManifestItem(itemName: "Item \($0)", quantity: 1) })
    let pieces = thirteen.batches(ofSize: 12)
    check(pieces.count == 2, "thirteen items are two reply-sized pieces", detail: "\(pieces.count)")
    check(pieces.map(\.count) == [12, 1], "twelve and the one left over", detail: "\(pieces.map(\.count))")
    check(thirteen.batches(ofSize: 12).flatMap(\.items).count == 13, "and nothing is lost in the split")
    check(thirteen.batches(ofSize: 20).count == 1, "an inventory that fits one reply stays one piece")
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 40. Splitting a gallery into batches

do {
    print("40. A gallery is split into batches by frame count and by bytes, and every frame travels")
    func image(_ index: Int, bytes: Int) -> LotImage {
        LotImage(
            mimeType: "image/jpeg",
            base64: "",
            byteCount: bytes,
            sourceURL: URL(string: "https://cdn.example.test/frame-\(index).jpg")!
        )
    }
    let images = (1...7).map { image($0, bytes: $0 * 100) }

    let byCount = LotImageLoader.batches(of: images, width: 3, perRequestBytes: 1_000_000)
    check(byCount.map(\.count) == [3, 3, 1], "batches take three frames each, the last one short", detail: "\(byCount.map(\.count))")
    check(byCount.flatMap(\.self).map(\.sourceURL) == images.map(\.sourceURL),
          "every frame travels exactly once, in gallery order")
    check(byCount.flatMap(\.self).count == images.count, "nothing is dropped and nothing is duplicated")

    // 100 + 200 fits 350; 300 on top of that does not, so the batch closes and the next one starts.
    let byBytes = LotImageLoader.batches(of: images, width: 10, perRequestBytes: 350)
    check(byBytes.map(\.count) == [2, 1, 1, 1, 1, 1], "a byte ceiling splits the run too", detail: "\(byBytes.map(\.count))")
    check(byBytes.allSatisfy { !$0.isEmpty }, "and no batch is ever empty")

    // A single frame larger than the whole budget travels on its own rather than stalling the walk.
    let oversized = LotImageLoader.batches(of: [image(1, bytes: 900), image(2, bytes: 900)], width: 5, perRequestBytes: 500)
    check(oversized.map(\.count) == [1, 1], "a frame over the budget goes alone", detail: "\(oversized.map(\.count))")

    let zeroWidth = LotImageLoader.batches(of: images, width: 0, perRequestBytes: 1_000_000)
    check(zeroWidth.map(\.count) == Array(repeating: 1, count: 7), "a width of zero reads one frame per batch", detail: "\(zeroWidth.map(\.count))")
    check(LotImageLoader.batches(of: [], width: 6, perRequestBytes: 1_000).isEmpty, "an empty gallery makes no batches")
}

// MARK: - 41. A batched route that finds nothing falls back

do {
    print("41. A manifest of nothing falls back to the gallery pass rather than failing the lot")
    let script = StubScript([
        .init(status: 200, body: jpegBytes, headers: ["Content-Type": "image/jpeg"]), // the photograph
        .init(status: 200, body: manifestBody([])),                                   // the batch: nothing sellable
        .init(status: 200, body: deepSeekSuccessBody),                                // the text pass
        .init(status: 200, body: deepSeekSuccessBody)                                 // the gallery pass
    ])
    let reports = ReportLog()
    let service = makeDeepSeekService(
        script,
        requestsPerMinute: 0,
        maxAttempts: 1,
        photosPerRequest: 4,
        report: { reports.note($0) }
    )
    let outcome = try await service.value(subject: onePhotoSubject)

    check(outcome.items.count == 1, "the lot is still valued", detail: "\(outcome.items.count)")
    check(outcome.manifest == nil, "with no inventory to show, because there was not one")
    check(outcome.passes == 2, "so the two-pass route ran instead", detail: "\(outcome.passes)")
    check(outcome.imagesSent == 1, "and the photograph travelled with the gallery pass", detail: "\(outcome.imagesSent)")
    check(
        reports.events.contains { if case .fallingBackFromManifest = $0 { return true } else { return false } },
        "and the console was told why the batch route was abandoned"
    )
    check(
        reports.events.contains { if case .manifesting = $0 { return true } else { return false } },
        "after announcing the batch it was about to send"
    )
    let chats = script.requests.filter { $0.url.absoluteString == "https://api.deepseek.com/chat/completions" }
    check(chats.count == 3, "batch, text pass, gallery pass", detail: "\(chats.count)")
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 42. A fallback out of the batched route trims to one request

do {
    print("42. A gallery the batches could hold is trimmed back to one request when the route falls back")
    let budget = jpegBytes.count + 10 // one frame fits one request; two do not
    let script = StubScript([
        .init(status: 200, body: frameBytes(1), headers: ["Content-Type": "image/jpeg"]),
        .init(status: 200, body: frameBytes(2), headers: ["Content-Type": "image/jpeg"]),
        .init(status: 200, body: frameBytes(3), headers: ["Content-Type": "image/jpeg"]),
        .init(status: 200, body: manifestBody([])), // batch 1: nothing sellable
        .init(status: 200, body: manifestBody([])), // batch 2
        .init(status: 200, body: manifestBody([])), // batch 3
        .init(status: 200, body: deepSeekSuccessBody), // the text pass
        .init(status: 200, body: deepSeekSuccessBody)  // the gallery pass
    ])
    let service = makeDeepSeekService(
        script,
        requestsPerMinute: 0,
        maxAttempts: 1,
        maxTotalImageBytes: budget,
        photosPerRequest: 6
    )
    let outcome = try await service.value(subject: threePhotoSubject)

    check(outcome.items.count == 1, "the lot is still valued", detail: "\(outcome.items.count)")
    check(outcome.imagesSent == 1, "the fallback carried one request's worth of the gallery", detail: "\(outcome.imagesSent)")
    check(outcome.imagesSkipped == 2, "and counted the two frames that would not fit", detail: "\(outcome.imagesSkipped)")

    let chats = script.requests.filter { $0.url.absoluteString == "https://api.deepseek.com/chat/completions" }
    check(chats.count == 5, "three batches, the text pass and the gallery pass", detail: "\(chats.count)")
    check(imageURLs(in: chats.last).count == 1, "the gallery pass carried exactly the frame that fits", detail: "\(imageURLs(in: chats.last).count)")
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 43. A long inventory is priced in reply-sized pieces

do {
    print("43. A 13-item manifest is priced in two requests rather than one truncated reply")
    let lines = (1...13).map { StubManifestLine(name: "Item \($0)", quantity: 1, views: [$0]) }
    let script = StubScript([
        .init(status: 200, body: jpegBytes, headers: ["Content-Type": "image/jpeg"]),
        .init(status: 200, body: manifestBody(lines)),
        .init(status: 200, body: deepSeekSuccessBody),
        .init(status: 200, body: deepSeekSuccessBody)
    ])
    let service = makeDeepSeekService(script, requestsPerMinute: 0, maxAttempts: 1, photosPerRequest: 6)
    let outcome = try await service.value(subject: onePhotoSubject)

    check(outcome.manifest?.count == 13, "the batch's thirteen items became the manifest", detail: "\(outcome.manifest?.count ?? -1)")
    check(outcome.passes == 3, "one batch plus two pricing requests", detail: "\(outcome.passes)")

    let chats = script.requests.filter { $0.url.absoluteString == "https://api.deepseek.com/chat/completions" }
    check(chats.count == 3, "one batch and two text-only pricing requests", detail: "\(chats.count)")
    check(imageURLs(in: chats[1]).isEmpty && imageURLs(in: chats[2]).isEmpty,
          "neither pricing request carries a photograph")
    check(userText(in: chats[1]).contains("12 distinct item(s)"), "the first piece holds twelve", detail: String(userText(in: chats[1]).prefix(110)))
    check(userText(in: chats[2]).contains("1 distinct item(s)"), "the second holds the one left over", detail: String(userText(in: chats[2]).prefix(110)))
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 44. A photograph the gallery lists twice travels once

do {
    print("44. The batched route sends a repeated photograph once, and says what it left out")
    // What a re-listed lot offers: the same picture at two addresses, and a photograph of something
    // else. Identical pixels are the only fold this route makes, and the one that cannot lose anything —
    // there is nothing in the second copy that the first does not show.
    let picture = detailedPNGBytes(seed: 1)
    let other = detailedPNGBytes(seed: 2)
    let repeatedSubject = ValuationSubject(
        lotNumber: "311",
        title: "Pallet of candles",
        rawDescription: "Mixed lot, 20 pieces.",
        currentBid: 60,
        imageURLs: [
            URL(string: "https://cdn.example.test/lot-311-1.jpg")!,
            URL(string: "https://cdn.example.test/lot-311-2.jpg")!,
            URL(string: "https://cdn.example.test/lot-311-3.jpg")!
        ],
        detailURL: nil
    )
    let script = StubScript([
        .init(status: 200, body: picture, headers: ["Content-Type": "image/png"]), // frame 1
        .init(status: 200, body: picture, headers: ["Content-Type": "image/png"]), // frame 2: the same file
        .init(status: 200, body: other, headers: ["Content-Type": "image/png"]),   // frame 3
        .init(status: 200, body: manifestBody([
            StubManifestLine(
                name: "Yankee Candle 22 oz jar", brand: "Yankee Candle", quantity: 6, views: [1]
            )
        ])),
        .init(status: 200, body: manifestBody([
            StubManifestLine(name: "Yankee Candle 22oz jar", brand: "Yankee", quantity: 4, views: [3])
        ])),
        .init(status: 200, body: deepSeekSuccessBody) // the pricing pass
    ])
    let reports = ReportLog()
    let service = makeDeepSeekService(
        script,
        requestsPerMinute: 0,
        maxAttempts: 1,
        photosPerRequest: 1,
        report: { reports.note($0) }
    )
    let outcome = try await service.value(subject: repeatedSubject)

    check(outcome.items.count == 1, "the lot is valued", detail: "\(outcome.items.count)")
    check(outcome.manifest?.count == 1,
          "and the two sightings became one manifest line, however each batch named it",
          detail: "\(outcome.manifest?.count ?? -1)")

    let chats = script.requests.filter { $0.url.absoluteString == "https://api.deepseek.com/chat/completions" }
    check(chats.count == 3, "two batches and one pricing request were posted", detail: "\(chats.count)")
    let batches = chats.filter { !imageURLs(in: $0).isEmpty }
    check(batches.count == 2, "only the frames that are not repeats were sent", detail: "\(batches.count)")
    let sent = batches.flatMap { imageURLs(in: $0) }
    check(sent.count == 2 && Set(sent).count == 2,
          "and the two that were sent are different photographs, not one picture bought twice",
          detail: "\(sent.count) image(s), \(Set(sent).count) distinct")

    // The frames the batches name, in the gallery's own numbering — read off the prompts, because which
    // frame the stub served which picture to is not a fact about the app.
    let named = batches.compactMap { photographNumber(in: userText(in: $0), of: 3) }.sorted()
    check(named.count == 2 && Set(named).count == 2,
          "each batch states the gallery number of the frame it carries",
          detail: "\(named) from \(batches.map { String(userText(in: $0).suffix(60)) }.joined(separator: " || "))")

    // What was left out is said out loud, with what it was left out for: a fold the operator cannot see
    // is indistinguishable from a photograph that went missing.
    let folded = reports.events.compactMap { event -> PhotoView? in
        guard case .folded(let view) = event else { return nil }
        return view
    }
    check(folded.count == 1, "the console was told once, as it happened", detail: "\(folded.count)")
    let leftOut = folded.first?.folds.map(\.frame) ?? []
    check(leftOut.count == 1, "with the one repeated photograph left out", detail: "\(leftOut)")
    check(leftOut.allSatisfy { !named.contains($0) },
          "and it is the frame no batch named, rather than one that was also sent",
          detail: "left out \(leftOut), batches named \(named)")
    check(folded.first.map { named.contains($0.representative) } == true,
          "while the frame its reading stands on is one that was sent",
          detail: "representative \(String(describing: folded.first?.representative)), sent \(named)")
    check(folded.first?.batchLogPhrase.contains("same picture as photograph") == true,
          "the line says what the two frames have in common",
          detail: folded.first?.batchLogPhrase ?? "—")
    check(folded.first?.batchLogPhrase.contains("left out of the batches") == true,
          "and says what became of it, rather than claiming it was read")

    check(outcome.imagesSent == 3,
          "every photograph of the gallery is still accounted for", detail: "\(outcome.imagesSent)")
    check(outcome.passes == 3, "two batches plus the pricing pass", detail: "\(outcome.passes)")
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 45. What makes two sightings one product

do {
    print("45. A shared code folds two sightings whatever they were named, and what disagrees keeps them apart")

    // The case the fold exists for: one carton, two batches, two names for it. What joins them is the
    // barcode read off the goods — the one thing on a carton that is not an opinion.
    let decoded = ManifestItem(
        itemName: "Cold Brew Coffee, 12 fl oz", brand: "Stok", identifiers: ["609032993551"]
    )
    let namedDifferently = ManifestItem(
        itemName: "iced coffee 12oz bottle", brand: "Stok", identifiers: ["609032993551"]
    )
    check(decoded.isSameProduct(as: namedDifferently),
          "a barcode both sightings carry identifies the product for both, whatever they were called",
          detail: "\(decoded.displayName) vs \(namedDifferently.displayName)")

    // Which is why the route folds the app's own reading of every frame into the batch answers: a code has
    // to be on *both* sightings to join them, and the batch that could not see the barcode otherwise
    // carries none.
    check(!decoded.isSameProduct(as: ManifestItem(itemName: "iced coffee 12oz bottle", brand: "Stok")),
          "while a code only one sighting carries is not a shared one")

    check(ManifestItem(itemName: "Coffee", identifiers: ["0123456789012"])
            .isSameProduct(as: ManifestItem(itemName: "iced coffee", modelNumber: "0123456789012")),
          "and the same digits read as an identifier or as a model number are still one code")

    // A code outranks a model number, because a barcode is decoded off the goods and a model number is
    // read off a label.
    check(ManifestItem(itemName: "Coffee", modelNumber: "A1", identifiers: ["0123456789012"])
            .isSameProduct(as: ManifestItem(itemName: "Coffee", modelNumber: "A2", identifiers: ["0123456789012"])),
          "and it outranks a model number the two batches read differently")

    // The same carton named at two lengths of breath — what comparing *words* buys over comparing strings.
    check(ManifestItem(itemName: "Yankee Candle 22 oz jar", brand: "Yankee Candle")
            .isSameProduct(as: ManifestItem(itemName: "yankee candles, 22oz", brand: "Yankee")),
          "one carton described two ways is one product")
    check(ManifestItem(itemName: "Energizer MAX AA, 24-pack", brand: "Energizer")
            .isSameProduct(as: ManifestItem(itemName: "Energizer MAX AA (24 pack)", brand: "Energizer")),
          "and so is one size written two ways")

    // What must never fold: the count, the size and the number that tell two products apart.
    check(!ManifestItem(itemName: "Energizer MAX AA, 24-pack", brand: "Energizer")
            .isSameProduct(as: ManifestItem(itemName: "Energizer MAX AA, 48-pack", brand: "Energizer")),
          "a pack count that disagrees is two different cases")
    check(!ManifestItem(itemName: "Energizer MAX AA, 24-pack", brand: "Energizer")
            .isSameProduct(as: ManifestItem(itemName: "Energizer MAX AAA, 24-pack", brand: "Energizer")),
          "and so is a different battery size")
    check(!ManifestItem(itemName: "AA batteries", modelNumber: "E91BP-24")
            .isSameProduct(as: ManifestItem(itemName: "AA batteries", modelNumber: "E91BP-48")),
          "two model numbers are two products, whatever the name says")
    check(!ManifestItem(itemName: "AA batteries", brand: "Duracell")
            .isSameProduct(as: ManifestItem(itemName: "AA batteries", brand: "Energizer")),
          "and two brands are two products")

    // Only codes *shaped* like one count: a pallet's every carton carries a freight label, and a number
    // that could be a price, a quantity or a tracking number must not fold a pallet into one line.
    check(!ManifestItem(itemName: "Paper towels", identifiers: ["12"])
            .isSameProduct(as: ManifestItem(itemName: "Trash bags", identifiers: ["12"])),
          "a bare short number is not a product code")
    check(!ManifestItem(itemName: "Paper towels", identifiers: ["ASSORTED"])
            .isSameProduct(as: ManifestItem(itemName: "Trash bags", identifiers: ["ASSORTED"])),
          "and neither is a word")

    // The same question end to end, through the route that has to answer it: three photographs read as two
    // batches, each batch naming the same goods differently and quoting the same digits off the carton.
    let script = StubScript([
        .init(status: 200, body: frameBytes(1), headers: ["Content-Type": "image/jpeg"]),
        .init(status: 200, body: frameBytes(2), headers: ["Content-Type": "image/jpeg"]),
        .init(status: 200, body: frameBytes(3), headers: ["Content-Type": "image/jpeg"]),
        .init(status: 200, body: manifestBody([
            StubManifestLine(
                name: "Cold Brew Coffee, 12 fl oz", brand: "Stok", quantity: 6, views: [1],
                identifiers: ["609032993551"]
            )
        ])),
        .init(status: 200, body: manifestBody([
            StubManifestLine(
                name: "iced coffee 12oz bottle", brand: "Stok", quantity: 4, views: [3],
                identifiers: ["609032993551"]
            )
        ])),
        .init(status: 200, body: deepSeekSuccessBody) // the pricing pass
    ])
    let service = makeDeepSeekService(script, requestsPerMinute: 0, maxAttempts: 1, photosPerRequest: 2)
    let outcome = try await service.value(subject: threePhotoSubject)
    let manifest = outcome.manifest ?? PalletManifest()
    check(manifest.count == 1,
          "two batches that read one barcode off the goods are one manifest line",
          detail: manifest.items.map(\.displayName).joined(separator: " | "))
    check(manifest.items.first?.views == [1, 3],
          "naming every photograph it was seen in", detail: "\(manifest.items.first?.views ?? [])")
} catch {
    tally.bump()
    print("  FAIL  unexpected error: \(error)")
}

// MARK: - 46. The reader's second kind of evidence

do {
    print("46. The reader keeps the wording that names goods and drops the paperwork around them")
    let lines = [
        "Cold Brew Coffee",
        "12 fl oz (355 mL)",
        "SKU: 4711",
        "Ship To: DC 4 - Aisle 12",
        "www.example.com/track",
        "Tel: 555-0100",
        "Yankee Candle Company",
        "Fragile - This Side Up",
        String(repeating: "long ", count: 20)
    ]
    let kept = LotImageDigest.labelLines(in: lines)
    check(kept == ["Cold Brew Coffee", "Yankee Candle Company"],
          "only the two lines that name goods survive the filter", detail: "\(kept)")

    let evidence = LotImageEvidence(barcodes: ["0123456789012"], labelText: kept, imagesRead: 1)
    check(evidence.promptLines.contains {
            $0.contains("Wording read off the packing: Cold Brew Coffee · Yankee Candle Company")
          },
          "and the model is handed them as wording it did not have to read",
          detail: evidence.promptLines.joined(separator: " | "))
    check(evidence.logPhrase.contains("label wording Cold Brew Coffee · Yankee Candle Company"),
          "which the console repeats, so a price can be read against what it was built on",
          detail: evidence.logPhrase)
    check(!LotImageEvidence(labelText: ["Cold Brew Coffee"]).isEmpty,
          "wording on its own is something legible, not nothing")

    let merged = LotImageDigest.merge([
        LotImageEvidence(labelText: ["Cold Brew Coffee"], imagesRead: 1),
        LotImageEvidence(labelText: ["Yankee Candle Company"], imagesRead: 1)
    ])
    check(merged.labelText == ["Cold Brew Coffee", "Yankee Candle Company"] && merged.imagesRead == 2,
          "and the lot-wide roll-up keeps both frames' wording", detail: "\(merged.labelText)")
}

// MARK: - 47. Where each key comes from

do {
    print("47. Each provider names the page its key comes from, and what that key costs")

    // Both the Account sheet's two sections and the About box's instructions are printed from these,
    // so a provider that could not answer would ship a sheet whose only guidance is "paste a key".
    for provider in ValuationProvider.allCases {
        check(provider.keySignupURL.scheme == "https" && provider.keySignupURL.host() != nil,
              "\(provider.displayName)'s key page is an https address",
              detail: provider.keySignupURL.absoluteString)
        check(provider.keySourceName.count > 3,
              "and the site is named for the operator", detail: provider.keySourceName)
        check(provider.keySteps.count >= 2,
              "with steps to follow", detail: "\(provider.keySteps.count) step(s)")
        check(provider.keySteps.allSatisfy { !$0.contains("**") && !$0.contains("`") },
              "written as plain sentences, because the About box prints them as plain text")
        check(provider.keySignupLabel == provider.keySignupURL.absoluteString
                .replacingOccurrences(of: "https://", with: ""),
              "and the link it prints is the page it opens", detail: provider.keySignupLabel)
    }

    // The two pages the README documents, pinned here: a link that drifts is a first run that ends in
    // a search engine.
    check(ValuationProvider.gemini.keySignupURL.absoluteString == "https://aistudio.google.com/apikey",
          "Gemini's key comes from AI Studio", detail: ValuationProvider.gemini.keySignupURL.absoluteString)
    check(ValuationProvider.deepSeek.keySignupURL.absoluteString == "https://platform.deepseek.com/api_keys",
          "and DeepSeek's from its own platform",
          detail: ValuationProvider.deepSeek.keySignupURL.absoluteString)

    // What each one costs, stated separately — that difference is the whole reason the sheet shows both
    // keys at once rather than one at a time.
    check(ValuationProvider.gemini.keyCostNote.lowercased().contains("free"),
          "Gemini's key is described as free", detail: ValuationProvider.gemini.keyCostNote)
    check(ValuationProvider.deepSeek.keyCostNote.lowercased().contains("prepaid"),
          "and DeepSeek's as prepaid", detail: ValuationProvider.deepSeek.keyCostNote)

    // Nothing in either section may be mistakable for the other's: two boxes with the same label and
    // the same placeholder would be a key pasted into the wrong service.
    check(ValuationProvider.gemini.keyLabel != ValuationProvider.deepSeek.keyLabel,
          "the two sections are labelled for different services",
          detail: "\(ValuationProvider.gemini.keyLabel) / \(ValuationProvider.deepSeek.keyLabel)")
    check(ValuationProvider.gemini.keyPlaceholder.hasPrefix("AIza")
            && ValuationProvider.deepSeek.keyPlaceholder.hasPrefix("sk-"),
          "and each field shows the shape of its own key",
          detail: "\(ValuationProvider.gemini.keyPlaceholder) / \(ValuationProvider.deepSeek.keyPlaceholder)")

    // The row the Account sheet's header and the panel's tooltip both read.
    let armed = ProviderKeyState(provider: .gemini, isReady: true, modelID: "gemini-2.5-flash")
    let idle = ProviderKeyState(provider: .deepSeek, isReady: false, modelID: "deepseek-flash")
    check(armed.summary == "Gemini · gemini-2.5-flash · key set",
          "a provider with a key reads as key set", detail: armed.summary)
    check(idle.summary == "DeepSeek · deepseek-flash · no key",
          "and one without reads as no key", detail: idle.summary)
    check(armed.id == ValuationProvider.gemini.rawValue && idle.id == ValuationProvider.deepSeek.rawValue,
          "each row is identified by its provider, so a list of both cannot mix them up",
          detail: "\(armed.id) / \(idle.id)")
}

print(tally.value == 0 ? "\nALL CHECKS PASSED" : "\n\(tally.value) CHECK(S) FAILED")
exit(tally.value == 0 ? 0 : 1)
