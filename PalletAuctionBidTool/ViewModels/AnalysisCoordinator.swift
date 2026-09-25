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

    /// Rows of the page currently being read that have landed on the board, and how many cards that page
    /// reported. Both are cleared when the next page starts, and they are what the walk's bar counts
    /// *within* a page: a **1 page** run creeps as the board fills rather than standing still until the
    /// walk is over (see `PageWalkProgress.fraction`).
    private(set) var pageRowsLanded = 0
    private(set) var pageRowsOnPage = 0
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

    /// Lot pages already read in this run, keyed by lot: the gallery *and* the description the page
    /// carried (see `subjectForLotPage`).
    ///
    /// The page is read at most **once per lot per action**, because the two things it is read for —
    /// the photographs a scan appraises from, and the listing's own description that both passes build
    /// their prompt from — are wanted first by the cheap pass and then by the photographed one, and a
    /// second GET would buy nothing. Entries are dropped when an action starts for that lot and when a
    /// run is reset, so a retry re-reads the page rather than reusing a gallery from an earlier
    /// attempt.
    private var lotPageSubjects: [UUID: ValuationSubject] = [:]

    /// Set when **Stop** cancelled a scan, so the closing status line says "stopped" rather than
    /// "finished".
    private var scansWereStopped = false

    /// The appraisal the operator last asked for: the rows it covers and which button started it.
    ///
    /// Kept when a job ends rather than cleared with it, so a row's **Price** keeps naming its row
    /// (`Pricing Lot #19002`) instead of falling back to the board's count the moment its one row is
    /// done.
    /// Cleared when the rows themselves go — **Clear**, **Run** and **Reset valuations** — because a
    /// job about rows that no longer exist has nothing left to report.
    private var appraisalJob: AppraisalJob?

    /// The row the appraisal is on right now, and the step inside it — what the modal's detail line and
    /// its money readout speak for.
    ///
    /// The row outlives the step it names on purpose: a row's figures land as its last step ends, and a
    /// money line that emptied itself the instant the answer arrived would hide the very number the
    /// operator was waiting for. `inHandStep` is therefore cleared the moment there is no step in
    /// progress, while the row stays until something else takes the readout over — the next row clicked,
    /// **Clear**, or a fresh run.
    private(set) var inHandLotID: UUID?

    /// The step the row in hand is on; `nil` between steps and once that row is done.
    private(set) var inHandStep: AppraisalStep?

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

    /// One scan step: a console line, the live note on the row, and the readout's own step.
    ///
    /// The note is written only while the row is still being read. A report is delivered from another
    /// task, so one can land after the scan has already finished — and a completed row wearing
    /// `photograph 12 of 12` would read as a scan that never ended. The readout's step is taken from the
    /// report either way: it is what says which row the modal's money line is speaking for.
    private func record(_ report: PhotoScanReport, on lot: LotItem) {
        log(report.logLine, source: .valuation)
        // The report names a step to *start* or one that has just landed; `nil` means it closed
        // something out (a reconciliation that landed), which leaves the readout where it was.
        if let step = AppraisalStep(report.event) { note(step, on: lot) }
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
    /// pages read out of the pages this run is going to read, and once things are being appraised it is
    /// the rows of *that* appraisal — the single lot a row's **Price** clicked, or the pending board an
    /// **Eval all** covers (see `appraisalJob`). A three-page run therefore fills 1/3, 2/3, full as it
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

    /// What this run will read, in pages — the denominator of the walk's readout and its bar.
    ///
    /// The rule itself lives in `PageWalkProgress.target`, with its own checks in the offline harness:
    /// "1 page" in **Run Tuning** against a site whose pager advertises four is a one-page job, and the
    /// pill has to say `page 1 of 1` rather than promise the three pages nobody is going to read. `nil`
    /// is an **All pages** walk of a listing that has not reported a count yet.
    private var pageTarget: Int? {
        PageWalkProgress.target(
            budget: pageLimit,
            walksEveryPage: settings.walksEveryPage,
            listingPages: listingPageCount
        )
    }

    /// Pages read, out of the pages this run intends to read, plus the share of the page being read whose
    /// cards have landed. `nil` while that total is unknown.
    private var scrapeProgress: Double? {
        PageWalkProgress.fraction(
            pagesRead: pagesExtracted,
            pageRowsLanded: pageRowsLanded,
            pageRowsOnPage: pageRowsOnPage,
            target: pageTarget
        )
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

    /// Records what an appraisal covers, which is what the pill and the bar count against.
    ///
    /// A row's button joins a row-sized job of the same kind already in hand: several rows may be
    /// clicked through at once (`canScan` allows it), and a second click would otherwise re-point the
    /// readout at itself while the first was still running — two rows at work, `1 of 1` claimed. A
    /// batch always replaces what was there: it is exclusive with the row buttons, and its own scope is
    /// the pending set it was built from.
    private func beginAppraisal(kind: AppraisalJob.Kind, lotIDs: [UUID], isBatch: Bool) {
        if !isBatch, let job = appraisalJob, !job.isBatch, job.kind == kind {
            var joined = job
            lotIDs.forEach { joined.include($0) }
            appraisalJob = joined
            return
        }
        appraisalJob = AppraisalJob(kind: kind, lotIDs: lotIDs, isBatch: isBatch)
    }

    /// How many of a job's rows the appraiser has answered.
    ///
    /// A **Price** is answered once its row is terminal, and `LotItem.markAnalyzing` clears that state
    /// as the request starts — so a re-price of a row that already carried figures counts its own work
    /// rather than reading as done the moment it began. An **Eval** is answered once the cheap pass has
    /// stopped, which is the only mark a text-only request leaves: `markPrePricing` goes on before the
    /// request and comes off when it lands *or* fails, so a failure closes its row instead of pinning
    /// the bar short of full on a job that is over.
    private func answeredRows(in job: AppraisalJob) -> Int {
        job.lotIDs.count { id in
            guard let lot = lots.first(where: { $0.id == id }) else { return false }
            switch job.kind {
            case .price: return lot.analysisState.isTerminal
            case .eval: return !lot.isPrePricing
            }
        }
    }

    /// The row the modal's detail line and money readout speak for, when one is in hand.
    var inHandLot: LotItem? {
        guard let inHandLotID else { return nil }
        return lots.first { $0.id == inHandLotID }
    }

    /// The row in hand's own figures — open bid, retail, resale, profit — as the modal's bottom line
    /// prints them, or `nil` when no row is in hand.
    ///
    /// The row's *display* figures, which is the same pair the table's money columns print: its valuation
    /// when it has one and its text-only eval until then. That is what makes the line move during an
    /// **Eval** run, where nothing has been valued yet and the board's own totals are all zero.
    var inHandMoney: LotMoney? {
        guard let lot = inHandLot else { return nil }
        return LotMoney(
            currentBid: lot.currentBid,
            retail: lot.displayRetail,
            resale: lot.displayResale,
            provisional: !lot.hasValuation && lot.isPrePriced
        )
    }

    /// The step the row in hand is on, in the words the modal prints: `Lot 19002 — photograph 5 of 12`.
    var progressStep: String? {
        guard let lot = inHandLot, let step = inHandStep else { return nil }
        return "Lot \(lot.lotNumber) — \(step.phrase)"
    }

    /// Records that the appraiser is on `step` in `lot`, which is what the readout points itself at.
    private func note(_ step: AppraisalStep, on lot: LotItem) {
        inHandLotID = lot.id
        inHandStep = step
    }

    /// Points the readout at a row that has no step yet — what a row's button does the moment it is
    /// pressed, so the modal's money line is about the row the operator asked for before the first
    /// request has even gone out.
    private func pointReadout(at lot: LotItem) {
        inHandLotID = lot.id
        inHandStep = nil
    }

    /// Notes that the row in hand has finished the step it was on, without forgetting the row itself:
    /// see `inHandLotID`.
    private func finishStep(for lot: LotItem) {
        guard inHandLotID == lot.id else { return }
        inHandStep = nil
    }

    /// Drops the readout's row and step — the rows they name are going away.
    private func resetInHandRow() {
        inHandLotID = nil
        inHandStep = nil
    }

    /// The job in hand as the pill prints it: `Evaluating Lot #19002`, `Pricing Lot #3 of 12`.
    private func appraisalText(_ job: AppraisalJob) -> String {
        job.text(
            AppraisalJob.Position(
                lotNumber: inHandLot?.lotNumber,
                index: job.position(of: inHandLotID),
                answered: answeredRows(in: job)
            )
        )
    }

    /// The line under the counters while rows are being appraised: the job in hand, then the board's
    /// own tally.
    ///
    /// The pill names the job; this adds what the pill cannot say — how the board stands after it. The
    /// two are genuinely different numbers for a single row (`Pricing Lot #19002` *and* `1 ok, 0 failed`
    /// out of a hundred rows), so both are printed rather than one standing in for the other.
    private func appraisalTally() -> String {
        let board = "\(valuedCount) ok, \(failedCount) failed"
        guard let job = appraisalJob else { return "Valued \(terminalCount) of \(lots.count) — \(board)" }
        return "\(appraisalText(job)) — \(board)"
    }

    /// What the bar fills against while things are being appraised: the job's own rows when one is in
    /// hand, and the board otherwise.
    ///
    /// The row in hand contributes its current step's share, so the bar creeps through a photographed
    /// appraisal — one tick per photograph — instead of standing still for the two minutes a dozen
    /// requests take. A step's share is always short of 1, so a row only ever counts as a whole row once
    /// it has actually been answered.
    private var appraisalProgress: Double {
        if let job = appraisalJob, job.count > 0 {
            let answered = Double(answeredRows(in: job)) + inHandShare(in: job)
            return min(1, answered / Double(job.count))
        }
        guard !lots.isEmpty else { return 1 }
        return min(1, (Double(answeredCount) + stepShare) / Double(lots.count))
    }

    /// How much of the row in hand's own share counts, when that row belongs to `job` — or the raw share
    /// when the readout is speaking for the board.
    private func inHandShare(in job: AppraisalJob) -> Double {
        guard let id = inHandLotID, job.lotIDs.contains(id) else { return 0 }
        return stepShare
    }

    /// The current step's share of its row, or `0` when nothing is mid-step.
    private var stepShare: Double { inHandStep?.share ?? 0 }

    var progressLabel: String {
        switch phase {
        case .scraping:
            // The rows count, not just the pages: a page is one request but many lots, and the number
            // that moves as the board fills is what says the walk is getting somewhere.
            let page = scrapedPageText(max(pagesExtracted, 1))
            return lots.isEmpty ? "Scraping — \(page)" : "Scraping — \(page) · \(lots.count) lot(s)"
        case .idle:
            return "Waiting to start"
        case .valuing:
            if let job = appraisalJob { return appraisalText(job) }
            return lots.isEmpty ? phase.label : "Valued \(terminalCount) of \(lots.count)"
        case .finished, .stopped, .failed:
            // A job that has been asked for says what became of it, whatever phase closed it out:
            // "Pricing Lot #19002" is the answer to a row's button, and the board's count is not.
            if let job = appraisalJob { return appraisalText(job) }
            guard !lots.isEmpty else { return phase.label }
            return terminalCount == 0
                ? "Loaded \(lots.count) lot(s) — nothing scanned"
                : "Valued \(terminalCount) of \(lots.count)"
        }
    }

    /// Where a scrape is, in the most specific form known: pages read out of the pages this run is
    /// going to read (`pageTarget` — the operator's **Pages** budget, capped by the listing's own
    /// count when it has reported one), and **All pages** with no count as just that — "page 2 — all
    /// pages", because there is no number to print yet and a made-up 100 would read as a promise.
    private func scrapedPageText(_ page: Int) -> String {
        PageWalkProgress.text(page: page, target: pageTarget)
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

        runTask = Task { @MainActor [settings] in
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
        // The rows are still here but the figures the job reported are not, so the readout goes back
        // to "waiting" rather than closing out a job whose answers have been thrown away — and the money
        // line stops speaking for a row whose figures it just dropped.
        appraisalJob = nil
        resetInHandRow()
        phase = .idle
        statusText = "Valuations cleared."
    }

    private func resetRunState() {
        lots.removeAll()
        seenLotKeys.removeAll()
        lotPageSubjects.removeAll()
        appraisalJob = nil
        resetInHandRow()
        pagesExtracted = 0
        pageRowsLanded = 0
        pageRowsOnPage = 0
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
            // A new page's own rows start from nothing: the bar counts the page it is reading.
            pageRowsLanded = 0
            pageRowsOnPage = 0
            statusText = "Scanning \(scrapedPageText(page))"
            log("Page \(page) started — \(lotsSoFar) lot(s) known", source: .scraper)

        case .lotExtracted(let page, let index, let of, let lot):
            // One row, as it lands. The page's cards come back in a single payload, so what this counts
            // is the app's own insertion of them — one row, one update — which is what the pill's lot
            // count, the bar and the table all move on.
            pageRowsLanded = index
            pageRowsOnPage = of
            guard seenLotKeys.insert(lot.dedupeKey).inserted else { break }
            self.lots.append(LotItem(scraped: lot))
            statusText = of > 1
                ? "Page \(page) — card \(index) of \(of) on it, \(lots.count) lot(s) on the board"
                : "Page \(page) — \(lots.count) lot(s) on the board"

        case .pageExtracted(let page, let cards, let newLots, let linked, let runningTotal):
            pagesExtracted = max(pagesExtracted, page)
            // The page is read: its own share gives way to the page count itself.
            pageRowsLanded = 0
            pageRowsOnPage = 0
            statusText = "Page \(page) — \(self.lots.count) lot(s) on the board"
            // Which rows can offer **Open** is decided on the page, and the count is worth printing
            // rather than looking like a missing control: a card whose markup carries no address that
            // names the lot leaves that row's third button off.
            log(
                "Page \(page) extracted: +\(newLots) row(s) (\(runningTotal) unique reported); "
                    + "\(linked)/\(cards) with a lot-page address",
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

    /// Hands a task's result back to the main actor, whatever thread that task last resumed on.
    ///
    /// A `Task { [weak self] in … }` written inside this class reads as if it ran on the main actor,
    /// and at the top it does: the body is compiled against this class's isolation and its first
    /// statement runs there. What the type system cannot promise is where the body *resumes* after an
    /// `await` — the continuing statements run on whatever executor the runtime returns the task to,
    /// and a synchronous call into a main-queue-only path from a cooperative thread does not apply
    /// anything: it trips `dispatch_assert_queue` inside the callee's own isolation check, which is an
    /// `EXC_BREAKPOINT` inside the app rather than a compile error.
    ///
    /// `LotItem.applyValuation` is exactly such a path — the row's totals and its items are written
    /// under `@MainActor` — so every task below hands its result over through this hop instead of
    /// calling `finishScan`/`finishPrePrice`/… directly. The hop costs one suspension at a point where
    /// the work was already asynchronous, and it buys the one thing the task bodies were assuming:
    /// that the row is touched on the main actor, by construction rather than by convention.
    private nonisolated func onMainActor(_ body: @MainActor @Sendable () -> Void) async {
        await MainActor.run(body: body)
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
        // A fresh click re-reads the lot's page: the gallery on it may have changed since the last
        // attempt, and a row that failed a moment ago is exactly the row worth retrying.
        lotPageSubjects[lot.id] = nil

        lot.markAnalyzing()
        // The job in hand is this one row — or one more row onto the same job, if another **Price**
        // is still running. The readout points at it before anything is requested, so its own figures
        // are on the modal's money line from the first click.
        pointReadout(at: lot)
        beginAppraisal(kind: .price, lotIDs: [lot.id], isBatch: false)
        phase = .valuing
        statusText = "Appraising lot \(lot.lotNumber) with \(settings.activeModelID)"
        log(
            "Scanning lot \(lot.lotNumber) — \(settings.provider.displayName) "
                + "\(settings.activeModelID), \(settings.photoScanSummary) on its lot page"
        )

        scanTasks[lot.id] = Task { @MainActor [weak self] in
            // The lot's own page is read first, and both passes are built from it — see
            // `subjectForLotPage`. A page that will not read is not a failure: the card's thumbnails
            // and its teaser stand in, and the log says so (deviation 24).
            let subject = await self?.subjectForLotPage(lot) ?? card

            // The cheap text-only first look: the row shows a provisional figure while the
            // photographed pass is still being paid for. It sends no photographs, but it reads the
            // same description the scan will — the page's copy, not the card's teaser.
            await self?.runPrePrice(lot, subject: subject, using: service, automatic: true)

            let result: Result<ValuationOutcome, Error>
            do {
                result = .success(try await service.value(subject: subject))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            // Through the hop rather than called here: see `onMainActor`.
            await self.onMainActor { self.finishScan(of: lot, with: result) }
        }
    }

    // MARK: - Lot pages

    /// The subject a pass should be made from: the lot's own page when it can be read — its gallery
    /// **and** its description — and the card alone when it cannot.
    ///
    /// A lot card only carries a thumbnail or two and a teaser ("Pallet of General Merchandise"), so
    /// the page is where the photographs actually are and where the listing's real copy is. How many
    /// photographs there are varies per lot, which is exactly why the app asks the page instead of the
    /// operator (deviation 24). The page is read through the listing the scraper already has loaded, so
    /// the request carries the login session and the results page never moves; the whole path is
    /// best-effort, because a scan must not fail over a page that will not read.
    ///
    /// Read once per lot per action and remembered in `lotPageSubjects`: the cheap pass and the
    /// photographed pass want the same two things, and a second GET would buy nothing.
    private func subjectForLotPage(_ lot: LotItem) async -> ValuationSubject {
        if let cached = lotPageSubjects[lot.id] { return cached }

        let card = lot.valuationSubject
        guard let detailURL = lot.detailURL else { return card }
        // No scraper, or one that has never loaded a page: there is no session to read the lot page
        // with, and building a web view just for this would be a page load per scan.
        guard let scraper, let page = scraper.webView.url,
              page.scheme == "http" || page.scheme == "https" else {
            return card
        }

        // What the readout says is happening: the row's own page is being read, which is the first step
        // of both passes — the gallery and the description come off the one GET.
        note(.readingPage, on: lot)
        do {
            let report = try await scraper.lotPageImages(for: detailURL)
            guard report.ok else {
                log(
                    "Lot \(lot.lotNumber): \(report.summary) — scanning the card's "
                        + "\(card.imageURLs.count) thumbnail(s) instead",
                    source: .scraper
                )
                return card
            }

            // Description first, then photographs, so the recorded copy and the subject agree.
            lot.applyLotPageDescription(report.description ?? "")
            let subject = card
                .withDescription(report.description ?? "")
                .withImages(report.imageURLs)

            // A page that read but carried neither thing worth having leaves the card alone, and says
            // so — otherwise the log would read as if the page had contributed something. The card is
            // still remembered, so the second pass does not fetch the same page again for nothing.
            guard subject != card else {
                log(
                    "Lot \(lot.lotNumber): \(report.summary) — nothing the card did not already have",
                    source: .scraper
                )
                lotPageSubjects[lot.id] = card
                return card
            }

            log("Lot \(lot.lotNumber): \(report.summary)", source: .scraper)
            lotPageSubjects[lot.id] = subject
            return subject
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
        let card = lot.valuationSubject
        lotPageSubjects[lot.id] = nil

        lot.markPrePricing()
        // One row's **Eval**: the readout counts this row, not the board it sits on — and points at it
        // straight away, so the modal's money line is about the lot the operator just clicked.
        pointReadout(at: lot)
        beginAppraisal(kind: .eval, lotIDs: [lot.id], isBatch: false)
        phase = .valuing
        statusText = "Evaluating lot \(lot.lotNumber) from its listing text"
        log(
            "Evaluating lot \(lot.lotNumber) — \(settings.provider.displayName) "
                + "\(settings.activeModelID), the listing's own description (no images sent)"
        )

        prePriceTasks[lot.id] = Task { @MainActor [weak self] in
            // The lot's page is read for its description too: a text-only estimate is only worth
            // anything if it is built from the listing's real copy rather than the card's teaser.
            let subject = await self?.subjectForLotPage(lot) ?? card
            // The page is read; the model is what is being waited on now.
            self?.note(.evaluatingText, on: lot)
            let result: Result<PrePriceEstimate, Error>
            do {
                result = .success(try await service.prePrice(subject: subject))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            await self.onMainActor { self.finishPrePrice(of: lot, with: result) }
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
        // **Eval all**: the job is the pending set the batch was built from.
        beginAppraisal(kind: .eval, lotIDs: targets.map(\.id), isBatch: true)
        // The money line starts on the first row the batch will answer for.
        if let first = targets.first { pointReadout(at: first) }
        phase = .valuing
        statusText = "Evaluating \(targets.count) lot(s) from their listing text"
        // A fresh batch re-reads every lot's page: the descriptions are what makes the text-only pass
        // worth paying for, and a page read during an earlier attempt must not stand in for this one.
        lotPageSubjects.removeAll()
        log(
            "Evaluating \(targets.count) lot(s) with \(settings.provider.displayName) "
                + "\(settings.activeModelID) — each lot's own description, no images, "
                + "\(AppSettings.batchConcurrency) at a time"
                + pacingSuffix(for: settings)
        )

        let service = makeValuationService(settings, { _ in })
        let concurrency = AppSettings.batchConcurrency
        prePriceBatchTask = Task { @MainActor [weak self] in
            await self?.prePrice(targets, using: service, concurrency: concurrency, automatic: false)
            guard let self else { return }
            // Asked here rather than inside the hop below: `Task.isCancelled` answers for whichever
            // task asks, and the answer that matters belongs to this one.
            let cancelled = Task.isCancelled
            await self.onMainActor { self.finishPrePriceBatch(stopped: cancelled || self.scansWereStopped) }
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
        // as "thinking" rather than as nothing happening — on the row and on the modal's step line.
        lot.markPrePricing()
        note(.evaluatingText, on: lot)

        do {
            record(try await service.prePrice(subject: subject), on: lot)
        } catch {
            recordPrePriceFailure(error, on: lot)
        }
    }

    /// Applies one row's pre-price and unwinds its bookkeeping.
    private func finishPrePrice(of lot: LotItem, with result: Result<PrePriceEstimate, Error>) {
        prePriceTasks[lot.id] = nil
        finishStep(for: lot)

        switch result {
        case .success(let estimate): record(estimate, on: lot)
        case .failure(let error): recordPrePriceFailure(error, on: lot)
        }

        // Something else is still working: let it write the closing line.
        guard prePriceTasks.isEmpty, scanTasks.isEmpty, prePriceBatchTask == nil else { return }
        phase = scansWereStopped ? .stopped : .finished
        // A row's **Eval** keeps to its own job here, because the pill above names that row and a
        // board-scoped line under it ("1 of 100 lot(s) evaluated") would contradict it. A batch closes
        // out against the board, which is the number its own button was about.
        if let job = appraisalJob, !job.isBatch {
            statusText = "\(appraisalText(job)) — evaluated from the listing text"
        } else {
            statusText = "\(prePricedCount) of \(lots.count) lot(s) evaluated from the listing text"
        }
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
        // **Price all**: the job is every lot this batch will answer for, so the readout counts the
        // rows the button was pressed for rather than the whole board.
        beginAppraisal(kind: .price, lotIDs: targets.map(\.id), isBatch: true)
        // As in `prePriceUnvalued`: the money line starts on the batch's first row.
        if let first = targets.first { pointReadout(at: first) }
        phase = .valuing
        statusText = "Appraising \(targets.count) lot(s) with \(settings.activeModelID)"
        // A fresh batch re-reads every lot's page rather than reusing galleries from an earlier run.
        lotPageSubjects.removeAll()
        log(
            "Scanning \(targets.count) unvalued lot(s) with \(settings.provider.displayName) "
                + "\(settings.activeModelID), \(settings.photoScanSummary) on each lot page, "
                + "\(AppSettings.batchConcurrency) at a time\(pacingSuffix(for: settings))"
        )

        let service = makeValuationService(settings, batchScanReporter())
        let concurrency = AppSettings.batchConcurrency
        scanBatchTask = Task { @MainActor [weak self] in
            await self?.valuate(targets, using: service, concurrency: concurrency)
            guard let self else { return }
            // As above in `prePriceUnvalued`: this task's own cancellation is what closes the batch.
            let cancelled = Task.isCancelled
            await self.onMainActor { self.finishBatch(stopped: cancelled || self.scansWereStopped) }
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
        finishStep(for: lot)

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
                let subject = await subjectForLotPage(lot)
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

        log("Evaluating \(pending.count) lot(s) from their own description before pricing them")
        pending.forEach { $0.markPrePricing() }

        let width = min(max(concurrency, 1), max(pending.count, 1))

        await withTaskGroup(of: (Int, Result<PrePriceEstimate, Error>).self) { group in
            var next = 0

            while next < pending.count {
                if Task.isCancelled { break }
                let index = next
                next += 1
                // Each lot's own page is read here, in the queueing loop, so the GETs overlap the
                // model calls already in flight rather than delaying the batch behind one serial pass
                // over every page. The same read feeds the photographed pass that follows, which is
                // what `subjectForLotPage`'s cache is for.
                let subject = await subjectForLotPage(pending[index])
                // Handed to the model: the readout says which step the row it is speaking for is on.
                note(.evaluatingText, on: pending[index])
                group.addTask {
                    do {
                        return (index, .success(try await service.prePrice(subject: subject)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
                if next < pending.count, next % width == 0, let finished = await group.next() {
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
        statusText = appraisalTally()
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
        statusText = appraisalTally()
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
