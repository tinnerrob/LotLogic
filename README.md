# TheLotLizard

**Crawl the lots. Snap up the profits.**

A native macOS app that scrapes liquidation-auction lot listings from a site you sign into,
appraises every pallet with a multimodal model (Gemini by default, DeepSeek Flash as an
alternative), and shows the numbers in one expandable table — so you can decide, before the
hammer falls, whether a lot is worth bidding on.

> The app is called **TheLotLizard**; the Xcode project, the target, the source folder and the
> bundle identifier all keep the name they were created with (`PalletAuctionBidTool`,
> `com.mFT.PalletAuctionBidTool`). That is deliberate and load-bearing: `UserDefaults` and the
> readings cache are keyed by bundle identifier, so renaming the bundle would take the operator's
> API keys, login and column choices with it. `PRODUCT_NAME` is what puts *this* name on the app the
> operator sees — the Dock, the menu bar, the window and the About sheet. See deviation 30.

* **Scrape** — a hidden `WKWebView` logs in with your credentials and walks the result pages you ask
  for (a count from the **Pages** menu, or **All pages**), harvesting lot numbers, titles,
  descriptions, current bids and photo URLs (the thumbnails a card
  carries; the photographs worth appraising are read off each lot's own page when that lot is
  scanned). The lot number is the
  one the site prints — a card whose only identifier is its own DOM element id (`ItemMain19002`) is
  reduced to the digits (`19002`) rather than shown as an element address.
* **Price on demand** — nothing is appraised behind your back. Every row carries **Eval**, **Price**
  and **Open**. **Eval** asks the provider one cheap question about the listing text alone (no
  photograph is fetched or billed, though the lot's own page is read once for its description column)
  and **Price** sends that lot's text *and* **every photograph in its own gallery** — the count is the
  lot's business, so the lot's page answers it instead of a
  setting — and **Open** puts that same page in a window over the table, for the photographs and the fine
  print nothing has to pay for. A **Price** is a *thorough* scan: each photograph is asked about on its
  own (`LotPhotoScan`), the reading is kept on this machine (`PhotoReadingStore`), and one last request
  reconciles the readings into the pallet's line items — so a small item in the corner of frame nine is
  priced rather than averaged away by the pallet in front of it, and re-scanning the same lot with the
  same model does not pay for the same photograph twice. **Photos / scan** in Run Tuning is the ceiling
  for a metered key; the toolbar has the same pair for every lot that has nothing yet.
  Either reply is constrained to a JSON schema, so the app gets numbers it can add up instead of
  prose — including `evidence`, the label wording or barcode digits each price was built from, since
  the app reads the barcodes and model numbers off the photographs itself before the model sees them
  (deviation 26). DeepSeek is asked twice per scan: once for the listing text, then again with the
  photographer's eye.
* **Decide** — the table rolls those items up into per-lot retail, resale, profit and ROI, sortable
  by lot, description, bid, retail, resale, profit or ROI in either direction, with a progress bar
  and activity console at the bottom. The table always fills the window, its column boundaries are
  drag-to-resize handlebars, and everything that is not the table's business lives in the window's
  unified titlebar — **Account** (`⌘,`), **Tuning** and **About** — rather than in the way of the
  rows.

---

## Build & run

```bash
open PalletAuctionBidTool.xcodeproj          # Xcode 26+, macOS 14+ deployment target
# or, from the command line:
xcodebuild -project PalletAuctionBidTool.xcodeproj -scheme PalletAuctionBidTool \
           -configuration Debug -destination 'platform=macOS' build
```

The project is Swift 6 with `SWIFT_STRICT_CONCURRENCY = complete`; it must build without
concurrency warnings. There are no third-party dependencies.

Verify the transports and the table's rules (quota retry, pacing, cancellation, request shaping, both
DeepSeek passes, how a lot's own gallery is attached and trimmed to one request's inline
budget, the description column reaching both the cheap and the thorough prompt, a whole thorough scan
driven end to end — one request per photograph, the readings reused from
the store on the second scan, and a failed reconciliation falling back to the on-machine merge — the
on-device label reader's rules for what counts as a barcode or a model number, every sort
field, the bid ceilings, the anchor threshold, the search matching, the
column geometry — including how it stretches to fill a wider window — the cleaning of scraped lot
numbers, the sold / empty-catalogue rules, the address of a listing's later result pages, and what the
progress readout counts — the pages a walk will read and the rows an appraisal covers)
without a key or any network traffic: it compiles the real services and the real UI-free models
against a stubbed `URLProtocol`:

```bash
./Tools/free-tier-harness/run.sh     # exits non-zero if any check fails
```

The injected page script has its own check: it compiles `ScraperScript` with the real selector
profile, dumps the generated JavaScript and runs it against a small DOM shim in Node — the
lot-number rules, the sold-badge / empty-catalogue rules, the addresses a listing prints for its
later pages and the parameter it numbers them with, and the reading of a lot's own page (a gallery
split between a main frame and a thumbnail strip, a strip photo repeated in both, a carousel of eight
thumbnails that must not become seventeen images, the live catalogue's own layout — one photograph
under one name at three sizes, `_s` / `_l` / `_xl`, each with its own `?ts=`, and a strip its
JavaScript builds from a data blob, with a neighbouring lot and the site's logo left out — a lazy-loaded
photo, a header logo and a promo banner that must be left out, the description column read with its
heading stripped, a page that declares its images only in a meta tag and a JSON blob, and a 404) are
all driven there (skipped, not
failed, when Node is absent):

```bash
./Tools/scraper-js-check/run.sh      # exits non-zero if any check fails
```

The brand images are generated too, for the same reason: the artwork export carries the design
tool's transparency checkerboard *in its pixels* and no alpha channel, so it cannot be dropped into
the catalogue as-is. `Tools/brand-assets` keys that checkerboard out, un-mixes the antialiased rim,
trims the empty margin the export carries and writes all three image sets. It is also the script to
re-run if the art is ever re-exported:

```bash
./Tools/brand-assets/run.sh [path/to/art.png]   # defaults to the export the assets were built from
```

The window is one column: a control panel, the lot table and the activity console, with the app's own
mark and name and its three buttons — **Account**, **Tuning** and **About** — in the unified titlebar
above them, and the run's progress in a modal that comes and goes with the work. A launch splash
covers the lot for a moment on the way in and dissolves into it (see deviation 31).

1. Launch the app.
2. Paste the **lot-list URL** (the page that already lists lots, e.g. `…/auctions?page=1`).
3. Optionally open **Account** (titlebar, or `⌘,`) and fill in **Site email / Site password** —
   leave both blank to scrape anonymously or to reuse the session already stored by the app.
4. In the same sheet, pick a **Provider** and paste its API key.
   **Gemini** (Google AI Studio) has a **free tier** that needs no billing account and costs
   nothing — see *Cost* below. **DeepSeek Flash** is the paid alternative: cheaper per token, but it
   draws on a prepaid balance. Each provider keeps its own key and model, so switching back and
   forth is free. The **Account** button in the titlebar wears an orange dot while the selected
   provider has no key, because nothing can be appraised without one.
5. Open **Tuning** if the defaults need changing — how many pages a run walks, how fast it may call
   out, how many of a lot's photographs a scan reads one at a time, and the bid percentages behind
   the **Max bid** column.
6. Press **Scrape Lots**. Pages stream into the table; no API call is made yet. An auction with
   nothing left to bid on stops on the first page and says **no active listings** — that is the
   catalogue's own answer, not a failure. Lots the site has already sold are listed too and flagged
   **Sold** in the **Active** column — a flag, not a lock: a closed lot's page still describes what
   was in it, so Eval and Price work on it like any other, and both all-lots passes include it.
7. Press **Eval all** for a cheap text-only figure on every lot, then **Price** the rows worth
   appraising — or **Price all** for the whole board — and sort the result by whichever number
   matters today. Drag a column's edge to resize it; the table always fills the window.

---

## Architecture

```
PalletAuctionBidTool/
├── TheLotLizardApp.swift           `@main`: the one window scene, its title (`Theme.appName`), its
│                                     default size and the trimmed menu
├── Models/
│   ├── AppSettings.swift            UserDefaults-backed operator input + validation
│   ├── ScrapedLot.swift             What one scraped card yields (+ resolved lot number, dedupe key,
│   │                                the site's sold marker and its status label)
│   ├── LotItem.swift                Observable row: scraped data + valuation + state
│   ├── LotNumber.swift              Cleans a scraped identifier: strips `Lot #`, unwraps DOM ids (UI-free)
│   ├── BidTargeting.swift           Bid ceiling per confidence + anchor-item threshold (UI-free)
│   ├── ColumnWidths.swift           Resizable column geometry and its clamping (UI-free)
│   ├── ColumnVisibility.swift       Which columns are drawn, and the names that persist (UI-free)
│   ├── LotSearch.swift              Lot-number-first search matching (UI-free)
│   ├── LotSort.swift                Sort fields + directions + the ordering rules (UI-free)
│   ├── PreviewSampleLots.swift      Debug-only fixture rows, so the populated table can be previewed
│   ├── DiscoveredItem.swift         One appraised item inside a lot
│   ├── PhotoReading.swift           What the model saw in ONE photograph — the unit a thorough scan
│   │                                is built from, plus its roll-up (`PhotoReadingSummary`)
│   ├── Formatting.swift             Currency / percent / geometry formatting helpers
│   ├── ScrapeProfile.swift          Declarative selector strategy (data, not code)
│   ├── ScrapeProfilePresets.swift   `ScrapeProfile.genericBase()` — the default strategy
│   ├── PaginationPlan.swift         The address of a listing's nth result page — an address in, an
│   │                                address out, so the walking rule is testable off-device
│   ├── RunProgress.swift            What the progress readout counts: the pages a walk will read and
│   │                                the rows an appraisal covers (UI-free)
│   └── ValuationProvider.swift      Gemini vs DeepSeek, with their models and settings labels
├── Services/
│   ├── ScraperScript.swift          Injected JavaScript (`window.__PAS`) automation — cards, and the
│   │                                reader for a lot's own page (`lotPageImages`)
│   ├── AuctionScraperService.swift  WKWebView host, JS bridge, login + pagination pipeline, lot-page
│   │                                fetch
│   ├── LotValuation.swift           Provider-independent layer: prompt, schema, decode, images
│   │                                (including the one-request inline budget), `ValuationService`,
│   │                                `RequestPacer`, `ValuationRetry`
│   ├── LotImageDigest.swift         On-device reading of the photographs: Vision barcodes plus
│   │                                identifier-shaped label text, handed to the model as literals
│   ├── LotPhotoScan.swift           The thorough pipeline: one request per photograph, readings
│   │                                reused from the store, one reconciliation, and the fallbacks
│   ├── LotPhotoScanPrompt.swift     The per-photograph and reconciliation prompts, the reading
│   │                                schema and its tolerant decode (`LotPhotoScanAnswer`)
│   ├── PhotoReadingStore.swift      Readings kept on disk, keyed by lot + model + prompt version
│   ├── GeminiValuationService.swift REST v1beta `:generateContent` client (schema-constrained)
│   └── DeepSeekValuationService.swift OpenAI-compatible `/chat/completions` client (json_object,
│                                    two passes: listing text, then photographs)
├── ViewModels/
│   └── AnalysisCoordinator.swift    @MainActor @Observable pipeline + progress/derived state, and the
│                                    per-action cache of each lot's page (gallery + description)
└── Views/
    ├── ContentView.swift            Layout: control panel, table, console — and the launch splash
    │                                over the lot of them
    ├── SplashView.swift             The launch splash: the brand art on a page of its own, for a
    │                                moment, then gone (see deviation 31)
    ├── ControlPanelView.swift       The titlebar (app mark and name, Account / Tuning / About) plus the
    │                                URL field, the run buttons and the auction page's info glyph
    ├── SiteSettingsSheet.swift      The modal behind Account: site login, provider, model, API key
    ├── RunTuningSheet.swift         The modal behind Tuning: run limits, then the bidding judgement
    ├── AboutSheet.swift             The modal behind About: the app's name and tagline over what it
    │                                does, and how to work it
    ├── SettingsFieldRow.swift       One labelled setting — the row every settings surface is built from
    ├── Theme.swift                  Design tokens: radii, paddings, chip/card fills plus the
    │                                `.cardStyle()` / `.chipStyle(tint:)` / `.microCaps(_:)` modifiers
    ├── LotTableView.swift           Toolbar (Eval all / Price all, sort, search, the columns
    │                                gear), table
    ├── LotTableRow.swift            Header (handlebar-resizable), lot rows, item rows, the buttons
    ├── BrowserPanelView.swift       Shows the real page (captcha / MFA hand-off)
    ├── LotPageSheetView.swift       A page as a sheet, behind a row's Open button and the panel's
    │                                info glyph — its own web view, the scraper's cookies
    ├── ResizableSheetWindow.swift   The one bit that makes a web-page sheet's window draggable, plus
    │                                the size both such sheets are built from (`WebPageSheetSize`)
    ├── LogConsoleView.swift         Folding activity console (folded, it shows the newest line; its
    │                                own chevron is the only control for it)
    └── ProgressSheetView.swift      The run's progress as a modal — bar, counters, the step the row
                                     in hand is on, that row's own money, and the Stop that ends it
├── Assets.xcassets/                 The brand images: `SplashArt` (light and dark), `AppMark` (the
│                                    lizard alone) and `AppIcon` — all three rebuilt from the artwork
│                                    export by `Tools/brand-assets` (see Build & run, deviation 31)
Tools/
├── free-tier-harness/               Offline harness: quota retry, pacing, both DeepSeek passes,
│                                    the table's ordering rules, bid ceilings, anchor flags, search
│                                    matching, lot-number cleaning, the sold/empty-catalogue rules,
│                                    what the progress readout counts (a walk's pages, an appraisal's
│                                    rows), column geometry — including stretch-to-fit — the column
│                                    chooser, the lot's own gallery being read and its images attached
│                                    and trimmed to one request's inline budget, the description column
│                                    replacing the card's teaser in both passes, the on-device label
│                                    reader, and a whole thorough scan driven end to end: one
│                                    request per photograph, the readings reused from the store on
│                                    a second scan, and a failed reconciliation falling back to the
│                                    on-machine merge (see Build & run)
├── scraper-js-check/                Runs the generated page script against a DOM shim in Node, so
                                     the lot-number *and* sold-badge rules are checked on the page
                                     side too — and so is the lot-page reader, with a `DOMParser` and
                                     a `fetch` standing in for the browser's: gallery containers and
                                     the junk outside them, a carousel of eight thumbnails read as
                                     eight addresses at the size each one opens, the live Magic Zoom
                                     layout (`_s`/`_l`/`_xl` of one photograph) and the strip that site
                                     builds in JavaScript, the site's own
                                     carousels and arrows left out, the description column, and the
                                     meta/JSON fallback
└── brand-assets/                    Rebuilds the three image sets in `Assets.xcassets` from the
                                     artwork export: it keys the export's own baked-in checkerboard
                                     out, un-mixes the antialiased rim, trims the empty margin the
                                     export carries, and writes the splash (light and dark), the
                                     titlebar mark and the ten icon sizes (see Build & run)
```

**Data flow**

```
AppSettings ──▶ AnalysisCoordinator.run()          (scrape only)
                     │
                     ├─ AuctionScraperService.scrape(...)  ──▶ ScraperEvent stream ──▶ rows appear
                     │        └─ window.__PAS.* (injected JS) ──▶ JSON strings ──▶ Swift decode
                     │
     Eval ───────────┴─▶ AnalysisCoordinator.prePrice(lot) ──▶ service.prePrice(subject)   (text only)
     row Price ──────┴─▶ AnalysisCoordinator.scan(lot) ──▶ makeValuationService(settings)
                     │        │
                     │        └─ window.__PAS.lotPageImages(url) ──▶ the lot's own gallery ──▶ the
                     │           (one GET, through the loaded listing)  + its description column   subject
                     │                                       │
                     │                                       ├─ LotPhotoScan.run(...)                (thorough)
                     │                                       │    ├─ PhotoReadingStore.readings(...) reuse
                     │                                       │    ├─ service.readPhoto(...)   one request/frame
                     │                                       │    ├─ PhotoReadingStore.store(...)    keep
                     │                                       │    └─ service.aggregate(...)  one reconciliation
                     │                                       │
                     │                                       ├─ GeminiValuationService.value(...)   (fallback, 1 pass)
                     │                                       └─ DeepSeekValuationService.value(...) (fallback, 2 passes)
                     └──────────────────────────────▶ ValuationOutcome ──▶ that LotItem only
```

The coordinator is the single source of truth for the UI. Every JS function returns a JSON
string so there is exactly one decode path on the Swift side; every payload is a `Codable`
struct declared next to the service that consumes it. Appraisal is never scheduled: a row's
**Eval** / **Price** buttons and the toolbar's two all-lots buttons are the only things that
call a provider. A lot handed to the coordinator already carries the number the site prints
(`ScrapedLot.resolvedLotNumber`), which is what the row, the log and the prompt all show.

---

## How one run works

1. **Open** — `startURL` is loaded in the web view with a desktop-Safari user agent; cookie
   storage is the shared default `WKWebsiteDataStore`, so a session survives across runs.
2. **Log in** — the injected script finds the site's own form (`loginFormSelectors`), fills it,
   submits, and then polls for proof of a session (`authenticatedSelectors`). If a captcha, MFA
   prompt or similar challenge is detected (`manualVerificationSelectors`) the run stops with
   `ScraperError.manualVerificationRequired` and the app opens the **live page** for you — see
   *Human-in-the-loop* below.
3. **Per page** — the script waits for lot cards *or* for the catalogue to say it has none. Cards
   are swept (lazy images, endless-ish lists) and every field extracted, including whether the site
   has marked the lot sold; `AuctionScraperService` keeps only lots whose `dedupeKey` is new — that key
   being the lot's own page when the card exposed one, and only otherwise its number, so two lots that
   print the same number on different pages are two lots. Each page says how many cards it found and
   how many were new, and names any card that yielded no lot or repeated one already on the board.
   Pagination is **by address first** — page 2 is the run's address carrying `?page=2`, page 3
   carries `?page=3`, and so on (`PaginationPlan`), using the site's own link for a page when it
   printed one — with a click of the site's own "next" control kept for listings that address
   nothing (**Load more**) and as the recovery when an address turns out to repeat a page already
   read. The walk ends when a page has no lots on it: the catalogue's own "no results" surface, a
   blank grid, the body of a 404, or a page whose signature has already been harvested. A page whose
   own "no results" surface matches (`noResultsSelectors` + `noResultsTextPattern`) ends the run
   instead of timing out: on page 1 that is reported as **no active listings**, not as a broken page.
4. **Scrape only** — the run ends there. Nothing is appraised automatically, so loading a board of
   200 lots costs nothing and touches no API key. The progress modal's bar measures the walk itself —
   pages read out of the pages this run is going to read — so three pages fill a third, two thirds,
   then all of it, and the run's own work is done at 100% ("Loaded 200 lot(s) — nothing scanned") until
   something is scanned. "The pages this run is going to read" is the smaller of the **Pages** budget
   and the listing's own count: asking for 1 page of a four-page listing is a one-page job, and both
   the bar and the pill say so (`page 1 of 1`). (An **All pages** walk of a listing that reports no
   page count has no honest denominator, so the bar spins instead: see `PageWalkProgress`.) The rows
   land one at a time: a page's cards come back in a single payload, so what the walk hands over —
   and what the table and the pill's lot count move on — is the app's own insertion of them, one
   `ScraperEvent.lotExtracted` per row, with a frame's worth between rows). The bar counts that too:
   it fills with the cards of the page being read, not only with the pages already read, so a **1 page**
   run creeps as the board fills instead of standing at nothing and then snapping to full
   (`PageWalkProgress.fraction`).
5. **Price a lot** — each row carries three buttons. **Eval** runs the cheap text-only pass: one
   request, no photograph fetched or billed, no line items, so the row keeps saying "not scanned"
   while its money columns show a provisional figure — the row's `provisional` flag and its italics
   are what say so. **Price** reads that lot's own page first — one GET, through the listing already
   loaded, so the results page never moves — and takes two things off it: the gallery, so the scan
   works from every photograph the lot shows rather than the card's thumbnail, and the description
   column, so the words the model reasons from are what the lot actually holds rather than the card's
   teaser. It then reads the lot *photograph by photograph*: every gallery image is downloaded
   concurrently and MIME-normalised, each one gets its own
   request (`inline_data` parts for Gemini, `image_url` data URLs for DeepSeek), and only then is the
   gallery reconciled into the pallet's line items in one further request. A card only ever shows
   thumbnails, so the lot's page is where the photographs are, and how many there are varies per lot:
   the page decides, not a setting (deviation 24) — **Photos / scan** then caps how many get the
   individual treatment, for a metered key. **Eval** reads the same page for the same reason: a
   text-only estimate is only worth anything if it is built from the listing's real copy, so it sends
   no photographs but the page's description, not the card's. **Open** is the same page in a sheet
   over the table — the
   photographs, the full description and the bid history, with nothing sent anywhere and with the
   run's session behind it, so it arrives signed in. Safari stays one click away in that sheet's
   header, and the sheet's own edges are drag handles — the page area opens at the size it always
   has and can be pulled out to whatever the photographs want. The toolbar does the same pair for
   every lot at once (**Eval all** / **Price all**),
   skipping only lots that already have the figure
   being asked for — a lot the site has marked sold is still priceable (deviation 22). Several rows
   may scan at once; outbound calls are spaced by the shared `RequestPacer` so
   **Requests / min** still means something during a batch. The table's toolbar also carries a
   **search** field (a lot number — `Lot #142`, `142` and `l142` all match — or any words from the
   listing), a **gear** that chooses which columns are drawn (**Active** is as optional as the rest;
   the chevron and the buttons are not, because a table that cannot price a row is not a table),
   and every column boundary in the header can be dragged: **Reset column widths** in the gear's menu
   puts them back. The column choice is the one view preference that outlives the window — it is
   remembered between launches, and a hidden column keeps its own width, so it comes back as it was
   left. The table is keyed on the columns being drawn, so flipping a switch rebuilds it outright
   rather than letting the header and the rows disagree about a layout that only exists at the
   window's width (deviation 23).

   **What the modal says while all that happens** is the readout's whole job, and it is drawn from
   the work in hand three times over. The pill names the job: a row's button names its row
   (`Evaluating Lot #19002`, `Pricing Lot #19002`, because that is whose figure it is), and an all-lots
   button counts its way through the rows it was built for (`Evaluating Lot #3 of 12`,
   `Pricing Lot #4 of 12`) — a batch's place is a position, never a board's lot number, since lot
   numbers do not run from 1. The line under the counters is the *step* the row in hand is on, and it
   moves with every request the appraisal makes: `reading the lot's own page`, `evaluating from the
   listing text`, `photograph 5 of 12`, `reconciling 12 reading(s) into the line items` — the events
   the thorough pipeline was already reporting, finally visible instead of only in the console
   (`AppraisalStep`). The bar counts the same way: a started step contributes a share of its row
   (a tenth for the page read and the text-only look, the bulk of it scaled by the row's own gallery,
   nine tenths for the reconciliation), so it creeps photograph by photograph and only reaches a row's
   whole share once that row is actually answered. And the money line at the bottom edge speaks for the
   row in hand — its open bid, its retail, its resale and the difference, taken from its valuation when
   it has one and from its text-only eval until then (`LotMoney.provisional` marks which) — because the
   board's totals are the wrong scope for it twice over: a single row's **Price** moved none of them,
   and an **Eval** run moved none of them either, an eval writing a provisional figure rather than a
   valuation. Nothing in hand (a fresh board, or a cleared one) falls back to the board's own totals,
   which is the only scope left to report.
6. **Roll up** — per lot: total retail, total resale, profit, ROI and a status badge. Each row also
   shows a **Max bid** — the highest bid worth placing, a tuned percent of the resale figure taken at
   the lot's *weakest* confidence level, and red once the live bid passes it. A ceiling that rests on
   an **Eval** rather than a **Price** is drawn in italics, so a first look never reads as a measured
   number. Expanding a row lists the appraised items — each with the label text, barcode digits or
   model number the price rests on under its name — and, for a lot that was read photograph by
   photograph, one line per frame saying what that frame showed (`photograph 3 of 12 — 4 visible ·
   $19 ea retail · sealed retail · front left`). That list is the point of the thorough scan: a figure
   can be traced back to a picture, and the frame that held nothing is listed as holding nothing
   rather than omitted. Any
   line at or above the **Anchor ≥** threshold (default $100) is flagged as an anchor. The progress
   modal shows live counters for the whole board, the step the row in hand is on, and that row's own
   open bid, retail, resale and profit as they land (deviation 29).

### How one scan works

A **Price** is a thorough scan, and the shape of it is the same on both providers — the provider only
supplies two things: how to ask about one photograph, and how to ask for the reconciliation.

1. **The gallery and the description are fetched.** The lot's own page is read for the containers the
   profile names as its gallery (deviation 24), the images are downloaded concurrently and
   MIME-normalised, and each is capped at 6 MB with
   the whole gallery capped by the request's inline budget. The same page read yields the listing's
   description column, which is what both passes reason from.
2. **A photograph at a time.** One request per photograph, carrying that frame alone, the listing text,
   and the app's own reading of *that* frame — barcode digits and printed identifiers included. The
   answer is a `PhotoReading`: what the frame showed, each product group with its location, packaging,
   condition, the units visible **from that angle** and the label wording it rests on. Requests are
   paced by the shared `RequestPacer` and run a few at a time (three by default), so a slow provider's
   latency is hidden without bunching calls.
3. **The readings are kept.** `PhotoReadingStore` writes them to `~/Library/Application Support`,
   under the bundle's own identifier (`com.mFT.PalletAuctionBidTool`) — not the name on the tin,
   which is a label rather than an address — keyed by lot number, model and prompt version. The next
   scan of that lot with that model restores
   them and re-reads only the photographs it has never seen — so **re-scanning costs the
   reconciliation, not the gallery**, and changing model, or suspecting a bad read, is what the
   settings modal's **Forget** button is for.
4. **One reconciliation.** A single request (no photographs unless **Photos / scan** left some out)
   folds the readings into the pallet's line items, with the quantities and totals that belong to the
   whole lot: three photographs of the same six cartons are six cartons, not eighteen.
5. **Two fallbacks, both cheaper than failing the lot.** If the reconciliation request fails, the
   readings are merged on this machine (`PhotoReadingMerge`) — the photographs that were paid for are
   not thrown away. If nothing could be read individually at all, the scan falls back to the
   single-pass appraisal below, which is exactly what a scan was before this pipeline existed.

What a scan never does is drop a photograph: a ceiling (`Photos / scan`, default **All photographs**)
decides how many frames get the individual treatment, and the rest travel with the reconciliation
request as images — so a low ceiling makes the line items coarser, never the pallet smaller.

| Provider | Requests per lot | Shape |
| --- | --- | --- |
| Gemini | 1 + n | One request per photograph (`n`), then one `responseSchema`-constrained reconciliation |
| DeepSeek | 1 + n | One request per photograph (`n`), then one `json_object`-mode reconciliation |

The single-pass appraisal is still there, and it is what the fallback runs:

| Provider | Requests per lot | Shape |
| --- | --- | --- |
| Gemini | 1 | One multimodal call: listing text + photographs, `responseSchema`-constrained |
| DeepSeek | 1–2 | Pass 1 reads the listing text alone; pass 2 reads the photographs with pass 1's JSON draft as prior context and is told to correct it |


DeepSeek's split is deliberate, and it is the reason it costs roughly twice as much per lot: the
model reads a product from a photograph measurably better when it already knows what the listing
claims is in the pallet, and separating the two stops a mis-read quantity in the text from being
copied straight into the answer. The passes degrade sensibly: a lot with no listing text uses one
pass, a lot with no readable photograph uses one pass, and if the photograph pass fails outright the
text pass's answer is kept rather than failing the lot (the row's expanded detail says how many
passes produced the numbers).

**How many photographs travel** is the lot's own business, and the app asks the lot: **Price**
fetches the lot's page and attaches the gallery it carries, along with the description column that
both passes reason from. What can still hold an image back is technical
rather than editorial — one photograph over 6 MB, or a whole gallery over the 12 MB budget a single
request is allowed (base64 inflates the payload by about a third, and the providers cap it) — and
anything held back is *counted*: the console says `40 of 46 image(s), 6 over the inline budget`
instead of quietly reporting forty, and `ValuationOutcome` carries the three numbers the row and the
log are built from. If the page cannot be read at all (a challenge, a 404, a gallery rendered only in
JavaScript), the card's thumbnails and its teaser stand in and the log says which happened — a scan
never fails over a page that will not read.

**The photographs are read twice, and the first reading is free.** Before anything is uploaded,
`LotImageDigest` runs Vision over the same images on this machine: `VNDetectBarcodesRequest` decodes
the barcodes the way a till does — from the bars — and `VNRecognizeTextRequest` reads the printed text
off labels, cartons and shelf tickets, and both are filtered down to what looks like a catalogue
identifier (a model/part/SKU number, or a GTIN of 8-14 digits; a voltage, a pack size or a printed
total is not one). Up to a dozen photographs are read, and the literals that come out — `Decoded
barcodes: 0123456789012`, `Printed identifiers: DCS620D, 4711` — are handed to the model as an
*already verified* reading, because the two things that pin a pallet's price to one exact product are
the two things a general vision model reads worst off a photograph. The prompt then asks for the
consequence: price the product the barcode or model number names rather than a category average, and
quote that identifier in each line's **`evidence`**, a new field that says what the figure rests on —
`label reads "Yankee Candle 22 oz" · UPC 609032993551`. It is drawn under the item's name when a row is
expanded, so a claimed price can be checked against the picture, and the reader's own findings land in
the console (`Lot 142: label reader read barcode(s) 0123456789012 · identifier(s) DCS620D`) even when
the model's answer is thin. Nothing legible is a normal outcome, not a failure: a pallet of loose goods
usually has no label worth reading, the row's evidence line is simply absent, and the appraisal is the
one it would have been without any of this. The pass is on-device, key-free and costs local time
rather than money: at most twelve photographs are looked at, barcode decoding runs on all of them
because it is cheap, and text recognition stops as soon as a few identifiers have been read, because
the other twenty angles are the same cartons.

Robots.txt, rate limits and each site's terms of use are your responsibility. The tool is
deliberately gentle: one page is fetched at a time (never parallel requests to the auction host),
and it stops as soon as a page comes back with no lots on it. **All pages** means exactly that —
it follows the pagination to the end — with a 100-page guard left in place so a catalogue that
paginates for ever cannot hold a run open.

### Human-in-the-loop

A hidden web view cannot be clicked, so the app hands the real page back to you:

* A challenge opens the live page by itself: the run reports it and the sheet comes up. That sheet is
  the scraper's *own* `WKWebView` — the *same* instance the automation is driving, cookies included —
  reparented into a window whose edges are drag handles, so a challenge screen can be given the room
  it needs.
* The **info** glyph beside the URL field opens a page as well, and it is the reading one: the address
  in the field, in a second web view on the same cookie jar (see the note on the row's **Open** button
  under deviation 17). Signing in there once is enough — every later run inherits the session — and
  nothing about a run in flight changes.
* Solve the captcha / enter the MFA code in whichever sheet came up, press **Done**, then **Scrape
  Lots** again. Because the app reuses one web view and one data store, the run resumes authenticated.
* The automation keeps running while a sheet is open, so page logs stay live in the console.


---

## Session, credentials and keys

| Value | Where it lives | Notes |
| --- | --- | --- |
| Auction URL, tunings, provider, model IDs | `UserDefaults` | Written when a run or a scan starts. |
| Site email / password | `UserDefaults` | **Plaintext caveat — see below.** Edited in the Account sheet (⌘,). |
| Gemini API key | `UserDefaults` | Sent as the `x-goog-api-key` header, never in a URL or a log line. |
| DeepSeek API key | `UserDefaults` | Sent as `Authorization: Bearer …`, never in a URL or a log line. |
| Site login cookie | `WKWebsiteDataStore.default()` | App container; persists between launches. |
| Scraped lots / valuations | memory only | Nothing is written to disk; quitting discards results. |
| Per-photograph readings | `~/Library/Application Support/<bundle id>/PhotoReadings/` | One JSON file per lot, keyed by model + prompt version, so a re-scan reuses what it already paid for. Cleared from the Account sheet's **Forget** button. `<bundle id>` is `com.mFT.PalletAuctionBidTool` — the bundle's own address, which is what the app is *built* as, not the name it prints (see deviation 30). |
| Which columns the table shows | `UserDefaults` | Written the moment a column is hidden or shown in the table's gear, so the choice survives a relaunch. Only that key is written — see deviation 23. |

**Known caveat:** credentials and the API keys live in `UserDefaults`, which is not an encrypted
store. That is acceptable for a single-operator local tool, but it is *not* appropriate for a
shared or distributed build: move the values into the Keychain before shipping this to anyone
else. The scaffolding is already narrow — `AppSettings.persist()` is the only write path, and each
key is read in exactly one place (`GeminiValuationService.init` / `DeepSeekValuationService.init`).

---

## Cost: the free tier, and why the app does not drive a web UI

**Free is supported.** A Gemini API key from Google AI Studio with no billing account attached
drives the exact same `:generateContent` endpoint this app already uses: same models, same
multimodal input, same JSON contract. Nothing in the code changes and nothing is skipped — you
just operate inside the project's rate limits instead of the paid ones (open
[AI Studio → Rate limits](https://aistudio.google.com) to see your project's actual numbers, or
`ai.google.dev/gemini-api/docs/rate-limits` for the published tiers).

Three controls keep a free-tier run from failing lots:

| Control | Behaviour |
| --- | --- |
| **Requests / min** (run tuning, default `10`) | Upper bound on outbound calls per minute. `RequestPacer` is a single shared actor, so concurrent lots queue for the next slot instead of bunching. Set it to `0` / "off" to disable pacing. |
| **Photos / scan** (run tuning, default **All photographs**) | How many of a lot's photographs are read one at a time, and therefore how many requests a **Price** costs. A ceiling reads the first *n* frames individually and still sends the rest with the reconciliation — coarser line items, never a smaller pallet. |
| **429 retry** | A refusal is waited out, not failed: the delay comes from the `Retry-After` header, else from the `RetryInfo.retryDelay` in Google's error body (`"17s"`), else from exponential back-off with jitter. Up to 4 attempts per request. DeepSeek sends no delay hint, so it always uses the back-off. |
| **Stop** | Cancellation during a back-off ends the run immediately — a quota pause never holds the app hostage. |

On a free tier, remember that a **Price** now costs one request per photograph plus the
reconciliation. **Eval all** first is still the cheapest way to find the lots worth photographing, and
**Photos / scan** is the dial that turns a board of forty-frame lots into something a per-minute quota
can actually absorb. Readings already on this machine are reused, so re-pricing a lot after a tuning
change does not re-read its gallery.

Cheapest useful configuration: `gemini-2.5-flash-lite`, **Eval all** before any **Price**, and a
**Requests / min** you have watched one run of. The run log states the pacing it applied, so a slow
run is explained rather than
mistaken for a hang. If a run *does* exhaust the quota, the affected rows show
`rate limited` and the console carries the API's own message.

### The paid alternative: DeepSeek Flash

| | Gemini `gemini-2.5-flash` | DeepSeek `deepseek-flash` |
| --- | --- | --- |
| Free tier | **Yes** (AI Studio key, no billing account) | No — prepaid balance |
| Images | Yes (`inline_data`) | Yes (`image_url` data URLs) |
| Output contract | `responseSchema` — the model *cannot* emit prose | `json_object` only; no strict schema |
| Metering | Requests per minute (daily caps too) | Concurrency (2500 in flight), 429 above it |
| Cost per 1M tokens | Free tier, then paid tier | ~$0.15 in / $0.60 out off-peak, 2× at peak |

DeepSeek is the fallback when you want to stop thinking about per-minute quotas, and it is cheap
enough that a full board of lots costs cents. Three things to know before selecting it:

* **It costs about twice Gemini per lot, by design.** Each DeepSeek lot is appraised in two passes
  (listing text, then photographs seeded with that first answer), so budget two requests per lot.
  See *How one scan works*.
* **The output contract is weaker.** DeepSeek has JSON mode but no schema mode, and it warns that
  JSON mode "may occasionally return empty content". The app compensates by rendering the *same*
  schema Gemini enforces (`LotValuationPrompt.itemsSchema.jsonSchemaText`) into the prompt, decoding
  tolerantly, and re-asking once when the answer comes back empty — see deviation 10. Expect the
  occasional Low-confidence guess where Gemini would have been pinned.
* **Only `deepseek-flash` is offered,** because it is the only DeepSeek model that declares image
  input. `deepseek-v4-pro` is text-only, and silently appraising photos from listing text alone is
  worse than not offering it.

**Requests / min does not apply to DeepSeek the same way** — it meters concurrent requests, not
requests per minute, so leave the pacing at `10` only if you want a gentle run; setting it to
"off" is safe there. Thinking mode is turned off explicitly (`reasoning_effort: "none"`), because
its documented default is `high` and reasoning tokens are billed as output.

### What this app will not do: automate google.com's "AI Mode" or gemini.google.com

Prompting a browser tab the way a human would is not a cheaper path to the same result — it is a
different, broken thing:

1. **The images would be lost.** Valuation depends on sending the pallet photos. A web UI accepts
   images only through an `<input type="file">`, and browsers deliberately refuse to let script
   populate a file input: `input.files` is read-only and a genuine `File`/`DataTransfer` cannot be
   synthesised from page JavaScript. The injected automation physically cannot attach the photos,
   so valuation would degrade to text-only — the exact thing the photos exist to fix.
2. **It breaks the contract.** The REST path hands the model a schema and gets strict JSON back.
   A web UI answers in prose behind generated class names and streamed shadow-DOM nodes, so
   confidence values, per-item structure and the error taxonomy would all have to be re-derived
   from rendered markup that changes without notice.
3. **It puts your account at risk.** Automating Google Search/Gemini front ends is against their
   terms and is what abuse systems are built to catch; the failure mode is a blocked account or IP,
   not an error message.

So: "free as in no billing account" is a supported, documented mode. "Free as in no API key, by
driving a consumer web page" is not, deliberately.

---

## Deliberate deviations from the original brief

1. **No `GoogleGenAI` Swift SDK.** There is no supported Swift package for the Gemini API, so the
   client is a direct REST implementation against `v1beta` (`:generateContent`) on `URLSession`.
   Rationale: one fewer dependency to pin, and the request/response shapes are small enough to
   model explicitly with `Codable`.
2. **`gemini-2.5-flash`, not `gemini-1.5-flash`.** `1.5-flash` has been retired; the default is
   now `gemini-2.5-flash` (`GeminiValuationService.defaultModelID`), with `gemini-2.5-flash-lite`
   also offered. Both are multimodal, which the valuation step requires.
3. **No `Image(jpegData:)`.** That initialiser does not exist in SwiftUI on macOS, so image bytes
   reach Gemini as base64 `inline_data` parts instead of travelling through a SwiftUI image type.
4. **Schema-constrained output.** Responses are pinned with `response_mime_type: application/json`
   plus a `responseSchema`, so the model cannot answer with prose that would break decoding.
   `ResponseSchemaNode` builds that schema in Swift.
5. **Hand-built table, not SwiftUI `Table`.** `Table` cannot express hierarchical expand/collapse
   with per-row status badges, so the table is a `LazyVStack` of rows sharing the `LotColumn`
   geometry constants with the header — which also keeps header and body aligned.
6. **Pagination by address, with a click as the fallback.** A page is asked for the way the listing
   numbers it: page 2 is the run's address carrying `?page=2`, page 3 carries `?page=3`, and so on,
   and the walk stops at the first page that has no lots on it. `PaginationPlan` rewrites the
   parameter the site was *seen* using (its own page links are read for the name, in the same breath
   as the page count), so a catalogue paginating `?paged=` is never handed a `?page=` it would ignore,
   and an already-numbered address has its number replaced rather than duplicated. A listing that
   *prints* an address for the page — a numbered strip, a `rel="next"` link — is asked with that
   address first (`window.__PAS.pageAddress(n)`), which is the only thing that covers a path-shaped
   pagination (`/page/4`) the app could never guess; an address is only followed when its path is the
   listing being walked's own, so a "related auctions" strip one column over cannot redirect the walk
   into a different catalogue. Clicking the site's own "next" control survives
   for the listings addresses cannot move at all (**Load more**, form posts) and as the recovery when
   a loaded address repeats a page already read — a client-side router ignoring the parameter, or a
   site clamping every high number to its last page — which is detected by comparing the page
   signature against the ones already harvested. This replaced a walk that *only* clicked: on this
   catalogue, whose pagination is a strip of numbers with no `rel="next"` anywhere, the label rules
   found no next control and the run stopped after page 1 with "No next-page control was found" while
   `?page=2` sat in the markup.
7. **The page budget is a menu of counts, and it reads the listing's own length.** `Pages` offers
   1, 2, 3 … up to whichever is largest of ten, the count the listing reported on the last run, and
   the budget already in force, plus **All pages**. The count comes from `window.__PAS.pagination()`:
   the highest page number in the catalogue's own page links first, then the "page 3 of 24" (or
   "1–24 of 480") it prints in words, and `null` when the site says nothing — a "next"-only listing,
   which **All pages** handles regardless. This replaced a stepper capped at ten, on the grounds that
   a listings site with more than ten pages is ordinary and a menu must not silently truncate it:
   `ScrapeLimits.maximumPages` is now a 100-page runaway guard rather than a target, and
   `AppSettings.effectivePageLimit` clamps to it, so the menu, the JS loop and the service still
   cannot disagree about the ceiling. **All pages** is `pageLimit == 0` — one marker rather than a
   second setting — and the reading is best-effort: it never costs a request, and a site that does
   not advertise a count simply leaves the menu offering the counts it can.
8. **Pacing on by default (`Requests / min` = 10).** On a free-tier key an unbounded burst burns the
   per-minute quota and fails lots, so outbound calls are spaced by a shared `RequestPacer`
   and quota refusals are retried. Set the control to "off" to get the original unbounded
   behaviour back. The batch width that used to be a second control here is now
   `AppSettings.batchConcurrency` (3).
9. **Two providers behind one protocol, not one hard-coded client.** `ValuationProvider` selects
   between Gemini and DeepSeek Flash, and everything that is not wire format (prompt, schema,
   decode, image loading, pacing, retry) lives in `LotValuation.swift`. The coordinator only ever
   sees `ValuationService`, and `makeValuationService(settings)` is the single construction point,
   so a third back end is a conforming type plus one `case`.
10. **DeepSeek's missing strict-schema mode is compensated for rather than accepted.** DeepSeek
    offers `json_object` mode and nothing stronger, so the schema Gemini enforces
    (`LotValuationPrompt.itemsSchema`) is rendered to plain JSON Schema
    (`jsonSchemaText`) and embedded in the prompt, `ValuationPayload` decodes tolerantly, and an
    empty answer — which DeepSeek's own docs warn about — is re-asked before the lot is failed.
    One schema definition, two renderings, so the providers cannot drift.
11. **`:generateContent`, colon included — and that colon is load-bearing.** Google's routing is
    `models/{model}:generateContent`; the colon is part of the method name, not a separator, so the
    URL is assembled as a string rather than with `appendingPathComponent(_:)`, which would emit
    `/generateContent`. Verified against the live endpoint without a key: the slash form answers
    **HTTP 404 with an empty body**, the colon form answers a routed `403 PERMISSION_DENIED`
    ("please use API Key"). The harness asserts the colon form, because a 404 here reads like a bad
    model ID and would have every lot fail with `HTTP 404: no details`.
12. **Appraisal is manual, per row, instead of an automatic pass over the whole board.** A run now
    only scrapes; a lot is priced when its **Eval** or **Price** button is pressed, or when
    one of the toolbar's two all-lots buttons is. Rationale: the brief's "value every lot" spends a
    request on every row of a 200-lot page before the operator has seen a single bid, and most rows
    are never worth opening. Nothing else changed: the same
    `valuate(_:using:concurrency:)` task group drives both **Price all** and the old
    automatic pass, `AppSettings.batchConcurrency` still bounds it, and **Stop** still cancels
    everything in flight
    — a cancelled row simply returns to "not valued".
13. **DeepSeek is asked twice per lot, on purpose.** The first pass reads only the listing text; the
    second reads the photographs with that first answer attached as a draft to correct. It doubles
    DeepSeek's per-lot cost, and it is a deliberate trade: the text pass supplies quantities and
    product families that a photograph cannot show (what is *inside* a sealed carton), and the
    photograph pass keeps the text pass honest about what is really on the pallet. Degrade paths are
    explicit — no text or no readable photo means one pass, a failed photograph pass falls back to
    the text answer, and `ValuationOutcome.passes` records which happened so the row can say so.
14. **Sorting is a model type, not view code.** `LotSort`, `SortDirection` and `LotOrdering` live in
    `Models/LotSort.swift` with no SwiftUI import, so the offline harness compiles the *real*
    ordering rules and checks every field/direction combination. Two rules there are worth
    knowing: values sort naturally (`Lot 2` before `Lot 10`), and a missing value — ROI before a lot
    has a bid — always sorts last in both directions rather than pretending to be the best or worst.
15. **The bid ceiling, the anchor flag, the search and the column geometry are models too.**
    `BidTargeting.swift`, `LotSearch.swift`, `ColumnWidths.swift` and `ColumnVisibility.swift` hold
    the arithmetic, the matching, the clamping and the column choice, and none of them imports
    SwiftUI (or Foundation), so the harness compiles them and
    pins the rules: a lot is judged at its *weakest* line item's confidence (one shaky row is enough
    to sink a pallet), a lot carrying only an eval is judged at `Low` and flagged provisional rather than
    presented as appraised, a `$0` line is never an anchor however low the bar goes, `"Lot #142"`,
    `"142"` and `"l142"` all find lot 142, and a dragged column cannot go under 48pt or past 420pt.
    Three tables (`LotTableHeader`, `LotTableRow`, `DiscoveredItemRow`) share one `ColumnWidths`
    value, which is what keeps the header aligned to the rows it labels. `ColumnWidths.filling(_:)`
    adds the second half of that geometry: given the scroller's width it hands back the widths to
    draw at, stretching the thirteen data columns proportionally when the window is wider than the
    table and returning the stored layout untouched when it is not.
16. **A cheap text-only pass runs before the photographs, unconditionally.** An unscanned lot is
    asked about its listing copy first,
    so the table can show a provisional **Max bid** while the photographed price is still queued.
    The estimate deliberately touches no line items, no totals and no `analysisState`: the row keeps
    saying "not scanned", renders its provisional figures in italics, and a real valuation retires
    them (`applyValuation` calls `clearPrePrice`). The alternative — leaving the money columns blank
    until the expensive pass lands — wastes the one thing the operator already paid for: the
    listing text. This used to be a **Text-only first look** switch beside **Eval** in Run Tuning;
    the switch asked the operator to weigh a trade the app is better placed to answer (a row with no
    figure wants the cheap pass), and **Eval all** remains for pricing a board with no photographs
    at all.
17. **Three buttons per row: Eval, Price and Open.** **Eval** and **Price** are separate purchases, so
    they are separate buttons rather than one button with a mode. An eval prices a whole board for
    less than one photographed price, which is what lets the operator choose which lots deserve
    images; the photographed figure is what the bid ceiling should really rest on. The automatic pass
    of deviation 16 rides along in front of a scan and stands aside for a row that already has
    numbers; a click on **Eval** is already an explicit request, so it always runs. The button is
    greyed out for a lot that has
    been appraised already, because provisional figures are hidden behind a valuation: the request
    would buy a number nothing shows. (**Eval all** makes the same call per lot, so pressing it twice
    cannot pay twice.)
    The vocabulary is worth stating, because the code and the console still say "pre-price" where a
    *pass* is meant rather than a button: `prePrice(_:)` and the
    `prePricePrompt` are the machinery behind **Eval**, and a figure that came from it is a
    *provisional* one. What the operator clicks is never labelled with the machinery's name.
    **Open** is the third button and the only one that spends nothing: it shows the lot's own page in
    a sheet over the table. The lot number in the table is a second target for the same page, but that
    is a data column — an operator working down the buttons is not looking at it — and the button is
    drawn only for a lot whose card exposed an address, rather than as a permanently dead control. The
    number is not marked as clickable either: an arrow glyph on the end of it only crowded the column's
    one job, being read, while **Open** already says where a row's photographs are. It is announced the
    way the rest of the table is — the row's hover highlight, and a tooltip naming the lot — because
    the number is a shortcut for the operator who already knows it is there. The address behind either
    one is read off the listing the way the operator would find it by
    hand, and from four sources in order of quality: the anchors `detailLinkSelectors` names, then the
    card's own first usable anchor, then the anchor the matched card *lives inside* (a card selector
    often matches the inner body of a tile whose link wraps the whole thing), and finally — once the lot
    number is known — any anchor whose address carries that number, first around the card and then
    anywhere on the page.
    That last source is what makes the button appear on a catalogue whose cards are not links at all
    (`<div onclick>`, a JavaScript router): the number the card prints is in the address of the page
    it belongs to, and that address *is* on the listing, because the listing is what the app scraped.
    Addresses that are not a lot page — a `#`, a handler, a photograph, a sign-in or share link, a
    *different* lot whose number merely starts the same — are rejected in favour of the next candidate,
    and which addresses those are is profile data (`nonLotHrefPattern`), not code. A row the listing
    gave nothing for keeps two buttons, and the log says how many did: `Page 1 extracted: +24 row(s)
    …; 24/24 with a lot-page address`.
    It is *not* the live **Page** panel, and it is no longer the operator's browser either. That
    panel reparents the scraper's live `WKWebView` (deviation 19's captcha hand-off), so pointing it at
    a lot would take the automation off the results page it is working on. A browser tab was the old
    answer to that, at the price of leaving the table — and of opening into whichever window was in
    front, on top of the lot the operator was comparing. `LotPageSheetView` is the third option and the
    one actually wanted: a *second* web view on the same default `WKWebsiteDataStore` the scraper uses,
    so the page arrives signed in with the session the run just earned, the automation's page never
    moves, and a challenge cleared in the sheet counts for the next run as well. The control panel's
    **info** glyph is this sheet again — the same code path, pointed at the auction address in the URL
    field rather than at a row — which is what replaced the old **Page** button's reparenting of the
    live page. Safari is still one
    click away — **Open in Browser** in that sheet's header — for printing or a site that misbehaves
    in a web view, so the old behaviour became a choice rather than a dead end. The sheet can be dragged
    to the size the page wants, which is not something a SwiftUI sheet does on its own: one arrives as
    a title-bar-less `docModal` window with no `.resizable` in its style mask, and SwiftUI rewrites
    the window's own minimum and maximum on every layout pass, so the content adds the missing bit to
    that mask itself (`resizableSheetWindow()`) instead of giving up `.sheet(item:)` and
    reimplementing **Done** and the escape key for a hand-hosted `NSWindow`. A gallery, a long
    description and a bid history are read rather than glanced at, so the same opening size and the
    same drag apply to the live **Page** panel too — one value, `WebPageSheetSize`, for both sheets. The
    three of them are
    fixed chrome in a column of their own — `LotColumn.scan`, untitled (`LotColumn.scanTitle` is empty:
    three labelled buttons do not need a legend over them, and the header still draws a cell of that
    width to lay them out under) — because a table that cannot price a row is not a table, and their
    width is fixed rather than draggable: buttons are not
    numbers, and the widest state of the trio (**Re-eval** / **Re-price** / **Open**) is 225 of its
    246 points.
18. **A card's DOM `id` is not a lot number.** Plenty of layouts put the only handle they expose on
    the card element itself, and it is an element address: `ItemMain19002`, `item-row-88`,
    `data-key="ItemMain19002"`. Feeding that to the table, the log and the prompt made the row read
    `ItemMain19002` where the catalogue says `19002`. The profile now lists real lot-number fields
    first and keeps the DOM id in `lotNumberDOMIdAttributeCandidates`, consulted only after the
    fields, the page text and the detail address have all failed; `LotNumber` then reduces a
    wrapper-plus-digits value to its digits (`ItemMain19002` → `19002`) and strips printed labels
    (`Lot #142`, `Item No. 88` → `142`, `88`). A genuine SKU such as `ABC123` or `L208` is left
    alone — only a *known* wrapper word followed by digits is unwrapped — and a card that still has
    nothing borrows the number from its own deep link before falling back to a content hash. The
    same rule is applied on the page side, so `ScrapeProfile` carries the wrapper-word list too.
    Two rules that could each retire a lot in silence are settled with it, because together they are
    how a board came back **one short of the listing** with nothing anywhere to explain it. The word
    floor in `collectCards` / `readCard` dropped a compact tile that carried a lot number but said
    little, and the dedupe — keyed on the resolved number *alone* — dropped the second of two lots that
    print the same number on different pages. Neither was visible: `cardCount` counts the same set the
    floor does, and a suppressed duplicate was never mentioned. Now the floor admits any tile carrying
    a lot number (`lotSignalAttributes`, or a DOM `id` that unwraps to one), the dedupe keys on the
    lot's own page and falls back to the number only when the card exposed no page, and every page
    names whatever it did not turn into a row. Both halves are pinned offline: the harness checks that
    one lot page linked two ways is one lot, and that two lots printing the same number on different
    pages are two lots.
19. **The window's own titlebar is the app's chrome: Account, Tuning and About.** The panel used to
    carry three stacked rows above the table — a title row with the app's mark, a readiness pill and a
    gear, the URL row, and a folding **Run Tuning** card — and all of it came out of the height a
    hundred-row table actually needs. The title row is now the window's *own* titlebar: a SwiftUI
    toolbar sits where the traffic lights already live, and `windowToolbarStyle(.unified(showsTitle:
    false))` drops the system title so the app's icon and name are drawn there instead of two titles
    fighting. Three menus live at the bar's *trailing* edge. Landing them there took
    `ToolbarSpacer(.flexible)` (macOS 26, with the macOS 14–15 fallback of a plain `.primaryAction`
    group): on macOS 26 a trailing group on its own is laid out where the leading content ends, so
    the trio read as "next to the title" rather than "the window's buttons". The name is a label and
    not a control, so it opts out of the shared glass background macOS 26 puts behind every toolbar
    item (`.sharedBackgroundVisibility(.hidden)`) — the capsule behind a title is chrome for nothing.
    The menus then had to draw their own chrome too: macOS 26 *ignores* `buttonBorderShape` on
    toolbar buttons, so a squared-off corner means the same opt-out plus a `ButtonStyle` that owns the
    fill, the corner (5pt — a capsule is nearly half the button's height), the hairline and the hover
    and press states, rather than trying to reshape the system's. **Account** (`⌘,`) is the old gear,
    unchanged behind the glass: `SiteSettingsSheet` still holds the site email and password, the
    provider, the model and the provider's own key, and its tooltip carries the summary line the
    folded card used to print ("no site login · Gemini · gemini-2.5-flash · no key") — the move must
    not hide *which* provider is armed or whether it has a key, because those two facts decide
    whether the table's **Eval** and **Price** buttons do anything. The gear's orange dot came back
    for the same reason: with a tooltip and a button that say nothing at rest, the dot is what warns
    that no key is set and nothing can be scanned. **Tuning** opens `RunTuningSheet`, which is the
    folding card's contents as a modal — the run's limits (`Pages`, **Requests / min**,
    **Photos / scan**) over a hairline, then the bidding judgement (the three confidence percentages
    and the anchor threshold), one field per line so the captions line up and each control keeps the
    whole width. The fields themselves are unchanged and still built from `SettingsFieldRow`, so the
    two sheets cannot drift apart; edits still apply as typed, which is why both footers say
    **Done**, and the header keeps a one-line summary ("1 page(s) · 10 requests / min · every
    photograph per scan"). **About** opens `AboutSheet` — the app's name and tagline, its version read
    off the bundle, then a short prose tour of a session and of the two rooms the operator has to
    know, so the window can say what it is for without a bundled document. It was reached as *Help*
    until the app was named; see deviation 30. Moving the tuning card out of the panel retired
    `CollapsibleSection`, whose only consumer it was.
    The row under the bar was then squared off to match the menus above it. Because macOS 26 ignores
    `buttonBorderShape` on any button, **Scrape Lots** — the row's one accent-filled control — and
    **Stop** and **Clear** are painted by `PanelActionButtonStyle`: one corner (6pt, `Theme.chipRadius`),
    one height (`Theme.controlHeight`, 30pt), two emphases and the same hover and press states, so the
    three read as a set. The URL field is a box rather than a labelled `SettingsFieldRow`: a magnifier,
    `Theme.fieldFill`, and the accent hairline the table's own search box turns on while it is focused —
    held while the field carries a runnable address, so the panel's one input stays visible without a
    caption over it. The glyph at the row's end is the old **Page** button as the **info** it always
    was: it opens the address in the field through the same `LotPageSheetView` a row's **Open** button
    presents (deviation 17), so a deliberate look at the auction is a resizable sheet with its own web
    view, and the automatic captcha hand-off is the only thing that reparents the automation's live
    page now. The trio on the bar also stops `titlebarTrailingInset` (8pt) short of the window's
    trailing edge: the corner radius eats into the bar's last few points, and a button ending flush
    with it read as clipped.
    The run's progress moved out of the window altogether. It used to be `ProgressFooterView` — a
    bar, a counters line and the money totals pinned under the console — which took a permanent strip
    of the table's height for a readout that only means anything while work is running. It is now
    `ProgressSheetView`, a modal the control panel raises when `AnalysisCoordinator` has work in
    flight and lowers when it has none, so nothing covers the table with nothing to watch. That move is
    what let the row drop its **Stop**: the button that ends a run belongs to the run being watched,
    so it lives in the sheet, and the row carries a **Progress** button *while* something is running —
    the way back to the sheet after **Hide** (escape) puts it away without stopping anything. Stop
    deliberately has no shortcut of its own: escape dismissing a sheet is a reflex, and a reflex that
    killed a half-finished scrape would be a trap. The sheet kept the footer's four parts — the pill,
    the bar, the counters and a money line — and gained the one it was missing: the *step* the row in
    hand is on, which is what a photograph-by-photograph appraisal actually spends its time doing. Its
    money line changed scope rather than position: it speaks for that same row now (deviation 29).
    Two more of the row's states were settled with it.
    The URL field now wears the table's own search-box treatment exactly
    (`LotTableView.searchField`): an accent border while the caret is in it, and the ordinary hairline
    the moment it leaves, rather than staying lit whenever it happened to hold an address. And the
    panel's **info** glyph presents its page through `lotPageSheet`, the very modifier a row's **Open**
    button uses, so "the same modal" is one implementation the two call sites share rather than two
    that have to be kept in step.
20. **The table fills the window, and its column boundaries are handlebars.** Two related fixes for
    the same complaint — that a wide window left a dead strip beside the **Status** column and a
    short list of lots floated in the middle of a tall one. On width: the table measures its
    viewport (`GeometryReader`) and draws from `ColumnWidths.filling(viewport)`, so on a window wider
    than the table's 1,536-point layout the thirteen data columns share the slack in proportion to
    their own width, and the fixed chrome — the chevron, the **Eval** / **Price** / **Open** buttons,
    the row insets — never moves. On a narrower window the stored widths come back unchanged and the
    horizontal scroller earns its keep, so a column someone deliberately sized is never squeezed to
    fit. A drag is still clamped to 48–420pt in *stored* space, and the header divides the stretch
    back out before saving, which is what stops the layout creeping wider on every mouse move. On
    height: the scroll content is given the viewport's height with `.topLeading` alignment and
    `.defaultScrollAnchor(.top)`, because a scroll view centres content shorter than itself — the
    first lot must sit directly under the header, ready to be worked on. Resizing is by handlebar:
    each column boundary draws a hairline at rest, and under the pointer it lifts to a short accent
    capsule inside a 12-point hit area with the resize cursor, so the affordance is visible instead
    of a gesture you have to know about. Rows keep their zebra striping rather than gaining a grid.
21. **Debug builds ship fixture lots so the table can be looked at.** `PreviewSampleLots.swift`
    (`#if DEBUG`) builds seven lots covering every row state — appraised with line items, evaluated
    without a price, unscanned, **sold**, failed, and two number spellings — and `AnalysisCoordinator`
    has a `loadSamplesForPreview()` hook plus a `#Preview("Populated table")` in `LotTableView`. This
    table is hand-laid-out, so "does the stretch-to-fit layout actually line up, does a nested line
    sit under its pallet, does the failure tint read" are questions about pixels; answering them used
    to require a live auction URL, a session and somebody's patience. None of it is compiled into a
    release build, and none of it touches the network.
22. **A sold lot is flagged, kept and still priceable, and an auction with nothing to bid on says so.**
    Both come from
    the same complaint: the tool looked broken in front of a closed sale. Two rules now cover it.
    (a) *Reading the state.* `readCard` asks for the site's own marker — a short status element
    (`lotStatusSelectors`), then a card attribute, then, last, the card's whole text — and matches it
    against `soldTextPattern`, which is deliberately written to leave catalog copy alone:
    word-bounded, so `unsold`/`resold` never match, and with a negative lookahead, so
    *"sold as one pallet"* describes the sale format rather than retiring the lot. The answer travels
    as `ScrapedLot.isSold` / `statusText` → `LotItem.isActive` and shows in the table's new **Active**
    column (`Active` in green, `Sold` in red with the site's own label in the tooltip). Sold rows are
    *kept*: they are the auction's record, and a partly-closed sale should still read. They are also
    still *priceable*: the flag is information, not a gate, so a sold row keeps all three of its buttons
    and is included in both all-lots passes — the page a closed lot points at still describes the
    goods, and its figures are exactly what an operator comparing one sale to the next is after. (An
    earlier revision skipped sold lots everywhere, which made a sold-out board read as a broken tool:
    every row button greyed out and both batch buttons dark.) (b) *Reading the page.* A catalogue that
    has finished renders its own empty state — *"Results: No Items Found."* on the target site — rather
    than zero cards and a broken layout. `waitForCardsOrEmptyState` polls for cards *or* for that message
    (`noResultsSelectors` + `noResultsTextPattern`, with the page's own body text as the last resort
    when the grid is empty), and `AuctionScraperService.scrape` throws `ScraperError.noActiveLots` on
    page 1 instead of waiting out the render timeout — but only after the message has held for two
    consecutive polls, so a client-rendered grid that flashes its empty surface for a frame before the
    first cards arrive is not abandoned. The coordinator treats it as a *finished* run,
    not a failure: the console logs "no active listings", and the table's empty state
    explains it rather than inviting you to press **Scrape Lots** again. If every scraped lot is sold,
    the same wording is used for the board it just loaded. Both rules are pinned offline: the harness
    compiles the two regular expressions (check 28) and the Node DOM shim drives the real generated
    script against a SOLD badge, an attribute-only marker, a *"sold as one pallet"* description and an
    empty catalogue.

23. **The table's columns are the operator's to choose, and the choice is remembered.** A gear in the
    table's toolbar opens a menu of switches — one per data column — plus **Show all columns**. It is
    the counterweight to deviation 20: that fills a wide window, this lets a column or five be taken
    *out* of a narrow one, or out of the way of the two or three an operator actually bids from.
    Three decisions are worth stating. (a) *What is stored is the hidden set, not the visible one*
    (`ColumnVisibility.storedNames`): a column added in a later version — **Active** was the last —
    then arrives visible, instead of invisible until somebody goes looking for it. The names are
    written in table order under the `hiddenColumns` key, so the stored preference stays readable in
    `defaults read`; a name this build does not know is dropped rather than honoured, and a stored set
    that would hide *every* column is read as "never configured", so a preference file can never wedge
    the table. (b) *One rule, enforced twice*: every column may be hidden except the last visible one,
    because a table of no columns is not a view of the data and no menu could get the operator back
    out of it. `canToggle(_:)` disables that switch and refuses that write; the chevron and the
    **Eval** / **Price** / **Open** buttons are not cases in `LotColumnKey` at all, so they are not the
    chooser's to take away. (c) *A hidden column is a width of zero, not a second layout.*
    `ColumnWidths.width(_:)` returns 0 while `storedWidth(_:)` keeps the number, so the header, both
    row kinds, the nested indent, the table's total and the stretch-to-fit all close up around the
    choice without any of them having to know it happened — and the width a column was dragged to is
    still there when it comes back. The per-column shorthands are the *drawn* widths too
    (`widths.bid` reads zero while Bid is hidden) and the storage behind them is private, because the
    rows lay their cells out from those shorthands: one of them quietly reading storage would leave a
    hidden column taking its 96 points out of every row while the header above it closed up.
    (d) *The table is rebuilt on a change, and one empty cell is what keeps the grid honest.* The
    scroll content carries `.id(visibleColumns)`, so a flip re-lays-out the whole table rather than
    leaving SwiftUI to diff a layout that only exists at the viewport's width — a header that has
    moved on while the rows have not, or a left-over horizontal offset from a wider layout, is
    exactly what "the columns do not line up" looks like. A change of *data* does not touch that key,
    so scraping and valuations never disturb the viewport. Underneath, `TableCell` holds its column
    with an invisible width-by-1 block rather than trusting the content to be that wide, because
    SwiftUI drops `EmptyView().frame(width:)` outright. The header's disclosure cell and a product
    line's whole-pallet-only columns *are* empty cells, and each one used to take its width out of
    everything drawn to its right: the header sat a full chevron to the left of the rows it labelled,
    and a nested line's retail figure landed under **Bid**.
    **Reset column widths** now lives in this menu rather than the
    ellipsis one, because a width is a column's business, and it resets widths *only*: a column
    somebody went looking for is not a width. The choice is written the moment it is made — but only
    that one key, so flipping a switch cannot be the thing that commits a half-typed URL into the
    defaults. The columns gear wears a dot while anything is hidden: not "not configured yet", as
    the orange dot on **Account** means, but "not everything is being shown". The rules are pinned
    by harness check 29.

24. **The number of photographs is the lot's business, not a setting — so the app reads the lot's own
    page.** There was an `Images / lot` stepper (1–8, defaulting to 4), and it was wrong for the same
    reason a fixed page count would be: a lot's gallery is as long as the lot makes it. One sealed
    pallet shows two photographs; a mixed one shows forty; and the four a card carried were thumbnails
    either way, so the operator was guessing a number that was never theirs to know. The stepper is
    gone, along with `AppSettings.imagesPerLot` and the `imageLimit` argument the valuation services
    used to take, and **Price** now reads the lot's own page and attaches the gallery it carries —
    while **Eval**, which sends no photographs, reads the same page for the description column so its
    text-only estimate is built from the listing's real copy rather than the card's teaser.
    Four decisions are worth stating. (a) *The page is fetched, not navigated to.* `window.__PAS` runs
    a same-origin `fetch` against the lot's URL from inside the listing the scraper already has
    loaded, then parses the answer with `DOMParser`. That is what makes it affordable and safe: the
    request carries the operator's own session cookies (a second web view, or a Swift-side
    `URLSession`, would need a cookie copy to match), it costs one GET rather than a load-and-come-back,
    and the results page — its scroll position, its page number, the automation's own state — is never
    touched. `callAsyncJavaScript` is what awaits the promise; `evaluateJavaScript` would hand back the
    unresolved promise itself. (b) *The lot's gallery is read, and nothing else on the page is.* The
    page is not the lot: it also carries the site's logo, its promotion carousel, a "recently viewed"
    rail and links to the neighbouring lots, and a vision model asked to price a promotion banner will
    price it. So the reader is scoped to the containers the profile names — `lotPageGallerySelectors`,
    the left-hand slide column (`div.auc_slide.left`) that holds the frame and the strip of thumbnails
    beneath it, then the strip by name (`ul.mediaThumbnails`) in case a layout moves it out of that
    column — and the whole of each container's subtree, with the class the site also reuses for its own
    carousels deliberately *not* a rule: a rail of neighbouring lots read as this lot's gallery is how a
    lot with eight photographs became a scan of seventeen. Inside those containers one element is one
    photograph, and the elements are walked in document order — the album's own order, which is what the
    inline budget trims against. An anchor whose address *is* an image is a gallery *slot*: the frame
    shows one photograph at a time and the strip holds the album, so the address a thumbnail opens is
    the photograph and the `<img>` inside it is that same photograph at thumbnail size — taking both is
    how eight photographs become sixteen requests' worth of payload. An `<img>` outside such a link
    contributes its own *best* attribute rather than one entry per attribute (`src`, a lazy `data-src`,
    the `data-large_image` standing behind a thumbnail), a `<picture>`'s sources and its `<img>` are
    compared and the best of them wins, and a `style` attribute's `url(...)` counts when a layout paints
    a photograph in. Addresses are then keyed by *photograph* rather than by string: the variant folder,
    the size suffix, the `@2x` marker and the query string are stripped, and the better copy — the one
    whose name already said `large`, the one a thumbnail opens — replaces a worse one in place, so the
    frame's copy, the strip's thumbnail and the full-size copy a lightbox holds are one image rather
    than three. That is exactly what the live catalogue prints: one photograph under one name at three
    sizes — `112184_s.jpg` (56×100, the strip's own crop), `112184_l.jpg` (281×500, the frame, repeated
    as the anchor's `data-image`) and `112184_xl.jpg` (720×1280, the copy the thumbnail opens) — each
    with its own `?ts=` cache-buster, inside an `<a class="image-thumb-slide mz-thumb" href="…_xl.jpg"
    data-image="…_l.jpg"><img src="…_s.jpg"></a>`. The photograph is the *digits* and a size code that
    follows a number is only a size, so those three collapse to the one entry a viewer would open — 11
    photographs are 11 addresses of ~138 KB each, which one request carries comfortably. Two different
    photographs do not share a name, so nothing real is merged. The layout's
    own props never make the list either: spacers, 1×1 pixels, spinners, sprites, SVGs, and the arrows,
    close buttons and magnifiers a carousel keeps inside the very container the gallery is read from.
    A strip this site builds in JavaScript is read as well. Its page ships the frame and an empty
    `ul.mediaThumbnails`, so the addresses a `fetch` sees exist only in the data blob the script fills
    the strip from; the reader therefore also takes an address the page declares in a blob when it sits
    in the same *folder* as a photograph the containers already produced. `…/images/lot/1121/` is this
    lot, `…/images/lot/1187/` is the one in the "recently viewed" rail and `…/assets/` is the site's
    logo, so a JavaScript-built strip is recovered without a neighbouring lot being dragged in — and the
    reader says so rather than leaving the count to be taken on trust (`the page data supplied N more
    photograph(s) than the gallery markup held`). Nothing is capped: how many photographs a lot has is
    the lot's business. Only when *no* container
    matched at all — a gallery built entirely in JavaScript, with no container to read and no folder to
    match a declared address against — does the reader fall back to the places a page declares its lead
    image (`og:image`, `twitter:image`, `link rel="image_src"`, `imageMetaSelectors`) and to image URLs
    inside data blobs (JSON-LD, `__NEXT_DATA__`), and the report says so rather than reading as if the
    gallery had been found and happened to be empty. Relative
    addresses resolve against the *lot page*, not the listing — joining `/images/208-1.jpg` onto the
    results address is a silent 404, which is why `absolute(_:base)` now takes a base. The same read
    yields the listing's real copy: `lotPageDescriptionSelectors` is walked in order and the first
    selector that yields text is used, its heading ("Description") stripped and its whitespace
    condensed — the block itself (`div.active.ins_cnt.description-info-content`) before the column that
    contains it (`div.auc_info.right`), so the bid box, the countdown and the "ask a question" form
    beside the copy stay out of the prompt. That text replaces the card's teaser on the row and in both
    passes; a page that yields none leaves the card's copy alone rather than blanking it. The card's own
    thumbnails remain as the fallback and keep their profile bound, now named `maxCardImages` because
    that is all it ever was. (c) *A page that will not read is not a failed scan.* A challenge page, a
    404, a non-HTML document, or a gallery built in JavaScript that declares its addresses nowhere at
    all comes back as `ok:false` (or as zero images) and the scan proceeds with the card's thumbnails and
    its teaser, saying so in the log. The one
    thing that *can* still hold a photograph back is the provider's payload ceiling — one image over
    `maxImageBytes`, or a whole gallery over `LotImageLoader.defaultTotalBytes` (12 MB, ~16 MB once
    base64-encoded, comfortably inside Gemini's 20 MB request limit and DeepSeek's 48 MiB body cap) —
    and that is reported rather than silently applied: `ValuationOutcome` carries
    `imagesAvailable`/`imagesSent`/`imagesSkipped`, so the console can say `40 of 46 image(s), 6 over
    the inline budget`. (d) *It costs one extra request per lot.* About 1 GET on the auction host per
    scanned lot, which is why it happens at **scan** time rather than at scrape time: a board of 200
    lots where three are ever scanned pays for three page reads, and a sold or ignored lot pays
    nothing. One lot page is read per lot per action — the page's gallery is cached for the length of
    that action, so the pre-price pass and the photographed pass that follows it share one GET rather
    than fetching the same page twice, and clearing the cache is what makes a re-click re-read it.

25. **The table is one family of chips, one untitled control column, and a header that reads as
    chrome.** The visual pass over `LotTableView` / `LotTableRow` grew out of one concrete complaint —
    the **Eval** / **Price** / **Open** buttons moved sideways as their labels changed underneath the
    pointer, so a click aimed at **Price** could land on a button that had just become **Re-price**.
    Every part of the fix is a rule rather than a tweak. (a) *A button's slot is as wide as its widest
    label.* `RowActionSlot` lays an inert, hidden `Button` wearing **Re-eval** / **Re-price** /
    **Open** under the live control inside a `ZStack`; the reservation is a real bordered `.small`
    button, so it carries that control's own font, padding and icon rather than a body-font estimate,
    and the trio never shuffles as a state changes or as a request goes out. The reserve wears
    `.allowsHitTesting(false)` and `.accessibilityHidden(true)` so a click falls through to the row's
    expand gesture and the screen reader reads the live control, not the ghost. `LotColumn.scan` (246)
    is the three slots plus two `Theme.actionSpacing` gaps with slack, and only the Eval/Price pair is
    in every row — a card that exposed no address leaves two buttons — so the slack absorbs the
    difference. (b) *The control column is untitled.* Three labelled buttons do not need a legend over
    them, so `LotColumn.scanTitle` is `""` and the header draws an empty cell of that width; the
    constant survives because the header, the harness check and this file all point at it. (c) *The
    header is chrome, not a first row.* Its labels are micro-caps (uppercase, tracked, caption2) drawn
    a point taller than the rows' own padding, over a hairline — deliberately not a bold copy of the
    data. (d) *The chips are one family.* `Theme.chipStyle(tint:)` is the single capsule behind the
    pipeline state, the model's confidence and every flag (**provisional**, **evaluating**, **anchor**,
    **Active** / **Sold**); before, four views each carried their own font, padding and fill opacity and
    had already drifted. The tint is used twice on purpose — full strength for the text, 15% of the
    same hue behind it — so a red flag and a green one differ by colour rather than by shape. (e) *Zebra,
    hover and state tints come from `Theme`.* Rows keep their striping rather than gaining a grid, and
    their paddings, hairline and fills are tokens, so the header, both row kinds, the detail card and
    the toolbar cannot drift apart as they are edited one at a time. Nothing here adds a dependency or
    a behaviour: it is the same table with the same columns, drawn to one grid.

26. **The photographs are also read on this machine, and what the price rests on is part of the
    answer.** A multimodal model is asked to price a pallet from pictures, and the two things that
    turn "household goods, ~$600" into "that exact 24-pack, $180" — the barcode digits and the model
    number on the label — are the two things it reads least reliably off a photograph, because reading
    a barcode is a decoding job and reading small type is a resolution job. The Mac can do both, for
    nothing, with the framework that ships with the OS. So a scan now reads the photographs twice.
    (a) *Locally, first.* `LotImageDigest` decodes barcodes with `VNDetectBarcodesRequest` (the linear
    product symbologies plus the GS1 2-D kinds; QR is excluded, because on an auction photograph a QR
    is usually the site's own sign) and recognises text with `VNRecognizeTextRequest` at
    `.accurate`/no-language-correction, because `DCS620D` is not a word. Both are filtered to what
    could be a catalogue identifier: a mixed model/SKU code of five characters or more, a GTIN of 8-14
    digits, or a short bare number *only* when the line names itself (`SKU`, `UPC`, `part no.` — so a
    price, a quantity and a year stay out). Up to twelve photographs are read; the digits that survive
    are the digits that travel. This is deliberately a *reader*, not a decider: it prices nothing, it
    never guesses at a blurred label, and a pallet with nothing legible on it is a normal pallet.
    (b) *The reading is prompt text, not a second opinion.* The literals are echoed into the
    photograph prompt under a heading that says they were already read, with the instruction that
    follows from it — match each identifier to the product it belongs to, price that exact model and
    size rather than a category average, and do not contradict a decoded barcode. The prompt also
    warns off the failure mode that decoding makes possible: a tracking barcode stapled to the outside
    of a pallet is not a product identifier, and a freight label is not the goods. (c) *The answer says
    what it rests on.* `DiscoveredItem` gained `evidence` — the label wording, barcode digits or model
    number a line was priced from, quoted as read and empty when nothing was legible — which is in the
    response schema, survives the tolerant decode and the DeepSeek draft hand-off, and is drawn under
    the item's name in an expanded row. The reader's own findings are logged too (`Lot 142: label
    reader read barcode(s) 0123456789012 · identifier(s) DCS620D`), so the literal reads are visible
    even when the model's answer is thin. (d) *What it costs.* No key, no request, no upload: local
    CPU per scanned lot — at most twelve photographs are looked at, barcode decoding runs on all twelve
    (it is a scan for bars rather than a reading), and text recognition stops once four identifiers are
    out, because the rest of a gallery is the same cartons from another angle — plus a slightly longer
    prompt. What it buys is the difference between a figure that can only be believed and a figure that
    can be checked — and, when the barcode resolves, a price that was looked up for one product instead
    of averaged over a category. (e) *The classic `VN*` requests are used on purpose.* They are
    deprecated against the macOS 15 SDK in favour of the new Swift `Vision` types, which require
    macOS 15; this app deploys to macOS 14, and an availability split for no behavioural gain is not
    worth it.

27. **A photograph is priced on its own, and the readings are reconciled afterwards.** One request over
    a whole gallery asks the model to hold forty frames in its head at once, and the answer is an
    average over all of them: a thirty-dollar item in the corner competes with the pallet in front of
    it and usually loses. So a **Price** is now a *thorough* scan (`LotPhotoScan`), and the transport
    supplies only two things — how to ask about one photograph, and how to ask for the reconciliation
    — so both providers run the identical pipeline. (a) *One request per photograph.* The frame, the
    listing text and the app's own reading of **that** frame travel together, and the answer is a
    `PhotoReading` (`PhotoObject` per group: name, brand, category, the units visible *from that
    angle*, per-unit retail and resale, condition, packaging, where in the frame it sat, the
    identifiers and label wording it rests on, its confidence and its evidence). A reading is
    *evidence* rather than a conclusion, which is why it is stored as its own type: `quantity` is what
    one photograph shows, and deciding that three sightings of six cartons are six cartons is the
    reconciliation's job. (b) *A reading is reused, not re-bought.* `PhotoReadingStore` keeps them in
    `Application Support/<app>/PhotoReadings/`, one JSON file per lot, keyed by lot number, model and
    prompt version (`currentVersion`, so changing the question retires the answers to the old one).
    Re-scanning a lot with the same model costs the reconciliation instead of the gallery — which is
    the difference between a thorough scan being affordable and being a subscription — and the
    gallery itself is still fetched from the CDN, because image bytes were never the expensive part.
    (c) *One request reconciles.* The readings go to the model in gallery order with the instruction
    to fold duplicates into the pallet's real counts, and the line items that come back are the ones
    the row already knew how to show. (d) *Two fallbacks, both cheaper than failing the lot.* If the
    reconciliation request fails, `PhotoReadingMerge` folds the readings into line items on this
    machine — the photographs that were paid for are not thrown away, and the console says the merge
    happened rather than the request. If nothing could be read individually at all, the scan falls
    back to the single-pass gallery appraisal, which is unchanged and still the whole of the old
    behaviour. (e) *No photograph is ever dropped.* `Photos / scan` (default **All photographs**) caps
    how many frames get the individual treatment, and the rest travel with the reconciliation request
    as images, so a ceiling under a per-minute quota makes the line items coarser and never makes the
    pallet smaller — the same rule as deviation 24, one level down. (f) *The working is visible.* The
    scanning row says which frame it is on (`photograph 7 of 12 read: 4 product group(s)`), the console
    carries one line per step and then the roll-up (`12 photographs read one by one — 34 product
    group(s), 9 identifier(s)`), and the expanded row lists every reading, including the frames that
    turned out to hold nothing — an empty frame is a fact about the pallet, not a gap. (g) *What it
    costs.* Requests are linear in the number of photographs: 1 + *n* per lot, or 1 + *n* - *k* when
    *k* readings were already on this machine. That is the honest price of asking a smaller question
    once per frame instead of a large one once per pallet, and it is why the ceiling and the store
    exist rather than being optional extras.

28. **A task the pipeline starts hands its result back to the main actor instead of assuming it
    resumed there.** `AnalysisCoordinator` is `@MainActor`, so a `Task { … }` written inside it is
    compiled against that isolation and its first statement does run on the main actor. What the type
    system cannot promise is where the body *resumes* once an `await` has handed the task to another
    executor — and the row it writes to is main-actor only, so a body that resumed on a cooperative
    thread and then called `LotItem.applyValuation` did not quietly fail to apply anything: the
    synchronous write crossed into a main-queue-only path, the assertion in that method's own
    isolation check fired, and the app died with `EXC_BREAKPOINT`, reported inside `items.reduce`
    because that is where the row's totals are recomputed rather than where the call came from. Two
    rules hold now. Every task this class starts is spelled `Task { @MainActor … }`, so the work
    between suspending points is main-actor by declaration rather than by where the closure was
    written. And each one's last act is `await onMainActor { … }` — a single `MainActor.run` hop — so
    the row is touched on the main actor by construction, whatever executor the task was handed back
    to. The hop costs one suspension at a point where the work was already asynchronous and changes
    no arithmetic; `Task.isCancelled` is still read in the body, before the hop, because that question
    is about the task asking it.

29. **The progress readout counts the work that was asked for, not the size of the site.** Two
    numbers in the modal's pill were honest-looking but wrong, and both were wrong the same way — the
    denominator was something other than the job in hand. A run told to walk **one page** of a
    four-page catalogue printed `page 1 of 4`, promising three pages that were never going to be read,
    and a row's **Price** printed `0 of 100` on a hundred-lot board, which is the denominator of a job
    nobody asked for. The pill is the *only* place a run's shape is visible, and neither reading looks
    like a fault from inside the app: both read as work in progress. So the two rules moved into
    `Models/RunProgress.swift` as value types with their own checks in the offline harness, and the
    coordinator only feeds them. `PageWalkProgress.target` is the **smaller** of the **Pages** budget
    and the listing's own count — a walk stops when the pagination runs out of pages, so a budget
    longer than the listing is the listing's length, and one shorter than it is the budget: `1 page`
    against a four-page site is *page 1 of 1*. `AppraisalJob` carries the rows an appraisal covers: an
    `Eval` / `Price` job is the one row its button named (`Evaluating Lot #19002`, `Pricing Lot #19002`,
    joined by a second click while the first still runs, since `canScan` allows clicking through several
    rows at once), and a batch is the pending set its own button was built from — counted by place,
    since a batch's pill says where in *itself* it has got to (`Evaluating Lot #3 of 12`) rather than
    naming a lot number that would read as a position. Which one it is comes from the button that started
    it rather than from the lot count, which is why a job's rows are held in the order they joined it. The
    counters line and the two per-row status lines keep speaking for the whole board, because that is
    the tally the pill cannot show (`1 ok, 0 failed` out of a hundred rows). The values grew two more
    shapes in the same file, both of them things the readout was previously guessing at. `AppraisalStep`
    is the step the row in hand is on — the row's own page, the text-only look, `photograph 5 of 12`, the
    reconciliation, or the single-pass fallback — each with the phrase the modal prints and the share of
    its row the bar counts, mapped from the `PhotoScanEvent`s the thorough pipeline was already
    reporting. That is what turned the bar from something that jumped a row at a time into something
    that creeps per photograph, and it is why a scan no longer reads as frozen for the minutes a dozen
    requests take. The pill's wording moved with it: a row's button *names* its row
    (`Evaluating Lot #19002`) while an all-lots button *counts* through the rows it was built for
    (`Pricing Lot #3 of 12`), which is why a job now keeps its rows in the order they joined it rather
    than in a set — a batch's place has to be readable. And `LotMoney` is the bottom line's scope: the
    row in hand's own open bid, retail, resale and profit, from its valuation when it has one and its
    text-only eval until then. The board's totals used to sit there and moved for neither a single row's
    **Price** nor an **Eval** run at all — an eval writes a provisional figure, and the board's totals
    only ever summed valuations — so the line followed the work instead, falling back to the board only
    when no row is in hand.

30. **The app is TheLotLizard, and *Help* became *About*.** The tool was built under one name and is
    used under another: **TheLotLizard**, with one line saying what it is for — *"Crawl the lots. Snap
    up the profits."* The rename stops at the glass on purpose. `PRODUCT_NAME` (and a matching
    `CFBundleDisplayName`) is what puts the new name on the app the operator actually sees: the Dock,
    the menu bar, the window title and Finder. The Xcode project, the target, the source folder and
    the bundle identifier (`com.mFT.PalletAuctionBidTool`) keep the names they were created with,
    because a bundle identifier is a *data* address rather than a label. `UserDefaults` — the site
    login, both API keys, the auction URL, the hidden columns — is filed under it, and so is
    `PhotoReadingStore`'s cache of readings (`~/Library/Application Support/<bundle id>/`). Renaming
    the bundle is therefore a rename of the operator's saved state: an update that looked like
    cosmetics would silently orphan every key, every saved URL and every reading already paid for, and
    the app would come up looking freshly installed with no key and nothing to reuse. The build
    *identity* stays put and the *label* moves, which is the one arrangement where the rename is free.
    The titlebar's third menu was renamed with it, **Help** to **About**, and the file behind it
    `HelpSheet.swift` to `AboutSheet.swift`. It was never a help affordance in the first place —
    nothing about it is context-sensitive, it is not opened by a `?`, and a Help that answers questions
    the window already answers in its tooltips promises documentation this app does not have. What it
    holds is what an about box holds, and it now leads with it: the name, the tagline, and the version
    read off the bundle (`CFBundleShortVersionString` / `CFBundleVersion`, so the sheet cannot claim a
    version the build is not), then the same prose tour of a session it always carried. The name and
    the tagline are spelled exactly once — `Theme.appName` and `Theme.tagline` — because the titlebar's
    title, the window's own title and the About sheet all print them, and a name typed in three places
    is a name that will eventually be typed three ways.

31. **The app wears its own art: a launch splash, a real icon, and the mark in the titlebar.** None of
    the three existed as artwork before — the titlebar's mark was a `shippingbox.fill` glyph in a
    gradient tile, and the icon set was an empty iOS-shaped `AppIcon` with no images in it. The art is
    the designer's own export, and all three sets come out of one file (`SplashArt`, `AppMark`,
    `AppIcon`), so the shirt and the app cannot drift apart.
    **The splash is brand, not progress.** Nothing is read, scraped or appraised while it is up, so
    there is no work to tie it to and nothing it could honestly report: it is timed (`Theme.splashDwell`,
    1.7s) and a click takes it away early for an operator who has seen it before. It is an *overlay over
    the window*, not a sheet and not a second window — the panel underneath is live the whole time, and a
    sheet would have to be dismissed and would slide off the window rather than hand it back. `ContentView`
    owns the one flag; `SplashView` owns both exits (its timer and the click) and the fade, and
    `ContentView(showsSplash: false)` is what previews pass, because a preview is not a launch.
    **Two appearances, because the art is dark ink.** The name and tagline are drawn in dark type, which
    disappears on a dark page, and a dark appearance cannot simply reuse a white one behind a bright
    card without flashing the window white at every launch. `SplashArt` therefore ships a dark variant
    whose two lines of type are re-inked light — the mark's own greens are left exactly as drawn, since
    they read on either page — and `Theme.splashPageDark` is the deep paper it sits on. The page follows
    the appearance; the art follows the catalogue, which is where a dark variant belongs.
    **Nothing is resampled at runtime.** The export carries roughly a fifth of empty margin on every
    side, which is why a splash drawn at a sane width reads a third smaller than it is; the assets are
    trimmed to the art's own ink and then generated *at the size the window draws them* (`320pt` and
    2× that), so `Theme.splashArtWidth` is the width the eye actually gets.
    **The supplied artwork needed rebuilding to be usable.** The exports are flat RGB — the design tool's
    transparency checkerboard (`#CCCCCC`/`#FFFFFF`, 10px cells) is baked into the pixels and there is no
    alpha channel — and the file named for the icon is the designer's whole *size sheet* (1024/512/256/
    64/32/16 panels, labels and all) rather than a single icon. `Tools/brand-assets` therefore rebuilds a
    real matte: it classifies the checkerboard (nothing in the art is neutral *and* that light), flood
    fills it in from the border so the light ink *inside* the art — the mark's eye, the gaps between its
    legs, the counters of the wordmark — is never eaten, and un-mixes the one-pixel antialiased rim so no
    grey halo survives on a coloured page. The mark for the icon and the titlebar is cut from the splash
    art, which is the largest clean copy of it to hand; a single 1024px icon exported *with* real alpha is
    the one thing that would improve it.
    **The icon is a macOS icon set, not one 1024.** The appiconset the template shipped held three
    `universal`/`platform: ios` entries and no files at all; a Mac app icon is a set of rasters, so what
    is there now is the ten `mac` entries (`16…512`, 1× and 2×), with the mark drawn into the middle four
    fifths of the canvas — where macOS's own icon grid expects an app's artwork to sit. It is the bare
    mark rather than a tile, which is what the designer's small-size panels show. All ten land in
    `Assets.car`, which is what `CFBundleIconName` points the system at; the `AppIcon.icns` Xcode emits
    beside it carries only a subset (16 and 128 here), so the catalogue is the icon that matters.
    **The titlebar's mark is the icon in miniature**, on a pale tile: that art is transparent, and its
    dark greens would sink into a dark titlebar without something behind them. It replaced a gradient tile
    and an SF Symbol, and the name beside it is still `Theme.appName` — the same single spelling the
    window title and the About sheet use.

---

Selectors live in data, not code: edit `ScrapeProfilePresets.genericBase()` or add a new
`ScrapeProfile` and hand it to `AuctionScraperService(profile:)`. Every list is tried in order,
most specific first. Nothing in `ScraperScript.swift` has to change.

Two rules decide whether a tile is a card at all, and both matter when a board comes back one short
of the listing. `minimumCardTextLength` is the floor that keeps a broad selector's empty wrappers
out; `lotSignalAttributes` — plus a DOM `id` that unwraps to a number (`ItemMain19002`) — admits a
tile that carries a lot number however little it says, so a compact card is a lot rather than a
silent loss. A card counted by one rule and retired by the other is exactly how a page of 100 became
99 with nothing in the log to explain it, which is why the two share one test and why every page now
says `N cards …, M new` and names, on its own line, any card that yielded no lot or turned out to be
one already on the board.

Two of those lists are about a lot's *state* rather than its fields, and they are the ones to check
first on a new site:

| Field | What it is for |
| --- | --- |
| `lotStatusSelectors` | Where the site puts a sold / closed / ended badge on a card. |
| `soldTextPattern` | JS regex deciding that badge means sold. Keep the word-boundary and the negative lookahead — they are what stop *"sold as one pallet"* from retiring a biddable lot. |
| `noResultsSelectors` | The surface a finished catalogue shows its empty state in. |
| `noResultsTextPattern` | JS regex confirming that surface is the empty state and not a "Results: 24 items" counter. |

Two more lists decide what a **Price** sends, now that the count comes off the lot's own page:

| Field | What it is for |
| --- | --- |
| `lotPageGallerySelectors` | The containers a lot's own page keeps its gallery in, most specific first — the left-hand slide column (`.auc_slide.left`), which holds the frame and the thumbnail strip beneath it, then the strip by name (`ul.mediaThumbnails`) in case a layout moves it out. This is the whole of the reader's image scope: everything inside them counts, walked in document order with one address per photograph (the copy a thumbnail opens, de-duplicated across the sizes of that photograph — `_s`/`_l`/`_xl` of one name are one photograph), and nothing outside them is looked at at all, which is what keeps the site's logo, its promotion banner, its own carousels and the "recently viewed" rail out of a valuation. A strip the site builds in JavaScript is recovered from the page's own data blob, and only for addresses that share the gallery's folder (see deviation 24). |
| `lotPageDescriptionSelectors` | Where the page prints the listing's real copy, most specific first — the description block before the column that contains it. The first selector yielding text wins, its heading is stripped and its whitespace condensed; that text replaces the card's teaser in both the **Eval** and the **Price** prompt. |
| `maxCardImages` | How many thumbnails are taken from a *card*. Only the fallback path uses it: a lot whose page cannot be read is still appraised from its card. It is not the lot's image count, and nothing in the UI sets it. |
| `imageMetaSelectors` | Where a page declares its lead image (`og:image`, `twitter:image`, `link rel="image_src"`). These are the last resort, read only when no gallery container matched — a gallery built entirely in JavaScript. |
| `lotPageTimeoutSeconds` | How long one lot's page is given before the scan falls back to the card's thumbnails. |

And two decide *which address is the lot's own page* — the one **Open** shows, and the one the page
reader fetches for a **Price**:

| Field | What it is for |
| --- | --- |
| `detailLinkSelectors` | Anchors on a card that point at the lot's page, most specific first. Tried before the card's generic first anchor, which is what picks the lot page out of a tile that also links to the auction, a wish list or a photograph. |
| `nonLotHrefPattern` | JS regex for addresses that are never a lot's page: the session's own pages, wish-list / share / print buttons, the legal pages, social hosts. A rejected address is skipped in favour of the next candidate rather than ending the search. |

Neither list is required for a lot to have an address: the script also looks for the anchor the
matched card *lives inside*, and for any anchor whose address carries the lot number the card
printed. A site whose catalogue URLs are shaped in a way this profile has never seen therefore still
gets its **Open** buttons — but naming the pattern is what keeps the right tile from being opened
when a card carries three links.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| The app is called TheLotLizard, but Xcode, its folder and the saved settings still say PalletAuctionBidTool | Working as intended — the label moved, the build's identity did not. Finder, the Dock and the menu bar read `PRODUCT_NAME` / `CFBundleDisplayName` (`TheLotLizard.app`), while the project, the target, the source folder and the bundle identifier keep their original names, because `UserDefaults` and the readings cache are keyed by bundle identifier. See deviation 30. |

| "No lot cards were found" | The log prints page diagnostics (matched selectors, card counts, ready state). Check that the URL really is a listing page, then widen `cardSelectors`. |
| A run stops after page 1, or after a few pages | Working as intended, and the log says which reason fired — the walk ends at the first page with no lots on it, and every stop is reported: *"The listing reports N page(s) — there is no page 2"*, *"No lot cards appeared on page 2 — the listing has no such page"*, *"Page 2 served a page already read …"*, *"The listing did not change after clicking next"*. Pages are asked for by address (deviation 6): `?page=2`, `?page=3`, …, in the parameter the listing was seen using, and with the listing's own link for the page when it printed one. So the fix is the address shape: check in the **info** page window whether the *next* page really is `?page=2` (a POST or a JS-only pager is what the click fallback covers — widen `nextPageSelectors` for that), and note that `?p=`-shaped pagination is deliberately not read as a page number. |
| A run walks past the last page, or loops | Should not be possible: the listing's own page count ends the walk when it reported one, a repeated page signature is caught against every page already read, and `ScrapeLimits.maximumPages` is the 100-page runaway guard. If it happens anyway, the site is answering different content for the same page number (a rotating "recommended" strip is enough) — the log's `Pagination: asked for page N, the site's address says page M` line says which address it actually landed on. |
| "No active listings" | Working as intended (deviation 22): the page's own empty state — *"Results: No Items Found."* — or every scraped lot being marked sold. Nothing was spent and nothing failed. If the auction really does have lots, widen `noResultsSelectors` / `noResultsTextPattern` (a false positive) or check the auction page through the **info** glyph. |
| The board holds fewer lots than the listing shows | Read the console first: every page logs `N cards …, M new`. A *"yielded no lot"* line means the card selectors matched a tile nothing could be read from, so widen `cardSelectors` (or the tile is genuinely empty) — the count of `with a lot-page address` on the extracted line is the other clue. A *"lots already on the board"* line means two cards resolved to the *same lot page*, so check `detailLinkSelectors` and `nonLotHrefPattern`: an anchor that is not the lot's own (the catalogue, a share link) makes two lots look like one. |
| The **Active** column says "Sold" on lots that are still open | The sold rule matched something the site did not mean. The site's own badge is the authority (a short status element, then a card attribute, then the card text), so add the site's real badge to `lotStatusSelectors` and, if its wording trips the fallback, tighten `soldTextPattern`. The harness's check 28 pins the "sold as one pallet" case, and the Node shim pins the badge cases. |
| The **Active** column says "Active" on lots the site has sold | The marker is somewhere the profile does not look. Find the element that carries it on the auction page (the **info** glyph) and add its selector to `lotStatusSelectors` (or its attribute name to the list in `readCard`). Sold lots are only *flagged* — never dropped and never locked, so nothing is lost and nothing is off limits while you tune it. |
| The table's columns do not line up under their headers | Should not be possible: the header and every row are laid out from one `ColumnWidths`, and the scroll content is re-keyed on the column choice. If a column still drifts, a cell is failing to hold its width — see deviation 23(d), where an empty cell is the usual culprit. Widths, not positions, are what the header and the rows share. |
| "Automation ready" never logs | The page blocked main-frame injection or JavaScript. Open the auction page (the **info** glyph) and inspect. |
| Login never completes | Wrong form selectors, or a challenge screen. Open the auction page (the **info** glyph) to see what the site is asking. |
| A lot is skipped or failed | The provider returned an unusable reply, or images failed to download. The row shows the reason and the console has the detail. Press **Price** again on that row — a failure is per lot, not per run. |
| A row's **Price** button is greyed out | The selected provider has no key (**Account, ⌘, → API key** — **Account** wears an orange dot while that is the case), or the lot is already appraised. The progress modal's status line names which. Rows are also locked while a scrape or an all-lots batch is running — press its **Stop**, or wait. |
| A row's **Eval** button is greyed out | The same key gate as **Price**, or the lot already has an appraisal: a real valuation hides provisional figures, so evaluating it again would buy a number nothing shows. Use **Reset valuations** in the table menu first. |
| A row has no **Open** button | The card declared no address for that lot, so there is nothing to open and no button to press. The address search has four sources (deviation 17): the anchors `detailLinkSelectors` names, the card's own first usable anchor, the anchor the matched card *lives inside*, and — once the lot number is known — any anchor whose address carries that number, on the card or anywhere on the page. So the usual fix is a shape the profile does not know: put the site's lot-page pattern in `detailLinkSelectors` and its furniture (sign-in, share, wish list) in `nonLotHrefPattern` in `ScrapeProfilePresets.genericBase()`. The log says how many rows came with an address: `Page 1 extracted: +24 row(s) …; 24/24 with a lot-page address` — `0/24` means every card was in the same shape, which is worth a look on the auction page (the **info** glyph). |
| Nothing is appraised after a run | Expected: a run only scrapes now (deviation 12). Press **Eval** for a cheap text-only figure, **Price** to appraise a row from its photographs, or the two **…all** buttons to work through every lot that has nothing yet. |
| The Lot / SKU column shows something like `ItemMain19002` | The card exposed no lot number of its own, so the app fell back to the `id` — and the wrapper rule did not recognize the site's prefix. Add the element that carries the number to `lotNumberSelectors` (or its attribute to `lotNumberAttributeCandidates`) in `ScrapeProfilePresets.genericBase()`, and add the site's id prefix to `lotNumberWrapperWords`. See deviation 18. |
| `Eval all` says every lot already has a figure | Working as intended: lots with a valuation or an eval are skipped rather than evaluated again (deviation 17). **Reset valuations** in the table menu clears them if you want them priced again. |
| The progress bar only fills part of the way on a scrape-only run | It does not any more — the bar measures the work in hand rather than a fixed share of it. While the walk runs it is pages read out of the pages this run is *going to* read, so a 3-page run fills a third, two thirds, then all of it; a finished scrape is 100%, because the pages *were* the job. |
| The pill says `page 1 of 4` when I asked for 1 page | Fixed: the denominator is the smaller of the **Pages** budget and the listing's own count, because a walk stops when the pagination runs out of pages. One page of a four-page catalogue is a one-page job, so both the pill and the bar say `page 1 of 1`. A budget *longer* than the listing reads as the listing's length (`page 2 of 4`), which is the same rule from the other side. |
| A row's **Price** shows `Pricing Lot #19002` but the counters say `1 ok, 0 failed` of 100 | Correct, and the two are different questions. The pill counts the job the button asked for — one row, named, because that is whose figure is being bought; the counters line keeps speaking for the whole board, which is the tally the pill cannot show. Press **Price all** and the pill switches to that batch's own scope (`Pricing Lot #4 of 12`). |
| The pill counts a batch (`Pricing Lot #3 of 12`) and never names a lot | Expected: in a batch the place in the job is what moves, and a board's lot numbers do not run from 1 — `Pricing Lot #19002 of 12` would read as a place that does not exist. A row's own button names its row instead (`Pricing Lot #19002`), and the step line under the counters carries the lot number whenever one is being read. |
| The modal's step line says `photograph 7 of 12` and looks stuck | It is waiting on the provider: one request per photograph is what a thorough scan *is*, and the console timestamps each read (`Lot 142: photograph 7 of 12 read: 5 product group(s)`). Press **Eval** if you want a figure in seconds instead, or lower **Photos / scan** so fewer frames get the individual treatment. |
| The bottom of the modal says `Lot #19002 · eval` | The money line speaks for the row in hand, and that row's figures are still the text-only eval's. A real valuation replaces them the moment the photographed pass lands — the row's own badge and its italic **Max bid** say the same thing. `Board` at that position instead means no row is in hand: nothing has been appraised yet, or the board has been cleared. |
| The progress bar jumps back to nearly empty when I start scanning | It does not any more: the bar measures the work in hand, and a row's own **Eval** / **Price** is a one-row job, so it fills as that row is answered rather than re-scaling to the whole board. It still re-scales when the work changes — a walk's pages, then the rows of whatever appraisal was asked for — because those are genuinely different jobs. |
| The progress bar spins instead of filling | The walk's total is genuinely unknown: **All pages** on a listing whose pagination reports no page count. An indeterminate bar is the honest answer, and the status pill prints `page 2 — all pages` so the position is still readable. Pick a page count in **Pages** if you would rather see a fraction. |
| A row's items have no line under their names | Nothing legible was found on that lot's photographs — no barcode, no model number, no label worth quoting (deviation 26). That is a normal outcome for loose goods: the numbers are the model's, and they rest on what is visible. The console line `label reader read nothing legible on N photograph(s)` is the same statement. |
| The item line under a name quotes a number that does not match the photograph | The label reader read something off a label in the gallery — often a freight or stock-room sticker rather than the packaging, which is why the prompt is told to ignore tracking labels when they do not match a product. Re-**Price** the row: the console prints the literal reads (`label reader read barcode(s) … · identifier(s) …`) so you can see which label produced it. |
| Dragging one column edge seems to move the others | Expected: the table stretches to exactly fill the window, so the slack a widened column gives up is shared by the rest in proportion. **Reset column widths** in the table menu restores the shipped layout. |
| A column has gone missing from the table | The gear in the table toolbar hides columns, and the choice is remembered between launches — the gear is dotted while anything is hidden, and its tooltip counts how many. **Show all columns** in that menu draws them all again. |
| The table keeps its size when the window is narrowed | Also expected: below the table's natural width the dragged widths are kept and the table scrolls sideways, rather than squeezing columns someone deliberately sized. |
| A row says "2 passes" | DeepSeek appraised it twice — listing text first, then photographs (deviation 13). Gemini rows are single-pass. |
| Rows show `rate limited` | The provider refused the request: Gemini's per-minute (or per-day) allowance is used up, or DeepSeek's concurrency ceiling was hit. Lower **Requests / min**, wait for the window to reset (Gemini's daily quotas reset at midnight Pacific), or switch model. The app already waits out and retries short refusals. |
| Every lot fails with `HTTP 404` | Nothing to fix — the endpoint used to be built with `appendingPathComponent`, which turns Google's `:generateContent` method into a non-existent path. See deviation 11. |
| Rows show `HTTP 401`/`403` on DeepSeek | The key is missing, wrong, or the prepaid balance is empty. A `402`/`Insufficient Balance` message comes straight from the API's error body. |
| Valuation is much slower than the lots suggest | **Requests / min** is pacing the calls on purpose (the log prints `paced to N request(s)/min`). Raise it if your plan allows, or set it to "off". |
| Slow scans | Each request carries **every** photograph in the lot's gallery, and DeepSeek sends the lot twice. Switch to `gemini-2.5-flash-lite`, or narrow the board with **Eval all** first so only the lots worth it carry photographs. |
| A scan sends fewer images than the lot page shows | The rest did not fit one request's inline budget (one image over 6 MB, or the set over 12 MB); the console line says `N of M image(s), K over the inline budget`. Nothing to configure — the budget is the provider's payload ceiling — but a lot of very large photographs will always be trimmed. |
| A scan sends *more* images than the lot has photographs, or prices the site's own banner | `lotPageGallerySelectors` is too loose for the site (a bare `[class*='slide' i]`, or a container that wraps the header as well as the gallery, or a class the site reuses for its own carousels). Tighten it to the element that holds the lot's photographs — deviating from *this* lot's gallery is what an appraisal is allowed to be wrong about. The reader already sends one address per photograph: each thumbnail's *opened* copy rather than the thumbnail, and one entry per photograph however many sizes the page prints. |
| The log prints `the page data supplied N more photograph(s) than the gallery markup held` | Expected on a site whose thumbnail strip is built in JavaScript: the HTML the reader fetches holds the frame and an *empty* strip, and the other addresses came from the page's own data blob. They were taken because they share the lot's folder — the check that keeps the "recently viewed" rail out — so the count is the lot's photographs, not the page's images. Nothing to configure. |
| An **Eval** reads the card's teaser rather than the full copy | `lotPageDescriptionSelectors` matched nothing on the lot page — the site keeps its copy somewhere the profile does not name, or serves it only to a signed-in session. Add the container (the block itself first, the column second) and re-**Eval**. |
| The log says "the lot page could not be read" | The scan fell back to the card's thumbnails and the card's teaser. Usual causes: the page needed a login the session did not have, or the site served a challenge page. Open the auction page (the **info** glyph) to see what the site is returning. A gallery built in JavaScript is not by itself the reason — its strip is read from the page's own data blob when the addresses share the gallery's folder (see the row above) — so this is a page the reader could not get at, not one it could not parse. |
| Rows show `empty model answer` on DeepSeek | JSON mode returned nothing even after the automatic re-ask (DeepSeek documents this failure mode). Re-run the lot; it is a per-call coin flip, not a configuration problem. |

