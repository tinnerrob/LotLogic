//
//  TheLotLizardApp.swift
//  PalletAuctionBidTool
//

import SwiftUI

@main
struct TheLotLizardApp: App {

    /// - Note: a hidden `WKWebView` drives the scrape, and Safari-style third-party cookie
    ///   prompts would interrupt a scripted login, so the default `WindowGroup` is the only
    ///   scene. The scraper's own web view is deliberately *not* attached to any window (see
    ///   `AuctionScraperService`); the only pages the operator ever sees are ones asked for —
    ///   the captcha hand-off (`BrowserPanelView`) and a lot's own page (`LotPageSheetView`),
    ///   both as sheets over this one window.
    var body: some Scene {
        WindowGroup(Theme.appName) {
            ContentView()
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        // The titlebar's own row is the app's toolbar (see `ControlPanelView`): **Account**,
        // **Tuning** and **About** live at its trailing edge beside the traffic lights, and the
        // unified style is what lets that bar share the panel's background instead of reading as a
        // second strip above it. The system title is suppressed because the toolbar draws the app's
        // own mark and name in its place — one title, not two — while the title set here is still
        // what the Window menu, Mission Control and the window's own accessibility name read.
        .windowToolbarStyle(.unified(showsTitle: false))

        // A second window would give the operator two live pipelines; the UI is a single
        // long-running job, so extra windows are not offered.
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
