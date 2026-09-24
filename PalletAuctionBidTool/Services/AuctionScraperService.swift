//
//  AuctionScraperService.swift
//  PalletAuctionBidTool
//
//  Hidden WKWebView that logs in and harvests lot cards off the auction pages.
//

import Foundation
import WebKit

/// Scrape-wide hard limits.
///
/// Deliberately top-level and non-isolated so both the `@MainActor` service and the
/// settings/validation code can read it without hopping actors.
enum ScrapeLimits {
    /// Runaway guard on how many result pages will ever be walked.
    ///
    /// This is a guard, not a target, and it is no longer the brief's ten pages: the walk ends when
    /// the listing runs out of pages (no next control, no change, no cards), so the number below only
    /// decides when a catalogue that paginates for ever has to be given up on. **All pages** in the
    /// control panel means exactly that — walk until the site stops — which is why the ceiling had to
    /// move: a listings site with more than ten pages is ordinary, and a menu that stops at ten would
    /// silently truncate it.
    static let maximumPages = 100

    /// `AppSettings.pageLimit`'s "every page" marker: the guard above, reached by asking for none.
    static let allPagesMarker = 0

    /// Pages walked by a fresh install, before the operator has an opinion.
    static let defaultPages = 3
}

/// Credentials typed into the site's own login form.
struct ScraperCredentials: Sendable, Equatable {
    var email: String
    var password: String

    var isEmpty: Bool {
        email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Progress reported while a scrape is in flight. Delivered on the main actor.
enum ScraperEvent: Sendable {
    case status(String)
    case pageStarted(page: Int, limit: Int, lotsSoFar: Int)
    case pageExtracted(page: Int, lots: [ScrapedLot], runningTotal: Int)
    /// How long the listing is, as the listing itself renders it (see `PaginationReport`). Reported
    /// once per run, after the first page's cards are up.
    case pagination(PaginationReport)
    case paginationFinished(reason: String)
}

/// Everything that can go wrong between "point at a URL" and "got lots".
enum ScraperError: LocalizedError, Equatable {
    case invalidURL(String)
    case navigation(String)
    case automationNotInstalled
    case loginFormNotFillable(reason: String)
    case loginRejected
    case loginTimedOut(seconds: Int)
    case manualVerificationRequired(detail: String)
    case noLotsFound(diagnostics: String)
    /// The catalog answered, and the answer was "nothing to bid on" — see `noResultsTextPattern`.
    case noActiveLots(detail: String)
    case javaScript(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let text):
            "That is not a usable URL: \(text)"
        case .navigation(let message):
            "The page failed to load: \(message)"
        case .automationNotInstalled:
            "The scraper script never installed itself — the page may block JavaScript or main-frame injection."
        case .loginFormNotFillable(let reason):
            "The login form was found but could not be driven (\(reason))."
        case .loginRejected:
            "The site rejected the credentials: the login form came back after submitting."
        case .loginTimedOut(let seconds):
            "Login did not complete within \(seconds)s."
        case .manualVerificationRequired(let detail):
            "A human is needed: the page is showing a captcha / MFA challenge (\(detail)). Solve it in the browser window, then run again."
        case .noLotsFound(let diagnostics):
            "No lot cards were found. Page diagnostics: \(diagnostics)"
        case .noActiveLots(let detail):
            "No active listings — the auction catalog has no lots to bid on (\(detail))."
        case .javaScript(let message):
            "Page script error: \(message)"
        case .decoding(let message):
            "Could not read the page result: \(message)"
        }
    }

    /// Short tag used in per-lot status text.
    var shortReason: String {
        switch self {
        case .invalidURL: "invalid URL"
        case .navigation: "page load failed"
        case .automationNotInstalled: "automation not installed"
        case .loginFormNotFillable: "login form unusable"
        case .loginRejected: "login rejected"
        case .loginTimedOut: "login timed out"
        case .manualVerificationRequired: "manual verification required"
        case .noLotsFound: "no lots found"
        case .noActiveLots: "no active listings"
        case .javaScript: "page script error"
        case .decoding: "unreadable page result"
        }
    }
}

// MARK: - JavaScript payload contracts

/// Reply from `window.__PAS.fillLogin(...)`.
struct LoginFillReport: Codable, Sendable {
    var ok: Bool
    var error: String?
    var emailField: String?
    var passwordField: String?
    var emailFilled: Bool?
    var passwordFilled: Bool?
}

/// Reply from `window.__PAS.submitLogin()`.
struct LoginSubmitReport: Codable, Sendable {
    var ok: Bool
    var error: String?
    var via: String?
    var control: String?
    var label: String?
}

/// Reply from `window.__PAS.manualCheck()`.
struct ManualCheckReport: Codable, Sendable {
    var required: Bool
    var selector: String?
    var element: String?
    var stalledLoginForm: Bool?
}

/// Reply from `window.__PAS.pageSignature()`; used to detect that pagination worked.
struct PageSignature: Codable, Sendable, Equatable {
    var count: Int
    var hash: String
    var url: String
    var selector: String?
}

/// Reply from `window.__PAS.extractLots()`.
struct ExtractionReport: Codable, Sendable {
    var page: Int
    var url: String
    var selector: String?
    var cardCount: Int
    var lots: [ScrapedLot]
}

/// Reply from `window.__PAS.pagination()` — how long the listing says it is.
///
/// The catalogue's own pagination is the only honest source for a page count: the app cannot know a
/// listing's length without loading it, and the operator picks a page budget *before* pressing Run.
/// So this is what the **Pages** menu lists (plus **All**, which needs no count at all), and
/// `pages == nil` simply means the site does not say — a "next"-only listing, which `hasNext`
/// describes.
struct PaginationReport: Codable, Sendable, Equatable {
    /// Total result pages the listing reports, when it says.
    var pages: Int?
    /// Whether a next-page control is on offer right now — the fallback the walk keeps for listings
    /// that address nothing.
    var hasNext: Bool
    /// The query-string parameter the listing numbers its pages with (`page`, `paged`, …), when its
    /// own links were seen using one. The walk rewrites pages through this name, so a site that
    /// paginates `?paged=` is never asked with a `?page=` it would ignore.
    var parameter: String?
    /// Where the number came from, in words, for the log.
    var source: String?

    /// Freshly decoded reports carry no page count at all, which is the same answer as "not reported".
    static let unknown = PaginationReport(pages: nil, hasNext: false, parameter: nil, source: nil)

    /// One line for the activity log.
    var summary: String {
        let origin = source.flatMap { $0.isEmpty ? nil : $0 } ?? "no reason given"
        // The name the page numbers hide behind is worth printing whenever it is not the ordinary one:
        // a walk that stops early is usually a walk asking a question the site does not answer, and
        // this is the one line that says whether that is a possibility.
        let naming = parameter
            .flatMap { $0.caseInsensitiveCompare("page") == .orderedSame ? nil : $0 }
            .map { " Page numbers are carried in \"\($0)\"." } ?? ""
        guard let pages, pages > 1 else {
            return hasNext
                ? "The listing reports no page count (\(origin)) — more pages may follow.\(naming)"
                : "The listing reports no page count (\(origin)).\(naming)"
        }
        return "The listing reports \(pages) page(s) — \(origin).\(naming)"
    }
}

/// Reply from `window.__PAS.clickNext(...)`.
struct ClickNextReport: Codable, Sendable {
    var clicked: Bool
    var reason: String?
    var control: String?
    var label: String?
    var alternatives: Int?
    var signature: PageSignature?
}

/// Reply from `window.__PAS.noResults()`.
struct NoResultsReport: Codable, Sendable {
    var present: Bool
    var text: String?
    var selector: String?

    /// One-line reason for the log and the status line.
    var summary: String {
        let message = (text?.condensedWhitespace).flatMap { $0.isEmpty ? nil : $0 }
            ?? "the catalog reported no lots"
        return selector.map { "\(message) [\($0)]" } ?? message
    }
}

/// Reply from `window.__PAS.diagnostics()` — the debugging breadcrumb when a scrape finds nothing.
struct PageDiagnostics: Codable, Sendable {
    var url: String
    var title: String
    var readyState: String
    var profileName: String
    var cardSelector: String?
    var cardCount: Int
    var hasPasswordField: Bool
    var loginFormPresent: Bool
    var authenticated: Bool
    var nextControlCount: Int
    var bodyTextLength: Int
    var noResults: Bool?
    var noResultsText: String?

    /// Single-line summary used in error messages and the activity log.
    var summary: String {
        [
            "title=\"\(title.prefix(60))\"",
            "readyState=\(readyState)",
            "profile=\(profileName)",
            "cards=\(cardCount)",
            "selector=\(cardSelector ?? "none")",
            "loginForm=\(loginFormPresent)",
            "authenticated=\(authenticated)",
            "nextControls=\(nextControlCount)",
            "noResults=\(noResults ?? false)",
            "bodyChars=\(bodyTextLength)"
        ].joined(separator: " ")
    }
}

/// Reply from `window.__PAS.lotPageImages(url)`.
///
/// One lot's own page, read *through* the loaded listing so the request carries the operator's
/// session, then parsed off-screen. `images` is every photograph the page mentions — however many
/// that is, because the count is the lot's business rather than a setting (see deviation 24).
///
/// An unreadable page is reported, not thrown: a lot whose page cannot be read is still appraised
/// from the thumbnails its card carried, and `note` / `error` are what let the log say which
/// happened.
struct LotPageImages: Codable, Sendable {
    var ok: Bool
    var url: String
    var images: [String]
    var note: String?
    var error: String?

    var imageURLs: [URL] { images.compactMap { URL(string: $0) } }

    /// One line for the activity log.
    var summary: String {
        guard ok else { return "the lot page could not be read (\(error ?? "no reason given"))" }
        if let note, !note.isEmpty { return note }
        return "\(images.count) image(s) on the lot page"
    }
}

/// Payload handed to `window.__PAS.fillLogin(...)`.
private struct LoginPayload: Encodable {
    var email: String
    var password: String
}

// MARK: - Message relay

/// Forwards page-side log lines out of `WKWebView` and into the service.
///
/// Kept as its own tiny type because the message handler has to be registered on the
/// configuration *before* the `WKWebView` is built — that is, before `self` may be used.
@MainActor
private final class ScriptMessageRelay: NSObject, WKScriptMessageHandler {

    let handlerName: String
    var onMessage: ((String) -> Void)?

    init(handlerName: String) {
        self.handlerName = handlerName
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == handlerName, let body = message.body as? String else { return }
        onMessage?(body)
    }
}

// MARK: - Service

/// Drives a hidden `WKWebView` across the auction site: login, pagination, extraction.
///
/// The coordinator keeps exactly one instance for the life of the app. That is deliberate: the
/// web view is the thing a human interacts with when a site throws a captcha (see
/// `BrowserPanelView`), and `scrape(...)` carries no state of its own, so consecutive runs are
/// independent while the login session in the shared default `WKWebsiteDataStore` is reused.
@MainActor
final class AuctionScraperService: NSObject {

    /// Desktop-Safari user agent. Several liquidation hosts serve a reduced (or blocked)
    /// layout to the stock `WKWebView` agent string.
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    let profile: ScrapeProfile
    let webView: WKWebView

    private let relay: ScriptMessageRelay
    private let onLog: (@MainActor (String) -> Void)?
    private var navigationFailure: String?

    /// How many documents have finished loading in this web view.
    ///
    /// `webView.load` returns before the navigation begins, so "the page is ready" is not enough to
    /// know *which* page is ready: the document being left is still there, script and all, and would
    /// happily answer a `pageSignature()` about the page the walk has just left. Comparing this count
    /// across a load is what ties the wait to the document that was asked for.
    private var documentsLoaded = 0

    /// - Parameters:
    ///   - profile: selector strategy injected as `CONFIG` into the page.
    ///   - onLog: receives both page-side (`window.webkit.messageHandlers`) and Swift-side lines.
    init(profile: ScrapeProfile, onLog: (@MainActor (String) -> Void)? = nil) {
        self.profile = profile
        self.onLog = onLog

        let configuration = WKWebViewConfiguration()
        // `.default()` keeps the login cookie in the user's container between runs.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let relay = ScriptMessageRelay(handlerName: ScraperScript.logHandlerName)
        self.relay = relay
        let controller = configuration.userContentController
        controller.add(relay, name: ScraperScript.logHandlerName)

        // Injecting the automation as a user script (rather than evaluating it by hand) means
        // every main-frame navigation — including a full-page "next page" load — arrives
        // instrumented, with no re-install step to race against.
        var automationInstalled = false
        if let source = try? ScraperScript.source(profile: profile) {
            controller.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
            automationInstalled = true
        }

        let frame = CGRect(x: 0, y: 0, width: 1440, height: 2000)
        self.webView = WKWebView(frame: frame, configuration: configuration)

        super.init()

        webView.customUserAgent = Self.desktopUserAgent
        webView.isInspectable = true
        webView.navigationDelegate = self
        relay.onMessage = { [weak self] message in
            self?.log("page: \(message)")
        }

        if automationInstalled {
            log("Automation ready — profile “\(profile.name)”")
        } else {
            log("Could not encode the scrape profile; automation script was not installed")
        }
    }

    /// Stops pending page work and detaches the message handler.
    ///
    /// The app does not call this during normal operation — the session and the page must survive
    /// between runs so a hand-solved captcha keeps working. It exists for tests and for an
    /// explicit teardown when the service is genuinely disposable.
    func tearDown() {
        relay.onMessage = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ScraperScript.logHandlerName)
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}

// MARK: - JavaScript bridge

extension AuctionScraperService {

    /// Runs `script` and returns the raw bridged result.
    ///
    /// `WKWebView` bridges JSON-serialisable JavaScript values to Foundation objects directly.
    /// The injected automation always returns strings, so callers mostly funnel through
    /// `decodeJSON(_:as:)`; the raw form exists for the two boolean predicates.
    private func evaluateRaw(_ script: String) async throws -> Any? {
        do {
            return try await webView.evaluateJavaScript(script)
        } catch {
            throw ScraperError.javaScript(error.localizedDescription)
        }
    }

    private func evaluateString(_ script: String) async throws -> String? {
        try await evaluateRaw(script) as? String
    }

    private func evaluateBool(_ script: String) async throws -> Bool {
        let value = try await evaluateRaw(script)
        if let boolean = value as? Bool { return boolean }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text == "true" || text == "1" }
        return false
    }

    private func evaluateNumber(_ script: String) async throws -> Int {
        let value = try await evaluateRaw(script)
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String, let parsed = Int(text) { return parsed }
        return 0
    }

    /// Like `evaluateBool`, but treats a script error as `false`.
    ///
    /// Needed while a navigation is in flight: `evaluateJavaScript` throws until the new
    /// document exists, and that is an expected state during polling rather than a failure.
    private func evaluateBoolTolerant(_ script: String) async -> Bool {
        (try? await evaluateBool(script)) ?? false
    }

    private func decodeJSON<T: Decodable>(_ script: String, as type: T.Type) async throws -> T {
        guard let text = try await evaluateString(script) else {
            throw ScraperError.decoding("\(script) returned nothing")
        }
        guard let data = text.data(using: .utf8) else {
            throw ScraperError.decoding("\(script) returned non-UTF8 text")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ScraperError.decoding("\(script): \(error.localizedDescription)")
        }
    }

    /// Escapes a Swift string into a JavaScript string literal (via JSON, whose escapes match).
    private func javaScriptLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let literal = String(data: data, encoding: .utf8) else {
            throw ScraperError.decoding("could not escape payload for JavaScript")
        }
        return literal
    }

    /// Runs a *promise-returning* script and decodes its JSON string result.
    ///
    /// `evaluateJavaScript` hands back the value of the expression, which for an async page function
    /// is an unresolved promise (and not bridgeable). `callAsyncJavaScript` waits for it instead, so
    /// the page-side function that has to await a network round trip can keep the same
    /// "everything returns a JSON string" contract as the synchronous ones.
    private func decodeAsyncJSON<T: Decodable>(
        _ body: String,
        arguments: [String: Any],
        as type: T.Type
    ) async throws -> T {
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(
                body,
                arguments: arguments,
                in: nil,
                contentWorld: .page
            )
        } catch {
            throw ScraperError.javaScript(error.localizedDescription)
        }
        guard let text = raw as? String else {
            throw ScraperError.decoding("\(body) returned nothing")
        }
        guard let data = text.data(using: .utf8) else {
            throw ScraperError.decoding("\(body) returned non-UTF8 text")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ScraperError.decoding("\(body): \(error.localizedDescription)")
        }
    }

    /// `true` when the automation script is present and initialised in the current document.
    private func isAutomationReady() async -> Bool {
        await evaluateBoolTolerant("!!(window.__PAS && window.__PAS.ready === true)")
    }
}

// MARK: - Lot pages

extension AuctionScraperService {

    /// Reads one lot's own page — every image on it — through the listing already loaded.
    ///
    /// Nothing is navigated: the page is fetched from inside the current document, so the request
    /// carries the session this web view already authenticated, and the results page (its scroll
    /// position, its page number, the automation's own state) is untouched. One lot therefore costs
    /// one GET rather than a load-and-come-back.
    ///
    /// A page that cannot be read is *not* an error state for the caller: the report's `ok` is
    /// `false` with the reason, and a scan falls back to the card's thumbnails. The only throws here
    /// are a web view that is not on a page at all, or automation that is not installed.
    func lotPageImages(for url: URL) async throws -> LotPageImages {
        guard await isAutomationReady() else { throw ScraperError.automationNotInstalled }
        return try await decodeAsyncJSON(
            "return await window.__PAS.lotPageImages(url);",
            arguments: ["url": url.absoluteString],
            as: LotPageImages.self
        )
    }
}

// MARK: - Pipeline

extension AuctionScraperService {

    /// Loads `startURL`, optionally logs in, then walks result pages.
    ///
    /// The walk is **by address**: page 2 is the run's address carrying `?page=2`, page 3 carries
    /// `?page=3`, and so on, until a page turns up with no lots on it — a catalogue's own "nothing
    /// here" state, a blank grid, or the body of a 404, all of which `waitForCardsOrEmptyState` reads
    /// as the end. Clicking the site's own "next" control is kept as the fallback for listings that do
    /// not address their pages at all (**Load more**) and as the recovery when an address is ignored.
    /// Before this, the walk *only* clicked, which is why a catalogue whose pagination is a strip of
    /// numbers with no `rel="next"` stopped after one page.
    ///
    /// `pageLimit` is the operator's page budget. `<= 0` means **every page**: the walk runs until the
    /// listing stops offering one, with `ScrapeLimits.maximumPages` left as the runaway guard.
    ///
    /// - Returns: every unique lot discovered, in page order.
    func scrape(
        startURL: URL,
        credentials: ScraperCredentials?,
        pageLimit: Int,
        emit: @escaping @MainActor (ScraperEvent) -> Void
    ) async throws -> [ScrapedLot] {
        let limit = pageLimit > 0
            ? min(pageLimit, ScrapeLimits.maximumPages)
            : ScrapeLimits.maximumPages

        emit(.status("Opening \(startURL.absoluteString)"))
        try await start(url: startURL)

        if let credentials, !credentials.isEmpty {
            try await authenticate(credentials: credentials, emit: emit)
        } else {
            emit(.status("No credentials supplied — scraping with the current session"))
        }

        var collected: [ScrapedLot] = []
        var seenKeys = Set<String>()
        // Page fingerprints already read. A site that ignores the page number in an address — a
        // client-side router, or one that clamps every high number to its last page — answers with a
        // page this walk has already harvested, and that repeat is how the walk notices.
        var seenPages = Set<String>()
        var listingPageCount: Int?
        // How later pages are addressed. Built from the address the site itself settled on once page 1
        // is up, so a catalogue that canonicalises or redirects is still asked in its own terms.
        var plan: PaginationPlan?
        var page = 1
        var needsNavigation = false

        pageLoop: while page <= limit {
            emit(.pageStarted(page: page, limit: limit, lotsSoFar: collected.count))

            if needsNavigation {
                let route = plan ?? PaginationPlan(baseURL: startURL)
                guard try await advance(to: page, pageCount: listingPageCount, plan: route, emit: emit) else {
                    break pageLoop
                }
            }
            needsNavigation = true

            switch try await waitForCardsOrEmptyState(timeout: profile.lotRenderTimeoutSeconds) {
            case .cards:
                // How long the listing is, asked once, off the first page's own pagination: the count is
                // a fact about the whole catalogue, the first page is where it is rendered, and the name
                // its page links use for a page number is read from the same place. Best-effort — a site
                // that does not say is reported as not saying.
                if page == 1 {
                    // Every later page is a rewrite of the address the *site* settled on rather than of
                    // the one that was typed: a catalogue that redirects to a canonical address would
                    // otherwise have page numbers appended to the address it refuses.
                    let listing = await pagination()
                    plan = PaginationPlan(baseURL: webView.url ?? startURL, parameter: listing?.parameter)
                    listingPageCount = listing?.pages
                    if let listing { emit(.pagination(listing)) }
                }
                break

            // The page itself says there is nothing to bid on. On page 1 that ends the run — and it
            // is the auction's answer, not a scraper failure, so it is reported as such. Past page 1
            // it is the end of the listing, which is exactly what an address walk is looking for.
            case .empty(let detail):
                if page == 1 {
                    log("The catalog reports no lots: \(detail)")
                    throw ScraperError.noActiveLots(detail: detail)
                }
                emit(.status("The results ended — \(detail)"))
                emit(.paginationFinished(reason: "No more lots — \(detail)"))
                break pageLoop

            // Neither cards nor an admission: the page is not a listing we understand.
            case .unknown:
                if page == 1 {
                    // One last look before calling it a scraper failure: a "no results" surface that
                    // rendered too late for the loop is still the catalogue's own answer.
                    if let empty = try? await emptyState(), empty.present {
                        log("The catalog reports no lots: \(empty.summary)")
                        throw ScraperError.noActiveLots(detail: empty.summary)
                    }
                    let diagnostics = try await diagnostics()
                    throw ScraperError.noLotsFound(diagnostics: diagnostics.summary)
                }
                emit(.paginationFinished(reason: "No lot cards appeared on page \(page) — the listing has no such page"))
                break pageLoop
            }

            try await settle()
            let report = try await extractLots(page: page)
            let newLots = report.lots.filter { seenKeys.insert($0.dedupeKey).inserted }
            collected.append(contentsOf: newLots)
            log("Page \(page): \(report.cardCount) cards via \(report.selector ?? "no selector"), \(newLots.count) new")
            emit(.pageExtracted(page: page, lots: report.lots, runningTotal: collected.count))

            // A page whose fingerprint has already been read is not this page at all: the number in the
            // address was ignored, clamped or redirected away. Clicking the site's own control is the
            // one thing left to try — a **Load more** listing is what that recovers, and it is what this
            // walk used to rely on exclusively — and a click that moves nothing ends the walk.
            let signature = try? await pageSignature()
            if page > 1, let signature, seenPages.contains(signature.hash) {
                emit(.status("Page \(page) served a page already read (\(signature.url)) — trying the site's own next control"))
                guard try await clickToAdvance(to: page + 1, emit: emit) else { break pageLoop }
                needsNavigation = false
                page += 1
                continue pageLoop
            }
            if let signature { seenPages.insert(signature.hash) }

            if page == limit {
                emit(.paginationFinished(reason: "Reached the \(limit)-page limit"))
                break
            }

            page += 1
        }

        log("Scrape finished — \(collected.count) unique lot(s)")
        return collected
    }

    /// Snapshot of the current document: card count, login state, next-control availability.
    func diagnostics() async throws -> PageDiagnostics {
        try await decodeJSON("window.__PAS.diagnostics()", as: PageDiagnostics.self)
    }

    /// Content fingerprint of the visible cards, used to prove pagination actually moved.
    func pageSignature() async throws -> PageSignature {
        try await decodeJSON("window.__PAS.pageSignature()", as: PageSignature.self)
    }

    /// Asks the listing how many result pages it has. Never throws: a page that cannot answer is
    /// simply a listing with no page count, which the **Pages** menu already offers an answer for.
    func pagination() async -> PaginationReport? {
        try? await decodeJSON("window.__PAS.pagination()", as: PaginationReport.self)
    }

    /// Navigates and waits until the automation script reports itself ready.
    private func start(url: URL) async throws {
        guard try await load(url) else { throw ScraperError.automationNotInstalled }
    }

    /// Loads `url` into the hidden web view and waits until the automation script is live on it.
    ///
    /// Shared by the first page and by every page after it, so the walk can never read a page the
    /// script has not seen. A transport failure still throws — a walk that loses the network should say
    /// so rather than claim the listing ended — while `false` means the page simply never finished
    /// loading, which for a later page is the end of the listing rather than a broken run.
    ///
    /// - Returns: `false` when the page never finished loading.
    private func load(_ url: URL) async throws -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ScraperError.invalidURL(url.absoluteString)
        }
        navigationFailure = nil
        // `webView.load` returns before the navigation has even begun, and the *previous* document's
        // script is still ready while it has. Counting finished documents is what says the page being
        // waited for is the page that arrived; without it a walk over matched its own address would
        // read page 1 again and call page 2 a repeat.
        let generation = documentsLoaded
        log("Loading \(url.absoluteString)")
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60))

        return try await poll(timeout: 45, interval: .milliseconds(250)) {
            if let failure = self.navigationFailure {
                throw ScraperError.navigation(failure)
            }
            if self.documentsLoaded == generation { return false }
            if self.webView.isLoading { return false }
            return await self.isAutomationReady()
        }
    }

    /// Polls `condition` until it returns `true`, or `timeout` seconds elapse.
    ///
    /// Errors thrown by `condition` propagate immediately, which is how a failed navigation
    /// aborts a wait instead of burning the whole timeout.
    private func poll(
        timeout: TimeInterval,
        interval: Duration = .milliseconds(250),
        _ condition: () async throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if try await condition() { return true }
            if Date() >= deadline { return try await condition() }
            try await Task.sleep(for: interval)
        }
    }

    /// How a page answered "is there anything here to bid on?".
    private enum PageReadiness {
        /// Lot cards rendered.
        case cards
        /// The page's own no-results message supplied the reason.
        case empty(String)
        /// Neither appeared before the timeout.
        case unknown
    }

    /// Waits until the page shows lot cards, or admits it has none.
    ///
    /// The second half is what stops a run on an auction that has closed. Without it the tool waits
    /// out the whole render timeout and then reports a page that "had no cards", which reads as a
    /// scraper failure rather than as an auction with nothing left to bid on.
    private func waitForCardsOrEmptyState(timeout: TimeInterval) async throws -> PageReadiness {
        var readiness = PageReadiness.unknown
        var emptySightings = 0
        _ = try await poll(timeout: timeout, interval: .milliseconds(400)) {
            let count = (try? await self.evaluateNumber("window.__PAS.cardCount()")) ?? 0
            if count > 0 {
                readiness = .cards
                return true
            }
            if let empty = try? await self.emptyState(), empty.present {
                // Two sightings in a row: a client-rendered grid can paint its "nothing here"
                // surface for a frame before the first cards arrive, and acting on that one glimpse
                // would abandon a page that had plenty to bid on. A catalogue with genuinely
                // nothing to sell keeps saying so.
                emptySightings += 1
                if emptySightings >= 2 {
                    readiness = .empty(empty.summary)
                    return true
                }
            } else {
                emptySightings = 0
            }
            return false
        }
        return readiness
    }

    /// The page's own "no lots" message, when it is showing one.
    ///
    /// A catalogue says this in its own words — "Results: No Items Found." on the site this tool was
    /// built for — which is why the detection is a profile-driven selector + regex pair rather than
    /// a hard-coded string.
    func emptyState() async throws -> NoResultsReport {
        try await decodeJSON("window.__PAS.noResults()", as: NoResultsReport.self)
    }

    /// Sweeps the viewport (so lazily rendered cards and images materialise) and pauses.
    private func settle() async throws {
        _ = try? await evaluateRaw("window.__PAS.scrollSweep()")
        _ = try await poll(timeout: 8, interval: .milliseconds(200)) {
            let sweeping = await self.evaluateBoolTolerant("window.__PAS.isSweeping()")
            return !sweeping
        }
        try await Task.sleep(for: .milliseconds(profile.settleDelayMilliseconds))
    }

    /// Stamps the 1-based page counter into the page (it becomes each lot's `sourcePage`) and extracts.
    private func extractLots(page: Int) async throws -> ExtractionReport {
        _ = try? await evaluateRaw("window.__PAS.setPage(\(page))")
        return try await decodeJSON("window.__PAS.extractLots()", as: ExtractionReport.self)
    }
}

// MARK: - Login

extension AuctionScraperService {

    /// Drives the site's own login form and waits until the session is accepted.
    ///
    /// Credentials are only ever handed to the page's own form (`fillLogin`); the tool never
    /// posts them itself, which keeps it compatible with CSRF tokens and JS-driven forms.
    private func authenticate(
        credentials: ScraperCredentials,
        emit: @escaping @MainActor (ScraperEvent) -> Void
    ) async throws {
        guard await evaluateBoolTolerant("window.__PAS.hasLoginForm()") else {
            emit(.status("No login form on this page — continuing with the existing session"))
            return
        }

        emit(.status("Filling the login form"))
        let fields = LoginPayload(email: credentials.email, password: credentials.password)
        let encoded = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
        let literal = try javaScriptLiteral(encoded)
        let fill = try await decodeJSON("window.__PAS.fillLogin(\(literal))", as: LoginFillReport.self)
        guard fill.ok else {
            throw ScraperError.loginFormNotFillable(reason: fill.error ?? "the form could not be filled")
        }
        log("Filled email field (\(fill.emailField ?? "?")) and password field (\(fill.passwordField ?? "?"))")

        emit(.status("Submitting credentials"))
        let submit = try await decodeJSON("window.__PAS.submitLogin()", as: LoginSubmitReport.self)
        guard submit.ok else {
            throw ScraperError.loginFormNotFillable(reason: submit.error ?? "no submit control was found")
        }
        log("Submitted the login form via \(submit.via ?? "unknown"), control: \(submit.control ?? "?")")

        emit(.status("Waiting for the site to accept the session"))
        let deadline = Date().addingTimeInterval(profile.loginTimeoutSeconds)
        var stalled = false

        while Date() < deadline {
            try Task.checkCancellation()

            let manual = try await decodeJSON("window.__PAS.manualCheck()", as: ManualCheckReport.self)
            if manual.required {
                throw ScraperError.manualVerificationRequired(
                    detail: manual.element ?? manual.selector ?? "challenge detected"
                )
            }
            stalled = manual.stalledLoginForm ?? false

            if await evaluateBoolTolerant("window.__PAS.isAuthenticated()") {
                emit(.status("Signed in"))
                return
            }
            try await Task.sleep(for: .milliseconds(400))
        }

        if stalled { throw ScraperError.loginRejected }
        throw ScraperError.loginTimedOut(seconds: Int(profile.loginTimeoutSeconds.rounded()))
    }
}

// MARK: - Pagination

extension AuctionScraperService {

    /// Moves the hidden web view to result page `page`.
    ///
    /// By address, because that is the shape a numbered pagination prints and the shape the operator
    /// asked for: `?page=1`, `?page=2`, `?page=3`, … The listing's own link for that page is used when
    /// it printed one, otherwise the run's address has its page number rewritten (`PaginationPlan`).
    /// A click only gets the job when no address is available at all, and it is the recovery when a
    /// loaded address turns out to repeat a page already read (see the walk in `scrape`).
    ///
    /// This is the fix for the walk that stopped after one page on the catalogue this tool targets:
    /// its pagination is a strip of numbers with no `rel="next"` anywhere, so the click-only walk
    /// reported "No next-page control was found" while `?page=2` sat in the markup.
    ///
    /// - Returns: `false` when the page could not be reached, which ends the walk.
    private func advance(
        to page: Int,
        pageCount: Int?,
        plan: PaginationPlan,
        emit: @escaping @MainActor (ScraperEvent) -> Void
    ) async throws -> Bool {
        // The listing's own count is where the walk stops cleanly: it is the number the **Pages** menu
        // was built from, so asking for one page more is asking a question the listing already answered.
        if let pageCount, page > pageCount {
            emit(.paginationFinished(reason: "The listing reports \(pageCount) page(s) — there is no page \(page)"))
            return false
        }

        guard let target = await pageURL(for: page, plan: plan) else {
            return try await clickToAdvance(to: page, emit: emit)
        }
        guard try await load(target) else {
            emit(.paginationFinished(reason: "Page \(page) never finished loading (\(target.absoluteString))"))
            return false
        }

        // A site that clamps its page numbers or redirects the address answers with a page of its own
        // choosing. Saying so in the log is what makes "the walk stopped early" answerable without a
        // debugger — and the page the walk lands on is what the next iteration reads.
        if let landed = webView.url, let answered = PaginationPlan.pageNumber(of: landed), answered != page {
            log("Pagination: asked for page \(page), the site's address says page \(answered) (\(landed.absoluteString))")
        }
        return true
    }

    /// The address that should ask for `page`: the listing's own link for it when the page printed
    /// one, otherwise the run's address with its page number rewritten.
    private func pageURL(for page: Int, plan: PaginationPlan) async -> URL? {
        let printed = try? await evaluateString("window.__PAS.pageAddress(\(page))")
        if let address = printed ?? nil, let url = URL(string: address) {
            return url
        }
        return plan.url(page: page)
    }

    /// Clicks the next-page control and confirms the grid content actually changed.
    ///
    /// The fallback path: a listing that offers a **Load more** button, or one whose addresses the site
    /// ignores, is only ever moved by the site's own control.
    ///
    /// - Returns: `false` when there is no next control, the click was refused, or the grid stayed
    ///   identical (the usual signature of a soft "end of results" state).
    private func clickToAdvance(
        to page: Int,
        emit: @escaping @MainActor (ScraperEvent) -> Void
    ) async throws -> Bool {
        let controls = (try? await evaluateNumber("window.__PAS.nextControlCount()")) ?? 0
        guard controls > 0 else {
            emit(.paginationFinished(reason: "No next-page control was found, and page \(page) has no address to load"))
            return false
        }

        let before = try await pageSignature()
        var click = try await decodeJSON("window.__PAS.clickNext(false)", as: ClickNextReport.self)
        if !click.clicked {
            log("Pagination: default click refused (\(click.reason ?? "unknown")) — retrying with force")
            click = try await decodeJSON("window.__PAS.clickNext(true)", as: ClickNextReport.self)
        }
        guard click.clicked else {
            emit(.paginationFinished(reason: "The next-page control would not activate (\(click.reason ?? "unknown"))"))
            return false
        }
        emit(.status("Advancing to page \(page) via \(click.label ?? click.control ?? "the next control")"))

        let moved = try await poll(timeout: 25, interval: .milliseconds(400)) {
            if let failure = self.navigationFailure {
                throw ScraperError.navigation(failure)
            }
            let after = (try? await self.pageSignature()) ?? before
            return after != before
        }
        guard moved else {
            emit(.paginationFinished(reason: "The grid did not change after clicking next"))
            return false
        }
        return true
    }
}

// MARK: - WKNavigationDelegate

extension AuctionScraperService: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        documentsLoaded += 1
        log("Loaded \(webView.url?.absoluteString ?? "unknown URL")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recordNavigationFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        recordNavigationFailure(error)
    }

    /// Keeps `target="_blank"` links (which would otherwise be dropped) inside the hidden web view.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else {
            return .allow
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .cancel
        }
        webView.load(URLRequest(url: url))
        return .cancel
    }

    /// Records a load failure, ignoring the cancellations WebKit reports for superseded loads.
    private func recordNavigationFailure(_ error: Error) {
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled { return }
        navigationFailure = failure.localizedDescription
        log("Navigation failed: \(failure.localizedDescription)")
    }
}
