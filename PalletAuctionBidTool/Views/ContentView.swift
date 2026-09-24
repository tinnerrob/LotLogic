//
//  ContentView.swift
//  PalletAuctionBidTool
//
//  Root window: control panel, hierarchical lot table, activity log, progress footer.
//

import SwiftUI

/// The application window.
///
/// `settings` and `coordinator` are created together in `init` and held in `@State`: both are
/// `@Observable` reference types, so SwiftUI tracks the individual properties the UI reads and
/// only re-renders the rows whose data actually changed.
struct ContentView: View {

    @State private var settings: AppSettings
    @State private var coordinator: AnalysisCoordinator

    /// Console visibility. The console's own header is the only control for it — its chevron folds
    /// and unfolds the panel, and the footer deliberately carries no second toggle.
    @State private var showsLog = true

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _coordinator = State(initialValue: AnalysisCoordinator(settings: settings))
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

            Divider()

            ProgressFooterView(coordinator: coordinator)
        }
        // Wide enough for the full table (every column is visible at this size) and tall enough
        // for the panel, a useful number of rows and the console.
        .frame(minWidth: 1240, minHeight: 760)
        .background(Theme.windowFill)
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
    ContentView()
}
