//
//  Theme.swift
//  PalletAuctionBidTool
//
//  Shared visual tokens, so the panel, the table and the footer cannot drift apart.
//

import AppKit
import SwiftUI

/// The window's design tokens.
///
/// This is a dense operator tool, so the palette stays quiet: one accent colour (SwiftUI's), one
/// card fill and two hairlines. Everything else is a spacing number, kept here so the three
/// surfaces that use it stay on the same 4-point grid.
enum Theme {

    /// Corner radius shared by every card.
    static let cardRadius: CGFloat = 10
    /// Outer padding of a panel's content.
    static let panelPadding: CGFloat = 14
    /// Spacing between the stacked groups inside a panel.
    static let groupSpacing: CGFloat = 12
    /// Spacing between the controls inside one row of a panel.
    static let controlSpacing: CGFloat = 14
    /// Width of the leading label column in a settings row.
    static let labelWidth: CGFloat = 92
    /// Spacing between the stacked fields of one settings card. Tighter than `groupSpacing`: those
    /// rows are a single form, and the shared label column already gives the eye a line to run down.
    static let fieldSpacing: CGFloat = 8

    /// Vertical padding inside a lot row. The row is dense by design, but it needs enough air that
    /// the money columns read as numbers rather than as a wall of text.
    static let rowPadding: CGFloat = 6
    /// Vertical padding inside the sticky header. A touch taller than the rows' own padding, so the
    /// header reads as chrome sitting *over* the table rather than as another row in it.
    static let headerPadding: CGFloat = 7
    /// Horizontal padding inside a row and the header, matching `LotColumn.rowInsets`.
    static let rowInset: CGFloat = 8
    /// Gap between a row's action buttons.
    static let actionSpacing: CGFloat = 4
    /// Horizontal padding inside the console: its own header and the lines under it share one inset,
    /// so a folded console's newest line lines up with the log it came from.
    static let consoleInset: CGFloat = 10

    /// Corner radius of a chip and of the search field: small enough to stay crisp at caption size.
    static let chipRadius: CGFloat = 6
    /// Horizontal padding inside a chip.
    static let chipPadding: CGFloat = 5
    /// Vertical padding inside a chip. One point: a chip is a label with a tint, not a button.
    static let chipPaddingVertical: CGFloat = 1
    /// Opacity of a chip's tint behind its text.
    static let chipFill: Double = 0.15

    /// Letter spacing of the header's micro-caps labels. Uppercase at caption size is the one place
    /// the table raises its voice, so it is given room to breathe.
    static let headerTracking: CGFloat = 0.6

    /// Fill behind a card. `controlBackgroundColor` is the correct panel colour in both
    /// appearances (the app follows the system theme).
    static var cardFill: Color { Color(nsColor: .controlBackgroundColor).opacity(0.55) }
    /// Hairline drawn around a card.
    static var cardStroke: Color { Color.primary.opacity(0.08) }
    /// Fill behind the window itself.
    static var windowFill: Color { Color(nsColor: .windowBackgroundColor) }
    /// Fill behind the scrolling table body.
    static var tableFill: Color { Color(nsColor: .controlBackgroundColor) }
    /// Hairline between rows, and under the sticky header. One step stronger than `cardStroke`: a
    /// table is read across, so its rules have to survive being scanned rather than studied.
    static var rule: Color { Color.primary.opacity(0.10) }
    /// Fill of an alternate (zebra) row — just enough tint to follow a wide row with the eye.
    static var zebraFill: Color { Color.primary.opacity(0.025) }
    /// Fill laid over a row while the pointer is on it.
    static var hoverFill: Color { Color.accentColor.opacity(0.07) }
    /// Fill of the neutral count pill in the toolbar.
    static var countFill: Color { Color.primary.opacity(0.09) }
    /// Fill behind a field: the toolbar's search box, and the console.
    static var fieldFill: Color { Color.primary.opacity(0.06) }
}

extension View {

    /// Dimmed, hairline-bordered card: the control-panel sections and the console.
    func cardStyle(radius: CGFloat = Theme.cardRadius) -> some View {
        background(Theme.cardFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.cardStroke)
            )
    }

    /// The one capsule every chip in the table wears.
    ///
    /// There are three of them — the pipeline state, the model's confidence and the flags
    /// (`provisional`, `evaluating`, `anchor`, **Active**/**Sold**) — and they are one family of
    /// labels rather than three tinted pills. Keeping the type, the padding and the fill in one
    /// modifier is what stops them drifting apart as they are edited one at a time.
    ///
    /// The tint is used twice on purpose: full strength for the text and a wash of the same hue
    /// behind it, so a red flag and a green one are told apart by colour alone rather than by shape.
    func chipStyle(tint: Color) -> some View {
        font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.chipPadding)
            .padding(.vertical, Theme.chipPaddingVertical)
            .background(tint.opacity(Theme.chipFill), in: Capsule())
    }

    /// A sticky table header's label: uppercase micro-caps, tracked out, so the header reads as
    /// chrome over the data rather than as a bold first row.
    func microCaps(_ isActive: Bool) -> some View {
        textCase(.uppercase)
            .tracking(Theme.headerTracking)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
    }
}

