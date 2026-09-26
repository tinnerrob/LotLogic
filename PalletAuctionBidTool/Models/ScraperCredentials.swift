//
//  ScraperCredentials.swift
//  PalletAuctionBidTool
//
//  Credentials typed into the site's own login form.
//
//  Its own file rather than a corner of the WebKit service: `AppSettings.credentials` is the app's
//  only reader, and the offline harness compiles the settings without a `WebKit` dependency.
//

import Foundation

/// Credentials typed into the site's own login form.
struct ScraperCredentials: Sendable, Equatable {
    var email: String
    var password: String

    var isEmpty: Bool {
        email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
