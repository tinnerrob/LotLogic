//
//  LotTableRow.swift
//  PalletAuctionBidTool
//
//  Row views, badges and shared column geometry for the lot table.
//

import AppKit
import CoreGraphics
import SwiftUI

/// Alignment for the resizable columns, matching how their cells are drawn.
extension LotColumnKey {

    /// Money and counts read right-aligned so their digits line up down the column; text reads
    /// left-aligned at the column's leading edge.
    var alignment: Alignment {
        switch self {
        case .lotNumber, .title, .confidence, .status, .active: .leading
        case .bid, .maxBid, .items, .retail, .resale, .profit, .roi, .ratio: .trailing
        }
    }
}

/// How a header checkbox is drawn for each amount of checking: an empty box for none, a filled box
/// with a dash to say "some, and not all", and a filled box with a check for the lot.
///
/// The dash is what makes a partly-checked table legible as a *state* rather than as a mismatch: the
/// filled pair both say "there is a selection here", and the glyph says whether it is finished.
extension LotSelection.Scope {

    var systemImage: String {
        switch self {
        case .none: "square"
        case .some: "minus.square.fill"
        case .all: "checkmark.square.fill"
        }
    }
}

/// A fixed-width column cell.
///
/// The width is a *placeholder*, and that is the whole point: a cell is what keeps the header and
/// both row kinds on the same grid, so it has to hold its column even when it draws nothing. An
/// empty cell arrives as `EmptyView` — the header's disclosure column, a product line's
/// whole-pallet-only columns — and SwiftUI drops `EmptyView().frame(width:)` outright, so the cell
/// silently shrank to nothing and every column after it slid left by that width. The invisible
/// block below is what actually holds the width; the content is only drawn on top of it.
struct TableCell<Content: View>: View {

    private let width: CGFloat
    private let alignment: Alignment
    private let content: Content

    init(_ width: CGFloat, alignment: Alignment = .leading, @ViewBuilder content: () -> Content) {
        self.width = width
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        // A hidden column arrives here as width zero, and a zero-width *frame* is not the same as no
        // view: the text inside it would still be laid out and drawn, spilling over the column
        // beside it. So a cell with nothing to be wide draws nothing at all.
        if width > 0 {
            ZStack(alignment: alignment) {
                Color.clear.frame(width: width, height: 1)
                content
                    .frame(width: width, alignment: alignment)
                    .lineLimit(1)
            }
        }
    }
}

/// Sticky column titles.
///
/// The header is generated from `LotColumnKey.allCases`, so the columns' order, their titles, the
/// order each one sorts by and the width it is drawn at all live in one place — and every row kind
/// walks the same list, which is what keeps a hand-built table aligned. Clicking a title sorts it
/// (when it has an order); the handlebar on its trailing edge resizes it. A hidden column is skipped
/// outright rather than drawn at zero width, so its resize grip cannot end up on a boundary that is
/// not there.
///
/// The header carries *two* layouts on purpose. `widths` is the stored one, which a drag writes to;
/// `stored` is that same layout with the operator's column choice applied, and `drawn` is `stored`
/// stretched to fill the window (see `ColumnWidths.filling(_:)`). Cells are laid out from `drawn` so
/// the header still lines up with the rows in a wide window, while a drag converts back to the stored
/// layout before it is saved — otherwise every drag in a stretched window would bake the stretch into
/// the widths and the table would grow by itself a little on every mouse move.
struct LotTableHeader: View {

    @Binding var widths: ColumnWidths
    /// `widths` with the current column choice applied — what a drag has to convert back to, and what
    /// the stretch is measured against. Differs from `widths` only while a column is hidden.
    let stored: ColumnWidths
    /// The widths actually being drawn, stretched to the window.
    let drawn: ColumnWidths
    @Binding var sort: LotSort
    @Binding var direction: SortDirection
    /// What is checked, as the table owns it. The header reads it for the box's own state and writes
    /// it through that same box, so the box and the two **…selected** buttons cannot disagree about
    /// what is checked.
    @Binding var selection: LotSelection
    /// The rows the table is *drawing*, in the order it is drawing them — what the box speaks for.
    ///
    /// Deliberately not the whole board: a search narrows the table, and a box drawn over the table
    /// must not reach past what is on screen. It is the same list the sort ordered, so "all" here means
    /// "all, as the operator sees them stacked".
    let drawnRowIDs: [UUID]

    var body: some View {
        HStack(spacing: 0) {
            // The checkbox column's own head: the select-all box. Drawn in the same cell the rows'
            // checkboxes are, from the same constant, so the boxes line up down the table.
            TableCell(LotColumn.selection) { selectAllBox }

            TableCell(LotColumn.expander) { EmptyView() }

            // The actions column carries no title under any name — the constant it would carry is
            // `""` (see `LotColumn.scanTitle`) — because the buttons drawn in it name themselves,
            // and a heading over a column of controls is a legend rather than a label. The cell is
            // still drawn, and still *asks* for that title, so the width the rows' buttons are laid
            // out under and the title they do not get both come from one place.
            TableCell(LotColumn.scan) { Text(LotColumn.scanTitle).microCaps(false) }

            ForEach(LotColumnKey.allCases) { key in
                if drawn.visibility.isVisible(key) {
                    headerCell(for: key)
                }
            }
        }
        .padding(.horizontal, Theme.rowInset)
        .padding(.vertical, Theme.headerPadding)
        .frame(width: drawn.totalWidth, alignment: .leading)
        .background(.bar)
        // A hairline rather than a `Divider`, so the rule under the header is the same weight as the
        // ones between the rows it scrolls over.
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }

    /// One title: a tap target for the sort, a handlebar for the width.
    ///
    /// The label is drawn in micro-caps (`Theme.microCaps`), and the column carrying the table's
    /// current order is the only one in colour: the header is chrome, so the one place the eye has to
    /// find in it is where the rows are being ranked from.
    private func headerCell(for key: LotColumnKey) -> some View {
        TableCell(drawn.width(key), alignment: key.alignment) {
            HStack(spacing: 3) {
                Text(key.label)
                if isActive(key) {
                    Image(systemName: direction.systemImage)
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .microCaps(isActive(key))
        }
        .overlay(alignment: .trailing) { resizeGrip(for: key) }
        .contentShape(Rectangle())
        .onTapGesture { if let field = key.sortField { select(field) } }
        .help(help(for: key))
    }

    /// `true` when this column carries the table's current order.
    private func isActive(_ key: LotColumnKey) -> Bool {
        key.sortField != nil && key.sortField == sort
    }

    private func select(_ field: LotSort) {
        if sort == field {
            direction = direction.toggled
        } else {
            sort = field
            direction = field.initialDirection
        }
    }

    private func help(for key: LotColumnKey) -> String {
        let resize = "Drag its right edge to resize the column."
        guard let field = key.sortField else { return "\(key.label). \(resize)" }
        guard isActive(key) else { return "Sort by \(field.label). \(resize)" }
        return "Sorted by \(field.label) (\(direction.label.lowercased())) — click for "
            + "\(direction.toggled.label.lowercased()). \(resize)"
    }

    /// The box over the rows: all of them checked, some of them, or none.
    ///
    /// The glyph is the state; the click is a *direction*, and `LotSelection.Scope` is what decides
    /// which way it goes — a box that is not fully on fills the table, and one that is empties it. So
    /// a partly-checked table reads as "not finished yet": an operator who has hand-picked three rows
    /// and then reaches for the header wants the rows they have not looked at, not an empty table.
    ///
    /// Like the rows' own checkboxes it is a glyph in a plain button rather than a `Toggle`, and for
    /// the same reason: this column is 24 points of chrome, and a `Toggle` would bring a label and a
    /// layout with it.
    private var selectAllBox: some View {
        Button {
            selection.toggleAll(drawnRowIDs)
        } label: {
            Image(systemName: scope.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(scope == .none ? Color.secondary : Color.accentColor)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .disabled(drawnRowIDs.isEmpty)
        .help(selectAllHelp)
    }

    /// How much of the drawn table is checked — what the glyph is drawn from and what the click
    /// direction is read from.
    private var scope: LotSelection.Scope { selection.scope(of: drawnRowIDs) }

    /// What the box's tooltip says. The same `Scope` that decides the glyph decides the sentence, so
    /// what the box says it will do and what it does cannot drift apart.
    private var selectAllHelp: String {
        let reach = "It counts only the rows the table is showing, so a search narrows what it reaches."
        switch scope {
        case .none:
            return "Check every row in the table (\(drawnRowIDs.count)) — the lots **Eval selected** "
                + "and **Price selected** then work through. \(reach)"
        case .some:
            let checked = drawnRowIDs.count { selection.contains($0) }
            return "\(checked) of \(drawnRowIDs.count) rows checked — click to check them all. \(reach)"
        case .all:
            return "All \(drawnRowIDs.count) rows are checked — click to clear them. \(reach)"
        }
    }

    /// Binds one column's width for the handlebar that drags it.
    ///
    /// The read is in drawn space, which is what the operator sees and aims at; the write divides
    /// the stretch back out, so the *stored* layout keeps only the change the drag asked for.
    private func resizeGrip(for key: LotColumnKey) -> some View {
        ColumnResizeGrip(
            width: Binding(
                get: { drawn.width(key) },
                set: { widths.setWidth($0 / stretch, for: key) }
            ),
            label: key.label
        )
    }

    /// How much wider the drawn layout is than the stored one — `1` when the window is exactly the
    /// table's width or narrower, so the division above is the identity in the common case.
    ///
    /// Measured against `stored` rather than `widths`, so a hidden column does not distort the
    /// conversion: both sides must describe the same set of columns.
    private var stretch: CGFloat {
        stored.dataWidth > 0 ? drawn.dataWidth / stored.dataWidth : 1
    }
}

/// The draggable handle on a column's trailing edge.
///
/// A `DragGesture` rather than a `Slider`, because a table column is resized by the boundary you can
/// see and grab. Each change is applied to the width captured when the drag began, so the edge
/// tracks the pointer exactly instead of accelerating away from it, and `ColumnWidths` clamps the
/// result so no column can be dragged out of existence.
///
/// Two things are drawn, and they do different jobs. The **hairline** is always there: it is what
/// makes the column boundaries traceable across a wide header. The **handlebar** appears under the
/// pointer: a short accent capsule on the boundary, so the resize affordance becomes something the
/// operator can see and aim at instead of a gesture they have to know about. Both sit inside a hit
/// area wider than either, because a 1pt line is not something anyone can actually hit.
private struct ColumnResizeGrip: View {

    @Binding var width: CGFloat
    let label: String

    /// The width the current drag started from; `nil` when no drag is in flight.
    @State private var startWidth: CGFloat?
    @State private var isHovering = false

    private var isDragging: Bool { startWidth != nil }

    /// `true` while the handle should be showing its grab affordance.
    private var isLit: Bool { isHovering || isDragging }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(ruleTint)
                .frame(width: isDragging ? LotColumn.resizeMark : 1)

            Capsule()
                .fill(Color.accentColor.opacity(isLit ? 0.9 : 0))
                .frame(width: LotColumn.resizeMark, height: LotColumn.resizeHandle)
        }
        .frame(width: LotColumn.resizeGrip)
        .contentShape(Rectangle())
        .offset(x: LotColumn.resizeGrip / 2)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if startWidth == nil { startWidth = width }
                    width = ColumnWidths.clamped((startWidth ?? width) + value.translation.width)
                }
                .onEnded { _ in startWidth = nil }
        )
        .help(helpText)
    }

    /// The boundary hairline: barely there at rest, brighter under the pointer, accent while the
    /// column is actually being dragged.
    private var ruleTint: Color {
        if isDragging { return .accentColor.opacity(0.75) }
        return .primary.opacity(isLit ? 0.22 : LotColumn.resizeRuleIdle)
    }

    private var helpText: String {
        "Drag to resize the \(label) column — the handle grabs on the boundary line. Other columns "
            + "share any slack, so the table keeps filling the window."
    }
}

/// One pallet row in the master table.
struct LotTableRow: View {

    let lot: LotItem
    /// Column geometry shared with the header and the nested rows.
    let widths: ColumnWidths
    /// The bid-ceiling policy behind the **Max bid** column.
    let policy: BidTargetPolicy
    let isExpanded: Bool
    /// Zebra striping: alternating rows carry a whisper of tint so a wide row stays followable.
    let isAlternate: Bool
    /// `true` when the operator has checked this row — see `LotSelection`.
    let isSelected: Bool
    /// Whether scanning is possible at all (a provider is configured, no scrape or batch running).
    /// A scan that is already in flight does not block the *other* rows.
    let canScan: Bool
    /// Whether the cheap text-only pass is possible for *this* row: the same gate as `canScan`, and
    /// no appraisal yet, because provisional figures are hidden behind a real valuation.
    let canPrePrice: Bool
    /// Starts the photographed appraisal of this lot.
    let onScan: () -> Void
    /// Starts the cheap text-only estimate of this lot. A click *is* the request: the pass that rides
    /// along in front of a scan stands aside for a row that already has numbers, but pressing this
    /// never asks for permission (see `AnalysisCoordinator.prePrice(_:)`).
    let onPrePrice: () -> Void
    /// Shows this lot's own page as a sheet. The request carries the address and the lot number, and
    /// is built by the row because the row is what knows both — see `pageControl`.
    let onOpenPage: (LotPageRequest) -> Void
    let toggle: () -> Void
    /// Checks or unchecks this row. The row only reports the click — what a check *means*, and what
    /// the two **…selected** buttons do with the set, belongs to the table (`LotSelection`).
    let onToggleSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            // The checkbox column comes first, outside the chevron: it is the one control here that
            // acts on the row as a *set* rather than on the row itself, and keeping it at the table's
            // edge is what lets a column of checks be read down in one glance.
            TableCell(LotColumn.selection) { selectionControl }

            TableCell(LotColumn.expander) {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(lot.discoveredItems.isEmpty ? .tertiary : .secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .disabled(lot.discoveredItems.isEmpty)
                .help(
                    lot.discoveredItems.isEmpty
                        ? "Nothing discovered for this lot yet"
                        : (isExpanded ? "Collapse" : "Expand")
                )
            }

            TableCell(LotColumn.scan) { actionControls }

            TableCell(widths.lotNumber) { lotNumberCell }

            TableCell(widths.title) {
                Text(lot.displayName.condensedWhitespace)
                    .foregroundStyle(.secondary)
                    .help(lot.rawDescription)
            }

            TableCell(widths.bid, alignment: .trailing) {
                Text(lot.currentBid > 0 ? lot.currentBid.currencyWholeText : "—")
                    .monospacedDigit()
            }

            TableCell(widths.maxBid, alignment: .trailing) { maxBidCell }

            TableCell(widths.items, alignment: .trailing) {
                Text(lot.itemCount == 0 ? "—" : "\(lot.itemCount)").monospacedDigit()
            }

            TableCell(widths.retail, alignment: .trailing) {
                Text(lot.displayRetail > 0 ? lot.displayRetail.currencyWholeText : "—")
                    .monospacedDigit()
                    .italic(lot.showsProvisionalNumbers)
                    .help(
                        lot.hasValuation
                            ? "Appraised retail of the discovered products."
                            : "Retail guessed from the listing text — no photographs read yet."
                    )
            }

            TableCell(widths.resale, alignment: .trailing) {
                Text(lot.displayResale > 0 ? lot.displayResale.currencyWholeText : "—")
                    .monospacedDigit()
                    .italic(lot.showsProvisionalNumbers)
                    .help(
                        lot.hasValuation
                            ? "Appraised resale: what the products should fetch."
                            : "Resale guessed from the listing text — no photographs read yet."
                    )
            }

            TableCell(widths.profit, alignment: .trailing) {
                Text(lot.hasValuation ? lot.projectedProfit.currencyWholeText : "—")
                    .monospacedDigit()
                    .fontWeight(lot.projectedProfit > 0 ? .semibold : .regular)
                    .foregroundStyle(profitTint)
            }

            TableCell(widths.roi, alignment: .trailing) {
                Text(lot.returnOnBid.map(\.percentText) ?? "—").monospacedDigit()
            }

            TableCell(widths.ratio, alignment: .trailing) {
                Text(lot.resaleToRetailRatio.map(\.percentText) ?? "—").monospacedDigit()
            }

            TableCell(widths.confidence) {
                ConfidenceBadge(level: lot.lowestConfidence, isEstimated: lot.hasValuation)
            }

            TableCell(widths.status) { statusCell }

            TableCell(widths.active) { activeCell }
        }
        .font(.callout)
        .padding(.horizontal, Theme.rowInset)
        .padding(.vertical, Theme.rowPadding)
        .frame(width: widths.totalWidth, alignment: .leading)
        .background(rowFill)
        .contentShape(Rectangle())
        .onTapGesture { if !lot.discoveredItems.isEmpty { toggle() } }
        .onHover { isHovering = $0 }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule.opacity(0.6)).frame(height: 1) }
    }

    // MARK: - Cells

    /// The row's checkbox: the table's own control rather than the row's, which is why its label is a
    /// bare glyph with no text of its own and its state is read straight from the table's
    /// `LotSelection`.
    ///
    /// Drawn as an SF Symbol inside a plain button instead of as a `Toggle`, because the row already
    /// treats a click as "expand": a `Toggle` brings its own label, its own layout and its own idea of
    /// where a click lands, while a button is a 14-point target that owns exactly its own glyph. The
    /// row's tap gesture stays underneath, so the checkbox is the only part of the row that does not
    /// expand it.
    private var selectionControl: some View {
        Button(action: onToggleSelect) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Uncheck lot \(lot.lotNumber)" : "Check lot \(lot.lotNumber)")
    }

    /// The lot number, doubled as the deep link to the lot's page on the auction site.
    ///
    /// An operator reading a row usually wants the photographs behind it: from here that is one
    /// click, where the expanded row's own link costs an expand plus a click. It opens the same
    /// in-window sheet the **Open** button does (`LotPageSheetView`), so a bare lot number and a
    /// button two columns along never lead to two different places.
    ///
    /// Nothing marks the number as clickable — no arrow beside it. The **Open** button already says
    /// where a row's photographs are, in words, at a size that can be hit; a seven-point glyph on the
    /// end of a lot number only made the number harder to read at a glance, which is what the cell is
    /// scanned for. The affordance stays anyway, for anyone who reaches for the number first, and is
    /// announced the way the rest of the table announces itself: the row's hover highlight, and a
    /// tooltip naming the lot it would open.
    @ViewBuilder
    private var lotNumberCell: some View {
        if let request = LotPageRequest(lot: lot) {
            Button {
                onOpenPage(request)
            } label: {
                lotNumberText
            }
            .buttonStyle(.plain)
            .help("Open lot \(lot.lotNumber) on the auction site")
        } else {
            lotNumberText
        }
    }

    private var lotNumberText: some View {
        Text(lot.lotNumber)
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(lot.currentBid > 0 ? .primary : .secondary)
    }

    /// Highest bid worth placing: the lot's resale figure times the percent for its *weakest* line
    /// item's confidence, because one shaky product is enough to sink a pallet.
    ///
    /// A ceiling built on an eval — no photograph read yet — is italic and grey, so a first look
    /// never reads as a measured number; one the live bid has already passed goes red.
    @ViewBuilder
    private var maxBidCell: some View {
        if let target = lot.bidTarget(using: policy) {
            maxBidText(target)
                .monospacedDigit()
                .fontWeight(target.isOverTarget ? .semibold : .regular)
                .foregroundStyle(maxBidTint(target))
                .help(maxBidHelp(target))
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    /// Returns `Text` so the provisional form can be italic: only `Text` carries that, and the
    /// alternative would restate the row's font.
    private func maxBidText(_ target: BidTarget) -> Text {
        let text = Text(target.maxBid.currencyWholeText)
        return target.isProvisional ? text.italic() : text
    }

    private func maxBidTint(_ target: BidTarget) -> Color {
        if target.isOverTarget { return .red }
        return target.isProvisional ? Color.secondary : Color.primary
    }

    private func maxBidHelp(_ target: BidTarget) -> String {
        var parts = [
            target.isProvisional
                ? "Provisional: \(target.percent)% of the \(target.resale.currencyWholeText) resale "
                    + "guessed from the listing text alone, at \(target.confidence.rawValue) confidence. "
                    + "It is replaced the moment the lot is scanned."
                : "\(target.percent)% of the \(target.resale.currencyWholeText) appraised resale, at "
                    + "\(target.confidence.rawValue) confidence."
        ]
        if target.isOverTarget {
            parts.append("The live bid of \(target.currentBid.currencyWholeText) is already past it.")
        } else if target.maxBid > 0 {
            parts.append(
                "The live bid of \(target.currentBid.currencyWholeText) leaves "
                    + "\(target.headroom.currencyWholeText) of room."
            )
        }
        parts.append("The percentages are set in Run Tuning.")
        return parts.joined(separator: " ")
    }

    /// Pipeline state, the cheap pass's state, and the detail line under both.
    private var statusCell: some View {
        HStack(spacing: 6) {
            AnalysisBadge(state: lot.analysisState)

            if lot.isPrePricing {
                FlagBadge(text: "evaluating", systemImage: "text.magnifyingglass", tint: .accentColor)
                    .help("A cheap text-only estimate is on its way: no photograph has been sent yet.")
            } else if lot.showsProvisionalNumbers {
                FlagBadge(text: "provisional", systemImage: "text.magnifyingglass", tint: .purple)
                    .help("Guessed from the listing text alone — an eval, not a price. The Max bid stays provisional until the lot is priced from its photographs.")
            }

            Text(statusDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Whether the auction still takes bids on this lot.
    ///
    /// The flag is the site's own word, read at scrape time (see `ScrapedLot.isSold`), not something
    /// derived from the numbers: a lot showing a live bid can still be sold if the page says so.
    /// It is *information*, not a gate. Sold rows stay in the table — they are the record of the
    /// auction, and a partly-closed sale should still read — and **Eval** and **Price** still work on
    /// them, because a closed lot's page is a perfectly good description of what was in it, and the
    /// appraisal is what an operator comparing this week's catalogue to last week's wants.
    @ViewBuilder
    private var activeCell: some View {
        if lot.isActive {
            FlagBadge(text: "Active", tint: .green)
                .help("The auction is still taking bids on this lot.")
        } else {
            FlagBadge(text: "Sold", systemImage: "tag.slash", tint: .red)
                .help(activeHelp)
        }
    }

    private var activeHelp: String {
        var parts = ["The site marks this lot sold, so there is nothing left to bid on."]
        if !lot.statusText.isEmpty {
            parts.append("The card said “\(lot.statusText)”. The marker is matched by `soldTextPattern` in the scrape profile.")
        }
        parts.append("The row stays as a record, and **Eval** and **Price** still work on it — the figures are what the lot went for, not a bid to place.")
        return parts.joined(separator: " ")
    }

    // MARK: - Presentation

    /// The row's manual affordances, side by side: **Eval** (the cheap text-only estimate),
    /// **Price** (the photographed appraisal) and **Open** (the lot's own page on the auction site).
    ///
    /// The first two are separate buttons because they are separate purchases. An eval is a fraction
    /// of a price's cost and is useful on its own — it gives a whole page of lots a first figure
    /// before the operator decides which ones deserve photographs — while the priced appraisal is
    /// what the bid ceiling should really rest on. Their states come straight from the lot's own
    /// fields, so the coordinator never has to publish a second copy of "is this row working?".
    ///
    /// Each of the three is drawn inside its own `RowActionSlot`, so the trio is three fixed
    /// positions rather than a strip that re-flows. Without that, every state change moved the
    /// furniture: **Eval** growing a **Re-** prefix after the lot's first eval, **Price** turning into
    /// **Re-price**, and either of them being swapped for a spinner while its request was out — each
    /// one nudged the buttons beside it, so a click aimed at the last button landed on the one that
    /// had moved into its place. The slots are why what the operator aims at does not move.
    private var actionControls: some View {
        HStack(spacing: Theme.actionSpacing) {
            prePriceControl
            scanControl
            pageControl
        }
    }

    /// The cheap pass's button. It carries its own progress state, because an eval runs while the
    /// row is still "not scanned": the analysis badge beside it has nothing to say about it.
    @ViewBuilder
    private var prePriceControl: some View {
        RowActionSlot(widest: "Re-eval", systemImage: "text.magnifyingglass") {
            if lot.isPrePricing {
                workingLabel("Evaluating…")
                    .help("Reading the listing text for a first estimate — no photograph is being sent.")
            } else {
                Button(action: onPrePrice) {
                    Label(lot.showsProvisionalNumbers ? "Re-eval" : "Eval", systemImage: "text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canPrePrice)
                .help(prePriceHelp)
            }
        }
    }

    /// What a slot shows while its request is out: a spinner and a word, centred in the space the
    /// button comes back to. Deliberately *not* a button — there is nothing to press until the
    /// request lands — but the same slot, so the buttons beside it stay put.
    private func workingLabel(_ label: String) -> some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.mini)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var prePriceHelp: String {
        guard canPrePrice else {
            if lot.hasValuation {
                return "This lot has an appraised figure already, which would hide a text-only estimate. "
                    + "Clear valuations in the table menu to eval it again."
            }
            return "Eval needs a provider key (the gear, ⌘,) and no scrape or batch running."
        }
        let body = "Eval: one cheap text-only request prices this pallet from its listing text — no "
            + "photographs are sent. The figures show in italics until a price replaces them."
        let sold = lot.isSold ? " This lot is marked sold: the estimate is still worth having as a record." : ""
        return (lot.showsProvisionalNumbers ? "Ask for the first estimate again. \\(body)" : body) + sold
    }

    /// The photographed appraisal. Its two states come straight from the lot's own analysis state.
    ///
    /// **Price** is the action the row leans on — it is the figure the bid ceiling should rest on —
    /// so it is the only button in the trio wearing the accent colour. **Eval** and **Open** stay
    /// neutral beside it, which is what makes the primary action findable in a table of two hundred
    /// rows without turning the table into a wall of blue.
    @ViewBuilder
    private var scanControl: some View {
        RowActionSlot(widest: "Re-price", systemImage: "arrow.clockwise") {
            switch lot.analysisState {
            case .analyzing:
                workingLabel("Scanning")

            case .completed:
                priceButton(label: "Re-price", systemImage: "arrow.clockwise") {
                    scanHelp("Price this lot again from its photographs — useful after changing the provider or the model, or once the lot's page has more photographs on it.")
                }

            case .pending, .failed, .skipped:
                priceButton(label: "Price", systemImage: "sparkles") {
                    scanHelp("Price this lot from its photographs and fill in the row's numbers.")
                }
            }
        }
    }

    /// The one accent-coloured button in a row, in both of its states: the same control, so
    /// **Price** and **Re-price** are the same width as each other and as the slot's reserve.
    private func priceButton(
        label: String,
        systemImage: String,
        help: () -> String
    ) -> some View {
        Button(action: onScan) {
            Label(label, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .tint(.accentColor)
        .controlSize(.small)
        .disabled(!canScan)
        .help(help())
    }

    /// The scanned appraisal's tooltip: what the click does, or why it cannot happen.
    private func scanHelp(_ body: String) -> String {
        guard canScan else {
            return "Pricing needs an API key (the gear, ⌘,) and no scrape or batch running."
        }
        let sold = lot.isSold ? " The lot is marked sold — the appraisal is a record, not a bid." : ""
        return body + sold
    }

    /// The way off the row and onto the site: this lot's own page, in a sheet over the table.
    ///
    /// The lot number is a target as well, but that is a data column — an operator working down the
    /// buttons is not looking at it, and the arrow that marks it as a link is the smallest thing on
    /// the row. Here the page is one click from the row itself. It is drawn only for a lot whose card
    /// exposed an address, rather than as a permanently dead button.
    ///
    /// It opens *in the window*, not in the operator's browser — see `LotPageSheetView` for why that
    /// is a second web view rather than the panel's reparenting surface, and how the page still
    /// arrives signed in. The bordered button style is not decoration: a bare `Link` renders as
    /// accent-coloured text on macOS, which would read as a label among two buttons rather than as
    /// the third one.
    @ViewBuilder
    private var pageControl: some View {
        if let request = LotPageRequest(lot: lot) {
            RowActionSlot(widest: "Open", systemImage: "arrow.up.right.square") {
                Button {
                    onOpenPage(request)
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(
                "Open lot \\(lot.lotNumber) on the auction site — its photographs and full description — "
                    + "in a window over the table. Nothing is sent to the valuation provider."
                )
            }
        }
    }

    private var statusDetail: String {
        // A thorough scan reports each photograph as it lands, so the row says which frame is being read
        // instead of showing one unchanging line for the whole gallery. The single-pass path reports
        // nothing and keeps the old wording.
        if case .analyzing = lot.analysisState, !lot.photoScanNote.isEmpty {
            return lot.photoScanNote
        }
        return switch lot.analysisState {
        case .pending:
            "queued"
        case .analyzing:
            lot.imagesAnalyzed > 0 ? "reading \(lot.imagesAnalyzed) image(s)" : "downloading images"
        case .completed:
            lot.passesUsed > 1
                ? "\(lot.imagesAnalyzed) image(s) · \(lot.passesUsed) passes"
                : "\(lot.imagesAnalyzed) image(s)"
        case .failed(let message):
            message
        case .skipped(let reason):
            reason
        }
    }

    private var profitTint: Color {
        guard lot.hasValuation else { return .secondary }
        if lot.projectedProfit > 0 { return .green }
        if lot.projectedProfit < 0 { return .red }
        return .primary
    }

    /// Zebra stripe, state tint and hover highlight layered together, so no state is ever made
    /// invisible by another.
    private var rowFill: some View {
        ZStack {
            if isAlternate { Theme.zebraFill }
            stateTint
            if isHovering { Theme.hoverFill }
        }
    }

    private var stateTint: Color {
        switch lot.analysisState {
        case .analyzing: Color.accentColor.opacity(0.12)
        case .completed: Color.green.opacity(0.06)
        case .failed: Color.red.opacity(0.07)
        case .pending, .skipped: Color.clear
        }
    }
}

/// One slot in a row's action trio, held to a single width whatever state it is drawn in.
///
/// A row's buttons are read as a column of controls, so anything that changes one button's width
/// moves the buttons next to it — and the operator's next click is aimed at where a button *was*.
/// There are two ways that happens: a label that grows (**Eval** → **Re-eval**, **Price** →
/// **Re-price**), and a button that is replaced by a spinner while its request is in flight.
///
/// The fix is to reserve the space the widest state needs, which is the button wearing its *full*
/// label, and draw every state inside that reservation. The reserve is laid out as a **real button**
/// rather than as hidden text: what has to be matched is the bordered control — its font under
/// `controlSize`, its internal padding, its icon — and a hidden `Label` would be measured at the
/// row's body font instead, reserving a width no button in the row actually has.
///
/// The reserve is inert: it is invisible, it takes no click (so a press in the slot still reaches the
/// row's own expand gesture) and it is hidden from assistive technology, which reads the live control
/// laid over it.
struct RowActionSlot<Content: View>: View {

    /// The widest label this action ever wears, e.g. **Re-eval**. The slot is exactly as wide as a
    /// bordered button drawing it.
    let widest: String
    /// The symbol drawn alongside it — an icon is part of the width, and the two states of a button
    /// do not always share one.
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Button(action: {}) {
                Label(widest, systemImage: systemImage)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .hidden()

            content
        }
    }
}

/// Nested row: one product the valuation engine believes is inside the pallet.
struct DiscoveredItemRow: View {

    let item: DiscoveredItem
    /// Column geometry shared with the header, so a nested line stays under its pallet.
    let widths: ColumnWidths
    /// `true` for a line item worth flagging as an anchor (see `AnchorItem`).
    let isAnchor: Bool
    var isAlternate = false

    var body: some View {
        HStack(spacing: 0) {
            TableCell(widths.identityWidth) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    connectorSymbol
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.itemName)
                        // What the price rests on, under the name it belongs to: the label wording,
                        // barcode digits or model number the model quoted off the photographs. It is
                        // the row's answer to "why this figure?" — a name alone cannot be argued with,
                        // a quoted UPC or model number can be checked against the picture.
                        if !item.evidence.isEmpty {
                            Label(item.evidence, systemImage: "barcode")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help("Priced from what the appraisal could read: \(item.evidence)")
                        }
                    }
                }
                .padding(.leading, 8)
            }

            // Columns that only mean something for a whole pallet.
            TableCell(widths.bid) { EmptyView() }
            TableCell(widths.maxBid) { EmptyView() }
            TableCell(widths.items) { EmptyView() }

            TableCell(widths.retail, alignment: .trailing) {
                Text(item.retailValue > 0 ? item.retailValue.currencyWholeText : "—")
                    .monospacedDigit()
            }
            TableCell(widths.resale, alignment: .trailing) {
                Text(item.resaleValue > 0 ? item.resaleValue.currencyWholeText : "—")
                    .monospacedDigit()
            }
            TableCell(widths.profit, alignment: .trailing) {
                Text(item.isPriced ? (item.resaleValue - item.retailValue).currencyWholeText : "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            TableCell(widths.roi) { EmptyView() }

            TableCell(widths.ratio, alignment: .trailing) {
                Text(item.resaleRatio.map(\.percentText) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            TableCell(widths.confidence) { ConfidenceBadge(level: item.confidenceLevel) }

            TableCell(widths.status) {
                HStack(spacing: 5) {
                    if isAnchor {
                        FlagBadge(text: "anchor", systemImage: "pin.fill", tint: .orange)
                            .help(anchorHelp)
                    }
                    Text(item.notes)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(item.notes)
                }
            }

            // The lot's active/sold state belongs to the pallet, not to a product inside it.
            TableCell(widths.active) { EmptyView() }
        }
        .font(.caption)
        .padding(.horizontal, Theme.rowInset)
        .padding(.vertical, 4)
        .frame(width: widths.totalWidth, alignment: .leading)
        .background(Color.primary.opacity(isAlternate ? 0.05 : 0.03))
    }

    /// Why this line is worth noticing: one product is a large share of the pallet's value, and a
    /// pallet is only as good as its biggest ticket.
    private var anchorHelp: String {
        "Anchor item: \(item.retailValue.currencyWholeText) of retail at \(item.confidenceLevel.rawValue) "
            + "confidence. Most of the pallet's value sits on this line, so it is the one to sanity-check "
            + "before bidding. The threshold is set in Run Tuning."
    }

    /// The line's marker: a star for an anchor, an elbow for everything shelved under it.
    @ViewBuilder
    private var connectorSymbol: some View {
        if isAnchor {
            Image(systemName: "star.fill")
                .font(.system(size: 8))
                .foregroundStyle(.orange)
                .help(anchorHelp)
        } else {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }
}


/// Row shown when a pallet row is expanded: what the site said, and what the pipeline did with it.
struct LotDetailRow: View {

    let lot: LotItem
    /// Column geometry, so the detail card spans the table even after the columns have been dragged.
    let widths: ColumnWidths
    /// Shows this lot's page as a sheet — the same one the row's **Open** button and its lot number
    /// use, so the card is a third door onto one page rather than a third kind of address.
    let onOpenPage: (LotPageRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !lot.rawDescription.condensedWhitespace.isEmpty {
                Text("Scraped text: \(lot.rawDescription.condensedWhitespace)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if lot.showsProvisionalNumbers {
                Label(
                    "Provisional, from the listing text: \(lot.prePriceRationale.condensedWhitespace)",
                    systemImage: "text.magnifyingglass"
                )
                .font(.caption2)
                .foregroundStyle(.purple)
                .textSelection(.enabled)
                .help("The eval reads the listing text before any photograph is sent, which is why this "
                    + "figure is a guess. Pricing the lot from its photographs replaces it.")
            }

            HStack(spacing: 12) {
                Label("Page \(lot.sourcePage)", systemImage: "doc.text.magnifyingglass")
                Label("\(lot.imageUrls.count) card thumbnail(s)", systemImage: "photo.on.rectangle.angled")
                Label("\(lot.imagesAnalyzed) sent to the model", systemImage: "paperplane")
                if lot.passesUsed > 1 {
                    Label("\(lot.passesUsed) passes", systemImage: "square.stack.3d.up")
                        .help(
                            "How many model requests produced these figures. A batched DeepSeek scan is "
                                + "one request per batch of photographs plus the one that priced the "
                                + "manifest; its text-then-photographs route is two."
                        )
                }
                Label("\(lot.itemCount) item(s) discovered", systemImage: "shippingbox")
                if lot.hasReadings {
                    Label(lot.readingSummary.compactPhrase, systemImage: "photo.stack")
                        .help(readingsSummaryHelp)
                }
                if lot.hasManifest {
                    Label(lot.manifestPhrase, systemImage: "list.bullet.rectangle")
                        .help(manifestSummaryHelp)
                }
                if let request = LotPageRequest(lot: lot) {
                    Button("Open lot page") { onOpenPage(request) }
                        .buttonStyle(.link)
                        .help("Show this lot on the auction site in a window over the table")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if lot.hasReadings {
                readingsBlock
            }

            if lot.hasManifest {
                manifestBlock
            }
        }
        .padding(.leading, Theme.rowInset)
        .padding(.trailing, Theme.rowInset)
        .padding(.vertical, 6)
        .frame(width: widths.totalWidth, alignment: .leading)
        .background(Color.primary.opacity(0.02))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule.opacity(0.6)).frame(height: 1) }
    }

    /// What the manifest chip on the card's first line means.
    ///
    /// The batched route's counterpart to `readingsSummaryHelp`: there, one request per frame; here, one
    /// request per *batch* of frames, followed by a single pricing request that carries no photographs at
    /// all. Worth saying because the chip reads `18 item(s)`, which is the inventory the pallet was
    /// priced from rather than a count of prices. The frames the batches found nothing in are counted
    /// here too, because "read from 24 photographs" on its own would read as though the rest of the batch
    /// were never looked at — and so is a count two batches read differently, because that number is the
    /// one the line above was priced from.
    private var manifestSummaryHelp: String {
        let manifest = lot.manifest
        let count = manifest?.photographCount ?? 0
        let empty = manifest?.unreadFrames.count ?? 0
        let disputed = manifest?.items.filter { $0.countConflict != nil }.count ?? 0
        return "The pallet's inventory, read from \(count) of its photographs in batches"
            + (empty > 0 ? " (\(empty) more were read and held nothing sellable)" : "")
            + " — each product counted once across every view the batches carried"
            + (disputed > 0
                ? ", with the \(disputed) count(s) two of them read differently resolved by evidence "
                    + "rather than by size"
                : "")
            + " — and then priced in one text-only request. The manifest below is what the line items above "
            + "were derived from, so a figure that looks wrong can be checked against the entry behind it."
    }


    /// What the readings chip on the card's first line means.
    ///
    /// Told two ways because a thorough scan has two shapes now: one request per frame, or one request
    /// per *view* when two frames turned out to show the same thing — and in the second case the chip's
    /// count and the gallery's photograph count are honestly different numbers.
    private var readingsSummaryHelp: String {
        guard lot.hasGroupedViews else {
            return "Each of these photographs was read on its own and the readings were then reconciled "
                + "into the line items above. A figure can be checked against the frame it came from."
        }
        return "Each of these photographs was read on its own — except the \(lot.groupedFrameCount) "
            + "below that showed exactly what another frame showed, which share that frame's reading. "
            + "The readings were then reconciled into the line items above, so a figure can still be "
            + "checked against the frame it came from."
    }

    /// What each photograph showed, one line per frame — the part of a thorough scan that is *evidence*
    /// rather than a figure.
    ///
    /// The card is where this belongs: the pallet's line items are the reconciled answer, and these are
    /// the observations they were built from, so a price that looks wrong can be traced to the frame it
    /// was read out of without spending another request. Every photograph the scan opened is listed,
    /// including the ones that turned out to hold nothing — an empty frame is a fact about the pallet.
    private var readingsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Photographs read one by one: \(lot.readingSummary.logPhrase)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            // The other half of the account: the frames the scan did not pay for, and what covers them.
            // Printed here rather than hidden, because "12 photographs read" and "9 requests" are both
            // true of a folded gallery and only together do they explain the count.
            if lot.hasGroupedViews {
                Text(lot.groupedViewsPhrase)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .help(
                        "A frame that showed what another frame showed was not read again: one reading "
                            + "covers both, and the frame still travels with the reconciliation — "
                            + "attached, unread — so nothing on the pallet goes unseen."
                    )
            }

            ForEach(lot.readings.inGalleryOrder) { reading in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(reading.positionText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(reading.displayName)
                            .font(.caption2)
                            .foregroundStyle(reading.isEmpty ? .tertiary : .secondary)
                            .textSelection(.enabled)
                        if !reading.detailPhrase.isEmpty || !reading.identifiers.isEmpty {
                            Text(
                                [reading.detailPhrase, reading.identifiers.joined(separator: " · ")]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: " · ")
                            )
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .help("One model request per photograph — or per group of frames that showed the same thing — "
            + "kept on this machine and reused by the next scan of this lot with the same model.")
    }

    /// What the batches read the pallet to hold — the batched route's evidence, as `readingsBlock` is the
    /// frame-by-frame route's.
    ///
    /// Printed in full rather than summarised: this is the inventory the pricing pass was handed, so a
    /// line item that looks wrong can be checked against the manifest entry it came from, and the gallery
    /// numbers each entry names are the photographs that entry rests on. One line per distinct product —
    /// which is the whole claim the batching makes, that a carton seen from four angles is one line here.
    /// A count two batches disagreed about is not hidden either: the entry prints the conflict and the
    /// evidence the fold used to settle it (`ManifestItem.countConflictNote`), because that number, not
    /// the larger one, is what the line behind it was priced from.
    private var manifestBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Manifest read from the photographs: \(lot.manifest?.logPhrase ?? "")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            ForEach(lot.manifest?.items ?? []) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.quantity > 0 ? "×\(item.quantity)" : "—")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        if !item.detailPhrase.isEmpty {
                            Text(item.detailPhrase)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }

                        // The one thing about an entry that the batches did not actually agree on: two of
                        // them read different counts, and the number the line was priced from is the one
                        // the better sighting supported. Printed in the caution colour because it is the
                        // count an operator can still check against the frames the entry names.
                        if let conflict = item.countConflictNote {
                            Text(conflict)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                                .help("Two batches read different counts for this product. The inventory "
                                    + "keeps the number the better sighting supported — the higher "
                                    + "confidence first, then the sighting that read a barcode, then the one "
                                    + "seen in more photographs — and this line was priced from that number, "
                                    + "so check the frames above if it looks wrong. The pricing pass is told "
                                    + "not to re-count it.")
                        }
                    }
                }
            }
        }
        .help("What the photographs were read to hold before any of it was priced — one entry per "
            + "distinct product, counted once across every view the batches carried, with the frames each "
            + "was seen in. Pricing looks these entries up; it does not re-count them. An entry that says "
            + "its count was disputed is one two batches read differently: the number shown is the one the "
            + "better sighting supported.")
    }
}


/// Pipeline state chip used in the row's status column.
struct AnalysisBadge: View {

    let state: LotItem.AnalysisState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(label)
        }
        .chipStyle(tint: tint)
        .help(state.label)
    }

    private var label: String {
        switch state {
        case .pending: "queued"
        case .analyzing: "analyzing"
        case .completed: "valued"
        case .failed: "failed"
        case .skipped: "skipped"
        }
    }

    private var tint: Color {
        switch state {
        case .pending: .secondary
        case .analyzing: .accentColor
        case .completed: .green
        case .failed: .red
        case .skipped: .orange
        }
    }
}

/// Confidence chip for a valuation, coloured by the model's self-reported certainty.
struct ConfidenceBadge: View {

    let level: DiscoveredItem.Confidence
    var isEstimated = true

    var body: some View {
        if isEstimated {
            Text(level.rawValue)
                .chipStyle(tint: tint)
                .help("Model confidence: \(level.rawValue)")
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private var tint: Color {
        switch level {
        case .high: .green
        case .medium: .orange
        case .low: .red
        }
    }
}

/// A small labelled chip in the row's status column, for the states that are not the pipeline's own
/// (`AnalysisBadge`) or the model's confidence (`ConfidenceBadge`): an eval in flight, a
/// provisional figure, an anchor line item.
///
/// Shared by the pallet and product rows so the three read as one family of flags rather than three
/// unrelated tinted pills.
struct FlagBadge: View {

    let text: String
    var systemImage: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 7, weight: .bold))
            }
            Text(text)
        }
        .chipStyle(tint: tint)
    }
}


#Preview("Lot rows") {
    let widths = ColumnWidths.standard
    let policy = BidTargetPolicy.standard
    let threshold = AnchorItem.defaultThreshold
    let valued = sampleValuedLot()
    let prePriced = samplePrePricedLot()

    // No `return`: the preview body is a result builder, and the bindings above it are declarations
    // the builder passes over rather than values it is asked to combine.
    VStack(spacing: 0) {
        LotTableHeader(
            widths: .constant(widths),
            // No column is hidden in this preview, so the stored layout and the drawn one are the
            // same value: `stored` is what a drag converts back to.
            stored: widths,
            drawn: widths,
            sort: .constant(.scrapeOrder),
            direction: .constant(.ascending),
            // One of the two rows below is checked, so the box over them is drawn in its *mixed*
            // state — the one state a single row's checkbox cannot show on its own.
            selection: .constant(LotSelection(ids: [valued.id])),
            drawnRowIDs: [valued.id, prePriced.id]
        )

        // A scanned pallet: solid numbers, one $100+ anchor and a Max bid from its resale total.
        LotTableRow(
            lot: valued,
            widths: widths,
            policy: policy,
            isExpanded: true,
            isAlternate: false,
            isSelected: true,
            canScan: true,
            canPrePrice: false,
            onScan: {},
            onPrePrice: {},
            onOpenPage: { _ in },
            toggle: {},
            onToggleSelect: {}
        )
        ForEach(valued.discoveredItems) { item in
            DiscoveredItemRow(
                item: item,
                widths: widths,
                isAnchor: item.isAnchor(threshold: threshold)
            )
        }
        LotDetailRow(lot: valued, widths: widths, onOpenPage: { _ in })

        // A lot waiting on its photographs: the text-only eval stands in, in italics.
        LotTableRow(
            lot: prePriced,
            widths: widths,
            policy: policy,
            isExpanded: true,
            isAlternate: true,
            isSelected: false,
            canScan: true,
            canPrePrice: true,
            onScan: {},
            onPrePrice: {},
            onOpenPage: { _ in },
            toggle: {},
            onToggleSelect: {}
        )
        LotDetailRow(lot: prePriced, widths: widths, onOpenPage: { _ in })
    }
    .frame(width: widths.totalWidth)
}

/// Palette for the preview above: one lot with three discovered items, two passes and a line item
/// over the anchor threshold. A function rather than statements inside the `#Preview` body, which is
/// a result builder.
@MainActor
private func sampleValuedLot() -> LotItem {
    let lot = LotItem(
        lotNumber: "142",
        currentBid: 210,
        rawDescription: "Pallet of returned general merchandise, 60 pieces, mixed departments.",
        imageUrls: [],
        title: "Pallet of returned general merchandise",
        detailURL: URL(string: "https://example.com/auction/lot/142")
    )
    lot.applyValuation(
        [
            DiscoveredItem(
                itemName: "AA batteries, 12x 2-pack",
                confidence: "High",
                retailValue: 420,
                resaleValue: 180,
                notes: "Fast mover.",
                evidence: "label reads \"Energizer MAX AA\" · UPC 039800011324"
            ),
            DiscoveredItem(
                itemName: "Scented candles, 24-pack",
                confidence: "Med",
                retailValue: 260,
                resaleValue: 140,
                notes: "Slow but steady.",
                evidence: "label reads \"Yankee Candle 22 oz\""
            ),
            DiscoveredItem(
                itemName: "Desk lamp, boxed",
                confidence: "Med",
                retailValue: 90,
                resaleValue: 45,
                notes: "Below the anchor line."
            )
        ],
        imagesAnalyzed: 4,
        passes: 2
    )
    return lot
}

/// Palette for the preview above: a lot priced from the listing text alone, so its row renders its
/// numbers and its Max bid provisionally.
@MainActor
private func samplePrePricedLot() -> LotItem {
    let lot = LotItem(
        lotNumber: "L208",
        currentBid: 150,
        rawDescription: "Two pallets of assorted home goods, shelf pulls, untested.",
        imageUrls: [],
        title: "Assorted home goods, 2 pallets",
        detailURL: URL(string: "https://example.com/auction/lot/208")
    )
    lot.markPrePricing()
    lot.applyPrePrice(
        PrePriceEstimate(
            retail: 1_450,
            resale: 780,
            confidence: .medium,
            rationale: "Typical 55-60% department-store resale for untested home goods at this volume."
        )
    )
    return lot
}

