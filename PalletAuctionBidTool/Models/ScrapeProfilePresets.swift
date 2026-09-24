//
//  ScrapeProfilePresets.swift
//  PalletAuctionBidTool
//
//  Ready-made selector strategies. Add a preset here to support a new auction site.
//

import Foundation

extension ScrapeProfile {

    /// Fully populated generic profile; the presets below derive from it so only the
    /// parts that differ per layout need to be declared.
    static func genericBase() -> ScrapeProfile {
        ScrapeProfile(
            name: "Generic liquidation grid",
            cardSelectors: [
                "[data-lot-id]", "[data-lot-number]", "[data-item-id]", "[data-lot]",
                "[class*='lot-card']", "[class*='lotCard']", "[class*='lot-item']",
                "[class*='lotItem']", "[class*='lot-tile']", "[class*='pallet-card']",
                "[class*='product-card']", "[class*='productCard']", "[class*='auction-card']",
                "[class*='listing-card']", "[class*='auction-item']", "[class*='card-body']",
                "li[class*='lot']", "article[class*='lot']", "article[class*='card']",
                "[class*='grid'] > [class*='card']", "[class*='grid'] > li",
                "table tbody tr", "[role='row'][data-row-key]", "tr[data-lot-id]"
            ],
            stopAtFirstMatchingSelector: true,
            excludeCardSelectors: [
                "nav", "header", "footer", "[class*='advert']", "[class*='banner']",
                "[class*='promo']", "[class*='recommend']", "[class*='related']",
                "[class*='newsletter']", "[class*='cookie']", "[class*='pagination']"
            ],
            minimumCardTextLength: 12,
            lotNumberAttributeCandidates: [
                "data-lot-id", "data-lotnumber", "data-lot-number", "data-lot", "data-item-id",
                "data-auction-id", "data-id"
            ],
            lotNumberSelectors: [
                "[class*='lot-id' i]", "[class*='lotnumber' i]", "[class*='lot-number' i]",
                "[class*='item-id' i]", "[class*='sku' i]", "[data-testid*='lot' i]",
                "[aria-label*='lot' i]"
            ],
            lotNumberRegexPattern: "(?:lot|item|pallet|sku|auction)\\s*#?\\s*:?\\s*([A-Za-z0-9][A-Za-z0-9\\-_.]{1,23})",
            // Read only after the real fields, the page text and the detail URL have all failed:
            // on many layouts the card's own id is an element address, not the printed number.
            lotNumberDOMIdAttributeCandidates: ["id", "data-key", "data-row-key", "data-testid"],
            lotNumberWrapperWords: [
                "itemmain", "item", "itemrow", "itemcard", "itemlisting",
                "lot", "lotrow", "lotcard", "lotitem", "lotmain",
                "auction", "auctionitem", "pallet", "palletcard",
                "product", "productcard", "listing", "listingcard",
                "card", "row", "grid", "tile", "main", "wrapper", "container", "sku"
            ],
            titleSelectors: [
                "h1", "h2", "h3", "h4", "[class*='title' i]", "[class*='name' i]",
                "[class*='headline' i]", "[itemprop='name']", "[data-testid*='title' i]", "a[title]"
            ],
            descriptionSelectors: [
                "[class*='description' i]", "[class*='desc' i]", "[class*='subtitle' i]",
                "[class*='sub-title' i]", "[class*='detail' i]", "[class*='brand' i]",
                "[class*='condition' i]", "p"
            ],
            bidSelectors: [
                "[class*='current-bid' i]", "[class*='currentbid' i]", "[class*='current_bid' i]",
                "[class*='bid-amount' i]", "[class*='bid' i]", "[class*='high-bid' i]",
                "[class*='price' i]", "[class*='amount' i]", "[data-testid*='bid' i]",
                "[itemprop='price']", "strong", "b"
            ],
            bidAttributeCandidates: ["data-bid", "data-current-bid", "data-price", "data-amount", "content", "value"],
            imageAttributeCandidates: [
                "src", "data-src", "data-original", "data-lazy-src", "data-lazy", "data-image",
                "data-image-url", "data-img", "data-thumb", "data-large_image", "data-zoom-image",
                "data-srcset", "srcset"
            ],
            maxCardImages: 4,
            imageMetaSelectors: [
                "meta[property='og:image']", "meta[property='og:image:secure_url']",
                "meta[name='twitter:image']", "meta[property='twitter:image']",
                "link[rel='image_src']"
            ],
            detailLinkSelectors: [
                "[class*='lot-link' i]", "[class*='lotlink' i]", "[class*='card-link' i]",
                "[class*='detail-link' i]", "[class*='detaillink' i]", "[class*='item-link' i]",
                "a[href*='/lot/' i]", "a[href*='/lots/' i]", "a[href*='/item/' i]",
                "a[href*='/items/' i]", "a[href*='/listing/' i]", "a[href*='/product/' i]",
                "a[href*='/auction/' i]"
            ],
            // The site's furniture, not a lot: the session's own pages, the wish list and share
            // buttons a tile carries, the legal pages, social hosts, and anything that is a file
            // rather than a page. Word-bounded so a catalogue's own paths are left alone.
            nonLotHrefPattern: "\\b(?:log-?in|log-?out|sign-?in|sign-?up|sign-?out|register|"
                + "cart|basket|checkout|account|profile|my-?account|watch-?list|favorite|favourite|"
                + "wishlist|share|print|privacy|terms|legal|cookie|help|support|contact|faq|about|"
                + "facebook|twitter|instagram|pinterest|linkedin|youtube|whatsapp|tiktok)\\b",
            lotStatusSelectors: [
                "[class*='sold' i]", "[class*='lot-status' i]", "[class*='lotstatus' i]",
                "[class*='lot-state' i]", "[class*='item-status' i]", "[class*='status' i]",
                "[class*='badge' i]", "[data-status]", "[data-lot-status]", "[data-state]",
                "[aria-label*='sold' i]"
            ],
            // Word-bounded so a nearby word ("unsold", "resold") is left alone, and the trailing
            // lookahead keeps catalog copy — "sold as one pallet", "sold in lots", "sold by the
            // pallet" — from retiring a lot that is still open. The negative lookahead is one of the
            // few places JS and ICU agree, so the harness can pin this exact rule (check 27).
            soldTextPattern: "\\bsold\\b(?!\\s*(?:as|in|by|per|with|separately|individually|together|at|on|for|from|off|singly))",
            noResultsSelectors: [
                "[class*='no-results' i]", "[class*='noresult' i]", "[class*='noresults' i]",
                "[class*='no-items' i]", "[class*='noitems' i]", "[class*='no-lots' i]",
                "[class*='nolots' i]", "[class*='empty' i]", "[class*='not-found' i]",
                "[class*='notfound' i]", "[class*='zero-results' i]", "[id*='no-results' i]",
                "[class*='alert' i]", "[role='status']", "[role='alert']"
            ],
            // The catalog this tool targets prints "Results: No Items Found."; the alternates cover
            // the other shapes liquidation sites use for the same message.
            noResultsTextPattern: "(?:no|zero)\\s+(?:items|results|lots|listings|products|auction items)"
                + "\\s*(?:were\\s+)?(?:found|available|listed|to show)?|(?:0|zero)\\s+(?:items|results|lots|listings|products)\\b",
            loginFormSelectors: [
                "form[action*='login' i]", "form[action*='signin' i]", "form[action*='sign-in' i]",
                "form[action*='auth' i]", "form[id*='login' i]", "form[class*='login' i]",
                "input[type='password']"
            ],
            loginEmailSelectors: [
                "input[type='email']", "input[name*='email' i]", "input[id*='email' i]",
                "input[autocomplete='username']", "input[autocomplete='email']",
                "input[name*='user' i]", "input[id*='user' i]", "input[name*='login' i]",
                "input[name*='account' i]", "input[type='text']"
            ],
            loginPasswordSelectors: [
                "input[type='password']", "input[name*='pass' i]", "input[id*='pass' i]",
                "input[autocomplete='current-password']"
            ],
            loginSubmitSelectors: [
                "button[type='submit']", "input[type='submit']",
                "button[id*='login' i]", "button[class*='login' i]", "button[name*='login' i]",
                "button[id*='signin' i]", "button[class*='signin' i]", "button[value*='login' i]",
                "form button:not([type])", "button[type='button']"
            ],
            authenticatedSelectors: [
                "[href*='logout' i]", "[href*='signout' i]", "[href*='sign-out' i]",
                "[id*='logout' i]", "[class*='logout' i]", "[class*='user-menu' i]",
                "[class*='account-menu' i]", "[class*='avatar' i]", "[data-testid*='account' i]",
                "[aria-label*='account' i]", "[aria-label*='user menu' i]"
            ],
            manualVerificationSelectors: [
                "iframe[src*='recaptcha' i]", "iframe[src*='hcaptcha' i]",
                "iframe[title*='challenge' i]", "[class*='cf-turnstile']", "[id*='captcha' i]",
                "[class*='captcha' i]", "[id*='otp' i]", "[name*='otp' i]",
                "[id*='mfa' i]", "[class*='two-factor' i]", "[class*='verification-code' i]"
            ],
            nextPageSelectors: [
                "[class*='pagination' i] a[rel='next']", "a[rel='next']",
                "[class*='pagination' i] [aria-label*='next' i]",
                "[class*='pager' i] [aria-label*='next' i]",
                "nav[aria-label*='pagination' i] a[rel='next']",
                "button[aria-label*='next' i]", "a[aria-label*='next page' i]",
                "[class*='next-page' i]", "[class*='page-next' i]", "[rel='next']",
                "[class*='pagination' i] li:last-child a",
                "[class*='load-more' i]", "button[class*='show-more' i]", "button[class*='view-more' i]"
            ],
            loginTimeoutSeconds: 45,
            lotRenderTimeoutSeconds: 20,
            lotPageTimeoutSeconds: 20,
            settleDelayMilliseconds: 900
        )
    }
}
