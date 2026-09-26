//
//  ScrapeLimits.swift
//  PalletAuctionBidTool
//
//  Page-count policy for walking a listing: the ceiling, the "every page" marker and the default.
//
//  Its own file because it is a model rather than a property of the WebKit service that walks the
//  pages: `AppSettings` reads it, the Pages menu is built from it, and the offline harness compiles
//  the settings without a `WebKit` dependency.
//

import Foundation

/// Scrape-wide hard limits.
///
/// Deliberately top-level and non-isolated so both the `@MainActor` service and the
/// settings/validation code can read it without hopping actors.
enum ScrapeLimits {
    /// Runaway guard on how many result pages will ever be walked.
    ///
    /// This is a guard, not a target, and it is no longer the brief's ten pages: the walk ends when
    /// the listing runs out of pages (no next control, no change, no cards), so the number below only
    /// decides when a catalogue that paginates for ever has to be given up on. **All pages** in the
    /// control panel means exactly that — walk until the site stops — which is why the ceiling had to
    /// move: a listings site with more than ten pages is ordinary, and a menu that stops at ten would
    /// silently truncate it.
    static let maximumPages = 100

    /// `AppSettings.pageLimit`'s "every page" marker: the guard above, reached by asking for none.
    static let allPagesMarker = 0

    /// Pages walked by a fresh install, before the operator has an opinion.
    static let defaultPages = 3
}
