//
//  RunProgress.swift
//  PalletAuctionBidTool
//
//  What the progress readout counts: the pages a walk will read, the rows an appraisal covers, and the
//  photographs a scan has answered.
//

import Foundation

/// How far a walk is through the pages it set out to read.
///
/// The readout's denominator is the work that was actually asked for — which is neither the site's own
/// page count nor the operator's budget on its own. Both halves live here, away from the coordinator,
/// because they are what the modal's pill and bar are built on and a wrong one is invisible: "page 1 of
/// 4" on a run that is only ever going to read one page looks exactly like a run three pages from done.
struct PageWalkProgress {

    /// The pages this walk is going to read: the operator's **Pages** budget, or — when they asked for
    /// **All pages** — the listing's own count once its pagination has reported one.
    ///
    /// A budget is capped by the listing's own count, because a walk stops when the pagination runs out
    /// of pages: asking for 10 pages of a 4-page listing is a 4-page job, and printing "of 10" would
    /// promise six pages nobody is going to read. This is the difference between "1 page" in **Run
    /// Tuning** and a site whose pager happens to advertise four: the run reads one page, so the readout
    /// says *page 1 of 1*. **All pages** with no count has no honest denominator at all, which `nil` is
    /// for.
    ///
    /// The cap only ever *lowers* the promise. A listing that under-reports its own length is walked
    /// past — "page 5 of 4" — which is the same thing every count read off a site's pager has always
    /// been able to do, and is why the bar never prints a number the site did not report.
    static func target(budget: Int, walksEveryPage: Bool, listingPages: Int?) -> Int? {
        if walksEveryPage { return listingPages }
        let pages = max(1, budget)
        return min(pages, listingPages ?? pages)
    }

    /// The pill's text for one page: `page 2 of 3`, or `page 2 — all pages` while a walk with no count
    /// is still going. A made-up 100 there would read as a promise, so a walk with no denominator says
    /// only what it knows.
    static func text(page: Int, target: Int?) -> String {
        guard let target else { return "page \(page) — all pages" }
        return "page \(page) of \(target)"
    }

    /// How far the walk has got, `0...1`, or `nil` when its total is unknown.
    ///
    /// Two things count, because a page is one request but many rows: the pages already read *and* the
    /// share of the page being read whose cards have landed on the board. Without the second half a
    /// **1 page** run stood at nothing for the whole read and then snapped to full, which is exactly the
    /// shape of a bar nobody trusts; with it the board filling and the bar filling are the same event.
    /// A page's own share is capped at its card count, so a walk that under-reported its length cannot
    /// push the bar past full.
    static func fraction(
        pagesRead: Int,
        pageRowsLanded: Int,
        pageRowsOnPage: Int,
        target: Int?
    ) -> Double? {
        guard let target, target > 0 else { return nil }
        let rows = pageRowsOnPage > 0
            ? Double(min(max(pageRowsLanded, 0), pageRowsOnPage)) / Double(pageRowsOnPage)
            : 0
        return min(1, (Double(max(pagesRead, 0)) + rows) / Double(target))
    }
}

/// One row's appraisal, step by step.
///
/// The pill says *which* row a job is on; this says what is being done to it, and it is why a scan no
/// longer looks frozen between the row's own page read and the answer landing: a photographed appraisal
/// is one GET for the lot's page, one text-only request, then either one request per photograph and one
/// reconciliation (the thorough route) or one request per batch of photographs and one text-only
/// request per dozen inventory lines (the batched one), and the readout shows each of them as it happens
/// (see `PhotoScanEvent`).
///
/// The photograph step is a *count* of the frames with an answer rather than the frame in flight, and
/// that is deliberate. Reads run a few at a time (`PhotoScanPlan.defaultConcurrency`) so no single frame
/// is "the" frame being read: three are, and their numbers come back in whatever order the provider
/// answers. A line — or a bar — built on the frame number therefore moves *backwards* (an operator
/// watching a nine-frame scan saw `1 of 9`, `7 of 9`, `3 of 9`), which is worse than saying less. The
/// count only ever goes up, and it is the same statement the bar needs. Which frame is being read stays
/// where it belongs: the console's own line, and the row's live note.
enum AppraisalStep: Equatable, Sendable {

    /// The row's own page is being read — the one GET that brings back its gallery *and* its
    /// description.
    case readingPage

    /// The cheap text-only pass is in flight: a row's **Eval**, or the first look that rides in front of
    /// a **Price**.
    case evaluatingText

    /// How many of the row's gallery have an answer in hand, out of the frames that travel: the unit of
    /// work a thorough scan is built from, counted rather than pointed at.
    ///
    /// An answered frame is one that was read, restored from this machine's store, or given up on — all
    /// three are work that is over, and all three move the readout on. The frame *number* is not carried
    /// here on purpose: see the type's own note on why the readout counts instead of naming one.
    case photograph(answered: Int, of: Int)

    /// The whole gallery is going over in one pass, because reading it photograph by photograph came
    /// back with nothing readable.
    case wholeGallery

    /// The readings are being reconciled into the pallet's line items.
    case reconciling(readings: Int)

    /// A settled manifest is being priced: text-only requests over the inventory (`LotManifestPrompt`,
    /// `PalletManifest`), which carry names and counts instead of photographs — one request per dozen
    /// lines, so usually one.
    ///
    /// Its own step rather than `reconciling`, because the two say different things and are counted in
    /// different units — a reconciliation folds *readings* into line items, this looks *items* up in a
    /// market and multiplies. The row's live note would be wrong under either name borrowed from the
    /// other.
    case pricingManifest(lines: Int)

    /// The line the modal prints while the row is on this step.
    var phrase: String {
        switch self {
        case .readingPage:
            "reading the lot's own page"
        case .evaluatingText:
            "evaluating from the listing text"
        case .photograph(let answered, let of):
            "\(answered) of \(of) photograph(s) answered"
        case .wholeGallery:
            "reading the whole gallery in one pass"
        case .reconciling(let readings):
            "reconciling \(readings) reading(s) into the line items"
        case .pricingManifest(let lines):
            "pricing \(lines) manifest line(s) into the pallet's items"
        }
    }

    /// How much of its row the step accounts for, `0..<1` — what lets the bar creep through a row
    /// instead of standing still until the row lands.
    ///
    /// The weights are the shape of a photographed appraisal rather than a promise about seconds: the
    /// page read and the text-only look are a tenth of the row each, the photographs are the bulk of it
    /// (scaled by the row's own gallery, so three frames and forty fill the bar at the same rate), and
    /// the reconciliation closes it out. A row is only ever *answered* once its work is over, so no step
    /// ever reaches 1: the last photograph of a seven-frame gallery and the reconciliation are both
    /// almost there, and "almost" is what the bar says until the answer lands.
    ///
    /// The photographs' bulk is added one *answered* frame at a time, in the order the answers land
    /// rather than in gallery order, which is what keeps the bar going forwards: the reads are in flight
    /// a few at a time, so gallery order is not an order the answers have. A frame the plan never reads —
    /// over the **Photos / scan** ceiling, or folded into another frame's view (`PhotoFrameGrouping`) —
    /// leaves the read phase short of the reconciliation's own share, which is where the bar picks the
    /// rest up.
    var share: Double {
        switch self {
        case .readingPage:
            0.1
        case .evaluatingText:
            0.2
        case .photograph(let answered, let of):
            // The numerator is capped at the gallery, so a frame counted twice cannot claim more of the
            // row than the reads themselves do.
            0.2 + 0.7 * (Double(min(max(answered, 0), max(of, 1))) / Double(max(of, 1)))
        case .wholeGallery:
            0.6
        case .reconciling:
            0.9
        case .pricingManifest:
            0.9
        }
    }
}

/// The appraisal the operator asked for, as the progress readout counts it.
///
/// The bar and the pill measure *the work in hand*, and for an appraisal that work is one row's **Eval**
/// or **Price** as often as it is a whole-board batch. Counting every appraisal against the board is what
/// made a single row report `0 of 100` — the denominator of a job nobody asked for — so a job carries its
/// own rows: the one a row's button named (`Evaluating Lot #19002`, `Pricing Lot #19002`), or the pending
/// set an all-lots button was built from (`Evaluating Lot #3 of 12`, `Pricing Lot #4 of 12` — a batch
/// counts its way through *itself*, because a board's lot numbers do not run from 1). Which one it is
/// comes from `isBatch` rather than from the count: a board holding exactly one lot still has a batch
/// button.
///
/// The rows are held by `id` rather than by reference: the readout outlives any one scan and must not
/// keep a lot alive, and the coordinator is the only thing that can say whether a row is answered yet.
/// They are held *in order* because a batch's pill counts places (`position(of:)`), which a set cannot
/// answer.
struct AppraisalJob {

    /// The verb the operator pressed, which is the whole of the difference between the two jobs: a
    /// **Price** waits on its row's analysis state, an **Eval** on the cheap pass's own flag.
    enum Kind: Equatable {
        case eval
        case price
    }

    /// Where the job stands: the row being worked on right now (when there is one) and how many of the
    /// job's rows the appraiser has answered.
    struct Position: Equatable {

        /// Lot number of the row in hand — what a single row's pill is named after.
        var lotNumber: String?

        /// 1-based place of the row in hand among the job's rows — what a batch's pill counts.
        var index: Int?

        /// Rows answered so far.
        var answered: Int
    }

    let kind: Kind

    /// The rows this job will answer for, **in the order they joined it**: one for a row's button, the
    /// batch's pending set for a batch.
    ///
    /// An array rather than a set because a batch's pill counts its way through the job
    /// (`Pricing Lot #3 of 12`), which needs a place as well as a membership.
    private(set) var lotIDs: [UUID]

    /// `true` when one of the table's all-lots buttons started it.
    let isBatch: Bool

    /// How many rows the job covers — the denominator of the readout.
    var count: Int { lotIDs.count }

    /// What the pill leads with: the verb the operator pressed.
    var verb: String { kind == .eval ? "Evaluating" : "Pricing" }

    /// The pill's text: the verb, and where the job has got to.
    ///
    /// A row's own button names the row — `Evaluating Lot #19002` — because that is the lot the figure
    /// belongs to and the row the operator is watching. A batch counts its way through the rows it
    /// covers instead — `Pricing Lot #3 of 12` — because a board's lot numbers do not run from 1, and
    /// `Pricing Lot #19002 of 12` would read as a place that does not exist. With no row in hand yet the
    /// batch prints the rows it has answered, which is the same statement one row behind, and both are
    /// capped at the job's own size so a row that landed early can never print `of 12` on row 13.
    func text(_ position: Position) -> String {
        guard isBatch else {
            guard let number = position.lotNumber else {
                return "\(verb) \(position.answered) of \(count)"
            }
            return "\(verb) Lot #\(number)"
        }
        let place = min(max(position.index ?? max(position.answered, 1), 1), max(count, 1))
        return "\(verb) Lot #\(place) of \(count)"
    }

    /// Where a row sits in the job, 1-based, or `nil` when it is not one of the job's rows.
    func position(of id: UUID?) -> Int? {
        guard let id, let index = lotIDs.firstIndex(of: id) else { return nil }
        return index + 1
    }

    /// Adds a row to a job already in hand — a second **Price** click while the first is still running,
    /// which `canScan` allows on purpose. The readout then counts both rows instead of re-pointing itself
    /// at whichever one was clicked last.
    mutating func include(_ id: UUID) {
        guard !lotIDs.contains(id) else { return }
        lotIDs.append(id)
    }
}

/// One row's money, as the modal's bottom line prints it.
///
/// The line speaks for the row in hand rather than for the board: a photographed appraisal lands one
/// figure at a time, and the row's own numbers are what say it is working. `provisional` marks figures a
/// text-only eval produced, so a `Retail` that is still a guess never reads as an appraisal.
struct LotMoney: Equatable, Sendable {

    /// What is bid on the lot right now — the one figure that needs no appraisal.
    var currentBid: Double

    var retail: Double

    var resale: Double

    /// `true` while the figures rest on the cheap text-only pass rather than on a valuation.
    var provisional: Bool

    /// What the lot is worth over what is bid on it — the line's one derived figure.
    var profit: Double { resale - currentBid }
}

extension AppraisalStep {

    /// The step a scan's own report names, or `nil` for a report that closes one out rather than
    /// starting anything: a reconciliation that landed, a grouping announced before the reads, a
    /// repeated photograph left out of the batches, or a fallback the pipeline already announced when it
    /// decided to take it.
    ///
    /// One place for the mapping, so the readout's vocabulary can only be changed here — the pipeline
    /// reports what it is doing (`PhotoScanEvent`) and knows nothing about pills or bars.
    init?(_ event: PhotoScanEvent) {
        switch event {
        // All three of the frame events name the same step, because the readout counts answers rather
        // than following a frame: a frame about to be read, one that landed and one that could not be
        // read are each news about how much of the gallery is answered. The frame number itself stays in
        // the console line the event also carries.
        case .reading(_, let of, let answered, _),
             .read(_, let of, let answered, _),
             .failed(_, let of, let answered, _):
            self = .photograph(answered: answered, of: of)
        case .aggregating(let photographs, _):
            self = .reconciling(readings: photographs)
        // The manifest route's two batch events are the frame events' trip through the same counter: a
        // batch answered is so many of the gallery's photographs answered, which is what the readout
        // counts. `.pricing` is the pricing pass starting; `.priced` closes the row out, so it names no
        // step.
        case .manifesting(_, _, _, let answered, let total),
             .manifested(_, _, _, let answered, let total),
             .manifestFailed(_, _, let answered, let total, _):
            self = .photograph(answered: answered, of: total)
        case .pricing(let items):
            self = .pricingManifest(lines: items)
        case .fallingBack, .fallingBackFromManifest:
            self = .wholeGallery
        // A batch's missing account of one of its frames is news about the inventory rather than about
        // the bar: every frame the batch *did* answer for is already counted by the events above, and the
        // bar must not move backwards over a frame the model passed over.
        case .folded, .grouped, .aggregated, .aggregatedLocally, .priced, .manifestSettled, .manifestGap:
            return nil
        }
    }
}
