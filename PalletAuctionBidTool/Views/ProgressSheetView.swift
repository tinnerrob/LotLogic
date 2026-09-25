//
//  ProgressSheetView.swift
//  PalletAuctionBidTool
//
//  The run's progress as a modal, with the one control that stops it.
//

import SwiftUI

/// What the pipeline is doing — a scrape walking pages, a batch of lots being appraised, a single
/// row's **Eval** / **Price** — with the **Stop** that ends it.
///
/// This is the footer's old readout (phase, bar, counters, status, money) as a modal, with the one line
/// it never had: the step the row in hand is on, which is what a photographed appraisal spends its time
/// doing. The bar cost the table a permanent strip of its height for something that only matters while
/// work is running, and moving **Stop** in here is what lets the control panel's one row drop its own:
/// that row is for *starting* work, this is for watching and ending it.
///
/// Presented while the coordinator has work in flight and closed by the panel when it has none, so
/// the table is never covered with nothing to watch. **Hide** leaves the run going and hands the
/// table back; the row's **Progress** button brings this back.
struct ProgressSheetView: View {

    let coordinator: AnalysisCoordinator

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.groupSpacing) {
            header
            Divider().opacity(0.6)
            progressBar
            counters
            step
            Divider().opacity(0.6)
            money
        }
        .padding(Theme.panelPadding + 2)
        .frame(width: 560)
    }

    /// Phase, and the two ways out of the modal: **Hide**, which escape also does, and **Stop**.
    ///
    /// Stop is the only filled button here and deliberately has no keyboard shortcut of its own:
    /// dismissing a sheet with escape is a reflex, and a reflex that cancelled a half-finished scrape
    /// would be a trap.
    private var header: some View {
        HStack(spacing: 10) {
            Label(coordinator.progressLabel, systemImage: phaseIcon)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(phaseTint.opacity(0.13), in: Capsule())
                .help(coordinator.statusText)

            Spacer(minLength: 12)

            Button("Hide") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .help(
                    "Leave the run going and go back to the table — the control panel's Progress button "
                        + "brings this back."
                )

            Button {
                coordinator.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("Cancels the scrape and every scan in flight.")
        }
    }

    /// The bar itself: determinate while the work in hand can be counted, and a plain spinner when it
    /// cannot.
    ///
    /// The fraction comes from the coordinator and measures *the work in hand* — pages read while the
    /// walk is running, lots answered while things are being appraised — so the bar reaches full when
    /// that work is done rather than parking at a fixed third. `nil` is the one case with no honest
    /// denominator (**All pages** on a listing that reports no page count), and an indeterminate bar
    /// says so better than an invented number would.
    @ViewBuilder
    private var progressBar: some View {
        if let fraction = coordinator.progressFraction {
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.2), value: fraction)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    /// What has been dealt with, and the one line saying what is happening right now.
    private var counters: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(coordinator.countsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text(coordinator.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The step the row in hand is on, while it is on one.
    ///
    /// A photographed appraisal is a dozen requests, and this is the line that says so: one update per
    /// photograph, then the reconciliation. Without it the modal showed a bar that barely moved and a
    /// status line written when the row was *picked*, which reads as nothing happening for minutes at a
    /// time. The spinner is the same one the row itself wears while it is being read.
    @ViewBuilder
    private var step: some View {
        if let text = coordinator.progressStep {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(text)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The money line at the bottom edge, ruled off from the status above it.
    ///
    /// The figures are the **row in hand's** own — open bid, what it retails for, what it will resell
    /// for, and the difference — drawn from that row's valuation when it has one and from its text-only
    /// eval until then (`LotMoney.provisional` says which). The board's totals used to sit here and they
    /// were the wrong scope twice over: a single row's **Price** moved none of them, and an **Eval** run
    /// moved none of them either, because an eval writes a provisional figure rather than a valuation. So
    /// the line follows the work instead, and only falls back to the board when no row is in hand — a
    /// fresh board, or one just cleared.
    private var money: some View {
        HStack(spacing: 11) {
            Text(scopeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let money = coordinator.inHandMoney {
                total("Open bid", money.currentBid)
                total("Retail", money.retail)
                total("Resale", money.resale)
                total("Profit", money.profit, highlight: true)
            } else {
                total("Open bid", coordinator.totalCurrentBid)
                total("Retail", coordinator.totalRetail)
                total("Resale", coordinator.totalResale)
                total("Profit", coordinator.totalProjectedProfit, highlight: true)
            }

            Spacer(minLength: 0)
        }
    }

    /// Which scope the four figures beside it are in: the lot being worked on, or the whole board.
    private var scopeLabel: String {
        guard let lot = coordinator.inHandLot else { return "Board" }
        let provisional = coordinator.inHandMoney?.provisional == true ? " · eval" : ""
        return "Lot #\(lot.lotNumber)\(provisional)"
    }

    private var phaseIcon: String {
        switch coordinator.phase {
        case .idle: "circle.dashed"
        case .scraping: "safari"
        case .valuing: "sparkles"
        case .finished: "checkmark.circle"
        case .stopped: "pause.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// Tint of the phase pill, so a stopped or failed run is visible at a glance.
    private var phaseTint: Color {
        switch coordinator.phase {
        case .idle: .secondary
        case .scraping, .valuing: .accentColor
        case .finished: .green
        case .stopped: .orange
        case .failed: .red
        }
    }

    private func total(_ title: String, _ value: Double, highlight: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(value.currencyWholeText)
                .monospacedDigit()
                .fontWeight(highlight ? .semibold : .regular)
                .foregroundStyle(tint(for: value, highlight: highlight))
        }
        .font(.caption)
    }

    private func tint(for value: Double, highlight: Bool) -> Color {
        guard highlight, value != 0 else { return .primary }
        return value > 0 ? .green : .red
    }
}

#Preview {
    let settings = AppSettings()
    return ProgressSheetView(coordinator: AnalysisCoordinator(settings: settings))
}
