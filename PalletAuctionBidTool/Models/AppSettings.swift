//
//  AppSettings.swift
//  PalletAuctionBidTool
//
//  User-facing configuration, persisted in `UserDefaults`.
//

import Foundation
import Observation

/// Everything the operator can configure, backed by `UserDefaults`.
///
/// Persistence is explicit (`persist()`) instead of property observers: `@Observable` rewrites
/// stored properties into observation-tracked ones, and keeping the write path as a single
/// explicit call keeps that interaction obvious and testable.
///
/// - Note: credentials and the API key are stored in the app's `UserDefaults` domain, which is
///   inside the user's own container. A production build should move these two fields to the
///   Keychain; see the README.
@MainActor
@Observable
final class AppSettings {

    /// Keys used in the `UserDefaults` domain.
    private enum Key {
        static let auctionURL = "auctionURL"
        static let email = "loginEmail"
        static let password = "loginPassword"
        static let apiKey = "geminiAPIKey"
        static let modelID = "geminiModelID"
        static let provider = "valuationProvider"
        static let deepSeekAPIKey = "deepSeekAPIKey"
        static let deepSeekModelID = "deepSeekModelID"
        static let pageLimit = "pageLimit"
        static let requestsPerMinute = "valuationRequestsPerMinute"
        static let highBidPercent = "bidTargetHighPercent"
        static let mediumBidPercent = "bidTargetMediumPercent"
        static let lowBidPercent = "bidTargetLowPercent"
        static let anchorThreshold = "anchorItemThreshold"
        static let hiddenColumns = "hiddenColumns"
    }

    /// How many lots a batch appraises at the same time.
    ///
    /// This was **Parallel lots**, a stepper in Run tuning, and the question it drew ("what is a
    /// parallel lot?") was the fair one: it is the width of the **Price all** / **Eval all** task
    /// group, not a property of a lot, and it says nothing about a scrape — one page is still fetched
    /// at a time, never in parallel against the auction host. Three hides a slow model behind its
    /// neighbours and still leaves the provider's 429 handling room to work (see `ValuationRetry`),
    /// and the per-minute ceiling in **Requests / min** is the control that actually matters.
    static let batchConcurrency = 3

    /// Pacing applied to a fresh install: this is inside the Gemini free tier's per-minute
    /// allowance, so an unconfigured key does not have to be throttled by the API. DeepSeek meters
    /// concurrency rather than requests per minute, so raise it (or set it to `0`) there.
    static let defaultRequestsPerMinute = 10

    /// Most recently used auction URL.
    var auctionURL: String

    /// Site login email. Edited in the settings modal behind the panel's gear (⌘,).
    var email: String

    /// Site login password. Same modal as `email`.
    var password: String

    /// Which back end appraises lots.
    var provider: ValuationProvider

    /// Google AI Studio key used for the Gemini REST calls.
    var apiKey: String

    /// Gemini model ID.
    var modelID: String

    /// DeepSeek key used for the DeepSeek REST calls.
    var deepSeekAPIKey: String

    /// DeepSeek model ID.
    var deepSeekModelID: String

    /// How many result pages to walk: a positive count, or `ScrapeLimits.allPagesMarker` (`0`) for
    /// **every page** — walk until the listing stops offering one.
    ///
    /// The marker is how the **Pages** menu says "All pages" without a second setting to keep in step
    /// with this one; `effectivePageLimit` is the only place it is turned back into a number.
    var pageLimit: Int

    /// Ceiling on outbound valuation requests per minute, so a metered key gets paced locally
    /// instead of being refused by the API. `0` means "no pacing".
    var requestsPerMinute: Int

    /// Percent of resale worth bidding on a High-confidence valuation.
    var highBidPercent: Int

    /// Percent of resale worth bidding on a Med-confidence valuation.
    var mediumBidPercent: Int

    /// Percent of resale worth bidding on a Low-confidence valuation.
    var lowBidPercent: Int

    /// Retail value at or above which one line item is flagged as an **anchor** in the nested
    /// table.
    var anchorThreshold: Double

    /// Which data columns the table draws, chosen from the gear in its toolbar.
    ///
    /// Stored as the *hidden* names (see `ColumnVisibility`), which is what keeps the choice from
    /// outliving the layout it was made against: a column added in a later version is drawn until the
    /// operator says otherwise.
    var columnVisibility: ColumnVisibility

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        auctionURL = defaults.string(forKey: Key.auctionURL) ?? ""
        email = defaults.string(forKey: Key.email) ?? ""
        password = defaults.string(forKey: Key.password) ?? ""
        provider = ValuationProvider(rawValue: defaults.string(forKey: Key.provider) ?? "") ?? .gemini
        apiKey = defaults.string(forKey: Key.apiKey) ?? ""
        modelID = defaults.string(forKey: Key.modelID) ?? GeminiValuationService.defaultModelID
        deepSeekAPIKey = defaults.string(forKey: Key.deepSeekAPIKey) ?? ""
        deepSeekModelID = defaults.string(forKey: Key.deepSeekModelID) ?? DeepSeekValuationService.defaultModelID
        // Read as an object, not an integer, so a deliberate 0 ("every page") survives a relaunch:
        // the marker and an absent key are the same number otherwise, and picking **All pages** must
        // not read as "never configured" the next morning.
        pageLimit = defaults.object(forKey: Key.pageLimit) as? Int ?? ScrapeLimits.defaultPages
        // Read as an object, not an integer, so a deliberate 0 ("no pacing") survives a relaunch
        // instead of being mistaken for "never configured".
        requestsPerMinute = max(
            0,
            defaults.object(forKey: Key.requestsPerMinute) as? Int ?? Self.defaultRequestsPerMinute
        )
        // Read every numeric as an object so a deliberate value (including 0) survives a relaunch
        // instead of being mistaken for "never configured"; nil falls back to the shipped policy.
        let defaultPolicy = BidTargetPolicy.standard
        highBidPercent = defaults.object(forKey: Key.highBidPercent) as? Int
            ?? defaultPolicy.highConfidencePercent
        mediumBidPercent = defaults.object(forKey: Key.mediumBidPercent) as? Int
            ?? defaultPolicy.mediumConfidencePercent
        lowBidPercent = defaults.object(forKey: Key.lowBidPercent) as? Int
            ?? defaultPolicy.lowConfidencePercent
        anchorThreshold = defaults.object(forKey: Key.anchorThreshold) as? Double
            ?? AnchorItem.defaultThreshold
        // Read as strings rather than as a set: the stored form is a list of column names, so a
        // preference file written by another version is readable, and a name this build does not
        // know is dropped rather than wedging the table (see `ColumnVisibility`).
        columnVisibility = ColumnVisibility(storedNames: defaults.stringArray(forKey: Key.hiddenColumns))
    }

    // MARK: - Validation

    /// Clamped page budget handed to the scraper.
    ///
    /// A positive `pageLimit` is capped by `ScrapeLimits.maximumPages`; the **All pages** marker
    /// (`0`) *is* that guard, so "every page" and "the most we would ever walk" are one number and
    /// cannot drift apart.
    var effectivePageLimit: Int {
        pageLimit > 0 ? min(pageLimit, ScrapeLimits.maximumPages) : ScrapeLimits.maximumPages
    }

    /// `true` while the page budget is **All pages** rather than a count.
    var walksEveryPage: Bool { pageLimit <= 0 }

    /// The page budget in words, for the run log and the status line.
    var pageLimitSummary: String {
        walksEveryPage
            ? "every page (up to \(ScrapeLimits.maximumPages))"
            : "\(effectivePageLimit) page(s)"
    }

    var credentials: ScraperCredentials? {
        let candidate = ScraperCredentials(email: email, password: password)
        return candidate.isEmpty ? nil : candidate
    }

    /// Parsed, validated auction URL; `nil` when the field is empty or unusable.
    var auctionURLValue: URL? {
        let trimmed = auctionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }

    /// The key belonging to the selected provider.
    var activeAPIKey: String {
        switch provider {
        case .gemini: apiKey
        case .deepSeek: deepSeekAPIKey
        }
    }

    /// The model belonging to the selected provider, falling back to its default when the stored
    /// choice is empty (a fresh install, or a reset).
    var activeModelID: String {
        let stored = switch provider {
        case .gemini: modelID
        case .deepSeek: deepSeekModelID
        }
        return stored.isEmpty ? provider.defaultModelID : stored
    }

    /// `true` when the *selected* provider has a credential, which is what the Run button and the
    /// readiness note care about.
    var hasAPIKey: Bool {
        !activeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether a scrape can start. Loading lots needs a URL and nothing else: the site login is
    /// optional and no API call is made until a lot is scanned by hand.
    var canStartScrape: Bool { auctionURLValue != nil }

    /// Whether on-demand work can run: the *selected* provider has a key. This is what gates the two
    /// per-row buttons (**Eval** and **Price**) and the two all-lots buttons in the table toolbar.
    ///
    /// There is no "valuation off" switch behind this any more. It never bought anything the buttons
    /// do not: the work is on demand, so not pressing them is the off switch, and an install with no
    /// key is told so by name.
    var canScanLots: Bool { hasAPIKey }

    // MARK: - Pricing policy

    /// The ceiling policy built from the three stored percentages, clamped by `BidTargetPolicy`.
    var bidTargetPolicy: BidTargetPolicy {
        BidTargetPolicy(
            highConfidencePercent: highBidPercent,
            mediumConfidencePercent: mediumBidPercent,
            lowConfidencePercent: lowBidPercent
        )
    }

    /// The anchor threshold clamped into `AnchorItem.thresholdRange`.
    var effectiveAnchorThreshold: Double {
        AnchorItem.clamped(anchorThreshold)
    }

    // MARK: - Column choice

    /// Whether the table draws this column. The table stamps this onto its layout at draw time, so
    /// the gear is the only place the choice is written.
    func isColumnVisible(_ key: LotColumnKey) -> Bool {
        columnVisibility.isVisible(key)
    }

    /// Shows or hides one column, and remembers it.
    ///
    /// Written straight away rather than at the next run: this is a view preference, and one that
    /// persisted only after a scrape would look like it had been forgotten. It writes *only* this key
    /// — the rest of the settings keep their documented write path (a run or a scan), so a toggle
    /// here cannot be the thing that freezes a half-typed URL into the defaults.
    func setColumn(_ key: LotColumnKey, visible: Bool) {
        columnVisibility.set(key, visible: visible)
        persistColumnVisibility()
    }

    /// Draws every column again — the way back from a table with too little left in it.
    func showAllColumns() {
        guard columnVisibility.isHidingAnything else { return }
        columnVisibility.showAll()
        persistColumnVisibility()
    }

    // MARK: - Persistence

    func persist() {
        defaults.set(auctionURL, forKey: Key.auctionURL)
        defaults.set(email, forKey: Key.email)
        defaults.set(password, forKey: Key.password)
        defaults.set(provider.rawValue, forKey: Key.provider)
        defaults.set(apiKey, forKey: Key.apiKey)
        defaults.set(modelID, forKey: Key.modelID)
        defaults.set(deepSeekAPIKey, forKey: Key.deepSeekAPIKey)
        defaults.set(deepSeekModelID, forKey: Key.deepSeekModelID)
        defaults.set(pageLimit, forKey: Key.pageLimit)
        defaults.set(requestsPerMinute, forKey: Key.requestsPerMinute)
        defaults.set(highBidPercent, forKey: Key.highBidPercent)
        defaults.set(mediumBidPercent, forKey: Key.mediumBidPercent)
        defaults.set(lowBidPercent, forKey: Key.lowBidPercent)
        defaults.set(anchorThreshold, forKey: Key.anchorThreshold)
        persistColumnVisibility()
    }

    /// Writes the column choice on its own.
    ///
    /// Nested inside `persist()` rather than duplicated, so there is still exactly one place that
    /// knows the stored shape — and callable by itself from a toggle in the table's gear, which needs
    /// to write *now* without also committing whatever is half-typed in Run tuning.
    private func persistColumnVisibility() {
        defaults.set(columnVisibility.storedNames, forKey: Key.hiddenColumns)
    }

    func reset() {
        auctionURL = ""
        email = ""
        password = ""
        provider = .gemini
        apiKey = ""
        modelID = GeminiValuationService.defaultModelID
        deepSeekAPIKey = ""
        deepSeekModelID = DeepSeekValuationService.defaultModelID
        pageLimit = ScrapeLimits.defaultPages
        requestsPerMinute = Self.defaultRequestsPerMinute
        highBidPercent = BidTargetPolicy.standard.highConfidencePercent
        mediumBidPercent = BidTargetPolicy.standard.mediumConfidencePercent
        lowBidPercent = BidTargetPolicy.standard.lowConfidencePercent
        anchorThreshold = AnchorItem.defaultThreshold
        // Every column back: a reset is "as shipped", and a table missing columns is not that.
        columnVisibility = .all
        persist()
    }
}
