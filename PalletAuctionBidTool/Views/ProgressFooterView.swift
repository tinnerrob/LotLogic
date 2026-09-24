//
//  ProgressFooterView.swift
//  PalletAuctionBidTool
//
//  Bottom status bar: progress, live counters, running totals.
//

import SwiftUI

/// Persistent footer under the table.
struct ProgressFooterView: View {

    let coordinator: AnalysisCoordinator

    var body: some View {
        VStack(spacing: 7) {
            progressBar

            HStack(spacing: 12) {
                Label(coordinator.progressLabel, systemImage: phaseIcon)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(phaseTint.opacity(0.13), in: Capsule())
                    .help(coordinator.statusText)

                Text(coordinator.countsSummary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)

                Text(coordinator.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 12)

                totals
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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

    /// Running money totals, ruled off from the pipeline status on their left.
    private var totals: some View {
        HStack(spacing: 11) {
            total("Open bid", coordinator.totalCurrentBid)
            total("Retail", coordinator.totalRetail)
            total("Resale", coordinator.totalResale)
            total("Profit", coordinator.totalProjectedProfit, highlight: true)
        }
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
