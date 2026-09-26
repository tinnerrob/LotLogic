//
//  ColumnWidths.swift
//  PalletAuctionBidTool
//
//  Resizable column geometry for the master lot table.
//
//  Deliberately SwiftUI-free — `CoreGraphics` is imported for `CGFloat` and nothing else — so the
//  clamping and the totals the sticky header and every row kind align to are compiled into the
//  offline harness and checked without a window: see `Tools/free-tier-harness`.
//

import CoreGraphics

/// The data columns the operator can drag to a new width, in table order.
///
/// Declaring the order here rather than in the header is what lets the header be built by iterating
/// the cases, and keeps the title, the sort order behind it and the shipped width in one place.
///
/// Every case here can also be hidden from the table's gear (see `ColumnVisibility`): this enum is
/// the data, and the fixed chrome — the row checkboxes, the chevron and the **Eval** / **Price** /
/// **Open** buttons — is deliberately not a case, so it is not something the chooser can take away.
enum LotColumnKey: String, CaseIterable, Identifiable, Sendable {

    case lotNumber
    case title
    case bid

    /// Highest bid worth placing, from the lot's resale figure and the confidence behind it.
    case maxBid

    case items
    case retail
    case resale
    case profit
    case roi
    case ratio
    case confidence
    case status

    /// Whether the auction still takes bids on the lot, or the site has marked it sold. The site's
    /// own marker is the authority (see `soldTextPattern`); a scraped lot carries the answer as
    /// `LotItem.isActive`.
    case active

    var id: String { rawValue }

    /// Header title.
    var label: String {
        switch self {
        case .lotNumber: "Lot / SKU"
        case .title: "Description"
        case .bid: "Bid"
        case .maxBid: "Max bid"
        case .items: "Qty"
        case .retail: "Retail"
        case .resale: "Resale"
        case .profit: "Profit"
        case .roi: "ROI"
        case .ratio: "R/R"
        case .confidence: "Conf"
        case .status: "Status"
        case .active: "Active"
        }
    }

    /// The order this column's header sorts by, when it has one. The count, the confidence, the
    /// two ratios and the lot's own active/sold flag are read-only: ordering by them adds nothing
    /// the other columns do not offer, and a click target that does nothing is worse than no click
    /// target.
    var sortField: LotSort? {
        switch self {
        case .lotNumber: .identifier
        case .title: .description
        case .bid: .currentBid
        case .maxBid: .maxBid
        case .retail: .retail
        case .resale: .resale
        case .profit: .profit
        case .roi: .roi
        case .items, .ratio, .confidence, .status, .active: nil
        }
    }

    /// Width a fresh install uses: wide enough for the column's own header plus a four-figure
    /// amount, narrow enough that the whole table fits a 1360pt window.
    var defaultWidth: CGFloat {
        switch self {
        case .lotNumber: 104
        case .title: 168
        case .bid: 96
        case .maxBid: 104
        case .items: 48
        case .retail: 92
        case .resale: 92
        case .profit: 100
        case .roi: 68
        case .ratio: 72
        case .confidence: 66
        case .status: 170
        case .active: 74
        }
    }
}

/// Columns that are fixed chrome rather than data, plus the geometry the drag grips share.
enum LotColumn {

    /// The row checkboxes: the header's own box and the one on every pallet row, sharing a column so
    /// the two line up.
    ///
    /// Fixed chrome rather than a data column, on the same reasoning as the buttons: the boxes are a
    /// control, not a number, and the two **…selected** buttons cannot be built without them — so the
    /// gear has no switch for it, and it is never stretched by `ColumnWidths.filling(_:)`. Narrower
    /// than the chevron beside it because a checkbox is aimed at rather than read.
    static let selection: CGFloat = 24

    /// Disclosure chevron. Fixed: resizing it would only misalign the rows against the header.
    static let expander: CGFloat = 20

    /// The per-row action buttons: **Eval**, **Price** and **Open**, left to right. Fixed: they are
    /// buttons, not numbers to widen.
    ///
    /// The number is the three buttons *plus* the two 4-point gaps between them, with a little slack.
    /// Each button is drawn inside a slot held to its own full label — **Re-eval**, **Re-price**,
    /// **Open** (see `RowActionSlot`) — so the trio never shuffles as a button changes or as a
    /// request goes out, and a clipped button is worse than a wide column. Only the Eval/Price pair is
    /// in every row — a lot whose card exposed no address simply has no **Open** — so the slack is
    /// also what keeps the buttons that *are* there from looking crowded against the lot number.
    static let scan: CGFloat = 246

    /// The actions column is deliberately **untitled**, and this is where that is written down.
    ///
    /// The three buttons name themselves, and a heading over a column of controls is a legend rather
    /// than a label: **Eval / price** was a sentence the operator had to read once and never again,
    /// while a heading like "Actions" would only restate what three labelled buttons already say. The
    /// header still draws *a cell* of this width — it is what the rows' buttons are laid out under —
    /// it just has nothing to put in it. The constant survives so the header, the harness check and
    /// the README all point at one place; `""` is the whole value.
    static let scanTitle = ""

    /// Horizontal padding inside a row, counted once in `ColumnWidths.totalWidth`.
    static let rowInsets: CGFloat = 16

    /// Hit area of a resize grip, centred on the column boundary.
    static let resizeGrip: CGFloat = 12

    /// Width of the grab handle the grip draws once the pointer is over it.
    static let resizeMark: CGFloat = 3

    /// Height of that handle. Tall enough to look like something you grab, short enough to sit
    /// inside the header strip without touching the hairline under it.
    static let resizeHandle: CGFloat = 15

    /// Opacity of the column boundary hairline while the pointer is elsewhere.
    static let resizeRuleIdle: Double = 0.09
}

/// Every resizable column's current width, plus which of them are being drawn.
///
/// A value type rather than a dictionary keyed by case or an array keyed by position: the table
/// takes a single `@State` copy, a preview hands in literal widths, and changing one column is
/// provably a change to nothing else.
///
/// `visibility` rides along here rather than being passed beside it because a hidden column has an
/// *effective* width of zero (see `width(_:)`): the header, both row kinds, the nested indent, the
/// table's total and the stretch-to-fill then all close up around the choice without any of them
/// having to know about it — which is the only way a drawn-by-hand table stays aligned.
struct ColumnWidths: Equatable, Sendable {

    /// Narrowest a column may be dragged. Below this the header label starts to clip, which reads
    /// as a broken table rather than a narrow column.
    static let minimumWidth: CGFloat = 48

    /// Widest a column may be dragged: past this one column can hide everything beside it.
    static let maximumWidth: CGFloat = 420

    /// Slack below which a window counts as "exactly the table's width". Without a tolerance the
    /// table would chase sub-point rounding every time the window moved.
    static let fillTolerance: CGFloat = 0.5

    // The stored widths. Private, and prefixed, because the names the rest of the app reads are the
    // *drawn* widths: `widths.bid` has to be zero while the Bid column is hidden, or a row would
    // still lay itself out at the width of a column nobody can see. `storedWidth(_:)` is the keyed
    // way in, `width(_:)` and the shorthands below are the way out.
    private var storedLotNumber: CGFloat
    private var storedTitle: CGFloat
    private var storedBid: CGFloat
    private var storedMaxBid: CGFloat
    private var storedItems: CGFloat
    private var storedRetail: CGFloat
    private var storedResale: CGFloat
    private var storedProfit: CGFloat
    private var storedROI: CGFloat
    private var storedRatio: CGFloat
    private var storedConfidence: CGFloat
    private var storedStatus: CGFloat
    private var storedActive: CGFloat

    /// Which columns are drawn. A hidden column keeps its width — see `storedWidth(_:)` — so
    /// showing it again restores the layout the operator had rather than a shipped default.
    var visibility: ColumnVisibility = .all

    // The width each column is drawn at, which is what the header, both row kinds and the nested
    // indent lay their cells out from — so the familiar `widths.bid` reads the same as it always did
    // and simply becomes zero when that column is hidden.
    var lotNumber: CGFloat { width(.lotNumber) }
    var title: CGFloat { width(.title) }
    var bid: CGFloat { width(.bid) }
    var maxBid: CGFloat { width(.maxBid) }
    var items: CGFloat { width(.items) }
    var retail: CGFloat { width(.retail) }
    var resale: CGFloat { width(.resale) }
    var profit: CGFloat { width(.profit) }
    var roi: CGFloat { width(.roi) }
    var ratio: CGFloat { width(.ratio) }
    var confidence: CGFloat { width(.confidence) }
    var status: CGFloat { width(.status) }
    var active: CGFloat { width(.active) }

    /// The shipped layout, and what **Reset column widths** restores.
    static let standard = ColumnWidths()

    init(
        lotNumber: CGFloat = LotColumnKey.lotNumber.defaultWidth,
        title: CGFloat = LotColumnKey.title.defaultWidth,
        bid: CGFloat = LotColumnKey.bid.defaultWidth,
        maxBid: CGFloat = LotColumnKey.maxBid.defaultWidth,
        items: CGFloat = LotColumnKey.items.defaultWidth,
        retail: CGFloat = LotColumnKey.retail.defaultWidth,
        resale: CGFloat = LotColumnKey.resale.defaultWidth,
        profit: CGFloat = LotColumnKey.profit.defaultWidth,
        roi: CGFloat = LotColumnKey.roi.defaultWidth,
        ratio: CGFloat = LotColumnKey.ratio.defaultWidth,
        confidence: CGFloat = LotColumnKey.confidence.defaultWidth,
        status: CGFloat = LotColumnKey.status.defaultWidth,
        active: CGFloat = LotColumnKey.active.defaultWidth,
        visibility: ColumnVisibility = .all
    ) {
        self.storedLotNumber = Self.clamped(lotNumber)
        self.storedTitle = Self.clamped(title)
        self.storedBid = Self.clamped(bid)
        self.storedMaxBid = Self.clamped(maxBid)
        self.storedItems = Self.clamped(items)
        self.storedRetail = Self.clamped(retail)
        self.storedResale = Self.clamped(resale)
        self.storedProfit = Self.clamped(profit)
        self.storedROI = Self.clamped(roi)
        self.storedRatio = Self.clamped(ratio)
        self.storedConfidence = Self.clamped(confidence)
        self.storedStatus = Self.clamped(status)
        self.storedActive = Self.clamped(active)
        self.visibility = visibility
    }

    /// Keeps a dragged width inside `minimumWidth...maximumWidth`.
    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    /// One column's current width — zero when the column is hidden.
    ///
    /// This is the width everything lays out from, which is why hiding a column is a change to
    /// `visibility` alone: the header, the rows, the nested rows and `totalWidth` all read it and
    /// close up on their own.
    func width(_ key: LotColumnKey) -> CGFloat {
        visibility.isVisible(key) ? storedWidth(key) : 0
    }

    /// The width this column is sized to, whether or not it is being drawn — so a drag is never lost
    /// to a column being hidden at the time, and showing it again puts it back.
    func storedWidth(_ key: LotColumnKey) -> CGFloat {
        switch key {
        case .lotNumber: storedLotNumber
        case .title: storedTitle
        case .bid: storedBid
        case .maxBid: storedMaxBid
        case .items: storedItems
        case .retail: storedRetail
        case .resale: storedResale
        case .profit: storedProfit
        case .roi: storedROI
        case .ratio: storedRatio
        case .confidence: storedConfidence
        case .status: storedStatus
        case .active: storedActive
        }
    }

    /// Resizes one column, clamped on the way in, so no caller has to remember the range.
    mutating func setWidth(_ width: CGFloat, for key: LotColumnKey) {
        write(Self.clamped(width), for: key)
    }

    /// Writes a width as given, without clamping.
    ///
    /// Only derived values use this — currently the stretched layout built by `filling(_:)`, whose
    /// whole job is to make the total land *exactly* on the window width, which a clamp could undo.
    /// Everything the operator drags goes through `setWidth(_:for:)`.
    private mutating func write(_ width: CGFloat, for key: LotColumnKey) {
        switch key {
        case .lotNumber: storedLotNumber = width
        case .title: storedTitle = width
        case .bid: storedBid = width
        case .maxBid: storedMaxBid = width
        case .items: storedItems = width
        case .retail: storedRetail = width
        case .resale: storedResale = width
        case .profit: storedProfit = width
        case .roi: storedROI = width
        case .ratio: storedRatio = width
        case .confidence: storedConfidence = width
        case .status: storedStatus = width
        case .active: storedActive = width
        }
    }

    /// Puts every column back to its shipped width, leaving the operator's column *choice* alone:
    /// this is a width reset, and a column they went looking for is not a width.
    mutating func reset() {
        let choice = visibility
        self = .standard
        visibility = choice
    }

    /// The widths the table actually draws at in a window `availableWidth` points wide.
    ///
    /// Wider than the table: the columns being drawn share the slack in proportion to their own
    /// width, so the table spans the window instead of leaving a dead strip beside the last column.
    /// Hiding a column hands its width to the ones that remain, because the slack is measured from
    /// `totalWidth` and that is the *drawn* total. The fixed chrome — the row checkboxes, the
    /// chevron, the **Eval** / **Price** / **Open** buttons and the row insets — is never stretched:
    /// those are controls, not numbers, and widening them would only push the data further right.
    ///
    /// Narrower than the table: the stored widths are returned untouched, so the operator keeps the
    /// layout they dragged and the table scrolls horizontally rather than squeezing columns they
    /// deliberately sized. Nothing here can shrink a column below `minimumWidth` either, because
    /// stretching only ever adds.
    func filling(_ availableWidth: CGFloat) -> ColumnWidths {
        let slack = availableWidth - totalWidth
        guard slack > Self.fillTolerance, dataWidth > 0 else { return self }
        return scaled(by: 1 + slack / dataWidth)
    }

    /// Every column being drawn multiplied by `factor`. Derived, so deliberately unclamped.
    ///
    /// Hidden columns are skipped rather than scaled to zero: a hidden column is not part of the
    /// drawn table, and rewriting its stored width would quietly discard the layout to come back to.
    private func scaled(by factor: CGFloat) -> ColumnWidths {
        var stretched = self
        for key in LotColumnKey.allCases where visibility.isVisible(key) {
            stretched.write(storedWidth(key) * factor, for: key)
        }
        return stretched
    }

    /// The fixed chrome: the row checkboxes, the disclosure chevron, the per-row action buttons and
    /// the row insets. Counted once, and never stretched by `filling(_:)`.
    static var chromeWidth: CGFloat {
        LotColumn.selection + LotColumn.expander + LotColumn.scan + LotColumn.rowInsets
    }

    /// The draggable columns being drawn, added up — the part of the table that absorbs a wider
    /// window.
    var dataWidth: CGFloat {
        LotColumnKey.allCases.reduce(0) { $0 + width($1) }
    }

    /// Every drawn data column plus the fixed chrome; the table never lays out narrower than this,
    /// which is what gives the horizontal scroller something real to scroll.
    var totalWidth: CGFloat { Self.chromeWidth + dataWidth }

    /// The leading columns a nested row's name cell spans, so an indented product line sits under
    /// the pallet it belongs to however the columns are sized — and shrinks with them when one of
    /// the two is hidden.
    var identityWidth: CGFloat {
        LotColumn.selection + LotColumn.expander + LotColumn.scan + width(.lotNumber) + width(.title)
    }
}
