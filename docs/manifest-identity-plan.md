# Manifest identity & cross-view dedupe — implementation plan

**Status:** approved for implementation. Each tier lands behind a green `xcodebuild` and a green
`Tools/free-tier-harness/run.sh` before the next begins.

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

### A. Fold provably-identical frames on the batched route
- Call `PhotoFrameGrouping.group(images:labels:limit:)` in `manifestRoute` **before**
  `LotImageLoader.batches`.
- Build the batch list from the representative frames; drop exact duplicates and merge their
  `LotImageEvidence` into the representative's, so a folded frame's decoded barcode still reaches
  the prompt.
- Report the fold to the console so the operator sees it. This folds only *same pixels / same full
  barcode set* — never "two angles of one carton" — so it cannot remove a view the model needed.
- **Acceptance:** a gallery whose frames 2 and 3 are byte-identical sends 2 manifest images, not 3;
  the fold is logged; frame 3's barcode still reaches the prompt.

### B. Identifier-first identity in `ManifestItem.isSameProduct`
- Add an **identifier intersection** test before model-number/name matching: a shared barcode/SKU is
  conclusive "same product" even when the names differ.
- Make it deterministic by injecting the **on-device** decodes into the fold: after a batch returns,
  for each item union its `views`, look those frames up in the already-computed `labels`, and append
  their `barcodes`/`identifiers` to the item's `identifiers`.
- **Acceptance:** two batches reporting the same UPC on frames 2 and 5 under different names fold to
  one item.

### C. Surface full recognised label text on-device
- Add `labelText: [String]` to `LotImageEvidence`, filled from the `VNRecognizeTextRequest` lines
  that are *not* identifier-shaped (capped, truncated). Add a "Printed label text: …" line to
  `promptLines` / `singlePhotographPromptLines`, so the model is handed more than the digits.
- **Acceptance:** the existing `LotImageDigest` harness check is extended so a stubbed reading yields
  label lines and the prompt carries them.

### D. Canonicalised, token-overlap name matching
- Replace exact normalised-name equality in `isSameProduct` with a token matcher: strip
  pack-count/size stopwords (`24-pack`, `22 oz`, `12x`, `12 ct`, …), build token sets, require brand
  compatibility **and** a token-containment/Jaccard threshold. Model-number match stays strongest;
  "both read different model numbers ⇒ two products" stays.
- **Acceptance:** `Yankee Candle 22 oz jar` vs `yankee candles, 22oz` merge; `Energizer MAX AA` vs
  `Duracell AA` do not.

## Tier 2 — model-side prompt and contract

- **E. `views` required and exhaustive.** Add `views` to `manifestSchema.required`, and add a
  top-level `unreadPhotos: [Int]` so every frame is either named in some item's `views` or declared
  goods-free. Decoding tolerates a missing `unreadPhotos`.
- **F. Same-carton cues and tiebreaker.** Extend `manifestSystemInstruction` with concrete cues (same
  barcode, same label wording, same brand + pack size, same stack position and neighbour, same
  damage) plus the rule "one entry with a note beats two entries", and a worked example of two sides
  of one 24-pack.
- **G. Manifest temperature 0.0.** Parameterise `requestBody` so the manifest batch sends
  `temperature: 0.0` (extraction wants determinism) while the pricing and reading passes keep `0.2`;
  mirror the same on the Gemini manifest path.
- **Acceptance (harness):** the schema lists `views` as required; the prompt carries the
  exhaustiveness rule and the cue list; the manifest request body's `temperature` is asserted to be
  `0.0`.

## Tier 3 — count accuracy

- **H. Prefer the better count; record the conflict.** In `merge`, when two batches disagree on
  `quantity`, keep the count from the batch with the higher `confidence`, else the one carrying a
  decoded barcode, else the one with more `views` — instead of an unconditional `max()`. Record a
  `countConflict` note that survives into the pricing prompt and the row. (A real numeric
  `countConfidence` field is a deliberate follow-up, not part of the first pass.)
- **Acceptance:** the quantity-resolution rule is harness-checked, and a conflict note is produced.

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
- Gemini needs its **own API key** — there is no keyless path — but a **free AI Studio key with no
  billing account** is enough for identity. Both keys already have homes (`AppSettings.apiKey` for
  Gemini, `AppSettings.deepSeekAPIKey` for DeepSeek); what is missing is the UI and readiness logic
  to use them together.
- `AppSettings`: add `hasGeminiKey` / `hasDeepSeekKey`; redefine `hasAPIKey` (and `canScanLots`) to
  require the pricing key **and**, when the split is on, the identity key.
- `SiteSettingsSheet`: show **two** credential fields (and a model field per provider) plus the
  "Identity (manifest) provider" picker; the status pill and the warning name *which* key is missing;
  the footnote explains that, when split, the Gemini key goes to Gemini for the manifest pass and the
  DeepSeek key to DeepSeek for pricing.
- `ControlPanelView` summary and dot, and `AnalysisCoordinator.requireScanning()`, inherit the new
  `hasAPIKey` and name the missing provider.

### J. Surface residual duplicates
- After pricing, flag `DiscoveredItem`s that share an identifier or overlapping photos/views, so the
  operator can correct what the model could not confidently merge — a "possible duplicate" chip in
  `DiscoveredItemRow` / the detail card.
- **Acceptance:** two priced rows built from one carton's two batches carry the chip.

## Order of work

1. Tier 1 (A → B → C → D) — the biggest accuracy wins, all on-device or in the fold.
2. Tier 2 (E → F → G) — prompt and contract, verified by the harness.
3. Tier 3 (H) — count resolution.
4. Tier 4 (I, credentials, J) — the largest surface, last, because it needs two keys and a new picker.

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
