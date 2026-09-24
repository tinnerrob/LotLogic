//
//  LogConsoleView.swift
//  PalletAuctionBidTool
//
//  Auto-scrolling activity console.
//

import SwiftUI

/// Monospaced console showing pipeline progress.
///
/// This is deliberately not a `List`: the log is append-only and capped by the coordinator, and
/// a `LazyVStack` keeps auto-scroll cheap while the table above is also ticking.
///
/// The console folds away from its own header — its chevron is the only control for it, so a run being
/// watched for the table's sake can reclaim the vertical space without hunting for another button —
/// and a folded console still shows the newest line in its header.
struct LogConsoleView: View {

    let lines: [AnalysisCoordinator.LogLine]
    @Binding var isExpanded: Bool

    @State private var isHoveringHeader = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if isExpanded {
                Divider()
                console
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(line.timestampText)
                                .foregroundStyle(.tertiary)

                            Text(line.source.rawValue.uppercased())
                                .foregroundStyle(tint(for: line.source))
                                .frame(width: 46, alignment: .leading)

                            Text(line.message)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .id(line.id)
                    }
                }
                .padding(.horizontal, Theme.consoleInset)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { _, _ in
                guard let last = lines.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    /// Doubles as the collapse control. Folded, it carries the newest line so the console still says
    /// *something* — the console's own answer to the question a folded panel asks, which **Run
    /// tuning** now answers the other way (see `CollapsibleSection`).
    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)

                Label("Activity", systemImage: "terminal")
                    .microCaps(false)

                Spacer(minLength: 8)

                if !isExpanded, let newest = lines.last {
                    Text(newest.message)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text("\(lines.count) line(s)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.consoleInset)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isHoveringHeader ? Theme.hoverFill : Color.clear)
            .background(.bar)
        }
        .buttonStyle(.plain)
        .onHover { isHoveringHeader = $0 }
        .help(isExpanded ? "Hide the activity log" : "Show the activity log")
    }

    private func tint(for source: AnalysisCoordinator.LogLine.Source) -> Color {
        switch source {
        case .app: .secondary
        case .scraper: .accentColor
        case .page: .teal
        case .valuation: .green
        case .error: .red
        }
    }
}
