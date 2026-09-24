//
//  ControlPanelView.swift
//  PalletAuctionBidTool
//
//  Top-of-window panel: the lot-list URL, run controls and two folding settings cards.
//

import SwiftUI

/// Operator input surface. Every field writes straight into `AppSettings`, which persists the
/// values to `UserDefaults` when a run or a scan starts.
///
/// The panel is deliberately shallow: the URL row, the run buttons and the readiness pill are always
/// visible, **Run tuning** folds away, and everything about the site session and the valuation
/// provider lives behind the gear in the title row (see `SiteSettingsSheet`). Credentials and quota
/// knobs therefore cost the table no vertical space at rest. The gear carries a one-line summary of
/// the modal beside it, plus a dot while no key is set — the one thing that silences every scan
/// button in the table.
struct ControlPanelView: View {

    @Bindable var settings: AppSettings
    let coordinator: AnalysisCoordinator

    /// Run tuning starts folded: its defaults are sane, and nothing in it is needed to get a first
    /// scrape out. The site login and the provider now live in a modal, so they need no state here at
    /// all.
    @State private var showsTuning = false
    /// Whether the settings modal is up.
    @State private var showsSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.groupSpacing) {
            titleRow
            urlRow
            tuningSection
        }
        .padding(.horizontal, Theme.panelPadding)
        .padding(.vertical, Theme.groupSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .sheet(isPresented: $showsSettings) {
            SiteSettingsSheet(settings: settings)
        }
    }

    // MARK: - Title + readiness

    private var titleRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    LinearGradient(
                        colors: [.accentColor, .accentColor.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 0) {
                Text("Pallet Auction Bid Tool")
                    .font(.headline)
                Text("Scrape a lot list, then appraise the pallets worth a second look.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            // The folded login card's summary line, kept: with the fields behind a gear, the panel
            // still has to say which provider is armed and whether it has a key.
            Text(settingsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(settingsSummary)

            settingsButton

            readinessPill
        }
    }

    /// The gear: **Site login & valuation** as a modal.
    ///
    /// This is what the expandable card used to be. A modal costs the table nothing while it is
    /// closed, which is the point — those four fields are set once per install and were otherwise
    /// paying for themselves in rows. `⌘,` is the macOS reflex for exactly this.
    private var settingsButton: some View {
        Button {
            showsSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .overlay(alignment: .topTrailing) {
                    if needsAPIKey {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(",", modifiers: .command)
        .help(
            needsAPIKey
                ? "Site login, provider, model and API key — no key is set, so nothing can be scanned. ⌘,"
                : "Site login, provider, model and API key. ⌘,"
        )
    }

    /// `true` while nothing can be appraised: no key for the selected provider, which is the one
    /// combination worth a mark on the gear — every **Eval** and **Price** button is inert without it.
    private var needsAPIKey: Bool { !settings.hasAPIKey }

    /// Always-on readiness state. This used to be a paragraph wedged beside the fields, which never
    /// survived a narrow window; a single pill fits any width and the full sentence is one hover
    /// away.
    private var readinessPill: some View {
        let note = readiness
        return Label(note.text, systemImage: note.icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(note.tint)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(note.tint.opacity(0.12), in: Capsule())
            .help(note.detail)
    }

    private var readiness: (text: String, detail: String, icon: String, tint: Color) {
        guard let url = settings.auctionURLValue else {
            let typed = settings.auctionURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                typed.isEmpty ? "Paste a lot-list URL" : "That URL is unusable",
                "The page that already lists lots, e.g. …/auctions?page=1. It needs an http(s) scheme and a host.",
                typed.isEmpty ? "info.circle" : "exclamationmark.triangle",
                typed.isEmpty ? .secondary : .orange
            )
        }

        let host = url.host() ?? "the site"
        if !settings.hasAPIKey {
            return (
                "Key needed to scan",
                "Scraping \(host) works right now; add a \(settings.provider.displayName) API key "
                    + "behind the gear (⌘,) to appraise lots.",
                "key",
                .orange
            )
        }
        return (
            "Ready · \(settings.activeModelID)",
            "Scrape \(settings.pageLimitSummary), then press Eval for a text-only guess (or Price "
                + "for photographs) on any lot — or use the all-lots buttons — to appraise with "
                + "\(settings.provider.displayName) \(settings.activeModelID).",
            "checkmark.circle",
            .green
        )
    }

    // MARK: - URL + run controls

    private var urlRow: some View {
        HStack(spacing: 10) {
            field("Auction URL") {
                TextField("https://www.example-auction.com/lots?page=1", text: $settings.auctionURL)
                    .onSubmit(runIfPossible)
            }
            .frame(maxWidth: .infinity)

            Button(action: runIfPossible) {
                Label("Scrape Lots", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!coordinator.canStart)
            .help(
                "Walk up to \(settings.effectivePageLimit) result page(s) and load every lot into the table. "
                    + "Appraisal is on demand, so this makes no API calls."
            )

            Button {
                coordinator.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!coordinator.isRunning)
            .help("Cancels the scrape and every scan in flight.")

            Button {
                coordinator.clearResults()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(coordinator.isRunning || coordinator.lots.isEmpty)
            .help("Empties the table and the activity log.")

            Button {
                coordinator.setBrowserVisible(true)
            } label: {
                Label("Page", systemImage: "safari")
            }
            .disabled(!coordinator.canShowBrowser || coordinator.isBrowserVisible)
            .help("Show the real auction page — required to clear a captcha or MFA prompt by hand.")
        }
    }

    private func runIfPossible() {
        guard coordinator.canStart else { return }
        coordinator.run()
    }

    // MARK: - Settings summary

    /// What the gear's caption says about the modal behind it.
    ///
    /// This is the folded login card's summary line, kept verbatim: hiding credentials behind a
    /// modal must not hide *which* provider is armed or whether it has a key, because those two
    /// facts decide whether the table's **Eval** and **Price** buttons do anything.
    private var settingsSummary: String {
        var parts: [String] = [settings.email.isEmpty ? "no site login" : settings.email]
        parts.append("\(settings.provider.displayName) · \(settings.activeModelID)")
        parts.append(settings.hasAPIKey ? "key set" : "no key")
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Run tuning

    private var tuningSection: some View {
        CollapsibleSection(
            title: "Run tuning",
            systemImage: "slider.horizontal.3",
            isExpanded: $showsTuning
        ) {
            tuningControls
        }
    }

    /// The tuning card's controls: the run's limits, then the bidding judgement behind the
    /// table's numbers — one field per line.
    private var tuningControls: some View {
        VStack(alignment: .leading, spacing: Theme.groupSpacing) {
            limitsRows
            Divider().opacity(0.6)
            biddingRows
        }
    }

    /// The run's two limits: how far a run walks, then how fast it is allowed to call out.
    ///
    /// Stacked rather than side by side, and the four bidding fields below them in the same shape.
    /// Laid out across the window the captions landed at two, then four, different x positions, so
    /// nothing in the card could be read down a column — and the controls had to share the width, so
    /// the **Pages** menu and the pacing stepper sat shoulder to shoulder with no room for the count
    /// the site reported. One field per line costs a little height in a card that is usually folded
    /// and gives every label the same left edge, with the rest of the window left over for a control
    /// that no longer has to share it — see `tuningField`.
    ///
    /// What used to sit beside them — a **Parallel lots** stepper and a **Valuation** switch — asked
    /// the operator to configure things the tool can answer for itself: batch width is a provider
    /// detail (`AppSettings.batchConcurrency`), and appraisal is on demand, so *not pressing*
    /// **Eval** or **Price** is the off switch.
    private var limitsRows: some View {
        VStack(alignment: .leading, spacing: Theme.fieldSpacing) {
            tuningField("Pages") {
                pageLimitPicker
            }

            tuningField("Requests / min", hidesControlLabel: false) {
                Stepper(value: $settings.requestsPerMinute, in: 0...600, step: 5) {
                    Text(pacingText).monospacedDigit()
                }
                .help(settings.provider.pacingHelp)
            }
        }
    }

    /// The page budget as a menu of counts rather than a stepper: a listing can be longer than any
    /// number a stepper would make convenient to reach, and the menu can say how long *this* one is —
    /// see `pageOptions`.
    private var pageLimitPicker: some View {
        Picker("Pages", selection: $settings.pageLimit) {
            Text(allPagesLabel).tag(ScrapeLimits.allPagesMarker)
            ForEach(pageOptions, id: \.self) { count in
                Text(count == 1 ? "1 page" : "\(count) pages").tag(count)
            }
        }
        .pickerStyle(.menu)
        .help(pageLimitHelp)
    }

    /// What the menu calls "walk until the listing stops".
    private var allPagesLabel: String { "All pages" }

    /// The counts the **Pages** menu offers: 1 up to whichever is largest of the width a menu should
    /// have, the count this listing reported the last time it was loaded, and the budget already in
    /// force — so picking 24 pages and reopening the menu keeps 24 in it, and a site with 60 pages is
    /// offered 60 rather than capped at a round number.
    ///
    /// The ceiling is `ScrapeLimits.maximumPages`, which is what **All pages** walks to, so the menu
    /// cannot offer a count the scraper would refuse.
    private var pageOptions: [Int] {
        let discovered = coordinator.listingPageCount ?? 0
        // The budget in force, when there is one: **All pages** is not a count, and expanding to the
        // 100-page guard would bury the list (and the choice) it belongs to.
        let chosen = max(settings.pageLimit, 0)
        let span = min(
            max(discovered, Self.defaultPageMenuSpan, chosen),
            ScrapeLimits.maximumPages
        )
        return Array(1...span)
    }

    /// Counts a fresh install is offered before any listing has been read.
    private static let defaultPageMenuSpan = 10

    /// The menu's tooltip: what the listing last said about itself, then what the choice means.
    private var pageLimitHelp: String {
        var parts: [String] = []
        if let count = coordinator.listingPageCount {
            parts.append("This listing reports \(count) page(s).")
        } else {
            parts.append("How many result pages to walk.")
        }
        parts.append(
            "\(allPagesLabel) follows the pagination until the listing runs out, up to the "
                + "\(ScrapeLimits.maximumPages)-page guard. The count comes from the site's own "
                + "pagination and is read on the next run."
        )
        return parts.joined(separator: " ")
    }

    /// The bidding judgement: how a resale figure becomes a bid ceiling, and which line items get
    /// flagged.
    ///
    /// One field per line, in the order the judgement is made: the three confidence percentages top
    /// to bottom (Low → High, the way a valuation firms up), then the anchor threshold. They are
    /// judgement rather than plumbing, which is why they sit apart from the limits above: the **Max
    /// bid** column and the anchor flags in the expanded rows are drawn from exactly these four
    /// numbers.
    private var biddingRows: some View {
        VStack(alignment: .leading, spacing: Theme.fieldSpacing) {
            tuningField("Bid · Low", hidesControlLabel: false) {
                Stepper(
                    value: $settings.lowBidPercent,
                    in: BidTargetPolicy.percentRange,
                    step: 5
                ) {
                    Text("\(settings.lowBidPercent)%").monospacedDigit()
                }
                .help(
                    "Highest bid worth placing against a Low-confidence valuation — the engine had to "
                        + "guess. A lot with only an eval is judged by this percentage, because its "
                        + "guess is capped at Low confidence. Clamped to \(percentRangeText)."
                )
            }

            tuningField("Bid · Med", hidesControlLabel: false) {
                Stepper(
                    value: $settings.mediumBidPercent,
                    in: BidTargetPolicy.percentRange,
                    step: 5
                ) {
                    Text("\(settings.mediumBidPercent)%").monospacedDigit()
                }
                .help(
                    "Same, for a Med-confidence valuation. Nothing has to be certain for a pallet to be "
                        + "worth bidding on, so this is normally the higher of the two."
                )
            }

            tuningField("Bid · High", hidesControlLabel: false) {
                Stepper(
                    value: $settings.highBidPercent,
                    in: BidTargetPolicy.percentRange,
                    step: 5
                ) {
                    Text("\(settings.highBidPercent)%").monospacedDigit()
                }
                .help(
                    "Highest bid worth placing against a High-confidence valuation, as a percent of "
                        + "the lot's resale. Clamped to \(percentRangeText)."
                )
            }

            tuningField("Anchor ≥", hidesControlLabel: false) {
                Stepper(
                    value: $settings.anchorThreshold,
                    in: AnchorItem.thresholdRange,
                    step: 25
                ) {
                    Text(anchorText).monospacedDigit()
                }
                .help(
                    "Retail value at or above which a single product is flagged as an anchor item: the "
                        + "one or two lines that carry the pallet, and the ones to sanity-check first. "
                        + "Clamped to \(thresholdRangeText)."
                )
            }
        }
    }

    /// Rendered as a bare dollar figure for the anchor stepper.
    private var anchorText: String { "$\(Int(settings.anchorThreshold))" }

    /// The bid percentages' allowed span, quoted in the steppers' help text.
    private var percentRangeText: String {
        "\(BidTargetPolicy.percentRange.lowerBound)–\(BidTargetPolicy.percentRange.upperBound)%"
    }

    /// The anchor threshold's allowed span, quoted in the same place.
    private var thresholdRangeText: String {
        "$\(Int(AnchorItem.thresholdRange.lowerBound))–$\(Int(AnchorItem.thresholdRange.upperBound))"
    }

    /// Rendered as "off" when pacing is disabled, so the stepper cannot be misread as "0 calls".
    private var pacingText: String {
        settings.requestsPerMinute > 0 ? "\(settings.requestsPerMinute)" : "off"
    }

    // MARK: - Field builder

    /// Label + control on one line: the panel's fields are laid out by the same row the settings
    /// modal uses, so **Run tuning** and **Site login & valuation** cannot drift apart visually.
    private func field<Content: View>(
        _ label: String,
        hidesControlLabel: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SettingsFieldRow(label: label, hidesControlLabel: hidesControlLabel) {
            content()
        }
    }

    /// A **Run tuning** field whose control keeps its own width at the left of the row.
    ///
    /// `SettingsFieldRow` hands its content the rest of the window, which a text field wants — that is
    /// why the modal's provider and key fields stretch. A `Picker` and a `Stepper` do not: given the
    /// slack they keep their intrinsic width and sit where the layout happens to put them, so every
    /// control in the card needs the same left edge as the picker above it. The `Spacer` is what pins
    /// them there, and it is why this card reads as one column of labels with one column of numbers.
    private func tuningField<Content: View>(
        _ label: String,
        hidesControlLabel: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        field(label, hidesControlLabel: hidesControlLabel) {
            HStack(spacing: 0) {
                content()
                Spacer(minLength: 0)
            }
        }
    }
}

#Preview {
    let settings = AppSettings()
    return ControlPanelView(settings: settings, coordinator: AnalysisCoordinator(settings: settings))
        .frame(width: 1240)
}

