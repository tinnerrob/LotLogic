//
//  ScrapeProfile.swift
//  PalletAuctionBidTool
//
//  Selector strategy used by the injected DOM automation script.
//

import Foundation

/// Declarative description of how to drive one auction site.
///
/// The profile is encoded to JSON and injected verbatim into the hidden `WKWebView`, so
/// the JavaScript never hard-codes selectors: retargeting the tool at a different
/// liquidation site means editing data here, not rewriting any web code.
/// Every selector list is tried in order, most specific first.
struct ScrapeProfile: Codable, Hashable, Sendable {

    var name: String

    // MARK: Lot card discovery

    /// Candidate card containers, most specific first.
    var cardSelectors: [String]
    /// When `true` the first selector that yields cards wins (prevents double counting).
    var stopAtFirstMatchingSelector: Bool
    /// Cards matching any of these (or living inside them) are ignored.
    var excludeCardSelectors: [String]
    /// Cards with less visible text than this are treated as empty wrappers.
    var minimumCardTextLength: Int

    // MARK: Field extraction

    /// Attributes on the card element itself that may hold the lot number.
    ///
    /// Real lot-number fields only. A card's own `id` is deliberately absent: on many layouts that
    /// is a DOM address (`ItemMain19002`) rather than the number the site prints, so it lives in
    /// `lotNumberDOMIdAttributeCandidates` and is consulted last.
    var lotNumberAttributeCandidates: [String]
    /// Child selectors that may hold the lot number.
    var lotNumberSelectors: [String]
    /// JS regex (first capture group wins) applied to card text when no element matched.
    var lotNumberRegexPattern: String
    /// Attributes that only *happen* to carry the lot number — the card's DOM `id`, a row key.
    /// Read only after every real field, the page text and the detail URL have failed, and then
    /// unwrapped through `lotNumberWrapperWords`.
    var lotNumberDOMIdAttributeCandidates: [String]
    /// Words a site glues in front of the digits when it mints a DOM id. A value that is exactly one
    /// of these plus digits is reduced to the digits (`ItemMain19002` -> `19002`); a genuine SKU
    /// such as `ABC123` is left alone. Mirrors `LotNumber.domWrappers` in the Swift app, which
    /// applies the same rule to values scraped by an older build.
    var lotNumberWrapperWords: [String]
    var titleSelectors: [String]
    var descriptionSelectors: [String]
    var bidSelectors: [String]
    /// Attributes on the bid element that hold the amount (`content`, `data-bid`, ...).
    var bidAttributeCandidates: [String]
    /// Attributes scanned for image assets, including lazy-loading and `srcset` variants.
    var imageAttributeCandidates: [String]
    /// Upper bound on images taken from a *card's* thumbnail strip.
    ///
    /// Deliberately not "how many images a lot has": a card only ever carries thumbnails, and the
    /// photographs worth appraising are the ones on the lot's own page, which are read in full and
    /// uncapped — how many there are is the lot's business (see `ScraperScript`'s lot-page reader).
    /// This bound exists for the fallback path alone: a lot whose page cannot be read is still
    /// appraised from its card, where a handful of thumbnails is all a listing has to offer.
    var maxCardImages: Int
    /// Meta / link elements that declare a page's lead image, read when a lot's own page is scanned.
    ///
    /// A gallery is occasionally declared nowhere but the document head (`og:image`,
    /// `twitter:image`, `link rel="image_src"`), which is exactly the case where the gallery markup
    /// alone would come back with nothing. Deliberately a **last resort**, consulted only when no
    /// gallery container matched at all: a page that has a gallery has the lot's own photographs in
    /// it, while everything else the page mentions — the site's logo, a promotion banner, a
    /// "recently viewed" strip, the neighbours a footer links to — belongs to somebody else and a
    /// vision model asked to price it will price it.
    var imageMetaSelectors: [String]

    // MARK: The lot's own page (the Open button, and the page reader)

    /// Where a lot's own page keeps the **description** of what is in the lot, most specific first.
    ///
    /// A card carries a teaser — "Pallet of General Merchandise" — so a text estimate built from the
    /// card is a guess about a guess. The page's description column is where the site prints the
    /// listing's real copy: brands, model numbers, counts, condition wording. The page reader takes
    /// the first selector that yields text, so the description block itself is listed before the
    /// column that contains it.
    var lotPageDescriptionSelectors: [String]

    /// The containers a lot's own page keeps its **gallery** in, most specific first.
    ///
    /// This is the whole of the page reader's image scope: the main slide, then the thumbnail strip.
    /// Everything the profile names contributes, in the order it is named and with addresses
    /// de-duplicated, so a gallery split across two elements — a main frame and a separate
    /// `ul.mediaThumbnails` — is read whole. Nothing outside these containers is looked at; see
    /// `imageMetaSelectors` for the last-resort case.
    var lotPageGallerySelectors: [String]

    /// Anchors on a card that point at the lot's own page, most specific first.
    ///
    /// Tried before the card's generic first anchor, which matters on a tile that also links to the
    /// auction, a wish list or a photograph: naming the lot-page pattern picks the right one out of
    /// them. The address is also what the page reader fetches when a lot is priced (deviation 15),
    /// so a profile that misses it costs more than a button — the scan falls back to card thumbnails.
    var detailLinkSelectors: [String]

    /// JS regex (case-insensitive) matching hrefs that are never a lot's own page.
    ///
    /// The site's own furniture rather than a lot: `#`, handlers and off-web addresses are rejected
    /// by the script itself, but sign-in, wish-list, share, basket and legal links are a fact about a
    /// site, so they are declared here. A rejected href is simply skipped in favour of the next
    /// candidate, which is what lets a card whose first anchor is a share button still open its lot.
    var nonLotHrefPattern: String

    // MARK: Lot status (sold / active)

    /// Selectors for the badge or status element a card carries once its lot is no longer biddable.
    ///
    /// Consulted before the card's own words on purpose: a short dedicated badge is what the site
    /// *means* by "sold", while a description may merely mention the word (see `soldTextPattern`).
    var lotStatusSelectors: [String]
    /// JS regex (case-insensitive, no capture group needed) that marks a lot sold.
    ///
    /// Applied to a short status element's text first and only then to the card's whole text, so
    /// listing copy such as "sold as one pallet" cannot retire a lot that is still taking bids.
    var soldTextPattern: String

    // MARK: Empty auction

    /// Selectors for the surface a catalog shows when an auction has no lots to bid on.
    ///
    /// Matching one of these (with `noResultsTextPattern`) lets a run stop on page 1 and say there
    /// are no active listings, instead of waiting out the card timeout and reporting a broken page.
    var noResultsSelectors: [String]
    /// JS regex matched against a candidate's text to confirm it really is the no-results message
    /// rather than, say, a "Results: 24 items" counter sitting in the same widget.
    var noResultsTextPattern: String

    // MARK: Authentication

    var loginFormSelectors: [String]
    var loginEmailSelectors: [String]
    var loginPasswordSelectors: [String]
    var loginSubmitSelectors: [String]
    /// Presence of any of these proves the session is authenticated.
    var authenticatedSelectors: [String]
    /// Captcha / MFA / challenge surfaces that must be solved by a human.
    var manualVerificationSelectors: [String]

    // MARK: Pagination

    var nextPageSelectors: [String]

    // MARK: Timing

    var loginTimeoutSeconds: Double
    var lotRenderTimeoutSeconds: Double
    /// How long one lot's own page is given to answer before the fallback to the card's thumbnails.
    var lotPageTimeoutSeconds: Double
    /// Pause between pagination DOM mutations; some sites animate the page swap.
    var settleDelayMilliseconds: Int
}
