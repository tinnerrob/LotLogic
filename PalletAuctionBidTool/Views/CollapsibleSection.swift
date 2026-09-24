//
//  CollapsibleSection.swift
//  PalletAuctionBidTool
//
//  A titled, folding card — the expand/contract container the control panel is built from.
//

import SwiftUI

/// Expandable card used by the control panel.
///
/// The header row stays visible while the section is folded: a title, and the chevron that says
/// whether there is anything behind it. It deliberately carries no summary of its contents — **Run
/// tuning** used to print one ("3 page(s) · every lot-page image · 3 parallel · 10/min · bid …"), and
/// it grew into a paragraph that competed with the fields it described. What a folded card has to
/// say, it says when opened.
struct CollapsibleSection<Content: View>: View {

    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                Divider().opacity(0.6)
                content
                    .padding(.horizontal, Theme.panelPadding)
                    .padding(.top, Theme.groupSpacing)
                    .padding(.bottom, Theme.panelPadding)
            }
        }
        .cardStyle()
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)

                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 10)
            }
            .padding(.horizontal, Theme.panelPadding)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(isHovering ? 0.045 : 0))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isExpanded ? "Hide \(title)" : "Show \(title)")
    }
}

#Preview("Collapsible section") {
    CollapsibleSectionPreview()
}

private struct CollapsibleSectionPreview: View {

    @State private var isExpanded = true

    var body: some View {
        CollapsibleSection(
            title: "Run tuning",
            systemImage: "slider.horizontal.3",
            isExpanded: $isExpanded
        ) {
            Text("Fields belong here.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.panelPadding)
        .frame(width: 640)
    }
}
