//
//  LotTableView.swift
//  PalletAuctionBidTool
//
//  Expandable lot table: one row per pallet, nested rows per discovered product.
//

import SwiftUI

/// The master table.
///
/// Rows are hand-built rather than using SwiftUI's `Table`: the table is hierarchical (pallet →
/// discovered products) and every row carries its own **Scan** button, neither of which `Table`'s
/// flat, value-typed rows can express. Column widths come from `LotColumn` so the sticky header and
/// both row kinds stay aligned, and ordering comes from `LotOrdering` so the rules are testable
/// outside the UI.
struct LotTableView: View {

    let coordinator: AnalysisCoordinator

    /// The bid ceiling and anchor policies the table renders, read from `AppSettings` so the
    /// columns always agree with Run tuning.
    let policy: BidTargetPolicy
    let anchorThreshold: Double

    /// The same settings the columns above are read from. The table needs the object itself — not
    /// just the two derived values — because the gear in its toolbar writes the column choice back
    /// through it (`isColumnVisible(_:)` / `setColumn(_:visible:)`).
    let settings: AppSettings

    @State private var expandedLotIDs = Set<UUID>()
    @State private var sort: LotSort = .scrapeOrder
    @State private var direction: SortDirection = .ascending
    /// Search text: the lot number first, the listing copy second (see `LotSearch`).
    @State private var query = ""
    /// `true` while the caret is in the toolbar's search box, which is what lights its border.
    @FocusState private var isSearchFocused: Bool
    /// Column geometry, owned here so one drag moves the header and every row together. Widths only:
    /// *which* columns are drawn is the operator's persisted choice (`settings.columnVisibility`),
    /// stamped onto this layout as it is drawn — see `layout`.
    @State private var widths = ColumnWidths.standard
    /// The lot page a row has asked to see, held as the sheet's item. The request lives here rather
    /// than inside a row because a row is a value: a `@State` in one would be discarded the moment the
    /// table re-sorts, and the page would vanish under the operator mid-read.
    @State private var pageRequest: LotPageRequest?

    private var lots: [LotItem] { coordinator.lots }

    /// The rows the search leaves: what the sort then orders and the table draws.
    private var visibleLots: [LotItem] {
        LotSearch.filter(lots, query: query)
    }

    var body: some View {
        // The operator's column choice is read *here*, and stamped onto the dragged widths before the
        // viewport is measured: the table's dependence on that choice is then a value the body hands
        // down rather than something re-derived from the settings object inside a layout closure, so
        // hiding a column is an ordinary change of input and the table re-renders.
        let layout = self.layout

        VStack(spacing: 0) {
            toolbar
            Divider()

            // The viewport is measured rather than guessed: the table is drawn from
            // `layout.filling(_:)`, which stretches the columns to this width so the table spans the
            // window instead of leaving a dead strip beside the last column. Narrower than the table,
            // the same call hands back the dragged widths and the horizontal scroller does its job.
            // The height matters too — see `scrollingTable(viewport:layout:)`.
            GeometryReader { proxy in
                body(viewport: proxy.size, layout: layout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.tableFill)
        // A lot's own page, over the table rather than in the operator's browser. Presented from here
        // — the one place that owns the request — so the row can be a value and still open one.
        .sheet(item: $pageRequest) { request in
            LotPageSheetView(request: request)
        }
    }

    /// The table, or the state that stands in for it, in a known viewport.
    @ViewBuilder
    private func body(viewport: CGSize, layout: ColumnWidths) -> some View {
        if lots.isEmpty {
            emptyState
        } else if visibleLots.isEmpty {
            noMatchesState
        } else {
            scrollingTable(viewport: viewport, layout: layout)
        }
    }

    /// The rows, under a header pinned to the top of the scroller.
    ///
    /// `layout` arrives already stamped with the operator's column choice; `drawn` is that layout
    /// stretched to fill this window, and is the one thing the header and every row lay themselves
    /// out from — which is what keeps them on the same grid.
    private func scrollingTable(viewport: CGSize, layout: ColumnWidths) -> some View {
        let drawn = layout.filling(viewport.width)

        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(sortedLots.enumerated()), id: \.element.id) { index, lot in
                        lotBlock(for: lot, isAlternate: index.isMultiple(of: 2), widths: drawn)
                    }
                } header: {
                    LotTableHeader(
                        widths: $widths,
                        stored: layout,
                        drawn: drawn,
                        sort: $sort,
                        direction: $direction
                    )
                }
            }
            // Keyed on the columns being drawn, so a change to the choice rebuilds the table rather
            // than leaving SwiftUI to diff a layout that only exists at viewport width: a table whose
            // header has moved on while its rows have not — or that is still sitting at the scroll
            // offset of a wider layout — reads as columns that do not line up. A change of *data*
            // does not touch this key, so scraping and valuations never disturb the viewport.
            .id(layout.visibility.visibleColumns)
            // Both frames are load-bearing. The width is the column layout; the *height* is what
            // pins the rows to the top. A scroll view centres content that is shorter than its
            // viewport — with six lots in a tall window the first row would otherwise float halfway
            // down the screen — so the content is stretched to the viewport's height and its
            // alignment is stated outright rather than left to the default. `defaultScrollAnchor`
            // then keeps the scroll position itself on that first row.
            .frame(
                minWidth: drawn.totalWidth,
                maxWidth: drawn.totalWidth,
                minHeight: viewport.height,
                alignment: .topLeading
            )
        }
        .defaultScrollAnchor(.top)
        .background(Theme.tableFill)
    }

    /// The stored widths with the operator's column choice applied.
    ///
    /// Two things decide the shape of the table and they are owned in two places: the *widths* are
    /// this view's drag state, and the *choice of columns* is a preference that outlives the window.
    /// Stamping the one onto the other at draw time is what stops the two disagreeing — and it is why
    /// `widths` itself never carries a visibility, so a drag can never write a stale choice back.
    private var layout: ColumnWidths {
        var stamped = widths
        stamped.visibility = visibility
        return stamped
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label("Lots", systemImage: "shippingbox")
                .font(.subheadline.weight(.semibold))

            countBadge(lots.count)

            if LotSearch.isFiltering(query) {
                Text("\(visibleLots.count) of \(lots.count) shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if coordinator.unvaluedCount > 0 {
                Text("\(coordinator.unvaluedCount) waiting to be scanned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            searchField

            Button {
                coordinator.prePriceUnvalued()
            } label: {
                Label("Eval all", systemImage: "text.magnifyingglass")
            }
            .controlSize(.small)
            .disabled(!coordinator.canPrePriceUnvalued)
            .help(
                "Gives every lot that has no figure yet a cheap text-only eval from its listing text "
                    + "alone — one request each, no photographs. Lots that already carry a valuation or an "
                    + "eval are left alone, and lots the site marks sold are included."
            )

            Button {
                coordinator.scanUnvalued()
            } label: {
                Label("Price all", systemImage: "sparkles")
            }
            .controlSize(.small)
            .disabled(!coordinator.canScanUnvalued)
            .help(
                "Prices every lot that has no valuation yet from its photographs, using the provider and "
                    + "limits in Run tuning. Individual rows can be priced on their own too, and lots the "
                    + "site marks sold are included."
            )

            Divider().frame(height: 16)

            Text("Sort")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Sort by", selection: $sort) {
                ForEach(LotSort.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Order the rows. The column headers sort too.")

            Picker("Direction", selection: $direction) {
                ForEach(SortDirection.allCases) { option in
                    Label(option.label, systemImage: option.systemImage)
                        .labelStyle(.iconOnly)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!sort.isDirectional)
            .help(
                sort.isDirectional
                    ? "Ascending or descending"
                    : "Scrape order is the order the lots were found in — pick another sort to choose a direction."
            )

            Divider().frame(height: 16)

            columnsMenu

            Menu {
                Button("Expand all") {
                    withAnimation(.snappy) { expandedLotIDs = Set(lots.map(\.id)) }
                }
                .disabled(lots.isEmpty || expandedLotIDs.count >= lots.count)

                Button("Collapse all") {
                    withAnimation(.snappy) { expandedLotIDs.removeAll() }
                }
                .disabled(expandedLotIDs.isEmpty)

                Divider()

                Button("Reset valuations", role: .destructive) {
                    coordinator.resetValuations()
                }
                .disabled(coordinator.isRunning || coordinator.lots.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Expand or collapse every row, or clear every valuation and keep the scraped lots.")
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, Theme.rowInset + 4)
        .padding(.vertical, Theme.headerPadding)
        .background(.bar)
    }

    // MARK: - Column chooser

    /// The gear: which of the table's data columns are drawn, and the way back to the shipped widths.
    ///
    /// A menu of switches rather than a popover, because this is a small, flat set of choices the
    /// operator flips one at a time while wanting to watch the table change behind it — a menu leaves
    /// the table visible. The fixed chrome — the disclosure chevron and the **Eval** / **Price** /
    /// **Open** buttons — has no switch here, because it is not a case in `LotColumnKey`: a table
    /// that cannot price a row is not a table.
    private var columnsMenu: some View {
        Menu {
            Section("Columns") {
                ForEach(LotColumnKey.allCases) { key in
                    Toggle(key.label, isOn: columnBinding(key))
                        .disabled(!visibility.canToggle(key))
                }
            }

            Divider()

            Button("Show all columns") {
                settings.showAllColumns()
            }
            .disabled(!visibility.isHidingAnything)

            Button("Reset column widths") {
                withAnimation(.snappy) { widths.reset() }
            }
            .disabled(widths == ColumnWidths.standard)
        } label: {
            Image(systemName: "gearshape")
                .overlay(alignment: .topTrailing) {
                    // The panel's own gear marks "configured but not finished" with a dot; this one
                    // marks a table that is not showing everything it has, so a column the operator
                    // hid last week is never mistaken for a column that does not exist.
                    if visibility.isHidingAnything {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -3)
                    }
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(columnsHelp)
    }

    /// One column's switch, bound through `AppSettings` so a flip is written as it is made and read
    /// back from the same place.
    private func columnBinding(_ key: LotColumnKey) -> Binding<Bool> {
        Binding(
            get: { settings.isColumnVisible(key) },
            set: { settings.setColumn(key, visible: $0) }
        )
    }

    /// The operator's column choice, read once per use rather than sprinkled through the menu.
    private var visibility: ColumnVisibility { settings.columnVisibility }

    private var columnsHelp: String {
        let body = "Choose which columns the table shows, and put the widths back if a drag has left "
            + "the table awkward. The choice is remembered between launches, and a hidden column "
            + "keeps its own width for when it comes back."
        guard visibility.isHidingAnything else { return body }
        let hidden = visibility.hiddenCount == 1
            ? "1 column is hidden"
            : "\(visibility.hiddenCount) columns are hidden"
        return "\(hidden). \(body)"
    }

    /// The glyph that heads an empty state.
    ///
    /// A washed circle rather than a bare symbol: an empty table should read as deliberate — nothing
    /// loaded *yet* — instead of as a view that failed to draw. Sized on the 4-point grid so the two
    /// empty states line up with each other.
    private func emptyStateGlyph(_ systemImage: String, size: CGFloat = 32) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.05), in: Circle())
            .overlay(Circle().strokeBorder(Theme.cardStroke))
    }

    private func countBadge(_ value: Int) -> some View {
        Text("\(value)")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Theme.countFill, in: Capsule())
    }

    /// The finder: a lot number from a bid sheet, or any words from the listing copy.
    ///
    /// It is drawn as a field rather than as a bare `TextField` so the toolbar reads as one strip of
    /// controls: a tinted rounded box, a hairline that turns into the accent colour while the operator
    /// is typing in it, and a clear button that only exists when there is something to clear.
    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(isSearching ? Color.accentColor : Color.secondary)

            TextField("Lot number or text", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: 150)
                .focused($isSearchFocused)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                .strokeBorder(isSearching ? Color.accentColor.opacity(0.7) : Theme.cardStroke)
        )
        .help(
            "Filter the rows. A bare number finds the lot number — \"lot #142\", \"L142\" and \"142\" are "
                + "the same query — and anything else is matched against the listing text."
        )
    }

    /// `true` while the caret is in the search box, which is what lights its border.
    private var isSearching: Bool { isSearchFocused }
}

// MARK: - Rows and expansion

extension LotTableView {

    /// One lot: its row, plus the nested product lines and the description card when expanded.
    ///
    /// `widths` arrives already stretched to the window (`ColumnWidths.filling(_:)`), so a nested
    /// line lands under the column it belongs to rather than under the header's idea of where that
    /// column is.
    @ViewBuilder
    private func lotBlock(for lot: LotItem, isAlternate: Bool, widths: ColumnWidths) -> some View {
        let isExpanded = expandedLotIDs.contains(lot.id)

        VStack(spacing: 0) {
            LotTableRow(
                lot: lot,
                widths: widths,
                policy: policy,
                isExpanded: isExpanded,
                isAlternate: isAlternate,
                canScan: coordinator.canScan,
                canPrePrice: coordinator.canPrePrice && !lot.hasValuation,
                onScan: { coordinator.scan(lot) },
                onPrePrice: { coordinator.prePrice(lot) },
                onOpenPage: { pageRequest = $0 },
                toggle: { toggle(lot) }
            )

            if isExpanded, !lot.discoveredItems.isEmpty {
                ForEach(lot.discoveredItems) { item in
                    DiscoveredItemRow(
                        item: item,
                        widths: widths,
                        isAnchor: item.isAnchor(threshold: anchorThreshold),
                        isAlternate: isAlternate
                    )
                }
            }

            if isExpanded, !lot.rawDescription.condensedWhitespace.isEmpty {
                LotDetailRow(lot: lot, widths: widths, onOpenPage: { pageRequest = $0 })
            }
        }
    }

    /// Shown instead of the table when the search matched nothing, so an empty screen is never
    /// mistaken for an empty auction.
    private var noMatchesState: some View {
        VStack(spacing: 10) {
            emptyStateGlyph("magnifyingglass")
            Text("No lot matches “\(query)”")
                .font(.title3.weight(.medium))
            Text(
                "\(lots.count) lot(s) are loaded. A bare number is matched against the lot number, so "
                    + "clearing the punctuation usually finds it."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)

            Button("Show all \(lots.count)") { query = "" }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 44)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            emptyStateGlyph(
                coordinator.emptyListingNote == nil ? "shippingbox" : "tag.slash",
                size: 40
            )

            if let note = coordinator.emptyListingNote {
                Text("No active listings")
                    .font(.title3.weight(.medium))
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Text(
                    "The run stopped without spending anything. Sold lots stay listed when an auction "
                        + "returns them, flagged in the **Active** column, so a partly-closed sale is "
                        + "still readable."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            } else {
                Text("No lots yet")
                    .font(.title3.weight(.medium))
                Text(
                    "Press Scrape Lots to walk the result pages in a hidden web view and fill this table. "
                        + "Then press Eval on a row for a cheap text-only estimate, or Price to appraise it "
                        + "from its photographs."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 52)
    }

    /// The search narrows the loaded lots, the sort orders what is left.
    private var sortedLots: [LotItem] {
        LotOrdering.sorted(visibleLots, by: sort, direction: direction)
    }

    private func toggle(_ lot: LotItem) {
        withAnimation(.snappy(duration: 0.18)) {
            if expandedLotIDs.contains(lot.id) {
                expandedLotIDs.remove(lot.id)
            } else {
                expandedLotIDs.insert(lot.id)
            }
        }
    }
}

#Preview("Empty table") {
    let settings = AppSettings()
    return LotTableView(
        coordinator: AnalysisCoordinator(settings: settings),
        policy: settings.bidTargetPolicy,
        anchorThreshold: settings.effectiveAnchorThreshold,
        settings: settings
    )
    .frame(width: 1240, height: 420)
}

// The fixtures are `#if DEBUG`, so this preview is too — a release build has no sample lots to seed
// with (deviation 21).
#if DEBUG
#Preview("Populated table") {
    let settings = AppSettings()
    let coordinator = AnalysisCoordinator(settings: settings)
    coordinator.loadSamplesForPreview()
    return LotTableView(
        coordinator: coordinator,
        policy: settings.bidTargetPolicy,
        anchorThreshold: settings.effectiveAnchorThreshold,
        settings: settings
    )
    // Wide on purpose: this is where the columns have slack to share, so the table has to fill the
    // window rather than stopping short of the right edge.
    .frame(width: 1_560, height: 460)
}

// What the gear does to the table. The choice is assigned straight onto the settings rather than
// written through `setColumn(_:visible:)`: a preview must never persist a layout into the operator's
// real `UserDefaults` domain.
#Preview("Table with columns hidden") {
    let settings = AppSettings()
    let coordinator = AnalysisCoordinator(settings: settings)
    coordinator.loadSamplesForPreview()
    settings.columnVisibility = ColumnVisibility(
        hiddenColumns: [.title, .ratio, .confidence, .active]
    )
    return LotTableView(
        coordinator: coordinator,
        policy: settings.bidTargetPolicy,
        anchorThreshold: settings.effectiveAnchorThreshold,
        settings: settings
    )
    // Deliberately narrow: with four columns gone the table should sit inside a small window with
    // the survivors taking up the slack, not leave a dead strip where Description used to be.
    .frame(width: 1_100, height: 460)
}
#endif

