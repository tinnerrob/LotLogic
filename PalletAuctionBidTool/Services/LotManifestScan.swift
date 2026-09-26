//
//  LotManifestScan.swift
//  PalletAuctionBidTool
//
//  Reading a pallet's photographs a batch at a time, folding what came back into one inventory, and
//  pricing that inventory.
//
//  `LotPhotoScan` is this file's sibling, and the two exist for the same reason: a route is one algorithm
//  however the bytes travel. The thorough path is handed `read` and `aggregate`; this one is handed
//  `read` and `price`, and the shape of what it does is exactly the batched pass
//  `DeepSeekValuationService` used to keep to itself:
//
//  * **A batch is several views in one request**, which is the whole point: a carton at the front and the
//    same carton from the side are one carton only if one context can see both, and ten frames cost one
//    request rather than ten.
//  * **The inventory is folded on this machine** (`PalletManifest.absorb(_:)`), in gallery order, and the
//    frames a batch answered about but named nowhere are reported (`manifestGap`) rather than forgiven: a
//    photograph in neither an item's `views` nor its `unreadPhotos` is a product the inventory may be
//    short of.
//  * **Price is a separate, text-only pass** — the goods have been identified and counted, and what is
//    left is a lookup that photographs cannot improve. One reply prices so much of an inventory
//    (`itemsPerPriceRequest`), so a warehouse is priced in several complete replies rather than in one
//    truncated one.
//  * **A failed batch is a hole, not a failed lot**, and a route that produces nothing priceable at all
//    returns `nil` so the caller can fall back to a route that reads the gallery itself — while a
//    *cancelled* run is thrown and never falls back into a request nobody is waiting for.
//
//  What the route does not decide is who does those two jobs. Both are closures here, so a lot's
//  photographs can be read by one provider and its manifest priced by another
//  (`AppSettings.photoProvider`), in either direction, and neither transport keeps a copy of this file's
//  rules to stay in step with.
//

import Foundation

/// Runs one lot's manifest route: batch the gallery, read every batch into inventory items, fold them into
/// one `PalletManifest`, and price it in text-only requests.
enum LotManifestScan {

    /// What a completed manifest route produced.
    struct Outcome: Sendable {

        /// The pallet's line items, most valuable first — the order every other route returns them in.
        var items: [DiscoveredItem]

        /// The inventory the batches were folded into. Evidence rather than bookkeeping: it says what the
        /// photographs were *read to hold*, with the gallery numbers each product was seen in, so a figure
        /// that looks wrong can be traced to the item it was priced from without spending another request.
        var manifest: PalletManifest

        /// Batch requests issued — one per batch of the gallery.
        var batches: Int

        /// Pricing requests issued — one per reply-sized piece of the inventory, so ordinarily one.
        var prices: Int
    }

    /// Batches in flight at once.
    ///
    /// A service's own `RequestPacer` still spaces the requests themselves, so this only decides how much
    /// of a slow provider's latency is hidden — and unlike the per-photograph path there is no store to
    /// consult first, so every batch is a real request. Three matches the width a run of **Price all** uses
    /// and the concurrency the thorough path defaults to.
    static let batchesInFlight = 3

    /// Manifest items one **pricing** request asks for.
    ///
    /// The only thing bounding the second half is how much a model can enumerate in one reply: the app's
    /// own single-pass prompt caps itself at twelve line items for the same reason, and an answer
    /// truncated mid-object decodes as a failure rather than as a partial valuation. A pallet's inventory
    /// is one request as often as not; a warehouse's is priced in a few complete replies
    /// (`PalletManifest.batches(ofSize:)`).
    static let itemsPerPriceRequest = 12

    /// Ceiling on how much of a gallery the batched route downloads at all, in bytes.
    ///
    /// Two requests' worth, rather than the single request the other routes are bounded by: the whole point
    /// of batching is that a long gallery no longer has to fit in one request, so the *download* ceiling is
    /// what keeps "every photograph" true for a lot with forty of them. It is not unlimited on purpose —
    /// the frames are held in memory as base64 strings while they are sent, and three lots are appraised at
    /// a time — so a gallery past this is reported as skipped rather than quietly dropped
    /// (`LotImageDownload.overBudget`).
    static let downloadBytes = 2 * LotImageLoader.defaultTotalBytes

    /// Runs the route, or returns `nil` when it could not produce a valuation.
    ///
    /// The `nil` is the caller's cue to fall back, and the reason has already been reported to the console
    /// by then — so a run that ends in a single pass over the whole gallery still says why it abandoned the
    /// batches. A cancelled run is *thrown* instead, as everywhere else in this pipeline.
    ///
    /// - Parameters:
    ///   - images: the lot's downloaded frames, in gallery order, already trimmed to the route's own
    ///     download ceiling.
    ///   - labels: what the app's own reader found on those frames (`LotImageDigest`), index-aligned with
    ///     `images` and possibly shorter — a frame it could not decode is simply empty.
    ///   - evidence: the same readings merged over the whole gallery, which is what the pricing pass is
    ///     handed: a barcode is evidence about the *pallet*, once every frame has been looked at.
    ///   - width: how many frames one batch carries (**Photos / request**).
    ///   - read: how to ask about one batch — the provider that reads the photographs.
    ///   - price: how to ask for the pricing of one piece of the inventory — the appraiser, always.
    ///   - report: progress, as it happens, called from this call's own task so the reports arrive in the
    ///     order the route learns them and each can carry a count the caller standing behind it can vouch
    ///     for.
    static func run(
        subject: ValuationSubject,
        description: String,
        images: [LotImage],
        labels: [LotImageEvidence],
        evidence: LotImageEvidence,
        width: Int,
        perRequestBytes: Int,
        read: @escaping @Sendable (ManifestBatchRequest) async throws -> ManifestBatchAnswer,
        price: @escaping @Sendable (ManifestPriceRequest) async throws -> [DiscoveredItem],
        report: @escaping @Sendable (PhotoScanReport) -> Void
    ) async throws -> Outcome? {
        let lotNumber = subject.lotNumber
        let galleryCount = images.count

        // 0. Which of the gallery's photographs are the same picture, and so are not bought twice.
        //
        // The grouping is asked with the whole gallery as its ceiling, because every frame on this route is
        // read: there is no per-photograph limit for a frame to fall past here. A gallery that lists one
        // photograph twice — a re-listed lot, the same zoom image served at two addresses — is one
        // photograph, and a batch carrying it twice would be asking the model to reconcile it against
        // itself. Its own event rather than the thorough path's `grouped`, because the two routes do
        // different things with a repeated frame: this one does not send it at all, so the console line has
        // to say which happened.
        let repeated = await repeatedPictures(in: images, labels: labels)
        for view in repeated.views {
            report(PhotoScanReport(lotNumber: lotNumber, event: .folded(view)))
        }

        // The frames that need sending, with the gallery numbers they hold: a batch has to be able to say
        // "photographs 1, 3 and 4 of 5" for the `views` it answers to mean anything.
        let positions = galleryCount > 0
            ? (1...galleryCount).filter { !repeated.frames.contains($0) }
            : []
        guard !positions.isEmpty else { return nil }

        // The gallery, split into batches that each fit one request's inline budget.
        let batches = LotImageLoader.batches(
            of: positions.map { images[$0 - 1] },
            width: width,
            perRequestBytes: perRequestBytes
        )
        guard !batches.isEmpty else { return nil }

        // Each batch with the gallery numbers it covers, and the frames it answers for.
        let chunks = chunked(batches, over: positions, standing: repeated.stands)
        guard !chunks.isEmpty else { return nil }

        // Every batch's answer, by batch number — so the inventory is folded in gallery order however the
        // answers landed.
        var answers: [ManifestBatchAnswer?] = Array(repeating: nil, count: chunks.count)
        var firstFailure: Error?
        var failures: [String] = []
        // Frames with an answer behind them: read, or given up on. What the readout counts, exactly as it
        // counts the per-photograph path's answers.
        var answered = 0
        var requested = 0

        let window = min(batchesInFlight, chunks.count)
        await withTaskGroup(of: (Int, Result<ManifestBatchAnswer, Error>).self) { group in
            var next = 0

            while next < chunks.count {
                if Task.isCancelled { break }
                let index = next
                next += 1
                let chunk = chunks[index]
                // The app's own reading of **this** batch's frames, never of the gallery: a barcode decoded
                // off photograph 3 is not evidence about photograph 9 (see `LotImageDigest`).
                let batchEvidence = Self.evidence(labels, at: chunk.positions)
                // Announced here, from the loop that launches the request rather than from inside the
                // task, so the console says which batch is starting and the readout gets a count the
                // caller can vouch for.
                report(
                    PhotoScanReport(
                        lotNumber: lotNumber,
                        event: .manifesting(
                            batch: index + 1,
                            of: chunks.count,
                            frames: chunk.images.count,
                            answered: answered,
                            total: galleryCount
                        )
                    )
                )
                group.addTask {
                    do {
                        let answer = try await read(
                            ManifestBatchRequest(
                                description: description,
                                batch: index + 1,
                                batchCount: chunks.count,
                                positions: chunk.positions,
                                images: chunk.images,
                                imageCount: galleryCount,
                                evidence: batchEvidence
                            )
                        )
                        // The app's own reading of the frames this batch just answered about is folded
                        // into its answer: the digits the reader decoded are what joins two sightings of
                        // one carton when the batches named the goods around them differently. The
                        // batch's account of its frames travels through unchanged — enriching items
                        // cannot change which photographs it spoke for.
                        let coded = ManifestBatchAnswer(
                            items: Self.withLocalCodes(
                                answer.items,
                                labels: labels,
                                positions: chunk.positions
                            ),
                            unreadPhotos: answer.unreadPhotos
                        )
                        return (index, .success(coded))
                    } catch {
                        return (index, .failure(error))
                    }
                }
                // Wait for a slot to free up once the window is full.
                if next < chunks.count, next % window == 0, let finished = await group.next() {
                    requested += 1
                    collect(
                        finished,
                        into: &answers,
                        answered: &answered,
                        firstFailure: &firstFailure,
                        failures: &failures,
                        chunks: chunks,
                        galleryCount: galleryCount,
                        lotNumber: lotNumber,
                        report: report
                    )
                }
            }

            if Task.isCancelled { group.cancelAll() }
            for await finished in group {
                requested += 1
                collect(
                    finished,
                    into: &answers,
                    answered: &answered,
                    firstFailure: &firstFailure,
                    failures: &failures,
                    chunks: chunks,
                    galleryCount: galleryCount,
                    lotNumber: lotNumber,
                    report: report
                )
            }
        }

        // A batch's failure is never fatal on its own; a *stopped* run is stopped, so the cancellation is
        // rethrown rather than turned into a fallback nobody is waiting for.
        if let firstFailure, ValuationCancellation.isCancellation(firstFailure) { throw firstFailure }

        // Folded in gallery order, so the inventory reads the same whichever batch answered first.
        var manifest = PalletManifest()
        for answer in answers.compactMap({ $0 }) { manifest.absorb(answer) }

        guard !manifest.isEmpty else {
            report(
                PhotoScanReport(
                    lotNumber: lotNumber,
                    event: .fallingBackFromManifest(
                        reason: manifestFailurePhrase(failures: failures, requested: requested)
                    )
                )
            )
            return nil
        }

        // The inventory, stated before it is priced: this is the line that says what the photographs were
        // read to hold, and what the pricing pass is about to multiply. Then the pricing request itself,
        // announced with the number of lines it will be asked to price.
        report(PhotoScanReport(lotNumber: lotNumber, event: .manifestSettled(manifest)))

        let pieces = manifest.batches(ofSize: itemsPerPriceRequest)
        report(PhotoScanReport(lotNumber: lotNumber, event: .pricing(items: manifest.count)))

        do {
            var priced: [DiscoveredItem] = []
            for piece in pieces {
                let items = try await price(
                    ManifestPriceRequest(
                        description: description,
                        manifest: piece,
                        evidence: evidence
                    )
                )
                report(PhotoScanReport(lotNumber: lotNumber, event: .priced(items: items.count)))
                priced.append(contentsOf: items)
            }
            // Put back in the order the single-pass route returns — most valuable first — since each piece
            // only ordered itself.
            return Outcome(
                items: priced.sorted { $0.resaleValue > $1.resaleValue },
                manifest: manifest,
                batches: requested,
                prices: pieces.count
            )
        } catch {
            if ValuationCancellation.isCancellation(error) { throw error }
            report(
                PhotoScanReport(
                    lotNumber: lotNumber,
                    event: .fallingBackFromManifest(
                        reason: "the manifest was read but could not be priced "
                            + "(\(ValuationError.describe(error)))"
                    )
                )
            )
            return nil
        }
    }

    /// Files one batch's result: an answer to be folded in, or a failure to be reported and moved past.
    ///
    /// A failed batch is a hole in the inventory rather than a failed lot — the pallet is still worth
    /// appraising from the batches that answered, and the console says which one was lost. A batch that
    /// answered but left frames out of its account gets the same treatment from the other side: its items
    /// are kept, and the frames it said nothing about are named (`PhotoScanEvent.manifestGap`), because a
    /// photograph missing from both lists is a product the inventory may be short of.
    private static func collect(
        _ finished: (Int, Result<ManifestBatchAnswer, Error>),
        into answers: inout [ManifestBatchAnswer?],
        answered: inout Int,
        firstFailure: inout Error?,
        failures: inout [String],
        chunks: [ManifestChunk],
        galleryCount: Int,
        lotNumber: String,
        report: @Sendable (PhotoScanReport) -> Void
    ) {
        let (index, result) = finished
        let batch = index + 1

        switch result {
        case .success(let answer):
            answers[index] = answer
            answered += chunks[index].answered
            report(
                PhotoScanReport(
                    lotNumber: lotNumber,
                    event: .manifested(
                        batch: batch,
                        of: chunks.count,
                        items: answer.items.count,
                        answered: answered,
                        total: galleryCount
                    )
                )
            )
            // What the batch did *not* account for, if anything: the frames of its own batch that it named
            // in no item and declared in no `unreadPhotos` list.
            let gap = answer.unaccountedFrames(among: chunks[index].positions)
            if !gap.isEmpty {
                report(
                    PhotoScanReport(
                        lotNumber: lotNumber,
                        event: .manifestGap(batch: batch, of: chunks.count, frames: gap)
                    )
                )
            }
        case .failure(let error):
            if firstFailure == nil { firstFailure = error }
            let reason = ValuationError.describe(error)
            failures.append(reason)
            report(
                PhotoScanReport(
                    lotNumber: lotNumber,
                    event: .manifestFailed(
                        batch: batch,
                        of: chunks.count,
                        answered: answered,
                        total: galleryCount,
                        reason: reason
                    )
                )
            )
        }
    }

    /// The leading frames of a downloaded set that fit **one** request, in gallery order.
    ///
    /// Needed only when a route falls back out of the batched one: a batched route's download ceiling is
    /// wider than a single request (`downloadBytes`) because its batches *are* separate requests, while the
    /// per-photograph plan's reconciliation and the single-pass gallery pass both put what is left in one.
    /// A frame that does not fit ends the walk rather than being stepped over — what follows it in the
    /// gallery is a later view of the same pallet, so a tail that did not travel is easier to explain than a
    /// hole in the middle — and the frames the walk leaves behind are reported as skipped, not dropped.
    static func withinOneRequest(_ images: [LotImage], budget: Int) -> [LotImage] {
        var kept: [LotImage] = []
        var used = 0
        for image in images {
            guard used + image.byteCount <= budget else { break }
            kept.append(image)
            used += image.byteCount
        }
        return kept
    }

    /// The gallery's batches, each with the gallery numbers its frames hold.
    ///
    /// `LotImageLoader.batches(of:width:perRequestBytes:)` takes the frames in gallery order, so a batch is
    /// a run of the frames it was handed — but not necessarily a run of the *gallery*, because a photograph
    /// the gallery lists twice travels once (`PhotoFrameGrouping`). A batch therefore carries its gallery
    /// numbers instead of a range of them, and those numbers are what the prompt states and what the
    /// model's `views` come back in. Built as one immutable value rather than assembled in the route, so
    /// the batch tasks capture a constant.
    private static func chunked(
        _ batches: [[LotImage]],
        over positions: [Int],
        standing: [Int: Int]
    ) -> [ManifestChunk] {
        var chunks: [ManifestChunk] = []
        var cursor = 0
        for batch in batches {
            let held = Array(positions[cursor..<(cursor + batch.count)])
            chunks.append(
                ManifestChunk(
                    images: batch,
                    positions: held,
                    answered: held.reduce(0) { $0 + (standing[$1] ?? 1) }
                )
            )
            cursor += batch.count
        }
        return chunks
    }

    /// The app's own reading of the frames at `positions` (`LotImageDigest`).
    ///
    /// `labels` is index-aligned with the downloaded gallery and may be shorter than it — the reader stops
    /// rather than reading a frame it cannot decode — so a missing reading is simply empty, exactly as
    /// `LotPhotoScan` treats it.
    private static func evidence(_ labels: [LotImageEvidence], at positions: [Int]) -> LotImageEvidence {
        LotImageDigest.merge(
            positions.compactMap { labels.indices.contains($0 - 1) ? labels[$0 - 1] : nil }
        )
    }

    /// The frames of a gallery that are provably the same photograph as an earlier frame, and so are not
    /// sent in the batches (`PhotoFrameGrouping`).
    ///
    /// Only the `samePicture` fold is acted on: a frame folded on its decoded barcode is still sent,
    /// because its pixels are the only place a count of the goods can come from.
    private static func repeatedPictures(
        in images: [LotImage],
        labels: [LotImageEvidence]
    ) async -> RepeatedPictures {
        let grouping = await PhotoFrameGrouping.group(
            images: images,
            labels: labels,
            limit: images.count
        )

        var repeated = RepeatedPictures()
        for view in grouping.views {
            let folds = view.folds.filter { $0.reason == .samePicture }
            guard !folds.isEmpty else { continue }
            repeated.frames.formUnion(folds.map(\.frame))
            repeated.stands[view.representative, default: 1] += folds.count
            repeated.views.append(PhotoView(representative: view.representative, folds: folds))
        }
        return repeated
    }

    /// One batch's answer with the app's own reading of the frames it named folded in.
    ///
    /// This is what makes the identifier question (`ManifestItem.isSameProduct(as:)`) answerable when the
    /// digits were visible in one batch's photographs and not another's. A batch is told what the reader
    /// found on *its* frames, and the model is asked to quote a code it can see — but what the fold needs
    /// is not an answer about a code, it is the code itself, on the item, in the gallery's numbering. So
    /// the reader's decodes for each frame an item was seen in are appended to that item's identifiers
    /// here, on this machine, where they are facts rather than readings.
    ///
    /// Only frames **this batch** carried are consulted, and only the frames the item itself names: a
    /// `views` entry outside the batch is a slip by the model, and honouring it would attribute another
    /// frame's codes to this item.
    ///
    /// - Parameters:
    ///   - items: the batch's answer, as decoded.
    ///   - labels: the reader's per-frame readings, index-aligned with the downloaded gallery.
    ///   - positions: the gallery numbers of the frames the batch carried.
    private static func withLocalCodes(
        _ items: [ManifestItem],
        labels: [LotImageEvidence],
        positions: [Int]
    ) -> [ManifestItem] {
        var enriched = items
        for (index, item) in enriched.enumerated() {
            for view in item.views where positions.contains(view) {
                guard labels.indices.contains(view - 1) else { continue }
                let reading = labels[view - 1]
                for code in reading.barcodes + reading.identifiers where !enriched[index].identifiers.contains(
                    where: { $0.caseInsensitiveCompare(code) == .orderedSame }
                ) {
                    enriched[index].identifiers.append(code)
                }
                // The wording the reader made out stands in for a batch that named the goods around the
                // label rather than on it, and only ever fills a blank: a batch that read the label keeps
                // what it read (`ManifestItem.merge(_:)` makes the same choice the other way round).
                if enriched[index].labelText.isEmpty, let wording = reading.labelText.first {
                    enriched[index].labelText = wording
                }
            }
        }
        return enriched
    }

    /// Why the batched route came back with nothing, in one clause, for the console.
    private static func manifestFailurePhrase(failures: [String], requested: Int) -> String {
        guard let first = failures.first else { return "the batches read no goods" }
        guard requested > 1, failures.count < requested else {
            return "no batch could be read (\(first))"
        }
        return "\(failures.count) of \(requested) batch(es) could not be read (\(first))"
    }

    /// One batch of the gallery as a request to send.
    private struct ManifestChunk: Sendable {

        /// The frames that travel with the request, in gallery order.
        var images: [LotImage]

        /// The gallery numbers of those frames — what the prompt states, and what `views` is answered in.
        var positions: [Int]

        /// How many of the gallery's photographs this batch answers for: its own frames, plus the repeated
        /// photographs each of them stands for. What the readout's "answered of total" counts.
        var answered: Int
    }

    /// The frames of a gallery that are provably the same photograph as an earlier frame, and so are not
    /// sent in the batches (`PhotoFrameGrouping`).
    private struct RepeatedPictures {

        /// Gallery numbers the batches leave out.
        var frames: Set<Int> = []

        /// A gallery number that *is* sent, and how many repeated photographs it stands for.
        var stands: [Int: Int] = [:]

        /// One entry per folded view, in gallery order, for the console.
        var views: [PhotoView] = []
    }
}

