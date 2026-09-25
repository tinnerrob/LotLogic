//
//  ContentView.swift
//  PalletAuctionBidTool
//
//  Root window: control panel, hierarchical lot table, activity log.
//

import SwiftUI

/// The application window.
///
/// `settings` and `coordinator` are created together in `init` and held in `@State`: both are
/// `@Observable` reference types, so SwiftUI tracks the individual properties the UI reads and
/// only re-renders the rows whose data actually changed.
///
/// The window wears one thing that is not part of the tool: the launch splash, a full-window
/// overlay over this stack (see `SplashView`) that fades itself away a moment after the window
/// opens.
struct ContentView: View {

    @State private var settings: AppSettings
    @State private var coordinator: AnalysisCoordinator

    /// Console visibility. The console's own header is the only control for it: its chevron folds and
    /// unfolds the panel, and nothing else in the window offers a second toggle.
    @State private var showsLog = true

    /// Whether the launch splash is still over the window.
    ///
    /// `SplashView` writes `false` here from either of its two exits — its own timer, or a click —
    /// and the fade is its own too, so this is the only flag the window has to hold.
    @State private var showsSplash: Bool

    /// - Parameter showsSplash: whether the launch splash plays over this window. Previews pass
    ///   `false`: a preview is not a launch, and the splash would cover the panel it exists to show.
    init(showsSplash: Bool = true) {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _coordinator = State(initialValue: AnalysisCoordinator(settings: settings))
        _showsSplash = State(initialValue: showsSplash)
    }

    var body: some View {
        VStack(spacing: 0) {
            ControlPanelView(settings: settings, coordinator: coordinator)

            Divider()

            LotTableView(
                coordinator: coordinator,
                policy: settings.bidTargetPolicy,
                anchorThreshold: settings.effectiveAnchorThreshold,
                settings: settings
            )

            Divider()

            // The console is always present so its header can be used to fold and unfold it; only
            // the console body's height is conditional.
            LogConsoleView(lines: coordinator.logLines, isExpanded: $showsLog)
                .frame(height: showsLog ? 140 : nil)
        }
        // Wide enough for the full table (every column is visible at this size) and tall enough
        // for the panel, a useful number of rows and the console.
        .frame(minWidth: 1240, minHeight: 760)
        .background(Theme.windowFill)
        // The launch splash sits over the whole window — including the panel, which is already live
        // underneath it — and dissolves into it when it goes. It is an overlay rather than a sheet
        // for exactly that reason: a sheet would have to be dismissed, and it would slide off the
        // window rather than hand the window back.
        .overlay {
            if showsSplash {
                SplashView(isPresented: $showsSplash)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: browserBinding) {
            if let surface = coordinator.pageSurface {
                BrowserPanelView(webView: surface)
            }
        }
    }

    /// Mirrors `coordinator.isBrowserVisible` so the coordinator stays the source of truth.
    private var browserBinding: Binding<Bool> {
        Binding(
            get: { coordinator.isBrowserVisible },
            set: { coordinator.setBrowserVisible($0) }
        )
    }
}

#Preview {
    ContentView(showsSplash: false)
}
