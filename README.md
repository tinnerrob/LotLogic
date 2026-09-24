# Pallet Auction Bid Tool

A native macOS app that scrapes liquidation-auction lot listings from a site you sign into,
appraises every pallet with a multimodal model (Gemini by default, DeepSeek Flash as an
alternative), and shows the numbers in one expandable table — so you can decide, before the
hammer falls, whether a lot is worth bidding on.

* **Scrape** — a hidden `WKWebView` logs in with your credentials and walks the result pages you ask
  for (a count from the **Pages** menu, or **All pages**), harvesting lot numbers, titles,
  descriptions, current bids and photo URLs (the thumbnails a card
  carries; the photographs worth appraising are read off each lot's own page when that lot is
  scanned). The lot number is the
  one the site prints — a card whose only identifier is its own DOM element id (`ItemMain19002`) is
  reduced to the digits (`19002`) rather than shown as an element address.
* **Price on demand** — nothing is appraised behind your back. Every row carries **Eval**, **Price**
  and **Open**. **Eval** asks the provider one cheap question about the listing text alone (no
  photograph is fetched or billed) and **Price** sends that lot's text *and* **every photograph on
  its own page** — the count is the lot's business, so the lot's page answers it instead of a
  setting — and **Open** puts that same page in a window over the table, for the photographs and the fine
  print nothing has to pay for. The toolbar has the same pair for every lot that has nothing yet.
  Either reply is constrained to a JSON schema, so the app gets numbers it can add up instead of
  prose — including `evidence`, the label wording or barcode digits each price was built from, since
  the app reads the barcodes and model numbers off the photographs itself before the model sees them
  (deviation 26). DeepSeek is asked twice per scan: once for the listing text, then again with the
  photographer's eye.
* **Decide** — the table rolls those items up into per-lot retail, resale, profit and ROI, sortable
  by lot, description, bid, retail, resale, profit or ROI in either direction, with a progress bar
  and activity console at the bottom. The table always fills the window, its column boundaries are
  drag-to-resize handlebars, and the credentials and provider live behind the title row's gear
  (`⌘,`) rather than in the way of the rows.

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
DeepSeek passes, how a whole gallery of photographs is attached and trimmed to one request's inline
budget, the on-device label reader's rules for what counts as a barcode or a model number, every sort
field, the bid ceilings, the anchor threshold, the search matching, the
column geometry — including how it stretches to fill a wider window — the cleaning of scraped lot
numbers, the sold / empty-catalogue rules and the address of a listing's later result pages)
without a key or any network traffic: it compiles the real services and the real UI-free models
against a stubbed `URLProtocol`:

```bash
./Tools/free-tier-harness/run.sh     # exits non-zero if any check fails
```

The injected page script has its own check: it compiles `ScraperScript` with the real selector
profile, dumps the generated JavaScript and runs it against a small DOM shim in Node — the
lot-number rules, the sold-badge / empty-catalogue rules, the addresses a listing prints for its
later pages and the parameter it numbers them with, and the reading of a lot's own page (a
gallery served from another host, a lazy-loaded photo, a CSS background, a JSON blob, a 404) are all
driven there (skipped, not
failed, when Node is absent):

```bash
./Tools/scraper-js-check/run.sh      # exits non-zero if any check fails
```

The window is one column: a control panel that folds, the lot table, the activity console and the
progress footer.

1. Launch the app.
2. Paste the **lot-list URL** (the page that already lists lots, e.g. `…/auctions?page=1`).
3. Optionally open the **gear** (top right, or `⌘,`) and fill in **Site email / Site password** —
   leave both blank to scrape anonymously or to reuse the session already stored by the app.
4. In the same modal, pick a **Provider** and paste its API key.
   **Gemini** (Google AI Studio) has a **free tier** that needs no billing account and costs
   nothing — see *Cost* below. **DeepSeek Flash** is the paid alternative: cheaper per token, but it
   draws on a prepaid balance. Each provider keeps its own key and model, so switching back and
   forth is free. The gear wears an orange dot while the selected provider has no key, because
   nothing can be appraised without one.
5. Press **Scrape Lots**. Pages stream into the table; no API call is made yet. An auction with
   nothing left to bid on stops on the first page and says **no active listings** — that is the
   catalogue's own answer, not a failure. Lots the site has already sold are listed too and flagged
   **Sold** in the **Active** column — a flag, not a lock: a closed lot's page still describes what
   was in it, so Eval and Price work on it like any other, and both all-lots passes include it.
6. Press **Eval all** for a cheap text-only figure on every lot, then **Price** the rows worth
   appraising — or **Price all** for the whole board — and sort the result by whichever number
   matters today. Drag a column's edge to resize it; the table always fills the window.

---

## Architecture

```
PalletAuctionBidTool/
├── PalletAuctionBidToolApp.swift    Window scene, minimum window size, menu trimming
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
│   ├── Formatting.swift             Currency / percent / geometry formatting helpers
│   ├── ScrapeProfile.swift          Declarative selector strategy (data, not code)
│   ├── ScrapeProfilePresets.swift   `ScrapeProfile.genericBase()` — the default strategy
│   ├── PaginationPlan.swift         The address of a listing's nth result page — an address in, an
│   │                                address out, so the walking rule is testable off-device
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
│   ├── GeminiValuationService.swift REST v1beta `:generateContent` client (schema-constrained)
│   └── DeepSeekValuationService.swift OpenAI-compatible `/chat/completions` client (json_object,
│                                    two passes: listing text, then photographs)
├── ViewModels/
│   └── AnalysisCoordinator.swift    @MainActor @Observable pipeline + progress/derived state
└── Views/
    ├── ContentView.swift            Layout: control panel, table, console, footer
    ├── ControlPanelView.swift       Title row (readiness, gear), URL and run buttons, Run tuning card
    ├── SiteSettingsSheet.swift      The modal behind the gear: site login, provider, model, API key
    ├── SettingsFieldRow.swift       One labelled setting — the row both settings surfaces are built from
    ├── CollapsibleSection.swift     The expand/contract card Run tuning is built from
    ├── Theme.swift                  Design tokens: radii, paddings, chip/card fills plus the
    │                                `.cardStyle()` / `.chipStyle(tint:)` / `.microCaps(_:)` modifiers
    ├── LotTableView.swift           Toolbar (Eval all / Price all, sort, search, the columns
    │                                gear), table
    ├── LotTableRow.swift            Header (handlebar-resizable), lot rows, item rows, the buttons
    ├── BrowserPanelView.swift       Shows the real page (captcha / MFA hand-off)
    ├── LotPageSheetView.swift       A lot's own page as a sheet, behind the row's Open button and
    │                                its lot number — its own web view, the scraper's cookies
    ├── LogConsoleView.swift         Folding activity console (folded, it shows the newest line; its
    │                                own chevron is the only control for it)
    └── ProgressFooterView.swift     Progress bar, counters, running totals
Tools/
├── free-tier-harness/               Offline harness: quota retry, pacing, both DeepSeek passes,
│                                    the table's ordering rules, bid ceilings, anchor flags, search
│                                    matching, lot-number cleaning, the sold/empty-catalogue rules,
│                                    column geometry — including stretch-to-fit — the column
│                                    chooser, and every photograph a lot has being attached and
│                                    trimmed to one request's inline budget (see Build & run)
└── scraper-js-check/                Runs the generated page script against a DOM shim in Node, so
                                     the lot-number *and* sold-badge rules are checked on the page
                                     side too — and so is the lot-page reader, with a `DOMParser` and
                                     a `fetch` standing in for the browser's
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
                     │        └─ window.__PAS.lotPageImages(url) ──▶ every photograph on the lot's
                     │           (one GET, through the loaded listing)   own page ──▶ the subject
                     │                                       │
                     │                                       ├─ GeminiValuationService.value(...)   (default, 1 pass)
                     │                                       └─ DeepSeekValuationService.value(...) (2 passes)
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
   has marked the lot sold; `AuctionScraperService` keeps only lots whose `dedupeKey` is new.
   Pagination is **by address first** — page 2 is the run's address carrying `?page=2`, page 3
   carries `?page=3`, and so on (`PaginationPlan`), using the site's own link for a page when it
   printed one — with a click of the site's own "next" control kept for listings that address
   nothing (**Load more**) and as the recovery when an address turns out to repeat a page already
   read. The walk ends when a page has no lots on it: the catalogue's own "no results" surface, a
   blank grid, the body of a 404, or a page whose signature has already been harvested. A page whose
   own "no results" surface matches (`noResultsSelectors` + `noResultsTextPattern`) ends the run
   instead of timing out: on page 1 that is reported as **no active listings**, not as a broken page.
4. **Scrape only** — the run ends there. Nothing is appraised automatically, so loading a board of
   200 lots costs nothing and touches no API key. The footer's bar measures the walk itself — pages
   read out of the pages this run was asked to read — so three pages fill a third, two thirds, then
   all of it, and the run's own work is done at 100% ("Loaded 200 lot(s) — nothing scanned") until
   something is scanned. (An **All pages** walk of a listing that reports no page count has no honest
   denominator, so the bar spins instead: see `AnalysisCoordinator.progressFraction`.)
5. **Price a lot** — each row carries three buttons. **Eval** runs the cheap text-only pass: one
   request, no photograph fetched or billed, no line items, so the row keeps saying "not scanned"
   while its money columns show a provisional figure — the row's `provisional` flag and its italics
   are what say so. **Price** reads that lot's own page first — one GET, through the listing already
   loaded, so the results page never moves — and then sends the
   same prompt and the same scraped text plus **every photograph the page carries** (downloaded
   concurrently, MIME-normalised, then
   inlined as base64 — `inline_data` parts for Gemini, `image_url` data URLs for DeepSeek) and asks
   for a JSON array of items with retail/resale estimates. A card only ever shows thumbnails, so the
   lot's page is where the photographs are, and how many there are varies per lot: the page decides,
   not a setting (deviation 24). **Open** is the same page in a sheet over the table — the
   photographs, the full description and the bid history, with nothing sent anywhere and with the
   run's session behind it, so it arrives signed in. Safari stays one click away in that sheet's
   header. The toolbar
   does the same pair for every lot at
   once (**Eval all** / **Price all**), skipping only lots that already have the figure
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
6. **Roll up** — per lot: total retail, total resale, profit, ROI and a status badge. Each row also
   shows a **Max bid** — the highest bid worth placing, a tuned percent of the resale figure taken at
   the lot's *weakest* confidence level, and red once the live bid passes it. A ceiling that rests on
   an **Eval** rather than a **Price** is drawn in italics, so a first look never reads as a measured
   number. Expanding a row lists the appraised items — each with the label text, barcode digits or
   model number the price rests on under its name — and any
   line at or above the **Anchor ≥** threshold (default $100) is flagged as an anchor. The footer
   shows live counters and totals for the whole board.

### How one scan works

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
fetches the lot's page and attaches every image on it. What can still hold an image back is technical
rather than editorial — one photograph over 6 MB, or a whole gallery over the 12 MB budget a single
request is allowed (base64 inflates the payload by about a third, and the providers cap it) — and
anything held back is *counted*: the console says `40 of 46 image(s), 6 over the inline budget`
instead of quietly reporting forty, and `ValuationOutcome` carries the three numbers the row and the
log are built from. If the page cannot be read at all (a challenge, a 404, a gallery rendered only in
JavaScript), the card's thumbnails stand in and the log says which happened — a scan never fails over
a page that will not read.

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

* Press **Page** in the control panel (or let a challenge open it automatically) to see the live
  `WKWebView` — the *same* instance the automation is driving, cookies included.
* Solve the captcha / enter the MFA code there, press **Done**, then **Scrape Lots** again.
  Because the app reuses one web view and one data store, the run resumes authenticated.
* The automation keeps running while the sheet is open, so page logs stay live in the console.


---

## Session, credentials and keys

| Value | Where it lives | Notes |
| --- | --- | --- |
| Auction URL, tunings, provider, model IDs | `UserDefaults` | Written when a run or a scan starts. |
| Site email / password | `UserDefaults` | **Plaintext caveat — see below.** Edited in the settings modal (⌘,). |
| Gemini API key | `UserDefaults` | Sent as the `x-goog-api-key` header, never in a URL or a log line. |
| DeepSeek API key | `UserDefaults` | Sent as `Authorization: Bearer …`, never in a URL or a log line. |
| Site login cookie | `WKWebsiteDataStore.default()` | App container; persists between launches. |
| Scraped lots / valuations | memory only | Nothing is written to disk; quitting discards results. |
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
| **429 retry** | A refusal is waited out, not failed: the delay comes from the `Retry-After` header, else from the `RetryInfo.retryDelay` in Google's error body (`"17s"`), else from exponential back-off with jitter. Up to 4 attempts per request. DeepSeek sends no delay hint, so it always uses the back-off. |
| **Stop** | Cancellation during a back-off ends the run immediately — a quota pause never holds the app hostage. |

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
    listing text. This used to be a **Text-only first look** switch beside **Eval** in Run tuning;
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
    It is *not* the window's **Page** panel, and it is no longer the operator's browser either. That
    panel reparents the scraper's live `WKWebView` (deviation 19's captcha hand-off), so pointing it at
    a lot would take the automation off the results page it is working on. A browser tab was the old
    answer to that, at the price of leaving the table — and of opening into whichever window was in
    front, on top of the lot the operator was comparing. `LotPageSheetView` is the third option and the
    one actually wanted: a *second* web view on the same default `WKWebsiteDataStore` the scraper uses,
    so the page arrives signed in with the session the run just earned, the automation's page never
    moves, and a challenge cleared in the sheet counts for the next run as well. Safari is still one
    click away — **Open in Browser** in that sheet's header — for printing or a site that misbehaves
    in a web view, so the old behaviour became a choice rather than a dead end. The three of them are
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
19. **Site login & valuation is a modal behind a gear, not a card in the panel.** Those four fields
    are set once per install, and as an expanded card they cost the table about 120 points of height
    on every launch — the one resource a hundred-row table actually needs. So the panel's title row
    now carries a gear (`⌘,`) that opens `SiteSettingsSheet`: site email and password, provider,
    model and the provider's own key, with one line of grey type each and a full-width line for the
    key, which is pasted rather than typed. Nothing was hidden by the move: the summary line the
    folded card used to show ("no site login · Gemini · gemini-2.5-flash · no key") still sits beside
    the gear, the gear wears an orange dot while the selected provider has no key, the modal
    states the same thing as a pill, and every "add a key" hint in the table and the footer now
    names the gear instead of the card. Edits apply as typed — there is no Cancel — which is why the
    footer button says **Done**; both surfaces are built from `SettingsFieldRow`, so the panel's Run
    tuning and the modal cannot drift apart. **Run tuning** stays a folding card: unlike credentials,
    its numbers are worth watching and changing mid-session. Inside it the six fields now run one per
    line — `Pages`, then **Requests / min**, a hairline, then the three bid percentages and the anchor
    threshold — rather than two and then four across. Across the width the captions landed at four
    different x positions, so the card could not be read down a column, and the controls had to share
    the space: the **Pages** menu wants to say how long *this* listing is, and a menu that has to fit
    beside a stepper in half a window cannot say much. The stacked form costs about 100 points of
    height in a card that is folded by default, and buys one label column with the whole window left
    over for each control (the panel's own `tuningField`, which pins a picker or stepper to the left
    where `SettingsFieldRow` would otherwise let it float in the slack a text field would fill).
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
    not a failure: the footer and the console say "no active listings", and the table's empty state
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
    defaults. The gear wears the same dot the settings gear wears: there it means "not configured
    yet", here "not everything is being shown". The rules are pinned by harness check 29.

24. **The number of photographs is the lot's business, not a setting — so the app reads the lot's own
    page.** There was an `Images / lot` stepper (1–8, defaulting to 4), and it was wrong for the same
    reason a fixed page count would be: a lot's gallery is as long as the lot makes it. One sealed
    pallet shows two photographs; a mixed one shows forty; and the four a card carried were thumbnails
    either way, so the operator was guessing a number that was never theirs to know. The stepper is
    gone, along with `AppSettings.imagesPerLot` and the `imageLimit` argument the valuation services
    used to take, and **Price** now reads the lot's own page and attaches every image on it.
    Four decisions are worth stating. (a) *The page is fetched, not navigated to.* `window.__PAS` runs
    a same-origin `fetch` against the lot's URL from inside the listing the scraper already has
    loaded, then parses the answer with `DOMParser`. That is what makes it affordable and safe: the
    request carries the operator's own session cookies (a second web view, or a Swift-side
    `URLSession`, would need a cookie copy to match), it costs one GET rather than a load-and-come-back,
    and the results page — its scroll position, its page number, the automation's own state — is never
    touched. `callAsyncJavaScript` is what awaits the promise; `evaluateJavaScript` would hand back the
    unresolved promise itself. (b) *Everything on the page counts, and nothing is capped.* The reader
    collects the markup's `<img>` (including lazy `data-src` and every `srcset` candidate), `<picture>`
    sources, CSS background images and links to image files, plus the two places a gallery hides when
    it is not in the markup at all: a declared lead image (`og:image`, `twitter:image`,
    `link rel="image_src"`) and image URLs inside data blobs (JSON-LD, `__NEXT_DATA__`). Relative
    addresses resolve against the *lot page*, not the listing — joining `/images/208-1.jpg` onto the
    results address is a silent 404, which is why `absolute(_:base)` now takes a base. The card's own
    thumbnails remain as the fallback and keep their profile bound, now named `maxCardImages` because
    that is all it ever was. (c) *A page that will not read is not a failed scan.* A challenge page, a
    404, a non-HTML document or a gallery rendered entirely in JavaScript comes back as `ok:false` (or
    as zero images) and the scan proceeds with the card's thumbnails, saying so in the log. The one
    thing that *can* still hold a photograph back is the provider's payload ceiling — one image over
    `maxImageBytes`, or a whole gallery over `LotImageLoader.defaultTotalBytes` (12 MB, ~16 MB once
    base64-encoded, comfortably inside Gemini's 20 MB request limit and DeepSeek's 48 MiB body cap) —
    and that is reported rather than silently applied: `ValuationOutcome` carries
    `imagesAvailable`/`imagesSent`/`imagesSkipped`, so the console can say `40 of 46 image(s), 6 over
    the inline budget`. (d) *It costs one extra request per lot.* About 1 GET on the auction host per
    scanned lot, which is why it happens at **scan** time rather than at scrape time: a board of 200
    lots where three are ever scanned pays for three page reads, and a sold or ignored lot pays
    nothing.

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

---

## Retargeting to another auction site

Selectors live in data, not code: edit `ScrapeProfilePresets.genericBase()` or add a new
`ScrapeProfile` and hand it to `AuctionScraperService(profile:)`. Every list is tried in order,
most specific first. Nothing in `ScraperScript.swift` has to change.

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
| `maxCardImages` | How many thumbnails are taken from a *card*. Only the fallback path uses it: a lot whose page cannot be read is still appraised from its card. It is not the lot's image count, and nothing in the UI sets it. |
| `imageMetaSelectors` | Where a page declares its lead image (`og:image`, `twitter:image`, `link rel="image_src"`). The lot-page reader falls back to these when the gallery markup itself is rendered by JavaScript. |
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
| "No lot cards were found" | The log prints page diagnostics (matched selectors, card counts, ready state). Check that the URL really is a listing page, then widen `cardSelectors`. |
| A run stops after page 1, or after a few pages | Working as intended, and the log says which reason fired — the walk ends at the first page with no lots on it, and every stop is reported: *"The listing reports N page(s) — there is no page 2"*, *"No lot cards appeared on page 2 — the listing has no such page"*, *"Page 2 served a page already read …"*, *"The listing did not change after clicking next"*. Pages are asked for by address (deviation 6): `?page=2`, `?page=3`, …, in the parameter the listing was seen using, and with the listing's own link for the page when it printed one. So the fix is the address shape: check in **Page** whether the *next* page really is `?page=2` (a POST or a JS-only pager is what the click fallback covers — widen `nextPageSelectors` for that), and note that `?p=`-shaped pagination is deliberately not read as a page number. |
| A run walks past the last page, or loops | Should not be possible: the listing's own page count ends the walk when it reported one, a repeated page signature is caught against every page already read, and `ScrapeLimits.maximumPages` is the 100-page runaway guard. If it happens anyway, the site is answering different content for the same page number (a rotating "recommended" strip is enough) — the log's `Pagination: asked for page N, the site's address says page M` line says which address it actually landed on. |
| "No active listings" | Working as intended (deviation 22): the page's own empty state — *"Results: No Items Found."* — or every scraped lot being marked sold. Nothing was spent and nothing failed. If the auction really does have lots, widen `noResultsSelectors` / `noResultsTextPattern` (a false positive) or check the **Page** panel. |
| The **Active** column says "Sold" on lots that are still open | The sold rule matched something the site did not mean. The site's own badge is the authority (a short status element, then a card attribute, then the card text), so add the site's real badge to `lotStatusSelectors` and, if its wording trips the fallback, tighten `soldTextPattern`. The harness's check 28 pins the "sold as one pallet" case, and the Node shim pins the badge cases. |
| The **Active** column says "Active" on lots the site has sold | The marker is somewhere the profile does not look. Find the element that carries it in the **Page** panel and add its selector to `lotStatusSelectors` (or its attribute name to the list in `readCard`). Sold lots are only *flagged* — never dropped and never locked, so nothing is lost and nothing is off limits while you tune it. |
| The table's columns do not line up under their headers | Should not be possible: the header and every row are laid out from one `ColumnWidths`, and the scroll content is re-keyed on the column choice. If a column still drifts, a cell is failing to hold its width — see deviation 23(d), where an empty cell is the usual culprit. Widths, not positions, are what the header and the rows share. |
| "Automation ready" never logs | The page blocked main-frame injection or JavaScript. Open **Page** and inspect. |
| Login never completes | Wrong form selectors, or a challenge screen. Open **Page** to see what the site is asking. |
| A lot is skipped or failed | The provider returned an unusable reply, or images failed to download. The row shows the reason and the console has the detail. Press **Price** again on that row — a failure is per lot, not per run. |
| A row's **Price** button is greyed out | The selected provider has no key (**the gear, ⌘, → API key** — the gear is dotted orange while that is the case), or the lot is already appraised. The footer's status line names which. Rows are also locked while a scrape or an all-lots batch is running — press **Stop**, or wait. |
| A row's **Eval** button is greyed out | The same key gate as **Price**, or the lot already has an appraisal: a real valuation hides provisional figures, so evaluating it again would buy a number nothing shows. Use **Reset valuations** in the table menu first. |
| A row has no **Open** button | The card declared no address for that lot, so there is nothing to open and no button to press. The address search has four sources (deviation 17): the anchors `detailLinkSelectors` names, the card's own first usable anchor, the anchor the matched card *lives inside*, and — once the lot number is known — any anchor whose address carries that number, on the card or anywhere on the page. So the usual fix is a shape the profile does not know: put the site's lot-page pattern in `detailLinkSelectors` and its furniture (sign-in, share, wish list) in `nonLotHrefPattern` in `ScrapeProfilePresets.genericBase()`. The log says how many rows came with an address: `Page 1 extracted: +24 row(s) …; 24/24 with a lot-page address` — `0/24` means every card was in the same shape, which is worth a look in the **Page** panel. |
| Nothing is appraised after a run | Expected: a run only scrapes now (deviation 12). Press **Eval** for a cheap text-only figure, **Price** to appraise a row from its photographs, or the two **…all** buttons to work through every lot that has nothing yet. |
| The Lot / SKU column shows something like `ItemMain19002` | The card exposed no lot number of its own, so the app fell back to the `id` — and the wrapper rule did not recognize the site's prefix. Add the element that carries the number to `lotNumberSelectors` (or its attribute to `lotNumberAttributeCandidates`) in `ScrapeProfilePresets.genericBase()`, and add the site's id prefix to `lotNumberWrapperWords`. See deviation 18. |
| `Eval all` says every lot already has a figure | Working as intended: lots with a valuation or an eval are skipped rather than evaluated again (deviation 17). **Reset valuations** in the table menu clears them if you want them priced again. |
| The progress bar only fills part of the way on a scrape-only run | It does not any more — the bar measures the work in hand rather than a fixed share of it. While the walk runs it is pages read out of the pages this run was asked to read, so a 3-page run fills a third, two thirds, then all of it; a finished scrape is 100%, because the pages *were* the job. |
| The progress bar jumps back to nearly empty when I start scanning | Expected, and deliberate: once lots are being appraised the bar measures *that* work instead — lots answered out of lots on the board — so it re-scales when the work changes rather than pretending a scan is a continuation of a walk. |
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
| Slow scans | Each request carries **every** photograph on the lot's page, and DeepSeek sends the lot twice. Switch to `gemini-2.5-flash-lite`, or narrow the board with **Eval all** first so only the lots worth it carry photographs. |
| A scan sends fewer images than the lot page shows | The rest did not fit one request's inline budget (one image over 6 MB, or the set over 12 MB); the console line says `N of M image(s), K over the inline budget`. Nothing to configure — the budget is the provider's payload ceiling — but a lot of very large photographs will always be trimmed. |
| The log says "the lot page could not be read" | The scan fell back to the card's thumbnails. Usual causes: the page needed a login the session did not have, the site served a challenge page, or the gallery is built entirely in JavaScript and declares no `og:image`. Open **Page** to see what the site is returning; if the gallery really is JS-only, adding its JSON endpoint to `imageMetaSelectors` is not enough — the address has to appear in the page's own markup or data blob for the reader to find it. |
| Rows show `empty model answer` on DeepSeek | JSON mode returned nothing even after the automatic re-ask (DeepSeek documents this failure mode). Re-run the lot; it is a per-call coin flip, not a configuration problem. |

