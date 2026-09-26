# Manifest identity & cross-view dedupe — implementation plan

**Status:** Tier 1 (A–D) is implemented and green — `xcodebuild … CODE_SIGNING_ALLOWED=NO` builds and
`Tools/free-tier-harness/run.sh` passes with checks 44–46 added. **Tier 2 (E–G) is implemented too —
harness check 48** — see *Tier 2* below for what it came to. **Tier 3 (H) is implemented as well —
harness check 49** — see *Tier 3* below. **Tier 4 (I, credentials, J) is still to do.**
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
  is a Tier 4 job: that transport has no batched path yet, so when `ManifestService` lands it passes the
  same constant rather than its own.
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

## Tier 4 — stronger identity model, provider split, and surfacing

### I. Provider split (identity ≠ pricing)
- Add a `ManifestService` protocol (`manifestBatch(_:) async throws -> [ManifestItem]`) with its own
  request struct; both transports conform.
- Gemini answers via `generateContent` with `LotManifestPrompt.manifestSchema` as **`responseSchema`**
  (strict enforcement); DeepSeek answers as today (`json_object` plus the embedded schema).
- `DeepSeekValuationService` gains an optional injected `ManifestService`; when it is `nil` it batches
  itself (today's behaviour, unchanged). `manifestRoute` calls the injected service when there is one.
- Add `gemini-2.5-pro` to `GeminiValuationService.availableModelIDs` as the stronger identity model —
  DeepSeek has no stronger public vision model, which is *why* the split exists.
- New `AppSettings.identityProvider` (`.same` / `.gemini` / `.deepSeek`, default `.same`), a picker in
  the Account sheet, and `ValuationOutcome` reporting both the identity and the pricing model IDs.
- **Acceptance:** harness checks the identity request goes to the chosen provider and carries the
  right schema mode, and that pricing still goes to the pricing provider.

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
- `SiteSettingsSheet`: still to add the "Identity (manifest) provider" picker; the header pill, the
  per-section key chips and the warning already name *which* key is which, and the footnote already
  says that switching appraisers is lossless. Extend that footnote to explain that, when split, the
  Gemini key goes to Gemini for the manifest pass and the DeepSeek key to DeepSeek for pricing.
- `ControlPanelView` summary and dot, and `AnalysisCoordinator.requireScanning()`, inherit the new
  `hasAPIKey` and name the missing provider.

### J. Surface residual duplicates
- After pricing, flag `DiscoveredItem`s that share an identifier or overlapping photos/views, so the
  operator can correct what the model could not confidently merge — a "possible duplicate" chip in
  `DiscoveredItemRow` / the detail card.
- **Acceptance:** two priced rows built from one carton's two batches carry the chip.

## Order of work

1. Tier 1 (A → B → C → D) — the biggest accuracy wins, all on-device or in the fold. **Done.**
2. Tier 2 (E → F → G) — prompt and contract, verified by the harness. **Done** (check 48; README
   deviation 37).
3. Tier 3 (H) — count resolution. **Done** (check 49; README deviation 38).
4. Tier 4 (I, credentials, J) — the largest surface, last, because it needs two keys and a new picker.
   **Next.** (The Account sheet's two key sections and the About sheet's key instructions landed early, as
   deviation 36 — see *Credentials and the Account sheet*.)

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
