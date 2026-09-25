//
//  AnalysisCoordinator.swift
//  PalletAuctionBidTool
//
//  Orchestrates scrape -> valuation and publishes progress to the UI.
//

import Foundation
import Observation
import WebKit

/// Owns the whole analysis pipeline and is the single source of truth for the UI.
///
/// The coordinator is `@MainActor`-isolated, so every mutation of `lots` happens on the main
/// actor and SwiftUI rows update without any manual dispatching. The slow work (page loads,
/// downloads, valuation calls) is `await`ed, so the main actor is never blocked.
@MainActor
@Observable
final class AnalysisCoordinator {

    /// Coarse phase of a run; drives the progress bar and the button states.
    enum Phase: Equatable {
        case idle
        case scraping
        case valuing
        case finished
        case stopped
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .scraping, .valuing: true
            case .idle, .finished, .stopped, .failed: false
            }
        }

        var label: String {
            switch self {
            case .idle: "Idle"
            case .scraping: "Scraping pages"
            case .valuing: "Valuing lots"
            case .finished: "Finished"
            case .stopped: "Stopped"
            case .failed: "Failed"
            }
        }
    }

    /// One line in the activity console.
    struct LogLine: Identifiable, Hashable {
        enum Source: String {
            case app = "app"
            case scraper = "scrape"
            case page = "page"
            case valuation = "value"
            case error = "error"
        }

        let id = UUID()
        let timestamp: Date
        let source: Source
        let message: String

        var timestampText: String {
            timestamp.formatted(date: .omitted, time: .standard)
        }
    }

    // MARK: Observable state

    /// Rows shown in the master table, in scrape order.
    private(set) var lots: [LotItem] = []
    private(set) var phase: Phase = .idle
    private(set) var statusText = "Ready — paste an auction URL, then press Run."
    private(set) var logLines: [LogLine] = []

    /// Pages fully extracted so far (1-based count).
    private(set) var pagesExtracted = 0
    /// Page budget for the current/last run: a count, or `ScrapeLimits.maximumPages` when the
    /// operator asked for **All pages**.
    private(set) var pageLimit = 1

    /// How many result pages the listing reports, as read off its own pagination during the last run
    /// (see `PaginationReport`). `nil` means the site did not say, and the **Pages** menu falls back to
    /// the counts it can offer regardless.
    ///
    /// It lives here rather than in `AppSettings` because it is an observation about the site, not a
    /// preference: it is re-read on every run and never persists.
    private(set) var listingPageCount: Int?

    private(set) var valuedCount = 0
    private(set) var failedCount = 0
    private(set) var skippedCount = 0

    /// Set when a run ended because the auction had nothing to bid on — either the catalogue said so
    /// outright or every lot it listed is marked sold. The table shows it instead of the generic
    /// "press Scrape Lots" prompt, so an empty board is never mistaken for a tool that did not run.
    private(set) var emptyListingNote: String?

    // MARK: Dependencies

    private let settings: AppSettings
    private var runTask: Task<Void, Never>?

    /// The batch started by the table's **Price all** button.
    private var scanBatchTask: Task<Void, Never>?

    /// On-demand per-lot scans, keyed by lot: an entry doubles as the "this row is busy" flag, so
    /// a second click on the same row is ignored instead of firing a duplicate request.
    private var scanTasks: [UUID: Task<Void, Never>] = [:]

    /// On-demand per-lot pre-prices, keyed the same way. A separate dictionary from `scanTasks`
    /// because the two are separate purchases: a cheap text-only pass in flight must not be
    /// mistaken for a photographed scan (the row's own analysis state is what says "scanning"),
    /// and neither must overwrite the other's bookkeeping.
    private var prePriceTasks: [UUID: Task<Void, Never>] = [:]

    /// The batch started by the table's **Eval all** button.
    private var prePriceBatchTask: Task<Void, Never>?

    /// Set when **Stop** cancelled a scan, so the closing status line says "stopped" rather than
    /// "finished".
    private var scansWereStopped = false

    private var seenLotKeys = Set<String>()
    private let logLimit = 400

    /// The one long-lived scraper for the process.
    ///
    /// Reusing a single instance (instead of building one per run) keeps the login session and
    /// the page itself available after a run ends, which is what makes the browser panel work:
    /// a captcha or MFA prompt can only be solved by a human looking at the real page.
    /// `scrape(...)` keeps no cross-run state of its own, so re-runs are unaffected.
    private var scraper: AuctionScraperService?

    /// Injectable for tests; defaults to the client for whichever provider is selected.
    ///
    /// The report closure is a parameter rather than something read off `self`: a `ValuationService` is
    /// a `Sendable` value that may be called from any task, and a thorough scan reports each photograph
    /// from whichever task is doing the work (see `LotPhotoScan`). Passing it in is also what lets the
    /// default below decide *once* whether the photograph-by-photograph path is wanted at all —
    /// `AppSettings.photoScanPlan()` is the operator's answer to that.
    var makeValuationService: @MainActor (
        AppSettings,
        @escaping @Sendable (PhotoScanReport) -> Void
    ) -> ValuationService = { settings, report in
        AnalysisCoordinator.liveService(for: settings, report: report)
    }

    /// The client for the selected provider, with the thorough-scan plan and the reporter wired in.
    private static func liveService(
        for settings: AppSettings,
        report: @escaping @Sendable (PhotoScanReport) -> Void
    ) -> ValuationService {
        let plan = settings.photoScanPlan()
        switch settings.provider {
        case .gemini:
            return GeminiValuationService(
                apiKey: settings.apiKey,
                modelID: settings.activeModelID,
                requestsPerMinute: settings.requestsPerMinute,
                photoScan: plan,
                report: report
            )
        case .deepSeek:
            return DeepSeekValuationService(
                apiKey: settings.deepSeekAPIKey,
                modelID: settings.activeModelID,
                requestsPerMinute: settings.requestsPerMinute,
                photoScan: plan,
                report: report
            )
        }
    }

    /// The reporter a scan is built with: every step goes to the console, and the row being read says
    /// where in its gallery it is.
    ///
    /// The closure is handed to a `Sendable` service that calls it from whichever task is doing the
    /// work, so it hops back to the main actor to touch `logLines` and the row. Batches scan several
    /// lots at once, so a step from another lot's scan can land between two of this one's — which is
    /// also true of the finished valuations themselves; the lot number on every line is what keeps the
    /// console readable through it.
    private func scanReporter(for lot: LotItem) -> @Sendable (PhotoScanReport) -> Void {
        { [weak self, weak lot] report in
            Task { @MainActor in
                guard let self, let lot else { return }
                self.record(report, on: lot)
            }
        }
    }

    /// One scan step: a console line, and the live note on the row.
    ///
    /// The note is written only while the row is still being read. A report is delivered from another
    /// task, so one can land after the scan has already finished — and a completed row wearing
    /// `photograph 12 of 12` would read as a scan that never ended.
    private func record(_ report: PhotoScanReport, on lot: LotItem) {
        log(report.logLine, source: .valuation)
        guard case .analyzing = lot.analysisState else { return }
        lot.markPhotoScanStep(report.rowNote)
    }

    /// The reporter a batch scan is built with.
    ///
    /// One service serves every lot in a batch, so the step cannot be captured per row the way
    /// `scanReporter(for:)` does it: it is routed by the lot number the report carries.
    private func batchScanReporter() -> @Sendable (PhotoScanReport) -> Void {
        { [weak self] report in
            Task { @MainActor in
                guard let self else { return }
                guard let lot = self.lots.first(where: { $0.lotNumber == report.lotNumber }) else {
                    // The row went away mid-batch — a re-scrape or **Clear** replaced it. The console
                    // line still happened, and there is no row left to write the note onto.
                    self.log(report.logLine, source: .valuation)
                    return
                }
                self.record(report, on: lot)
            }
        }
    }


    init(settings: AppSettings) {
        self.settings = settings
        pageLimit = settings.effectivePageLimit
    }

    #if DEBUG
    /// Fills the table with `LotItem.previewSamples()` — no scrape, no network, no key.
    ///
    /// Debug builds only, and only ever called from a preview. It exists because this table is
    /// hand-laid-out: whether a stretch-to-fit column layout, a nested product line or a status tint
    /// actually reads correctly is a question about pixels, and answering it used to require a live
    /// auction URL. The samples cover every row state the pipeline can produce (see
    /// `PreviewSampleLots`).
    func loadSamplesForPreview() {
        let samples = LotItem.previewSamples()
        lots = samples
        valuedCount = samples.count { $0.hasValuation }
        phase = .finished
        statusText = "Preview fixture — \(samples.count) sample lot(s), nothing was scraped."
    }
    #endif

    // MARK: Derived UI state

    /// `true` while a scrape is walking pages *or* any lot is being appraised by hand. Everything
    /// that must not run two-at-once (a new scrape, **Clear**) keys off this.
    var isRunning: Bool { phase.isRunning || !scanTasks.isEmpty || !prePriceTasks.isEmpty }

    /// `true` when the only work in flight is on-demand work on single rows, whether that is a
    /// pre-price or a scan.
    var isScanning: Bool { !scanTasks.isEmpty || !prePriceTasks.isEmpty }

    /// Whether a row's **Price** button is live: an appraisal is configured, and no scrape or batch
    /// scan owns the pipeline. Another row's scan does *not* block it — clicking through several
    /// lots is exactly what the button is for.
    var canScan: Bool { !isExclusiveWork && settings.canScanLots }

    /// Whether a row's **Eval** button is live. Same gate as **Price**: both spend the same key,
    /// and both are refused for the same reasons — a scrape or a batch owning the pipeline.
    var canPrePrice: Bool { canScan }

    /// Whether **Price all** is live. Deliberately exclusive with the per-row scans, so a batch can
    /// never queue a second request for a lot somebody just clicked.
    ///
    /// Sold lots count: the site's marker is information, not a gate (see `LotTableRow.activeCell`),
    /// so a closed sale is as priceable as an open one — which is the whole point of loading it.
    var canScanUnvalued: Bool {
        canScan && !isScanning && lots.contains { !$0.hasValuation }
    }

    /// Whether **Eval all** is live, on the same rule as **Price all**, and only when there is
    /// at least one lot with neither a valuation nor an eval to give.
    var canPrePriceUnvalued: Bool {
        canScan && !isScanning && lots.contains { !$0.hasValuation && !$0.isPrePriced }
    }

    /// Lots still waiting for a first appraisal — what **Price all** would work through.
    var unvaluedCount: Int { lots.count { !$0.hasValuation } }

    /// Lots carrying a text-only pre-price, whether or not a scan has since superseded it.
    var prePricedCount: Int { lots.count { $0.isPrePriced } }

    /// Lots that reached a terminal state (valued, failed or skipped).
    var terminalCount: Int { valuedCount + failedCount + skippedCount }

    var activeCount: Int { lots.count - terminalCount }

    /// 0...1 for the bottom progress bar, or `nil` when the work in hand cannot be counted yet.
    ///
    /// The bar measures the work in hand against its own total instead of reserving a fixed share for
    /// scraping, so 100% always means "what was asked for is done": while the walk is running it is
    /// pages read out of the pages this run was told to read, and once lots are being appraised it is
    /// lots answered out of lots on the board. A three-page run therefore fills 1/3, 2/3, full as it
    /// walks instead of stopping a third of the way along — which is what the old fixed 35% split
    /// looked like on a run that had actually finished.
    ///
    /// The one thing that cannot be counted is an **All pages** walk of a listing that never says how
    /// many pages it has: `nil` asks the footer for an indeterminate bar rather than picking a
    /// denominator and calling an arbitrary page "100%".
    var progressFraction: Double? {
        guard !lots.isEmpty || pagesExtracted > 0 else { return 0 }
        switch phase {
        case .idle:
            // Nothing is running. A board with pages in it has had its scraping done, and nothing
            // else has been asked for, so the bar stays where the last run left it.
            return pagesExtracted > 0 ? 1 : 0
        // A walk in flight, or one that died part-way: pages read of pages asked for, which is the
        // one honest thing to say about a run that failed on page 4.
        case .scraping, .failed:
            return scrapeProgress
        case .valuing:
            return appraisalProgress
        // The scrape is over. If no appraisal has been asked for, the pages *were* the job — the
        // ordinary case, because a run never spends a token by itself — so the bar is full.
        case .finished, .stopped:
            guard hasAppraisalWork else { return phase == .finished ? 1 : scrapeProgress }
            return appraisalProgress
        }
    }

    /// What this run will read, in pages: the operator's **Pages** budget, or — when they asked for
    /// **All pages** — the listing's own count once its pagination has reported one.
    private var pageTarget: Int? {
        settings.walksEveryPage ? listingPageCount : max(1, pageLimit)
    }

    /// Pages read, out of the pages this run intends to read. `nil` while that total is unknown.
    private var scrapeProgress: Double? {
        guard let target = pageTarget, target > 0 else { return nil }
        return min(1, Double(pagesExtracted) / Double(target))
    }

    /// `true` once an appraisal of any kind has been asked for — a row, a batch, or a whole-board
    /// **Eval all**. Before that, the board's own work is the scrape and nothing else.
    private var hasAppraisalWork: Bool {
        phase == .valuing || isScanning || terminalCount > 0 || prePricedCount > 0
    }

    /// Lots the appraiser has answered for: valued, failed, skipped, or carrying the cheap text-only
    /// eval. An eval is a figure the operator asked for, so it counts — without it **Eval all** would
    /// finish with an empty bar, which is exactly the bug this replaced.
    private var answeredCount: Int {
        lots.count { $0.analysisState.isTerminal || $0.isPrePriced }
    }

    private var appraisalProgress: Double {
        guard !lots.isEmpty else { return 1 }
        return min(1, Double(answeredCount) / Double(lots.count))
    }

    var progressLabel: String {
        switch phase {
        case .scraping:
            return "Scraping — \(scrapedPageText(max(pagesExtracted, 1)))"
        case .idle:
            return "Waiting to start"
        case .valuing:
            return lots.isEmpty ? phase.label : "Valued \(terminalCount) of \(lots.count)"
        case .finished, .stopped, .failed:
            guard !lots.isEmpty else { return phase.label }
            return terminalCount == 0
                ? "Loaded \(lots.count) lot(s) — nothing scanned"
                : "Valued \(terminalCount) of \(lots.count)"
        }
    }

    /// Where a scrape is, in the most specific form known: the listing's own count when it reported
    /// one ("page 2 of 24"), the operator's budget otherwise ("page 2 of 3"), and **All pages** with
    /// no count as just that — "page 2 — all pages", because there is no number to print yet and a
    /// made-up 100 would read as a promise.
    private func scrapedPageText(_ page: Int) -> String {
        if let listingPageCount { return "page \(page) of \(listingPageCount)" }
        return settings.walksEveryPage ? "page \(page) — all pages" : "page \(page) of \(pageLimit)"
    }

    var totalCurrentBid: Double { lots.reduce(0) { $0 + $1.currentBid } }
    var totalRetail: Double { lots.reduce(0) { $0 + $1.totalRetail } }
    var totalResale: Double { lots.reduce(0) { $0 + $1.totalResale } }
    var totalProjectedProfit: Double { totalResale - totalCurrentBid }
    var totalDiscoveredItems: Int { lots.reduce(0) { $0 + $1.itemCount } }

    var countsSummary: String {
        "\(lots.count) lot(s) · \(valuedCount) valued · \(failedCount) failed · \(skippedCount) skipped"
    }

    var canStart: Bool { !isRunning && settings.canStartScrape }

    // MARK: - Browser panel

    /// Whether the live auction page is shown in the browser sheet.
    private(set) var isBrowserVisible = false

    /// The live page, or `nil` before the first run. Handed to `BrowserPanelView`.
    var pageSurface: WKWebView? { scraper?.webView }

    var canShowBrowser: Bool { pageSurface != nil }

    /// Shows/hides the browser sheet; refuses to open it before there is a page to show.
    func setBrowserVisible(_ visible: Bool) {
        isBrowserVisible = visible && canShowBrowser
    }

    // MARK: - Control

    /// Starts a fresh run. The run **scrapes only**: pages are walked and the table fills in, but
    /// no API call is made, so a run can never spend a token on a lot nobody asked about. Lots are
    /// appraised on demand — **Eval** / **Price** on a row, or the two all-lots buttons in the
    /// table toolbar.
    func run() {
        guard !isRunning else { return }
        guard let url = settings.auctionURLValue else {
            let message = "Enter a valid http(s) auction URL before running."
            phase = .failed(message)
            statusText = message
            log(message, source: .error)
            return
        }

        settings.persist()
        resetRunState()
        scansWereStopped = false
        phase = .scraping
        statusText = "Opening \(url.host() ?? url.absoluteString)"
        log("Run started — \(url.absoluteString) (\(settings.pageLimitSummary))")
        if !settings.hasAPIKey {
            log(
                "No \(settings.provider.displayName) key yet — lots will load, but scanning a row needs one.",
                source: .error
            )
        }

        runTask = Task { [settings] in
            await self.execute(url: url, settings: settings)
        }
    }

    /// Requests cancellation of everything in flight: the scrape, either batch, and any per-row
    /// scan or pre-price. Each cancelled job parks its own row, so no row is left spinning.
    func stop() {
        guard isRunning else { return }
        log("Stop requested — cancelling")
        statusText = "Stopping…"
        scansWereStopped = true
        runTask?.cancel()
        scanBatchTask?.cancel()
        prePriceBatchTask?.cancel()
        for task in scanTasks.values { task.cancel() }
        for task in prePriceTasks.values { task.cancel() }
    }

    /// Empties the table and the console (only when nothing is running).
    func clearResults() {
        guard !isRunning else { return }
        resetRunState()
        logLines.removeAll()
        phase = .idle
        statusText = "Ready — paste an auction URL, then press Run."
    }

    /// Drops every row's valuation so the next run starts clean.
    func resetValuations() {
        guard !isRunning else { return }
        for lot in lots { lot.resetValuation() }
        valuedCount = 0
        failedCount = 0
        skippedCount = 0
        phase = .idle
        statusText = "Valuations cleared."
    }

    private func resetRunState() {
        lots.removeAll()
        seenLotKeys.removeAll()
        pagesExtracted = 0
        valuedCount = 0
        failedCount = 0
        skippedCount = 0
        emptyListingNote = nil
        listingPageCount = nil
        pageLimit = settings.effectivePageLimit
    }

    // MARK: - Pipeline

    private func execute(url: URL, settings: AppSettings) async {
        let scraper = existingScraper()
        do {
            let scraped = try await scraper.scrape(
                startURL: url,
                credentials: settings.credentials,
                pageLimit: settings.effectivePageLimit
            ) { [weak self] event in
                self?.handle(event)
            }

            // Rows normally stream in through `.pageExtracted`; this is the safety net for a
            // scrape that completed without the UI having seen every page event.
            for lot in scraped where seenLotKeys.insert(lot.dedupeKey).inserted {
                lots.append(LotItem(scraped: lot))
            }

            guard !lots.isEmpty else {
                let message = "No lots were found on that page. Open the log for page diagnostics."
                phase = .failed(message)
                statusText = message
                log(message, source: .error)
                return
            }

            // Every lot on the board is sold: the scrape worked, the auction simply has nothing left
            // to bid on. Say that plainly instead of leaving a table of rows unexplained — the rows
            // are still workable (a closed lot's appraisal is a record worth having), so the note
            // points at that rather than at a dead end.
            if lots.allSatisfy({ !$0.isActive }) {
                let message = "No active listings — all \(lots.count) lot(s) on this auction are marked sold. "
                    + "They are still priceable: Eval or Price any row for its figures."
                emptyListingNote = message
                phase = .finished
                statusText = message
                log(message, source: .scraper)
                return
            }

            // Scrape only. Appraisal is on demand, so a run never spends a token by itself.
            let canScan = settings.canScanLots
            log(
                canScan
                    ? "\(lots.count) lot(s) loaded — press Eval for a text-only estimate or Price "
                        + "for photographs (or either all-lots button) to appraise with "
                        + "\(settings.activeModelID)\(pacingSuffix(for: settings))"
                    : "\(lots.count) lot(s) loaded — add a \(settings.provider.displayName) key to "
                        + "scan a row"
            )

            if Task.isCancelled {
                phase = .stopped
                statusText = "Stopped after \(pagesExtracted) page(s)."
                log("Run stopped by the operator")
            } else {
                phase = .finished
                statusText = canScan
                    ? "Loaded \(lots.count) lot(s) — scan them on demand"
                    : "Loaded \(lots.count) lot(s) — no API key, so nothing can be scanned"
                log("Scrape finished — \(lots.count) lot(s) ready to scan")
            }
        } catch ScraperError.noActiveLots(let detail) {
            // Not a failure: the auction answered, and the answer was "nothing to bid on". Reported
            // as a finished run so the console does not cry wolf over a closed sale.
            let message = "No active listings — the auction has nothing to bid on (\(detail))."
            emptyListingNote = message
            phase = .finished
            statusText = message
            log(message, source: .scraper)
        } catch {
            if Task.isCancelled || Self.isCancellation(error) {
                phase = .stopped
                statusText = "Stopped — \(countsSummary)"
                log("Run cancelled", source: .error)
            } else {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .failed(message)
                statusText = message
                log(message, source: .error)

                // A captcha / MFA prompt can only be cleared by a human, so put the real page
                // in front of them instead of waiting for them to find the Browser button.
                if case ScraperError.manualVerificationRequired = error {
                    setBrowserVisible(true)
                }
            }
        }
    }

    /// Returns the process-wide scraper, building it on first use.
    private func existingScraper() -> AuctionScraperService {
        if let scraper { return scraper }
        let created = AuctionScraperService(profile: .genericBase()) { [weak self] message in
            self?.log(message, source: .page)
        }
        scraper = created
        return created
    }

    /// `true` for the several shapes a cancellation can take (Swift concurrency or URLSession).
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let failure = error as NSError
        return failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled
    }

    // MARK: - Scraper events

    /// Projects a scraper progress event onto the observable state.
    private func handle(_ event: ScraperEvent) {
        switch event {
        case .status(let message):
            statusText = message
            log(message, source: .scraper)

        case .pageStarted(let page, let limit, let lotsSoFar):
            pageLimit = limit
            statusText = "Scanning \(scrapedPageText(page))"
            log("Page \(page) started — \(lotsSoFar) lot(s) known", source: .scraper)

        case .pageExtracted(let page, let lots, let runningTotal):
            pagesExtracted = max(pagesExtracted, page)
            var added = 0
            for lot in lots where seenLotKeys.insert(lot.dedupeKey).inserted {
                self.lots.append(LotItem(scraped: lot))
                added += 1
            }
            statusText = "Page \(page) — \(self.lots.count) lot(s) on the board"
            // Which rows can offer **Open** is decided on this page, and the only place that says so
            // is here: a card whose markup carries no address that names the lot leaves the third
            // button off, so the count is worth printing rather than looking like a missing control.
            let linked = lots.filter { $0.detailURLString != nil }.count
            log(
                "Page \(page) extracted: +\(added) row(s) (\(runningTotal) unique reported); "
                    + "\(linked)/\(lots.count) with a lot-page address",
                source: .scraper
            )

        case .pagination(let listing):
            // What the listing said about itself, kept for the **Pages** menu and the progress line:
            // "page 2 of 24" is a better answer than "page 2 of 100".
            listingPageCount = listing.pages
            log(listing.summary, source: .scraper)

        case .paginationFinished(let reason):
            log("Pagination finished: \(reason)", source: .scraper)
            statusText = "Scraping done — \(reason)"
        }
    }

    // MARK: - Valuation

    /// `true` while something owns the pipeline exclusively: a scrape walking pages, a **Price all**
    /// batch, or an **Eval all** batch. A single row's price or eval is *not* exclusive —
    /// rows are meant to be queued.
    private var isExclusiveWork: Bool {
        phase == .scraping || scanBatchTask != nil || prePriceBatchTask != nil
    }

    /// Appraises one lot on demand — what a row's **Price** button calls.
    ///
    /// Nothing is scheduled in advance any more: the operator picks the lots and each scan lands in
    /// its own row. Several rows may be scanned at once, so one slow lot cannot hold up the next
    /// click; the `RequestPacer` shared inside the service still protects the provider's quota.
    func scan(_ lot: LotItem) {
        guard lots.contains(where: { $0.id == lot.id }), scanTasks[lot.id] == nil else { return }
        guard requireScanning() else { return }

        settings.persist()
        scansWereStopped = false

        let service = makeValuationService(settings, scanReporter(for: lot))
        let card = lot.valuationSubject

        lot.markAnalyzing()
        phase = .valuing
        statusText = "Appraising lot \(lot.lotNumber) with \(settings.activeModelID)"
        log(
            "Scanning lot \(lot.lotNumber) — \(settings.provider.displayName) "
                + "\(settings.activeModelID), \(settings.photoScanSummary) on its lot page"
        )

        scanTasks[lot.id] = Task { [weak self] in
            // The cheap text-only first look, when it is switched on: the row shows a provisional
            // figure while the photographed pass is still being paid for. It needs no photographs, so
            // it starts on the card's copy of the listing while the lot page is being read.
            await self?.runPrePrice(lot, subject: card, using: service, automatic: true)

            // The lot's own page decides how many photographs travel — see deviation 24. A page that
            // will not read is not a failure: the card's thumbnails stand in, and the log says so.
            let subject = await self?.subjectForScanning(lot) ?? card

            let result: Result<ValuationOutcome, Error>
            do {
                result = .success(try await service.value(subject: subject))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.finishScan(of: lot, with: result)
        }
    }

    // MARK: - Lot pages

    /// The subject a scan should be made from: the lot's own page when it can be read, the card's
    /// thumbnails when it cannot.
    ///
    /// A lot card only carries a thumbnail or two, so the page is where the photographs actually
    /// are — and how many there are varies per lot, which is exactly why the app asks the page
    /// instead of the operator (deviation 24). The page is read through the listing the scraper
    /// already has loaded, so the request carries the login session and the results page never
    /// moves; the whole path is best-effort, because a scan must not fail over a page that will not
    /// read.
    private func subjectForScanning(_ lot: LotItem) async -> ValuationSubject {
        let card = lot.valuationSubject
        guard let detailURL = lot.detailURL else { return card }
        // No scraper, or one that has never loaded a page: there is no session to read the lot page
        // with, and building a web view just for this would be a page load per scan.
        guard let scraper, let page = scraper.webView.url,
              page.scheme == "http" || page.scheme == "https" else {
            return card
        }

        do {
            let report = try await scraper.lotPageImages(for: detailURL)
            guard report.ok, !report.imageURLs.isEmpty else {
                log(
                    "Lot \(lot.lotNumber): \(report.summary) — scanning the card's "
                        + "\(card.imageURLs.count) thumbnail(s) instead",
                    source: .scraper
                )
                return card
            }
            log("Lot \(lot.lotNumber): \(report.summary)", source: .scraper)
            return card.withImages(report.imageURLs)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log(
                "Lot \(lot.lotNumber): the lot page could not be read (\(message)) — scanning the "
                    + "card's thumbnails instead",
                source: .scraper
            )
            return card
        }
    }

    // MARK: - Pre-price

    /// Evals one lot from its listing text alone — the row's **Eval** button.
    ///
    /// This is the cheap half of a scan, on its own: one text-only request, no photograph fetched or
    /// billed, no line items. The row keeps saying "not scanned" while its money columns carry a
    /// provisional figure the bid ceiling can be read from, which is the whole point of having the
    /// button: a page of lots can be priced for less than one photographed scan, so images are only
    /// spent on the lots that look worth it.
    ///
    /// A click is an explicit request, so nothing conditions it: see `runPrePrice` for the pass that
    /// rides along in front of a scan, which stands aside for a row that already has numbers.
    func prePrice(_ lot: LotItem) {
        guard lots.contains(where: { $0.id == lot.id }) else { return }
        // One request per row at a time, whichever kind it happens to be.
        guard scanTasks[lot.id] == nil, prePriceTasks[lot.id] == nil else { return }
        guard requireScanning() else { return }

        settings.persist()
        scansWereStopped = false

        let service = makeValuationService(settings, { _ in })
        let subject = lot.valuationSubject

        lot.markPrePricing()
        phase = .valuing
        statusText = "Evaluating lot \(lot.lotNumber) from its listing text"
        log(
            "Evaluating lot \(lot.lotNumber) — \(settings.provider.displayName) "
                + "\(settings.activeModelID), listing text only (no images sent)"
        )

        prePriceTasks[lot.id] = Task { [weak self] in
            let result: Result<PrePriceEstimate, Error>
            do {
                result = .success(try await service.prePrice(subject: subject))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.finishPrePrice(of: lot, with: result)
        }
    }

    /// Evals every lot that has no figure at all — the table's **Eval all** button.
    ///
    /// Bounded by the same batch width as a batch scan, so the cheap pass cannot outspend a run it is
    /// arguably replacing. Lots that already carry a valuation or an eval are left alone rather than
    /// re-evaluated: pressing the button twice must not pay twice. Sold lots are included — see
    /// `canScanUnvalued`.
    func prePriceUnvalued() {
        guard !isRunning, requireScanning() else { return }

        let targets = lots.filter { !$0.hasValuation && !$0.isPrePriced }
        guard !targets.isEmpty else {
            statusText = "Every lot already has a figure."
            return
        }

        settings.persist()
        scansWereStopped = false
        phase = .valuing
        statusText = "Evaluating \(targets.count) lot(s) from their listing text"
        log(
            "Evaluating \(targets.count) lot(s) with \(settings.provider.displayName) "
                + "\(settings.activeModelID) — no images, \(AppSettings.batchConcurrency) at a time"
                + pacingSuffix(for: settings)
        )

        let service = makeValuationService(settings, { _ in })
        let concurrency = AppSettings.batchConcurrency
        prePriceBatchTask = Task { [weak self] in
            await self?.prePrice(targets, using: service, concurrency: concurrency, automatic: false)
            guard let self else { return }
            self.finishPrePriceBatch(stopped: Task.isCancelled || self.scansWereStopped)
        }
    }

    /// Closes out an **Eval all** batch.
    ///
    /// Its own closing line rather than the scan batch's, because a cheap pass has valued nothing:
    /// saying "finished — 0 valued" would read as a failure when it did exactly what was asked.
    private func finishPrePriceBatch(stopped: Bool) {
        prePriceBatchTask = nil
        phase = stopped ? .stopped : .finished
        statusText = stopped
            ? "Eval stopped — \(prePricedCount) of \(lots.count) lot(s) evaluated"
            : "Evaluated \(prePricedCount) of \(lots.count) lot(s) from their listing text"
        log(stopped ? "Eval batch stopped" : "Eval batch finished — \(prePricedCount) lot(s) evaluated")
    }


    /// One row's pre-price *inside a scan*, when there is still something to gain.
    ///
    /// `automatic` is what separates the two callers: the automatic pass is the one that stands aside
    /// for a row that already has numbers, while an explicit click (see `prePrice(_:)`) is honoured
    /// either way.
    ///
    /// The automatic pass is unconditional now. It used to sit behind a **Text-only first look**
    /// switch, and the switch was the wrong place for the decision: what it bought was a provisional
    /// figure for a row that has none, which is exactly what a row with no figure wants, and the
    /// alternative — a photographed scan with no text to correct it — is the one another setting
    /// (**Eval all**) already covers for the whole board.
    private func runPrePrice(
        _ lot: LotItem,
        subject: ValuationSubject,
        using service: ValuationService,
        automatic: Bool
    ) async {
        if automatic {
            guard !lot.hasValuation, !lot.isPrePriced else { return }
        }
        guard !lot.isPrePricing else { return }

        // Make the provisional state visible the moment the request starts, so a slow model reads
        // as "thinking" rather than as nothing happening.
        lot.markPrePricing()

        do {
            record(try await service.prePrice(subject: subject), on: lot)
        } catch {
            recordPrePriceFailure(error, on: lot)
        }
    }

    /// Applies one row's pre-price and unwinds its bookkeeping.
    private func finishPrePrice(of lot: LotItem, with result: Result<PrePriceEstimate, Error>) {
        prePriceTasks[lot.id] = nil

        switch result {
        case .success(let estimate): record(estimate, on: lot)
        case .failure(let error): recordPrePriceFailure(error, on: lot)
        }

        // Something else is still working: let it write the closing line.
        guard prePriceTasks.isEmpty, scanTasks.isEmpty, prePriceBatchTask == nil else { return }
        phase = scansWereStopped ? .stopped : .finished
        statusText = "\(prePricedCount) of \(lots.count) lot(s) evaluated from the listing text"
    }

    /// Records a landed eval on its row and in the console.
    private func record(_ estimate: PrePriceEstimate, on lot: LotItem) {
        lot.applyPrePrice(estimate)
        log(
            "Lot \(lot.lotNumber): evaluated from the listing text — retail "
                + "\(estimate.retail.currencyWholeText), resale \(estimate.resale.currencyWholeText) "
                + "(\(estimate.confidence.rawValue) confidence)",
            source: .valuation
        )
    }

    /// Records an eval that did not land.
    ///
    /// Failure is deliberately quiet and non-fatal: an eval is a bonus figure, and a provider
    /// hiccup here must not take the photographed appraisal down with it. The spinner is cleared
    /// either way so nothing sits "working" forever, and the row keeps whatever it already had.
    private func recordPrePriceFailure(_ error: Error, on lot: LotItem) {
        lot.clearPrePricing()
        if Self.isCancellation(error) { return }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        log("Lot \(lot.lotNumber): eval skipped — \(message)", source: .error)
    }

    /// Appraises every lot that has no valuation yet — the table's **Price all** button.
    ///
    /// Uses the same bounded-width task group the per-row button does, so
    /// `AppSettings.batchConcurrency` still means something, and it is exclusive with the per-row
    /// button so a batch can never pay twice
    /// for a lot somebody just clicked. Sold lots are included — see `canScanUnvalued`.
    func scanUnvalued() {
        guard scanBatchTask == nil, scanTasks.isEmpty, requireScanning() else { return }

        let targets = lots.filter { !$0.hasValuation }
        guard !targets.isEmpty else {
            statusText = "Every lot already has a valuation."
            return
        }

        settings.persist()
        scansWereStopped = false
        phase = .valuing
        statusText = "Appraising \(targets.count) lot(s) with \(settings.activeModelID)"
        log(
            "Scanning \(targets.count) unvalued lot(s) with \(settings.provider.displayName) "
                + "\(settings.activeModelID), \(settings.photoScanSummary) on each lot page, "
                + "\(AppSettings.batchConcurrency) at a time\(pacingSuffix(for: settings))"
        )

        let service = makeValuationService(settings, batchScanReporter())
        let concurrency = AppSettings.batchConcurrency
        scanBatchTask = Task { [weak self] in
            await self?.valuate(targets, using: service, concurrency: concurrency)
            guard let self else { return }
            self.finishBatch(stopped: Task.isCancelled || self.scansWereStopped)
        }
    }

    /// Shared gate for both scan entry points. Explains *why* a scan cannot run instead of quietly
    /// doing nothing, which is what makes a disabled button forgivable.
    private func requireScanning() -> Bool {
        guard !isExclusiveWork else {
            statusText = "A scrape or an all-lots batch is running — wait for it, or press Stop."
            return false
        }
        guard settings.hasAPIKey else {
            let message = "Add a \(settings.provider.displayName) API key behind the gear (⌘,), then scan again."
            statusText = message
            log(message, source: .error)
            return false
        }
        return true
    }

    /// Applies one row's scan result and unwinds the scan bookkeeping when it was the last one.
    private func finishScan(of lot: LotItem, with result: Result<ValuationOutcome, Error>) {
        scanTasks[lot.id] = nil

        switch result {
        case .success(let outcome):
            apply(outcome, to: lot)
        case .failure(let error) where Self.isCancellation(error):
            // Stop was pressed mid-scan. There is no partial answer to keep, so the row goes back
            // to "not valued" — which also leaves it scannable — rather than looking broken.
            lot.resetValuation()
            scansWereStopped = true
            log("Lot \(lot.lotNumber): scan stopped", source: .error)
        case .failure(let error):
            apply(error, to: lot)
        }

        guard scanTasks.isEmpty else { return }
        phase = scansWereStopped ? .stopped : .finished
        statusText = scansWereStopped ? "Stopped — \(countsSummary)" : "Finished — \(countsSummary)"
        if !scansWereStopped { log("Scan finished — \(countsSummary)") }
    }

    /// Closes out a **Price all** batch.
    private func finishBatch(stopped: Bool) {
        scanBatchTask = nil
        phase = stopped ? .stopped : .finished
        statusText = stopped ? "Stopped — \(countsSummary)" : "Finished — \(countsSummary)"
        log(stopped ? "Batch scan stopped" : "Batch scan finished — \(countsSummary)")
    }

    /// Appraises `targets`, keeping at most `concurrency` requests in flight.
    ///
    /// The service is captured as a `Sendable` value so the child tasks never touch the
    /// main-actor coordinator; results come back through the group and are applied here.
    private func valuate(
        _ targets: [LotItem],
        using service: ValuationService,
        concurrency: Int
    ) async {
        let width = min(max(concurrency, 1), max(targets.count, 1))

        // Cheap first: whole-pallet guesses land on their rows while the photographed passes are
        // still queued, so the table is useful during the expensive part of the run.
        await prePrice(targets, using: service, concurrency: width, automatic: true)
        if Task.isCancelled { return }

        await withTaskGroup(of: (Int, Result<ValuationOutcome, Error>).self) { group in
            var next = 0

            while next < targets.count {
                if Task.isCancelled { break }
                let index = next
                next += 1
                targets[index].markAnalyzing()
                let lot = targets[index]
                // One lot page is read per lot, here, in the queueing loop: the GET overlaps the
                // model calls already in flight rather than delaying the batch by a serial pass over
                // every lot's page before the first request goes out.
                let subject = await subjectForScanning(lot)
                group.addTask {
                    do {
                        return (index, .success(try await service.value(subject: subject)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
                // Wait for a slot to free up once the window is full.
                if next < targets.count, next % width == 0, let finished = await group.next() {
                    apply(finished, to: targets)
                }
            }

            if Task.isCancelled { group.cancelAll() }
            for await finished in group {
                if Task.isCancelled { continue }
                apply(finished, to: targets)
            }
        }
    }

    /// Runs the cheap text-only first look over a batch.
    ///
    /// Bounded by the same batch width as the real appraisal so the pre-price pass cannot outspend
    /// the run it is warming up, and never fatal: a lot that cannot be pre-priced simply waits for its
    /// photographed valuation, which is what would have happened anyway.
    ///
    /// `automatic` is the difference between the two callers, exactly as in `runPrePrice`: the
    /// "already has numbers" filter applies to the pass that rides along in front of a scan, while
    /// **Eval all** has already decided that question for itself.
    private func prePrice(
        _ targets: [LotItem],
        using service: ValuationService,
        concurrency: Int,
        automatic: Bool
    ) async {
        let pending = targets.filter { !$0.hasValuation && !$0.isPrePriced && !$0.isPrePricing }
        guard !pending.isEmpty else { return }

        log("Evaluating \(pending.count) lot(s) from their listing text before pricing them")
        pending.forEach { $0.markPrePricing() }

        let subjects = pending.map(\.valuationSubject)
        let width = min(max(concurrency, 1), max(pending.count, 1))

        await withTaskGroup(of: (Int, Result<PrePriceEstimate, Error>).self) { group in
            var next = 0

            while next < subjects.count {
                if Task.isCancelled { break }
                let index = next
                next += 1
                let subject = subjects[index]
                group.addTask {
                    do {
                        return (index, .success(try await service.prePrice(subject: subject)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
                if next < subjects.count, next % width == 0, let finished = await group.next() {
                    applyPrePrice(finished, to: pending)
                }
            }

            if Task.isCancelled { group.cancelAll() }
            for await finished in group {
                if Task.isCancelled { continue }
                applyPrePrice(finished, to: pending)
            }
        }

        // Anything cancelled mid-flight must not sit on a spinner for the rest of the session.
        pending.filter(\.isPrePricing).forEach { $0.clearPrePricing() }
    }

    /// Routes one batch pre-price to its row, by way of the same record helpers the single-row
    /// button uses, so both routes log and park a row identically.
    private func applyPrePrice(_ result: (Int, Result<PrePriceEstimate, Error>), to targets: [LotItem]) {
        let index = result.0
        guard targets.indices.contains(index) else { return }
        let lot = targets[index]

        switch result.1 {
        case .success(let estimate): record(estimate, on: lot)
        case .failure(let error): recordPrePriceFailure(error, on: lot)
        }
    }

    /// Routes one grouped result to its row.
    private func apply(_ result: (Int, Result<ValuationOutcome, Error>), to targets: [LotItem]) {
        let index = result.0
        guard targets.indices.contains(index) else { return }
        let lot = targets[index]

        switch result.1 {
        case .success(let outcome):
            apply(outcome, to: lot)
        case .failure(let error) where Self.isCancellation(error):
            // The batch was stopped: hand the row back as "not valued" so it can be scanned again.
            lot.resetValuation()
        case .failure(let error):
            apply(error, to: lot)
        }
    }

    /// Records a successful appraisal on its row and in the console.
    private func apply(_ outcome: ValuationOutcome, to lot: LotItem) {
        lot.applyValuation(
            outcome.items,
            imagesAnalyzed: outcome.imagesSent,
            passes: outcome.passes,
            readings: outcome.readings
        )
        valuedCount += 1
        // What the app's own reader made of the photographs travels with the figures rather than
        // staying in the prompt: it is the literal answer to "what is this price based on?", and it is
        // the one part of a valuation the operator can check against the photographs without spending
        // another request. Printed before the summary so the summary closes the lot's block.
        if let evidence = outcome.evidence {
            log("Lot \(lot.lotNumber): label reader read \(evidence.logPhrase)", source: .valuation)
        }
        // The thorough path's own accounting: how many photographs were read one at a time, how many
        // of those were free because this machine already knew them, and — when the last request was
        // the one that failed — that the line items were reconciled here instead.
        if !outcome.readings.isEmpty {
            let summary = outcome.readings.photoSummary
            log("Lot \(lot.lotNumber): \(summary.logPhrase)", source: .valuation)
            if outcome.readingsFromStore > 0 {
                log(
                    "Lot \(lot.lotNumber): \(outcome.readingsFromStore) reading(s) reused from this "
                        + "machine, \(outcome.scanRequests) request(s) sent",
                    source: .valuation
                )
            }
            if let reason = outcome.reconciliationFailure {
                log(
                    "Lot \(lot.lotNumber): reconciled on this machine — \(reason)",
                    source: .valuation
                )
            }
        }
        log(
            "Lot \(lot.lotNumber): \(outcome.items.count) item(s) — retail "
                + "\(lot.totalRetail.currencyWholeText), resale \(lot.totalResale.currencyWholeText), "
                + imagesPhrase(for: outcome)
                + "\(outcome.passes > 1 ? " in \(outcome.passes) passes" : "") "
                + "via \(outcome.modelID)",
            source: .valuation
        )
        statusText = "Valued \(terminalCount) of \(lots.count) — \(valuedCount) ok, \(failedCount) failed"
    }

    /// How many photographs travelled, out of how many the lot offered.
    ///
    /// The one place the "every image on the lot page" rule is visible: a lot whose gallery did not
    /// all fit one request says so — and says *why* — instead of quietly reading as if the lot had
    /// fewer photographs. A shortfall with nothing "over the inline budget" is an image that could
    /// not be downloaded at all, which the row's own failure text covers in detail.
    private func imagesPhrase(for outcome: ValuationOutcome) -> String {
        guard outcome.imagesSent < outcome.imagesAvailable else {
            return "\(outcome.imagesSent) image(s)"
        }
        let budgetNote = outcome.imagesSkipped > 0
            ? ", \(outcome.imagesSkipped) over the inline budget"
            : ""
        return "\(outcome.imagesSent) of \(outcome.imagesAvailable) image(s)\(budgetNote)"
    }

    /// Records a failed appraisal on its row and in the console.
    private func apply(_ error: Error, to lot: LotItem) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lot.markFailed(message)
        failedCount += 1
        log("Lot \(lot.lotNumber) failed: \(message)", source: .error)
        statusText = "Valued \(terminalCount) of \(lots.count) — \(valuedCount) ok, \(failedCount) failed"
    }

    // MARK: - Logging

    /// Describes the outbound pacing in the run log, so a slow run is explained rather than
    /// mistaken for a hang.
    private func pacingSuffix(for settings: AppSettings) -> String {
        settings.requestsPerMinute > 0
            ? ", paced to \(settings.requestsPerMinute) request(s)/min"
            : ""
    }

    private func log(_ message: String, source: LogLine.Source = .app) {
        logLines.append(LogLine(timestamp: .now, source: source, message: message))
        if logLines.count > logLimit {
            logLines.removeFirst(logLines.count - logLimit)
        }
    }
}
