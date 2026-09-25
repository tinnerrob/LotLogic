//
//  ControlPanelView.swift
//  PalletAuctionBidTool
//
//  Top-of-window panel: the lot-list URL and the run buttons, with the app's mark, the app's name and
//  the three settings buttons drawn into the window's unified titlebar.
//
//  `Theme.appName` is what the titlebar's title prints — the product's name. The target and the
//  bundle keep the name they were created with (see `Theme.appName` for why the bundle identifier in
//  particular must not move).
//

import SwiftUI

/// Operator input surface. Every field writes straight into `AppSettings`, which persists the
/// values to `UserDefaults` when a run or a scan starts.
///
/// This used to be three stacked rows — a title row, the URL row and a folding **Run Tuning** card.
/// The title row is now the window's titlebar: the app's name is drawn at its leading edge and the
/// three buttons (**Account**, **Tuning**, **About**) sit at the trailing one, so the bar the traffic
/// lights already live in carries them and the panel below is one shallow row of controls. The two
/// settings surfaces that were a gear and a card are sheets behind those buttons
/// (`SiteSettingsSheet`, `RunTuningSheet`), which costs the table nothing at rest — the one
/// resource a hundred-row table actually needs.
struct ControlPanelView: View {

    @Bindable var settings: AppSettings
    let coordinator: AnalysisCoordinator

    /// Which of the titlebar's three sheets is up, if any.
    ///
    /// One piece of state for all three rather than a flag each: only one can be up at a time, and one
    /// `.sheet(item:)` for the three is the form SwiftUI handles unambiguously. The row's page sheet
    /// (`pageRequest`) hangs off a different view for the same reason — two modals on one view is where
    /// SwiftUI's presentation gets ambiguous.
    @State private var presentedSheet: PanelSheet?

    /// The page the URL row's **info** glyph asks for. One address, one sheet: the panel presents the
    /// same `LotPageSheetView` a row's **Open** button does.
    @State private var pageRequest: LotPageRequest?

    /// Whether the URL field is being typed into, which is what lights its border.
    @FocusState private var isURLFieldFocused: Bool

    /// Whether the run's progress modal is up.
    ///
    /// The sheet follows the work rather than the operator having to open and close it: it comes up
    /// when the coordinator starts something and goes away when that work ends (see `body`). **Hide**
    /// in the sheet sets this back to `false` and lets the run carry on, which is why the row keeps a
    /// **Progress** button while something is running — the one way back to it.
    @State private var isProgressVisible = false

    /// The titlebar's menus, one sheet each.
    private enum PanelSheet: String, Identifiable {
        case account
        case tuning
        case about

        var id: String { rawValue }
    }

    var body: some View {
        urlRow
            .padding(.horizontal, Theme.panelPadding)
            .padding(.vertical, Theme.groupSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .toolbar { titlebar }
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .account:
                    SiteSettingsSheet(settings: settings)
                case .tuning:
                    RunTuningSheet(settings: settings, coordinator: coordinator)
                case .about:
                    AboutSheet()
                }
            }
            // The run's progress, as a modal rather than a strip under the table. Presented on a
            // *different* view from the sheets above, so SwiftUI never has two modals to resolve on
            // one presenter; the row's own page sheet hangs off the row for the same reason.
            .sheet(isPresented: $isProgressVisible) {
                ProgressSheetView(coordinator: coordinator)
            }
            // Work in flight brings the modal up, the end of it takes the modal down. **Hide** in the
            // sheet lowers it early without stopping anything, which the `Progress` button undoes.
            .onChange(of: coordinator.isRunning) { _, isRunning in
                isProgressVisible = isRunning
            }
    }

    // MARK: - Titlebar

    /// The window's titlebar: the app's mark and name at the leading edge, the three menus at the
    /// trailing one.
    ///
    /// The trailing group is pushed to the far right by `ToolbarSpacer(.flexible)`: on macOS 26
    /// `.primaryAction` on its own lays those items out where the leading content ends, which reads
    /// as "next to the title" rather than "the window's buttons". The name is a label and not a
    /// control, so it also opts out of the shared glass background macOS 26 puts behind every toolbar
    /// item; on earlier systems there is no such background and no spacer to draw, so the group is
    /// left to the trailing placement on its own.
    @ToolbarContentBuilder
    private var titlebar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { appTitle }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
            titlebarMenus.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { appTitle }
            titlebarMenus
        }
    }

    /// The window's three menus, as one trailing group.
    ///
    /// The group is pulled out of the shared glass background macOS 26 would otherwise draw behind
    /// it, so each menu's own chrome is the one that shows — see `TitlebarMenuButtonStyle`. The last
    /// button then stops `titlebarTrailingInset` short of the window's edge: the corner radius eats
    /// into the bar's last few points, and a button ending flush with it reads as clipped.
    @ToolbarContentBuilder
    private var titlebarMenus: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            accountButton
            tuningButton
            aboutButton
                .padding(.trailing, Self.titlebarTrailingInset)
        }
    }

    /// How far the titlebar's menus stop short of the window's trailing edge. See `titlebarMenus`.
    private static let titlebarTrailingInset: CGFloat = 8

    /// The chrome a titlebar menu draws for itself.
    ///
    /// macOS 26 puts its own glass capsule behind every toolbar item and *ignores*
    /// `buttonBorderShape`, so a squared-off menu means opting out of that shared background
    /// (`sharedBackgroundVisibility(.hidden)`, above) and drawing the whole control here — fill,
    /// corner, hover and press — rather than trying to reshape the system's.
    private struct TitlebarMenuButtonStyle: ButtonStyle {

        @State private var isHovering = false

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(
                cornerRadius: ControlPanelView.titlebarButtonRadius,
                style: .continuous
            )

            configuration.label
                .font(.body)
                .foregroundStyle(.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(fill(isPressed: configuration.isPressed), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.10)))
                .contentShape(shape)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }

        /// A toolbar button's three states, in the order they should read: resting, hovered, pressed.
        private func fill(isPressed: Bool) -> Color {
            if isPressed { return Color.primary.opacity(0.18) }
            return Color.primary.opacity(isHovering ? 0.12 : 0.07)
        }
    }

    /// Corner radius of a titlebar menu. The system's default is a capsule — nearly half the button's
    /// height — which reads as a lozenge beside the panel's squared-off cards; the trio is squared
    /// off to match them.
    private static let titlebarButtonRadius: CGFloat = 5

    /// The window's title, drawn into the toolbar rather than left to the system: the app's own mark
    /// in a tile at its leading edge and the name beside it, which is the one thing a stock title
    /// item cannot carry.
    ///
    /// The mark is the app's own artwork — `AppMark`, cut from the same file the icon set and the
    /// splash are built from — on a pale tile. The tile is not decoration: that art is transparent,
    /// and its dark greens would sink into a dark titlebar without something behind them. It is the
    /// app icon in miniature, which is what the space wants.
    private var appTitle: some View {
        HStack(spacing: 7) {
            Image("AppMark")
                .resizable()
                .interpolation(.high)
                .frame(width: Self.titlebarMarkSize, height: Self.titlebarMarkSize)
                .frame(width: Self.titlebarMarkTile, height: Self.titlebarMarkTile)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10))
                        )
                )

            Text(Theme.appName)
                .font(.headline)
        }
        .accessibilityElement(children: .combine)
    }

    /// Side of the mark drawn in the titlebar, and of the tile it sits in.
    private static let titlebarMarkSize: CGFloat = 17
    private static let titlebarMarkTile: CGFloat = 20

    /// **Account**: the modal that used to be the panel's gear.
    ///
    /// `⌘,` is the macOS reflex for exactly this, and the button's tooltip carries what the folded
    /// card's summary line used to say — the move behind a button must not hide *which* provider is
    /// armed or whether it has a key, because those two facts decide whether the table's **Eval**
    /// and **Price** buttons do anything. The dot is the old gear's warning, kept: with the readiness
    /// pill gone from the bar, this is what says at rest that nothing can be scanned yet.
    private var accountButton: some View {
        Button {
            presentedSheet = .account
        } label: {
            Text("Account")
                .overlay(alignment: .topTrailing) {
                    if needsAPIKey {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                            .offset(x: 5, y: -3)
                    }
                }
        }
        .buttonStyle(TitlebarMenuButtonStyle())
        .keyboardShortcut(",", modifiers: .command)
        .help(
            (needsAPIKey
                ? "Site login, provider, model and API key — no key is set, so nothing can be scanned."
                : "Site login, provider, model and API key.")
                + "  \(settingsSummary)  ·  ⌘,"
        )
    }

    /// **Tuning**: the folding **Run Tuning** card, as a modal.
    private var tuningButton: some View {
        Button("Tuning") { presentedSheet = .tuning }
            .buttonStyle(TitlebarMenuButtonStyle())
            .help(
                "How far a run walks (\(settings.pageLimitSummary)), how fast it calls out, how many "
                    + "photographs a scan reads one at a time, and the bid percentages and anchor "
                    + "threshold behind the table's numbers."
            )
    }

    /// **About**: what the app is called, and how to work it.
    private var aboutButton: some View {
        Button("About") { presentedSheet = .about }
            .buttonStyle(TitlebarMenuButtonStyle())
            .help(
                "What \(Theme.appName) does, and a quick tour of the table and its buttons."
            )
    }

    /// `true` while nothing can be appraised: no key for the selected provider, which is the one
    /// combination worth a warning, and what the dot on **Account** marks.
    private var needsAPIKey: Bool { !settings.hasAPIKey }

    // MARK: - URL

    /// The panel's one row: the auction address, then the run controls and the **info** glyph.
    ///
    /// The buttons draw their own chrome (`PanelActionButtonStyle`) and are deliberately taller than
    /// the table toolbar's own controls — this shallow row is the panel's whole job. **Scrape Lots**
    /// is the row's single accent-filled control; **Progress** and **Clear** are hairlines over a
    /// light fill. **Page** became an **info** glyph because it is not a run control at all: it opens
    /// the page for reading, exactly as a row's **Open** button does.
    ///
    /// **Stop** is not here. It belongs to the run it ends, so it lives in `ProgressSheetView`, which
    /// comes up while there is work to watch; this row keeps **Progress**, which is the way back to
    /// that sheet once **Hide** has put it away.
    private var urlRow: some View {
        HStack(spacing: 10) {
            urlField
                .frame(maxWidth: .infinity)

            Button("Scrape Lots", action: runIfPossible)
                .buttonStyle(PanelActionButtonStyle(emphasis: .primary))
                .disabled(!coordinator.canStart)
                .help(
                    "Walk \(settings.pageLimitSummary) of result pages and load every lot into the "
                        + "table. Appraisal is on demand, so this makes no API calls."
                )

            if coordinator.isRunning {
                Button("Progress") { isProgressVisible = true }
                    .buttonStyle(PanelActionButtonStyle(emphasis: .secondary))
                    .help("Show how far the run has come — and the Stop that ends it.")
            }

            Button("Clear") { coordinator.clearResults() }
                .buttonStyle(PanelActionButtonStyle(emphasis: .secondary))
                .disabled(coordinator.isRunning || coordinator.lots.isEmpty)
                .help("Empties the table and the activity log.")

            Button {
                pageRequest = auctionPageRequest
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(PanelIconButtonStyle())
            .disabled(auctionPageRequest == nil)
            .help(
                "Open the auction page in a window over the table — the same resizable sheet a row's "
                    + "Open button presents. Sign in or clear a captcha there, and the next run picks up "
                    + "the session."
            )
        }
        // The auction page as its own modal, over the panel rather than in the operator's browser, and
        // through the very modifier a row's **Open** button uses — one implementation, so the two
        // modals are the same modal rather than two that have to be kept in step.
        .lotPageSheet($pageRequest)
    }

    /// The auction page, typed in.
    ///
    /// Styled as the table's own search box is (`LotTableView.searchField`), down to the two states:
    /// an accent border while the operator is typing in it and the ordinary hairline the moment the
    /// caret leaves, whichever way the address reads. The magnifier is the same shorthand that box
    /// uses for "this is where you point the tool", and the whole box is a little taller than the
    /// toolbar's own fields because it is the first thing a new operator reaches for.
    private var urlField: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)

        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isURLFieldFocused ? Color.accentColor : Color.secondary)

            TextField("https://www.example-auction.com/lots?page=1", text: $settings.auctionURL)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focused($isURLFieldFocused)
                .onSubmit(runIfPossible)
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.controlHeight)
        .background(Theme.fieldFill, in: shape)
        .overlay(
            shape.strokeBorder(
                isURLFieldFocused ? Color.accentColor.opacity(0.7) : Theme.cardStroke
            )
        )
        .animation(.easeOut(duration: 0.12), value: isURLFieldFocused)
    }

    /// The page the **info** glyph opens: the address in the field. `nil` while the field holds
    /// nothing runnable — the same test that gates **Scrape Lots** — which is what greys the glyph.
    private var auctionPageRequest: LotPageRequest? {
        settings.auctionURLValue.map { LotPageRequest(url: $0, title: "Auction page") }
    }

    private func runIfPossible() {
        guard coordinator.canStart else { return }
        coordinator.run()
    }

    // MARK: - Settings summary

    /// What the **Account** button's tooltip says about the sheet behind it.
    ///
    /// This is the folded login card's summary line, kept verbatim: moving credentials behind a sheet
    /// must not hide *which* provider is armed or whether it has a key, because those two facts
    /// decide whether the table's **Eval** and **Price** buttons do anything.
    private var settingsSummary: String {
        var parts: [String] = [settings.email.isEmpty ? "no site login" : settings.email]
        parts.append("\(settings.provider.displayName) · \(settings.activeModelID)")
        parts.append(settings.hasAPIKey ? "key set" : "no key")
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Action chrome

    /// The chrome a control-panel action draws for itself.
    ///
    /// The same story as `TitlebarMenuButtonStyle`: macOS 26 puts its own glass behind a control and
    /// ignores `buttonBorderShape`, so a squared-off button means painting the whole thing. Two
    /// emphases share one corner, one height and one set of states — **Scrape Lots** is the row's
    /// single accent-filled control, **Stop** and **Clear** are hairlines over a light fill — so the
    /// row reads as one set rather than three buttons that happen to sit together.
    private struct PanelActionButtonStyle: ButtonStyle {

        /// Which of the row's two kinds of button this is: the one that starts the work, or one that
        /// moves beside it.
        enum Emphasis { case primary, secondary }

        let emphasis: Emphasis

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)

            configuration.label
                .font(.callout.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.4)
                .foregroundStyle(foreground)
                .padding(.horizontal, 15)
                .frame(height: Theme.controlHeight)
                .background(fill(isPressed: configuration.isPressed), in: shape)
                .overlay(shape.strokeBorder(stroke))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }

        private var foreground: Color {
            switch emphasis {
            case .primary: .white
            case .secondary: .primary
            }
        }

        /// A button's three states, in the order they should read: resting, hovered, pressed.
        private func fill(isPressed: Bool) -> Color {
            switch emphasis {
            case .primary:
                Color.accentColor.opacity(isPressed ? 0.75 : (isHovering ? 0.88 : 1))
            case .secondary:
                Color.primary.opacity(isPressed ? 0.16 : (isHovering ? 0.10 : 0.05))
            }
        }

        /// The primary button's fill is its border; only the secondary wears a hairline.
        private var stroke: Color {
            switch emphasis {
            case .primary: .clear
            case .secondary: Color.primary.opacity(0.12)
            }
        }
    }

    /// The chrome the row's one icon control draws for itself: the accent **info** glyph, with a wash
    /// of the same accent behind it under the pointer.
    private struct PanelIconButtonStyle: ButtonStyle {

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                .background(
                    Circle().fill(
                        Color.accentColor.opacity(configuration.isPressed ? 0.20 : (isHovering ? 0.12 : 0))
                    )
                )
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

#Preview {
    let settings = AppSettings()
    return ControlPanelView(settings: settings, coordinator: AnalysisCoordinator(settings: settings))
        .frame(width: 1240)
}

