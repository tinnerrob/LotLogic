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
/// - Note: credentials and the API keys are stored in the app's `UserDefaults` domain, which is
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
        /// The stored key for **Evaluate photos with**.
        ///
        /// Spelled as it was when the setting was called *Reads manifests*, and deliberately not renamed
        /// with it: the raw values below are unchanged too, so an install that had named a photograph
        /// provider keeps its choice across the rename instead of being reset to *Same as appraiser*.
        static let photoProvider = "identityProvider"
        static let deepSeekAPIKey = "deepSeekAPIKey"
        static let deepSeekModelID = "deepSeekModelID"
        static let pageLimit = "pageLimit"
        static let requestsPerMinute = "valuationRequestsPerMinute"
        static let highBidPercent = "bidTargetHighPercent"
        static let mediumBidPercent = "bidTargetMediumPercent"
        static let lowBidPercent = "bidTargetLowPercent"
        static let anchorThreshold = "anchorItemThreshold"
        static let hiddenColumns = "hiddenColumns"
        static let photosPerScan = "photosPerScan"
        static let photosPerRequest = "photosPerRequest"
    }

    /// How many lots a batch appraises at the same time.
    ///
    /// This was **Parallel lots**, a stepper in Run Tuning, and the question it drew ("what is a
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

    /// How many of a lot's photographs a scan reads **one at a time** by default: every one the lot
    /// carries.
    ///
    /// This is the thorough path's one real cost, and the reason the default is "all of them" rather
    /// than a token number is that a pallet's photographs are its evidence: a frame the scan skipped is
    /// a row of goods nobody priced. The ceiling exists for a metered key, not for the app — see
    /// `photosPerScan`.
    static let defaultPhotosPerScan = 0

    /// Most a scan will read one at a time, however the setting is stored.
    ///
    /// Past a couple of dozen frames a lot is a warehouse rather than a pallet, and the reconciliation
    /// request — which carries every reading anyway — is the cheaper place to spend the tail.
    static let maximumPhotosPerScan = 32

    /// The **Photos / scan** marker for reading the whole gallery in **one** request: every frame the
    /// inline budget can carry travels in a single body, so a lot costs one model call instead of one
    /// per photograph (`wholeGalleryPerScan` ⇒ `PhotoScanPlan.disabled` ⇒ the service's single pass).
    ///
    /// This is the route the app had before the per-photograph pipeline existed, kept as an explicit
    /// choice rather than as a leftover: a lot that only needs a coarse reading — a forty-frame gallery
    /// on a per-minute quota, or a first look before paying for the thorough scan — can spend one
    /// request on the whole of it instead of forty-one. What bounds it is the inline ceiling
    /// (`LotImageLoader.defaultTotalBytes`), and a frame that does not fit is reported as skipped
    /// rather than dropped, so the row can still say "38 of 40".
    ///
    /// Negative on purpose: every other value of this setting is a *count* of photographs read one at
    /// a time (`0` being all of them), so the marker cannot collide with a ceiling, and the choice is
    /// visible in the stored preference as the negative a count never is.
    static let wholeGalleryPerScan = -1

    /// The counts the **Photos / scan** menu offers, most generous last. `0` is every photograph.
    ///
    /// Counts only, because the count is what the menu's arithmetic is built on;
    /// `wholeGalleryPerScan` is not one, so the sheet draws that entry itself.
    static let photoScanChoices = [0, 4, 8, 12, 16, 24]

    /// How many of a lot's photographs one **batched** request carries by default: the count the
    /// DeepSeek route is built from (`AppSettings.photosPerRequest`).
    ///
    /// Six is the count that fits both halves of the trade. Several views of the same goods have to be
    /// *inside one request* for the model to see that the carton at the front and the carton at the side
    /// are one carton — that is the whole reason to batch rather than read frame by frame — and a batch
    /// that grows past a dozen frames starts costing as much as the requests it saved without telling
    /// the model anything new about the pallet.
    static let defaultPhotosPerRequest = 6

    /// Most one batched request will carry, however the setting is stored.
    static let maximumPhotosPerRequest = 24

    /// The counts the **Photos / request** menu offers. `0` is **Off** — the per-photograph route.
    static let photoRequestChoices = [0, 2, 4, 6, 8, 12]

    /// Photographs in flight at once, whatever the plan says; see `PhotoScanPlan.concurrency`.
    static let photoScanConcurrency = PhotoScanPlan.defaultConcurrency

    /// Most recently used auction URL.
    var auctionURL: String

    /// Site login email. Edited in the settings modal behind the panel's gear (⌘,).
    var email: String

    /// Site login password. Same modal as `email`.
    var password: String

    /// Which back end appraises lots.
    var provider: ValuationProvider

    /// Which back end **reads a lot's photographs**, while `provider` prices what was read
    /// (`PhotoProvider`, `docs/manifest-identity-plan.md` Tier 5).
    ///
    /// `.same` is the whole of what every install did before this existed, and it is the default: one
    /// provider for both jobs. Naming another provider buys the photograph half from the model that reads a
    /// carton best — a Gemini section pointed at its own model among them — while the prices stay on the
    /// appraiser's key, which is what keeps the reading half affordable as *only* the extraction step
    /// (`ValuationOutcome.identityModelID`, `manifestModelID`).
    ///
    /// It works in both directions, because both transports can read a batch and both can price a manifest:
    /// a DeepSeek-priced run may buy its photographs from Gemini, and a Gemini-priced run may buy them from
    /// DeepSeek. See `batchesPhotographs` for when the choice actually takes effect — a manifest needs a
    /// batch, and a batch needs a width on **Photos / request**.
    var photoProvider: PhotoProvider

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

    /// How many of a lot's photographs a scan reads **one at a time**, from the front of the gallery;
    /// `0` — the shipped default — means every photograph the lot carries, and `wholeGalleryPerScan`
    /// means none of them: the whole gallery travels in one request instead.
    ///
    /// A thorough scan asks a separate question about each photograph and then reconciles the answers,
    /// which is what makes a thirty-dollar item in the corner of frame nine show up in the line items
    /// instead of being averaged away by the pallet in front of it. The cost is one request per
    /// photograph, so this is the ceiling a metered key sets: photographs past it are not dropped —
    /// they travel with the reconciliation request — but they are not read individually either.
    ///
    /// The whole-gallery marker is the other end of the same trade, and the one way to make a lot cost
    /// a single request: it gives up the per-frame readings (and with them the store, the frame
    /// grouping, and the "which picture did this figure come from" trail) for a gallery-wide average.
    var photosPerScan: Int

    /// How many of a lot's photographs one **batched** request carries, or `0` for **Off** — read the
    /// gallery one frame at a time instead.
    ///
    /// The DeepSeek route's own setting (`DeepSeekValuationService.photosPerRequest`), and the one that
    /// trades requests against context: a batch of six frames answers a whole pallet in a couple of
    /// requests where reading frame by frame would spend one per photograph, and because the frames
    /// travel together the model can see that the carton at the front and the carton at the side are one
    /// carton rather than reconciling two reports afterwards. Gemini reads a gallery frame by frame and
    /// ignores this — see `batchesPhotographs`.
    var photosPerRequest: Int

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
        // An unrecognised or absent value is `.same`: the split is an extra, and a preference file that
        // predates it (or names a provider this build dropped) must read as "one provider, as before"
        // rather than as a run pointed at a service nobody chose.
        photoProvider = PhotoProvider(rawValue: defaults.string(forKey: Key.photoProvider) ?? "")
            ?? .same
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
        // Read as an object again, so a deliberate 0 ("every photograph") survives a relaunch instead
        // of being mistaken for "never configured" and silently becoming every photograph anyway — and
        // so the whole-gallery marker does, which a clamp at zero would eat. A count is still clamped
        // to what the pipeline can honour, so a hand-edited preference file cannot ask for a ceiling
        // this build has no route for.
        let storedPhotosPerScan = defaults.object(forKey: Key.photosPerScan) as? Int
        photosPerScan = storedPhotosPerScan == Self.wholeGalleryPerScan
            ? Self.wholeGalleryPerScan
            : max(0, min(storedPhotosPerScan ?? Self.defaultPhotosPerScan, Self.maximumPhotosPerScan))
        // Same object-for-an-integer read, for the same reason: **Off** (`0`) is a deliberate choice
        // about how a gallery is read, not an unset field.
        photosPerRequest = max(
            0,
            min(
                defaults.object(forKey: Key.photosPerRequest) as? Int ?? Self.defaultPhotosPerRequest,
                Self.maximumPhotosPerRequest
            )
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

    /// Photographs per scan clamped into what the pipeline can honour.
    ///
    /// The whole-gallery marker is not a count, so it passes through as itself rather than being
    /// clamped to `0`: "none of them read one at a time" and "every one of them read one at a time" are
    /// the two ends of this setting, and they must not collapse into each other.
    var effectivePhotosPerScan: Int {
        photosPerScan == Self.wholeGalleryPerScan
            ? Self.wholeGalleryPerScan
            : max(0, min(photosPerScan, Self.maximumPhotosPerScan))
    }

    /// `true` while a scan sends the whole gallery in **one** request: no per-photograph readings at
    /// all, just the frames (as many as the inline budget carries) and one gallery-wide question.
    var readsWholeGalleryInOneRequest: Bool { effectivePhotosPerScan == Self.wholeGalleryPerScan }

    /// Photographs per **batch** clamped into what one request can honour.
    var effectivePhotosPerRequest: Int { max(0, min(photosPerRequest, Self.maximumPhotosPerRequest)) }

    /// `true` while a scan reads **every** photograph of a lot one at a time, which is the default.
    ///
    /// The whole-gallery marker is deliberately *not* this: it reads none of them one at a time (see
    /// `readsWholeGalleryInOneRequest`), which is why the comparison is against `0` rather than against
    /// anything that is not a positive ceiling.
    var readsEveryPhotograph: Bool { effectivePhotosPerScan == 0 }

    /// `true` while a lot's photographs are read in **batches** rather than one at a time — which is the
    /// manifest route, whichever provider reads it.
    ///
    /// Two things have to agree for that: the operator has to have set a batch width, *and* that width has to
    /// belong to a route this build has. A batch is read by the provider **Evaluate photos with** names —
    /// DeepSeek, whose native shape it is, or whoever the operator pointed there — so the run batches when a
    /// width is set and either
    ///
    /// * the reader is DeepSeek, which can always read a batch into a manifest and price it too, or
    /// * the reader is somebody other than the appraiser, which is the split: one provider reads the
    ///   photographs and the other prices the inventory (`runsSplitPhotos`).
    ///
    /// A Gemini-priced, Gemini-read run therefore never batches however the width is set: Gemini's own
    /// photograph route is frame by frame (or one whole-gallery request), and **Photos / request** is inert
    /// rather than a second, silent route. That is the one case where `effectivePhotosPerRequest > 0` does
    /// not mean a batch, which is why the rule is written here once and read by both transports and by the
    /// sheets instead of being re-derived at each call site.
    var batchesPhotographs: Bool {
        guard effectivePhotosPerRequest > 0 else { return false }
        return manifestProvider == .deepSeek || manifestProvider != provider
    }

    /// `true` while naming a photograph provider can mean anything: a width has been set on **Photos /
    /// request**, so a manifest route could run if the operator pointed it somewhere.
    ///
    /// Read by the Account sheet for the **Evaluate photos with** row's enabled state, and deliberately *not*
    /// `batchesPhotographs`: that answers *"is this run batching?"*, which the row's own choice is part of the
    /// answer to — a row disabled by the thing it is about could never be turned on.
    var canNamePhotoProvider: Bool { effectivePhotosPerRequest > 0 }

    /// The photograph budget in words, for the run log and the status line.
    ///
    /// The whole-gallery route is its own phrase rather than a count of zero: "none of them read one at
    /// a time" is a different sentence from "the first 0 photograph(s)", and the log is the one place an
    /// operator sees which route a run is about to take (`photoRouteSummary`).
    var photoScanSummary: String {
        if readsWholeGalleryInOneRequest { return "the whole gallery in one request" }
        return readsEveryPhotograph
            ? "every photograph"
            : "the first \(effectivePhotosPerScan) photograph(s)"
    }

    /// The route in words, for the run log and the status line.
    ///
    /// A noun phrase, because that is how the log uses it — `Scanning lot 142 — Gemini
    /// gemini-3.8-flash, the whole gallery in one request on its lot page`. Says batching when it is on,
    /// the whole-gallery phrase when the operator chose it — which must not be followed by "read one at
    /// a time", since that is the route it was chosen instead of — and the per-photograph budget
    /// otherwise, so the line an operator reads before spending anything describes what the run will
    /// actually do.
    var photoRouteSummary: String {
        if batchesPhotographs { return "photographs in batches of \(effectivePhotosPerRequest)" }
        return readsWholeGalleryInOneRequest
            ? photoScanSummary
            : "\(photoScanSummary) read one at a time"
    }

    /// The thorough-scan plan the selected provider is built with.
    ///
    /// One place builds it, so the model it names, the ceiling it applies and the store it consults
    /// are the same for both transports — which is what makes "the reading was reused" mean the same
    /// thing whichever key paid for it.
    ///
    /// The batched route *displaces* it rather than running beside it: DeepSeek's manifest batches and
    /// the per-photograph scan are two ways of reading the same gallery, and a run that did both would
    /// pay twice for the photographs. So while batching is on, this plan is `.disabled` — and the
    /// DeepSeek service's own `photosPerRequest` is what it runs instead. Nothing else in the app has to
    /// know which route was chosen.
    ///
    /// **Photos / scan** set to `wholeGalleryPerScan` yields the same `.disabled`, and for the same
    /// reason: it *is* "one request carries the gallery, no per-photograph readings", which is exactly
    /// what `.disabled` means to either service (`GeminiValuationService.value(subject:)` goes straight
    /// to its single-pass body with every frame the inline budget holds). Nothing downstream has to
    /// learn a third route — a plan that reads no photograph individually needs no plan.
    func photoScanPlan() -> PhotoScanPlan {
        guard !batchesPhotographs, !readsWholeGalleryInOneRequest else { return .disabled }
        return .thorough(
            modelID: activeModelID,
            perImageLimit: effectivePhotosPerScan,
            concurrency: Self.photoScanConcurrency
        )
    }

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

    /// The key stored for one provider, named explicitly.
    ///
    /// The Account sheet shows both providers at once, so it asks *by name* rather than reading
    /// whichever one `provider` happens to point at. Every reader goes through these, so there is
    /// still exactly one place that knows a provider keeps its credential in its own field.
    func apiKey(for provider: ValuationProvider) -> String {
        switch provider {
        case .gemini: apiKey
        case .deepSeek: deepSeekAPIKey
        }
    }

    /// Stores a key against the provider it belongs to, so a section can write without caring which
    /// field that provider's key lives in.
    func setAPIKey(_ value: String, for provider: ValuationProvider) {
        switch provider {
        case .gemini: apiKey = value
        case .deepSeek: deepSeekAPIKey = value
        }
    }

    /// The model one provider would use, falling back to its default when the stored choice is empty
    /// (a fresh install, or a reset) **or is no longer offered**.
    ///
    /// The second half is the retirement rule. A model ID is only ever stored from `availableModelIDs` —
    /// the picker's own entries — so a value outside that list is a preference file written by a build
    /// whose menu has since dropped it, and serving it would send `:generateContent` to a retired model
    /// (an error on the first scan of every lot) while the operator's only visible setting still looks
    /// right. The current default is served instead. The stored string itself is left where it is:
    /// choosing a model in Account overwrites it, and an older build run from the same preference file
    /// still finds what it wrote.
    func modelID(for provider: ValuationProvider) -> String {
        let stored = switch provider {
        case .gemini: modelID
        case .deepSeek: deepSeekModelID
        }
        guard !stored.isEmpty, provider.availableModelIDs.contains(stored) else {
            return provider.defaultModelID
        }
        return stored
    }

    /// Stores a model against the provider it belongs to.
    func setModelID(_ value: String, for provider: ValuationProvider) {
        switch provider {
        case .gemini: modelID = value
        case .deepSeek: deepSeekModelID = value
        }
    }

    /// `true` when one *named* provider has a non-blank credential — `hasAPIKey` asked of a provider
    /// that is not necessarily the armed one, which is what the sheet's two sections and its header
    /// need.
    func hasAPIKey(for provider: ValuationProvider) -> Bool {
        !apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The key belonging to the selected provider.
    var activeAPIKey: String { apiKey(for: provider) }

    /// The model belonging to the selected provider, falling back to its default when the stored
    /// choice is empty (a fresh install, or a reset).
    var activeModelID: String { modelID(for: provider) }

    // MARK: - The identity half (Tier 4)

    /// The provider that reads a lot's **manifest**, given who is pricing it.
    ///
    /// `.same` answers `provider`, which is what makes the whole split a no-op for an install that has
    /// not asked for it — every caller can go through here without asking whether a split is on.
    var manifestProvider: ValuationProvider {
        photoProvider.provider(fallingBackTo: provider)
    }

    /// The model the manifest pass runs on.
    ///
    /// Read through `modelID(for:)`, so the identity half picks up whichever model its own section in
    /// Account names — including a model the appraiser would never be pointed at on price grounds.
    var manifestModelID: String { modelID(for: manifestProvider) }

    /// `true` when this install reads its photographs on one provider and prices them on another.
    ///
    /// Two things have to line up, and both are choices rather than facts: a width has to be set so that a
    /// manifest route exists at all (**Photos / request** — `batchesPhotographs`), and the photograph role has
    /// to be filled by a provider other than the appraiser's (`PhotoProvider`). Folding the first in is what
    /// keeps the setting from looking broken: an operator who names a photograph provider and then turns the
    /// width off gets one provider doing both jobs, which is the whole meaning of *Same as appraiser*.
    var runsSplitPhotos: Bool {
        batchesPhotographs && manifestProvider != provider
    }

    /// The identity pass in words, for the run log: `read on Gemini gemini-3.8-flash`, or `""` when the
    /// appraiser reads its own batches.
    ///
    /// Empty rather than *"read on DeepSeek"* when there is no split, because the line it is appended to
    /// already names the model doing the work — and three quarters of a run's console lines should not
    /// grow a clause about a setting that is off.
    var identityRouteSummary: String {
        runsSplitPhotos
            ? ", manifest read on " + manifestProvider.displayName + " " + manifestModelID
            : ""
    }

    /// The provider whose key is missing, when one is: `nil` means a scan can run.
    ///
    /// The appraiser is asked first — its key is the one every route needs — and then the identity
    /// provider, and only while the split is actually on. Reported as a *provider* rather than as a
    /// boolean so the readiness note and the coordinator can name the section that needs attention
    /// instead of saying "add a key" beside two key fields.
    var missingKeyProvider: ValuationProvider? {
        if !hasAPIKey(for: provider) { return provider }
        let reader = manifestProvider
        if runsSplitPhotos, !hasAPIKey(for: reader) { return reader }
        return nil
    }

    /// Which half of a split run a missing key belongs to, in words: `" (the manifest half)"`, or `""`
    /// when the key in question is the appraiser's or there is no split.
    ///
    /// A sentence about a missing key has to be able to say *what it was going to pay for*, because a
    /// split run buys two things from two providers and only the appraiser's key was ever needed to
    /// price anything. Said once here so the status line and the console agree on the phrase.
    func missingKeyRolePhrase(for missing: ValuationProvider) -> String {
        runsSplitPhotos && missing == manifestProvider ? " (the manifest half)" : ""
    }

    /// The missing key as a noun phrase for a sentence: `"a Gemini key (the manifest half)"`.
    ///
    /// Falls back to the appraiser's own provider when nothing is missing, so a caller that has already
    /// established there *is* a gap (the readiness note, the console line a scrape ends with) can drop
    /// `missingKeyProvider` and write one clause. A phrase rather than a whole sentence because the two
    /// surfaces word it differently — *"Add … behind the gear, then scan again"* and *"add … to scan a
    /// row"* — and only the key itself has to be named the same way.
    var missingKeyPhrase: String {
        let missing = missingKeyProvider ?? provider
        return "a \(missing.displayName) key\(missingKeyRolePhrase(for: missing))"
    }

    /// `true` when the *selected* provider has a credential, which is what the Run button and the
    /// readiness note care about.
    ///
    /// Widened for the split (Tier 4): a batched run whose manifest would be read on a provider with no
    /// key has to pay for two halves, so it is exactly as unready as one with no key at all — and the
    /// provider that is missing is named by `missingKeyProvider`. `hasAPIKey(for:)` is unchanged, which
    /// is what the two Account sections and the panel's tooltip ask.
    var hasAPIKey: Bool { missingKeyProvider == nil }

    /// Both providers with their key state, the armed one first.
    ///
    /// What the surfaces that speak about *both* providers read — the Account sheet's header, its two
    /// sections and the panel's own tooltip — so the order and the phrase `key set` / `no key` are
    /// decided once instead of three times.
    var providerKeyStates: [ProviderKeyState] {
        let states = ValuationProvider.allCases.map {
            ProviderKeyState(provider: $0, isReady: hasAPIKey(for: $0), modelID: modelID(for: $0))
        }
        // The armed provider leads: it is the fact the operator opened the sheet to check.
        return states.filter { $0.provider == provider } + states.filter { $0.provider != provider }
    }

    /// Whether a scrape can start. Loading lots needs a URL and nothing else: the site login is
    /// optional and no API call is made until a lot is scanned by hand.
    var canStartScrape: Bool { auctionURLValue != nil }

    /// Whether on-demand work can run: the *selected* provider has a key — and, when the run would read
    /// its manifest on another provider, that one has a key too (`missingKeyProvider`). This is what
    /// gates the two per-row buttons (**Eval** and **Price**) and the two all-lots buttons in the table
    /// toolbar.
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
        defaults.set(photoProvider.rawValue, forKey: Key.photoProvider)
        defaults.set(apiKey, forKey: Key.apiKey)
        defaults.set(modelID, forKey: Key.modelID)
        defaults.set(deepSeekAPIKey, forKey: Key.deepSeekAPIKey)
        defaults.set(deepSeekModelID, forKey: Key.deepSeekModelID)
        defaults.set(pageLimit, forKey: Key.pageLimit)
        defaults.set(requestsPerMinute, forKey: Key.requestsPerMinute)
        defaults.set(photosPerScan, forKey: Key.photosPerScan)
        defaults.set(photosPerRequest, forKey: Key.photosPerRequest)
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
    /// to write *now* without also committing whatever is half-typed in Run Tuning.
    private func persistColumnVisibility() {
        defaults.set(columnVisibility.storedNames, forKey: Key.hiddenColumns)
    }

    func reset() {
        auctionURL = ""
        email = ""
        password = ""
        provider = .gemini
        photoProvider = .same
        apiKey = ""
        modelID = GeminiValuationService.defaultModelID
        deepSeekAPIKey = ""
        deepSeekModelID = DeepSeekValuationService.defaultModelID
        pageLimit = ScrapeLimits.defaultPages
        requestsPerMinute = Self.defaultRequestsPerMinute
        photosPerScan = Self.defaultPhotosPerScan
        photosPerRequest = Self.defaultPhotosPerRequest
        highBidPercent = BidTargetPolicy.standard.highConfidencePercent
        mediumBidPercent = BidTargetPolicy.standard.mediumConfidencePercent
        lowBidPercent = BidTargetPolicy.standard.lowConfidencePercent
        anchorThreshold = AnchorItem.defaultThreshold
        // Every column back: a reset is "as shipped", and a table missing columns is not that.
        columnVisibility = .all
        persist()
    }
}
