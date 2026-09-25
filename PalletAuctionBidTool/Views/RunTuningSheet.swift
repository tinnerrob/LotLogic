//
//  RunTuningSheet.swift
//  PalletAuctionBidTool
//
//  The modal behind the titlebar's Tuning button: how far a run walks, how fast it calls out, and
//  the judgement that turns a valuation into a bid ceiling.
//

import SwiftUI

/// **Run Tuning**, as a modal rather than a folding card in the control panel.
///
/// These numbers are unlike the account's: a credential is set once per install, while these are
/// worth watching and changing mid-session — which is why they used to stay in the panel as a card
/// while the login moved behind a gear. The titlebar's **Tuning** button keeps them one click away
/// and returns the table the height the card spent, and inside a sheet the fields can be split into
/// their two halves — the run's limits, then the bidding judgement — with a caption over each
/// rather than a folding header in between.
///
/// Fields write straight into `AppSettings` as they are changed — there is no OK/Cancel — so the
/// footer's button says **Done**, exactly as `SiteSettingsSheet` does.
struct RunTuningSheet: View {

    @Bindable var settings: AppSettings
    let coordinator: AnalysisCoordinator

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.groupSpacing) {
            header
            Divider().opacity(0.6)
            limitRows
            Divider().opacity(0.6)
            biddingRows
            footnotes
            Divider().opacity(0.6)
            footer
        }
        .padding(Theme.panelPadding + 2)
        .frame(width: 640)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("Run Tuning", systemImage: "slider.horizontal.3")
                .font(.headline)

            Spacer(minLength: 12)

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(
                    "The run this sheet describes: how far it walks, how hard it is allowed to push "
                        + "the key, and how much of a lot's gallery a scan reads one frame at a time."
                )
        }
    }

    /// The two facts a run is judged by before any row is scanned — how far it walks and how fast it
    /// is allowed to call out — plus how much of a gallery a thorough scan reads frame by frame.
    private var summary: String {
        let pacing = settings.requestsPerMinute > 0
            ? "\(settings.requestsPerMinute) requests / min"
            : "no request ceiling"
        return "\(settings.pageLimitSummary)  ·  \(pacing)  ·  \(settings.photoScanSummary) per scan"
    }

    // MARK: - Run limits

    /// The run's limits: how far a run walks, how fast it is allowed to call out, then how many of a
    /// lot's photographs a scan reads one at a time.
    ///
    /// Stacked one field per line, as they were in the card: the captions land at one x position, so
    /// the sheet can be read down a column, and the rest of the width is left to each control
    /// (`tuningField` pins a picker or a stepper to the left where `SettingsFieldRow` would
    /// otherwise let it float in the slack a text field would fill).
    private var limitRows: some View {
        VStack(alignment: .leading, spacing: Theme.fieldSpacing) {
            sectionCaption("Run limits")

            tuningField("Pages") {
                pageLimitPicker
            }

            tuningField("Requests / min", hidesControlLabel: false) {
                Stepper(value: $settings.requestsPerMinute, in: 0...600, step: 5) {
                    Text(pacingText).monospacedDigit()
                }
                .help(settings.provider.pacingHelp)
            }

            tuningField("Photos / scan") {
                photoScanPicker
            }
        }
    }

    /// How many of a lot's photographs a scan reads one at a time.
    ///
    /// The one setting that changes what a scan *is* rather than how fast it runs: reading a pallet
    /// photograph by photograph is what keeps a small item in the corner of a frame from being
    /// averaged away by the pallet in front of it, and it costs one request per photograph. The
    /// default — every photograph the lot carries — is the answer that spends what the job is worth;
    /// the counts are the ceiling for a metered key. What is past the ceiling is not dropped: those
    /// photographs still travel with the reconciliation request, so a ceiling makes the line items
    /// coarser, never the pallet smaller.
    private var photoScanPicker: some View {
        Picker("Photos / scan", selection: $settings.photosPerScan) {
            Text(everyPhotographLabel).tag(0)
            ForEach(AppSettings.photoScanChoices.filter { $0 > 0 }, id: \.self) { count in
                Text("\(count) photographs").tag(count)
            }
        }
        .pickerStyle(.menu)
        .help(photoScanHelp)
    }

    /// What the menu calls "read each photograph on its own".
    private var everyPhotographLabel: String { "All photographs" }

    private var photoScanHelp: String {
        "How many of a lot's photographs are read one by one, then reconciled into the lot's line "
            + "items. \(everyPhotographLabel) is what the app defaults to and what the prices are "
            + "worth checking against: each reading names what one frame showed, so a figure can be "
            + "traced back to a picture. Readings are kept on this machine, so re-scanning a lot with "
            + "the same model only pays for the photographs it has never seen."
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

    // MARK: - Bidding judgement

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
            sectionCaption("Bidding judgement")

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


    // MARK: - Footnotes + footer

    private var footnotes: some View {
        Text(
            "The limits pace the scrape and the scans; the percentages and the threshold decide the "
                + "table's Max bid column and its anchor flags. Edits apply as you change them — "
                + "there is no Cancel."
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Set once, these numbers are the ones every run is judged by.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)

            Spacer(minLength: 12)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Field builders

    /// A micro-caps caption over a group of fields, so the two halves of the sheet read as two
    /// halves rather than as one long column.
    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .microCaps(false)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Label + control on one line: the sheet's fields are laid out by the same row the account
    /// modal uses, so the two cannot drift apart visually.
    private func field<Content: View>(
        _ label: String,
        hidesControlLabel: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SettingsFieldRow(label: label, hidesControlLabel: hidesControlLabel) {
            content()
        }
    }

    /// A field whose control keeps its own width at the left of the row.
    ///
    /// `SettingsFieldRow` hands its content the rest of the window, which a text field wants — that is
    /// why the account modal's provider and key fields stretch. A `Picker` and a `Stepper` do not:
    /// given the slack they keep their intrinsic width and sit where the layout happens to put them,
    /// so every control here needs the same left edge as the picker above it. The `Spacer` is what
    /// pins them there, and it is why this sheet reads as one column of labels with one column of
    /// numbers.
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

    // MARK: - Text

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
}

#Preview("Run Tuning") {
    let settings = AppSettings()
    return RunTuningSheet(settings: settings, coordinator: AnalysisCoordinator(settings: settings))
}

