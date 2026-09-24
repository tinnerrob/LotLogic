//
//  PalletAuctionBidToolApp.swift
//  PalletAuctionBidTool
//

import SwiftUI

@main
struct PalletAuctionBidToolApp: App {

    /// - Note: a hidden `WKWebView` drives the scrape, and Safari-style third-party cookie
    ///   prompts would interrupt a scripted login, so the default `WindowGroup` is the only
    ///   scene. The scraper's own web view is deliberately *not* attached to any window (see
    ///   `AuctionScraperService`); the only pages the operator ever sees are ones asked for —
    ///   the captcha hand-off (`BrowserPanelView`) and a lot's own page (`LotPageSheetView`),
    ///   both as sheets over this one window.
    var body: some Scene {
        WindowGroup("Pallet Auction Bid Tool") {
            ContentView()
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)

        // A second window would give the operator two live pipelines; the UI is a single
        // long-running job, so extra windows are not offered.
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
