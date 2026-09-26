# Manifest identity & cross-view dedupe — implementation plan

**Status:** Tier 1 (A–D) is implemented and green — `xcodebuild … CODE_SIGNING_ALLOWED=NO` builds and
`Tools/free-tier-harness/run.sh` passes with checks 44–46 added. **Tier 2 (E–G) is implemented too —
harness check 48** — see *Tier 2* below for what it came to. **Tier 3 (H) is implemented as well —
harness check 49** — see *Tier 3* below. **Tier 4's provider split (I) and the credentials work it needs
are implemented too — harness checks 50 and 50b** — see *Tier 4* below for what it came to. **Tier 5
(K–M) is implemented as well — harness check 50e, with 50b extended** — see *Tier 5* below, which is what
made the photograph half work in both directions. Part **J** (surfacing the duplicates a merge could not
settle) of Tier 4 is the one item still outstanding.
Each tier lands behind a green build and a green harness run before the next begins.

**What Tier 1 actually came to, against the plan below.** A: the route groups the gallery before it
batches, and acts only on the fold that cannot cost anything — a frame that is the *same picture*; the
grouping is asked with the whole gallery as its ceiling, and only `samePicture` folds are left out. That
needed three things the plan did not name: a `.folded(PhotoView)` console event (a repeated frame here is
*not* carried anywhere, so `grouped`'s wording would be false), `LotManifestPrompt.runPhrase(_:)` (a
batch can no longer state a *range* of gallery numbers — it names them as a list), and `ManifestChunk`
carrying each batch's gallery numbers plus how many frames it answers for, so the readout still reaches the
gallery. B: `productCodes` intersects barcode-shaped codes first, and `DeepSeekValuationService
.withLocalCodes(_:labels:positions:)` folds the reader's decodes for the frames an item names into that
item's identifiers. C: `labelText` on `LotImageEvidence`, filled by `labelLines(in:)`/`labelWording(_:)`
— the reader's *second* filter, kept narrow so the freight labels and paperwork stay out. D:
`namesDescribeSameProduct(_:_:)` over `nameTokens(_:)`, with sizes and pack counts canonicalised and
required to agree. Harness: 44 (the route's picture fold), 45 (the identity questions, unit and end to
end), 46 (the wording filter and its prompt line). README: deviation 35 added, and deviation 33's fold
paragraph rewritten where it described the old name-and-number fold.

**What Tier 4's split actually came to, against the plan below.** The seam is `ManifestService` plus
`ManifestBatchRequest` (the whole of a batch question as a value, so the two transports cannot drift about
what a batch is told), both transports conform, and `DeepSeekValuationService` takes an optional
`manifestService` whose `nil` *is* the old route. Three things the plan did not name: `ValuationOutcome
.identityModelID` (how the run says which model read the inventory it priced, `nil` wherever the model that
priced the lot read it too), `AppSettings.runsSplitIdentity` (the rule — batching on *and* a different
provider named — which is what keeps an inert setting from looking broken), and
`missingKeyRolePhrase(for:)` / `missingKeyPhrase` (a split run buys two things, so the readiness note and
the console have to be able to say *"a Gemini key (the manifest half)"*). `IdentityProvider.deepSeek` is a
case of its own rather than folded into `.same`, so the choice survives switching **Appraise with** to
Gemini and back, and `identityRouteSummary` states the second model once, in one place, for every call
site that prints it (the console's loading, settled and cancelled lines and the Account sheet's footer),
while the panel's tooltip words its own clause from the same two facts. Harness: 50 (the split end to end,
two stub hosts and both keys) and 50b (its three inert states and its two key truths), plus an assertion in
38 that an unsplit route records no identity model at all. README: deviation 39 added, and the
architecture tree, the setup steps, "How one scan works", the cost tables, the Account sheet's
description, the session/credentials table and the troubleshooting table all name the split.

## The problem

A lot's gallery is one pallet photographed several times — front, side, a lifted carton flap, and
often a re-listed copy of an image that already appears. The batched route
(`DeepSeekValuationService.manifestRoute`) sends the gallery in `photosPerRequest`-sized requests and
folds each batch's answer into one `PalletManifest`. Today the fold matches two sightings only on
**model number when both batches read one, else exact normalised product name**. So a carton split
across two batches — where one batch never saw the barcode the other did, or where the two batches
named the same product slightly differently — becomes **two rows**, and the pallet is paid for twice.

The same risk exists inside a batch (the prompt asks for it, but nothing verifies it) and on
re-scans (a stored reading and a fresh reading of the same frame).

## The four dedupe layers, as they stand

| # | Layer | Where | Signal |
|---|-------|-------|--------|
| 1 | On-device pre-request | `PhotoFrameGrouping` (16×16 luma fingerprint + equal decoded-barcode set), `LotImageDigest` | same pixels, same barcode **set** |
| 2 | Per-batch prompt rule | `LotManifestPrompt.manifestSystemInstruction` | "count once across views in this batch" |
| 3 | Cross-batch fold | `PalletManifest.absorb(_:)` → `ManifestItem.isSameProduct` / `merge` | model number, else exact name |
| 4 | Pricing pass | `LotManifestPrompt.pricingPrompt` | text only, no pixels |

Layer 1 runs on the thorough route only; the batched route never folds. Layer 3 is the known weak
point.

## Tier 1 — on-device + deterministic fold (highest leverage, cheapest)

### A. Fold provably-identical frames on the batched route — **done**
- Call `PhotoFrameGrouping.group(images:labels:limit:)` in `manifestRoute` **before**
  `LotImageLoader.batches`.
- Build the batch list from the representative frames; drop exact duplicates and merge their
  `LotImageEvidence` into the representative's, so a folded frame's decoded barcode still reaches
  the prompt.
- Report the fold to the console so the operator sees it. This folds only *same pixels / same full
  barcode set* — never "two angles of one carton" — so it cannot remove a view the model needed.
- **Acceptance:** a gallery whose frames 2 and 3 are byte-identical sends 2 manifest images, not 3;
  the fold is logged; frame 3's barcode still reaches the prompt.

### B. Identifier-first identity in `ManifestItem.isSameProduct` — **done**
- Add an **identifier intersection** test before model-number/name matching: a shared barcode/SKU is
  conclusive "same product" even when the names differ.
- Make it deterministic by injecting the **on-device** decodes into the fold: after a batch returns,
  for each item union its `views`, look those frames up in the already-computed `labels`, and append
  their `barcodes`/`identifiers` to the item's `identifiers`.
- **Acceptance:** two batches reporting the same UPC on frames 2 and 5 under different names fold to
  one item.

### C. Surface full recognised label text on-device — **done**
- Add `labelText: [String]` to `LotImageEvidence`, filled from the `VNRecognizeTextRequest` lines
  that are *not* identifier-shaped (capped, truncated). Add a "Printed label text: …" line to
  `promptLines` / `singlePhotographPromptLines`, so the model is handed more than the digits.
- **Acceptance:** the existing `LotImageDigest` harness check is extended so a stubbed reading yields
  label lines and the prompt carries them.

### D. Canonicalised, token-overlap name matching — **done**
- Replace exact normalised-name equality in `isSameProduct` with a token matcher: strip
  pack-count/size stopwords (`24-pack`, `22 oz`, `12x`, `12 ct`, …), build token sets, require brand
  compatibility **and** a token-containment/Jaccard threshold. Model-number match stays strongest;
  "both read different model numbers ⇒ two products" stays.
- **Acceptance:** `Yankee Candle 22 oz jar` vs `yankee candles, 22oz` merge; `Energizer MAX AA` vs
  `Duracell AA` do not.

## Tier 2 — model-side prompt and contract — **done** (harness check 48)

- **E. `views` required and exhaustive.** — **done.** `views` joined the manifest line's `required`
  (`itemName`, `quantity`, `confidence`, `views`), and the top level grew `unreadPhotos` — an array of
  gallery numbers — so every frame a batch was handed is either named in some entry's `views` or
  declared goods-free. The schema asks for it but does *not* require it, deliberately: DeepSeek's
  `json_object` mode is advisory, and the strict `responseSchema` provider (Tier 4's Gemini path) would
  fail a whole batch over an accounting list. The decode reads it when it is there and reads it as empty
  when it is not (`LotManifestAnswer.answer(fromAnswerText:finishReason:)` →
  `ManifestBatchAnswer`), and what the answer *did not* account for is named rather than swallowed:
  `ManifestBatchAnswer.unaccountedFrames(among:)` compares the answer with the frames the batch carried,
  the route reports the difference (`PhotoScanEvent.manifestGap`), and the frames a batch did declare
  empty ride on the inventory as `PalletManifest.unreadFrames` so the settled console line says
  `… 4 of the rest declared empty` instead of reading as though those photographs were never looked at.
- **F. Same-carton cues and tiebreaker.** — **done.** `manifestSystemInstruction` gained two rules: a
  cue list in the fold's own order of trust (barcode digits → model/part/SKU → brand with product line
  and pack count → label wording → printed size/weight/count → stack position and neighbours → damage
  and repacking), with a disagreement where it counts meaning two products; and the tiebreaker — *one
  entry with a note beats two entries* — with the worked example of two sides of one 24-pack (one entry,
  both frames in `views`, not a count of 2). The batch question repeats the accounting obligation where
  the gallery numbering is stated.
- **G. Manifest temperature 0.0.** — **done.** `LotManifestPrompt.manifestTemperature` is `0.0` and is
  what the DeepSeek batch sends; `LotValuationPrompt.standardTemperature` names the `0.2` every other
  pass samples at (the pricing pass, the photograph reads, the single-pass appraisals, in both
  transports — the literal is gone from `GeminiValuationService` too). The Gemini half of the "mirror"
  **landed in Tier 4**: `GeminiValuationService`'s `manifestBatch(_:)` passes this same constant rather
  than one of its own, so the batcher's temperature belongs to the batcher whichever model reads the batch.
- **Acceptance (harness):** check 48 reads the schema as JSON (a line must carry `views`;
  `unreadPhotos` is an array of numbers; the top level still requires only `manifest`), asserts each cue
  and the tiebreaker in the prompt, asserts both temperatures as constants, and then drives a real batch
  that answers about one frame, declares a second empty and passes over two more — asserting the
  inventory's `unreadFrames`, the settled line's clause, the `manifestGap` event's frames and its
  console wording, and `temperature: 0` on the batch request against `0.2` on the pricing request.
  (Check 39 covers the decode: a missing list reads as empty, and the same positions clamp applies.)

## Tier 3 — count accuracy

- **H. Prefer the better count; record the conflict.** — **done.** `merge(_:)` no longer maximises:
  `ManifestItem.mergeCount(with:)` ranks the two sightings on what the app can check — the claimed
  `confidence`, then a decoded product code (`productCodes`, the cue `isSameProduct(as:)` trusts first),
  then how many `views` the sighting was seen in, and only failing all three the larger count, which is
  the old rule and the one rung a tie can fall to without depending on which batch answered first. A
  sighting with no count at all (`quantity == 0`, what an omitted field decodes to) is not a second
  opinion and never shrinks the other's number. The comparison is between the two *sightings*, not between
  the folded line and the arriving batch: what the batch behind the count claimed is kept on the item as
  `ManifestItem.CountOwner`, because `views` and `identifiers` accumulate across every batch folded, and a
  third disagreeing batch measured against those would make the answer depend on how many batches arrived
  first. What they disagreed about is kept typed on the item —
  `ManifestItem.CountConflict` (`counts`, `kept`, `reason`) — and rendered as one sentence,
  `counts 4 and 6 disagreed; kept 6 — the sighting that read the barcode`, which travels two ways: as
  `ManifestPayload.Item.countConflict` on the manifest slab the pricing prompt carries (with pricing rule
  3 telling the model to price that count and not re-count it), and under the entry in the expanded row,
  in the caution colour. The counts are sorted and deduplicated, so the note reads the same whichever
  batch landed first; a third disagreeing batch adds its count rather than replacing the first two. The
  settled console line gained a clause for it (`… — 1 count(s) in dispute`), because a count the fold had
  to *resolve* is not the same kind of number as one the batches agreed on. No batch is ever asked for
  `countConflict` — it is the fold's conclusion about two answers, not something an answer can carry. A
  real numeric `countConfidence` stays a deliberate follow-up.
- **Acceptance (harness):** check 49 asserts the rule one rung at a time (confidence, code, views, larger
  as the fallback), the order-independence of the count and the note across every ordering of three
  disagreeing batches (the case that separates comparing sightings from comparing the folded line), that a
  silent sighting neither shrinks nor disputes a count, that agreement records nothing, that a third batch
  accumulates into `counts` (with `kept` always one of them), and that the note reaches the pricing
  prompt's slab (with rule 3 named) and the row; check 38 drives the live route to a real disagreement and
  asserts the note on the pricing request; check 39 covers the fold's own roll-ups under the new rule;
  check 48 still pins that the batch schema asks no batch for a conflict.

## Tier 4 — stronger identity model, provider split, and surfacing — **I and credentials done**
(harness checks 50, 50b); **J still to do**

### I. Provider split (identity ≠ pricing)
- Add a `ManifestService` protocol (`manifestBatch(_:) async throws -> ManifestBatchAnswer`) with its own
  request struct; both transports conform. (`ManifestBatchAnswer` rather than `[ManifestItem]` because the
  batch's *accounting* — which frames it declared empty — is only visible to the route if the answer
  carries it; deviation 37.)
- Gemini answers via `generateContent` with `LotManifestPrompt.manifestSchema` as **`responseSchema`**
  (strict enforcement); DeepSeek answers as today (`json_object` plus the embedded schema).
- `DeepSeekValuationService` gains an optional injected `ManifestService`; when it is `nil` it batches
  itself (today's behaviour, unchanged). `manifestRoute` calls the injected service when there is one.
- Add `gemini-2.5-pro` to `GeminiValuationService.availableModelIDs` as the stronger identity model —
  DeepSeek has no stronger public vision model, which is *why* the split exists. **Landed, and then the
  model retired with its series:** Google has since taken the whole 2.5 family away, so the menu offers
  `gemini-3.8-flash` alone (README deviation 2) and a stored 2.5 ID is served as that default
  (harness 50c). The role outlived the model, because what it turned out to buy is a second key and a
  strictly enforced `responseSchema` rather than a bigger model ID — the stronger-reader argument is
  the one part of this bullet the retirement took with it (README deviation 39(e)).
- New `AppSettings.identityProvider` (`.same` / `.gemini` / `.deepSeek`, default `.same`), a picker in
  the Account sheet, and `ValuationOutcome` reporting both the identity and the pricing model IDs.
- **Acceptance:** harness checks the identity request goes to the chosen provider and carries the
  right schema mode, and that pricing still goes to the pricing provider.
- **Landed** as checks 50 (the split end to end) and 50b (its inert states and its keys); see
  *What Tier 4's split actually came to* above for the three things the plan did not name.

### Credentials and the Account sheet (required *with* the split)

**Partly landed ahead of the split** (README deviation 36): the Account sheet now draws **two**
credential sections — a key and its own model picker each, both always on screen, under a segmented
**Appraise with** choice — and each section prints the page its key comes from, which the About sheet's
new *Getting an API key* also documents. `AppSettings.hasAPIKey(for:)` / `apiKey(for:)` /
`modelID(for:)` / `setAPIKey(_:for:)` / `setModelID(_:for:)` / `providerKeyStates` are the per-provider
accessors that made it possible; the readiness logic below should build on them rather than on the
armed-provider pair.

- Gemini still needs its **own API key** — there is no keyless path — but a **free AI Studio key with no
  billing account** is enough for identity. Both keys already have homes (`AppSettings.apiKey` for
  Gemini, `AppSettings.deepSeekAPIKey` for DeepSeek).
- `AppSettings`: redefine `hasAPIKey` (and `canScanLots`) to require the pricing key **and**, when the
  split is on, the identity key — `hasAPIKey(for:)` already answers for a *named* provider, so this is
  a short change once `identityProvider` exists.
- `SiteSettingsSheet`: the **Reads manifests** picker is in (always drawn, disabled while nothing
  batches, with the help text naming the row that has to change); the header pill, the per-section key
  chips and the warning already name *which* key is which, and the footnote already says that switching
  appraisers is lossless. Its split footnote says which key sees which half, and the warning for a
  missing *identity* key gives both ways out (paste it, or go back to *Same as appraiser*). **Landed.**
- `ControlPanelView` summary and dot, and `AnalysisCoordinator.requireScanning()`, inherit the new
  `hasAPIKey` and name the missing provider. **Landed** (`missingKeyPhrase` /`identityRouteSummary`).

### J. Surface residual duplicates
- After pricing, flag `DiscoveredItem`s that share an identifier or overlapping photos/views, so the
  operator can correct what the model could not confidently merge — a "possible duplicate" chip in
  `DiscoveredItemRow` / the detail card.
- **Acceptance:** two priced rows built from one carton's two batches carry the chip.

## Tier 5 — the photograph half, both ways (the photograph role) — **K, L and M done**

Tier 4 made the *identity* half a role another provider can fill, and stopped there: `identityProvider` was
inert unless **Appraise with** was DeepSeek *and* a **Photos / request** width was set, because the whole
manifest pipeline — split the gallery into batches, read them, fold the inventory, price it — lived inside
`DeepSeekValuationService`. The app therefore offered two photograph routes, picked by **Appraise with**
(Gemini reads frame by frame or the whole gallery; DeepSeek reads batches into a manifest), plus one
asymmetric extra: a DeepSeek appraisal could buy its photographs from Gemini, and a Gemini appraisal could
buy them from nobody but itself. Tier 5 makes the role symmetric and names it for what it is —
**Evaluate photos with** (`Same as appraiser` / `Gemini` / `DeepSeek`).

### K. The manifest pipeline becomes a shared orchestrator (`LotManifestScan`) — **done**
The per-photograph route already had this shape: `LotPhotoScan.run(...)` is provider-independent and is
handed two closures, `read` and `aggregate`. The manifest route got its sibling, moved out of
`DeepSeekValuationService.manifestRoute` + `pricingPass` + `collectManifest` (with `chunked`, `evidence`,
`repeatedPictures`, `withLocalCodes`, `manifestFailurePhrase`, `withinOneRequest` and the two private
chunk structs), and handed `read` and `price` closures: group, split, read, fold, account for gaps, report
and return `nil` on nothing priceable — written once, so the two transports cannot drift about what a batch
is asked or what a failed batch costs. `ManifestPriceRequest` + `ManifestPricingService` became the second
role, next to `ManifestService`: both the batch question and the pricing question are values, and either
transport can answer either.
- **Acceptance:** no behaviour change — checks 33, 37, 38, 39, 44–50 stayed green with no assertion
  rewritten, which is what proves the move was a move. **Met.** The one thing the plan did not name: the
  two constants a caller needs (`downloadBytes`, `withinOneRequest`) belong to the orchestrator rather than
  the transport, because they exist *because* the batched route's download ceiling is wider than one
  request — so `DeepSeekValuationService` now reads them from `LotManifestScan`.

### L. Both directions — **done**
`AppSettings.photoProvider` (`PhotoProvider.same` / `.gemini` / `.deepSeek`) names who reads a lot's
photographs; the **appraiser prices what it read**. The route rule is one line — a run takes the manifest
route when a width is set *and* the reader is DeepSeek or is somebody other than the appraiser:

| Evaluate photos with | Appraise with | Route |
| --- | --- | --- |
| Gemini (*Same* or named) | Gemini | Gemini's own: per-photograph (`Photos / scan`) or whole gallery |
| DeepSeek (*Same* or named) | DeepSeek | DeepSeek's own: batches (`Photos / request`) or per-photograph |
| Gemini | DeepSeek | manifest route: Gemini reads (`response_schema`-enforced), DeepSeek prices — Tier 4 |
| DeepSeek | Gemini | manifest route: DeepSeek reads, Gemini prices — **new in Tier 5** |

For the new direction `GeminiValuationService` gained `priceManifest(_:)` (a text-only `:generateContent`
call carrying `LotManifestPrompt.pricingPrompt`, held to `LotValuationPrompt.itemsSchema` as
`responseSchema`) and a manifest branch in `value(subject:)` that runs when the coordinator hands it a
width — plus the fallback DeepSeek has always had: a manifest route that produces nothing falls back to one
pass over the gallery, trimmed to one request's inline budget.
- **Acceptance:** check 50e drives the new direction end to end against two stub hosts (DeepSeek reads,
  Gemini prices) and asserts the batch request carries the frames, the batcher's own question and the cold
  temperature; the pricing request carries the manifest slab, no photographs and an enforced `items`
  schema; and the outcome names both models, with the folded inventory on the run. **Met.** Check 50b grew
  the rule's other end (the width off leaves it inert in that direction too; DeepSeek named as its own
  reader is not a split).

### M. The picker and the two run-tuning rows — **done**
- `SiteSettingsSheet`: **Reads manifests** became **Evaluate photos with**, enabled whenever a width is set
  (`AppSettings.canNamePhotoProvider`) rather than only while batching was already on — otherwise naming
  DeepSeek while Gemini appraises would be unreachable, since that *is* the choice that turns the batched
  route on. Its help has four states (no width / a width with no manifest route on this combination / a
  width resolved back to the appraiser / a real split), the footnote and the warning say which key sees
  which half, and the per-section chip reads *reads photographs*.
- `RunTuningSheet`: **Photos / request** stopped claiming to be inert on Gemini ("Gemini always reads frame
  by frame and ignores this row" is no longer true), and its tail names the reader from `photoProvider`;
  **Photos / scan**'s row is still disabled while a manifest route is on, which is the same rule as before
  with the reader generalised.
- `AboutSheet`, `ControlPanelView` and the README print the new name; the stored key and raw values were
  left alone (`identityProvider`), so no install migrates.

## Order of work

1. Tier 1 (A → B → C → D) — the biggest accuracy wins, all on-device or in the fold. **Done.**
2. Tier 2 (E → F → G) — prompt and contract, verified by the harness. **Done** (check 48; README
   deviation 37).
3. Tier 3 (H) — count resolution. **Done** (check 49; README deviation 38).
4. Tier 4 (I, credentials, J) — the largest surface, last, because it needs two keys and a new picker.
   **I and the credentials work are done** (harness checks 50, 50b; README deviation 39), and the Account
   sheet's two key sections plus the About sheet's key instructions landed earlier still, as deviation 36.
5. Tier 5 (K → L → M) — the photograph role generalised and pointed both ways. **Done** in one landing —
   K (the extraction) first, verified green with no assertion changed, then L and M (the settings, the
   wiring, the sheets) — with harness check 50e, 50b extended, and README deviation 40.
6. Tier 4's **J** — the "possible duplicate" chip on a priced row built from one carton's two batches:
   still the one item outstanding.

Each step: build (`xcodebuild … CODE_SIGNING_ALLOWED=NO`), run `Tools/free-tier-harness/run.sh`, add
the harness check named above, and update the README (architecture, "How one scan works", cost
tables, deviations, troubleshooting).

## Risks

- **Fuzzy name over-merging** distinct SKUs → gate on brand agreement plus identifiers, and keep the
  "different model numbers ⇒ different products" rule above the name test.
- **Dropping frames (Tier 1 A)** → merge the folded frame's evidence into the representative and log
  the fold; never silently discard a decode.
- **Provider split doubles credentials** and complicates readiness → readiness names the missing key,
  and the split is optional (`.same` is the default).
- **Gemini `responseSchema` dialect** → reuse the existing `ResponseSchemaNode` renderer, which
  already emits Google's uppercase schema form.
- **The two-way role makes the route rule harder to hold in one's head** (Tier 5) → the rule is stated
  once, in `AppSettings.batchesPhotographs` / `runsSplitPhotos`, and every surface (both sheets, the
  panel tooltip, the run log, the coordinator) reads it there rather than re-deriving it; the harness
  pins each of its four combinations, including the one where a width means nothing.
