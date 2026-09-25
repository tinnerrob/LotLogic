//
//  LotPhotoScan.swift
//  PalletAuctionBidTool
//
//  Reading a pallet one photograph at a time, and reconciling what came back.
//
//  The single-pass appraisal this replaces asked one question about a whole gallery. That is cheap
//  and it works, but it asks the model to hold forty frames in its head at once, and the answer is an
//  average over all of them: a thirty-dollar item in a corner competes with the pallet in front of it
//  and usually loses. This file is the alternative — one request per photograph, each answer a
//  `PhotoReading` of exactly what that frame showed, every reading stored on this machine
//  (`PhotoReadingStore`), and then **one** reconciliation request that turns the readings into the
//  pallet's line items with the quantities and totals that belong to the whole lot.
//
//  Everything provider-independent lives here. A `ValuationService` supplies two things and nothing
//  else — how to ask about one photograph, and how to ask for the reconciliation — so both transports
//  run this identical pipeline and the pacing, the store, the merge and the fallbacks cannot drift
//  apart (see `GeminiValuationService`, `DeepSeekValuationService`).
//
//  Three rules matter more than the rest:
//
//  * **No photograph is ever dropped from a scan.** A ceiling (`perImageLimit`) decides how many
//    frames get the detailed treatment, and the rest travel with the reconciliation request as
//    images, so a low ceiling makes the line items coarser but never makes the pallet smaller.
//  * **A reading is reused, not re-bought.** Readings already on this machine are restored before any
//    request is made, and only the photographs the store has never seen are read again.
//  * **A reconciliation that fails does not lose the scan.** `PhotoReadingMerge` folds the readings
//    into line items on this machine, so a lot whose *n* photographs were paid for still produces a
//    valuation when the last request is the one that fails.
//

import Foundation

/// How a scan reads a lot's photographs.
struct PhotoScanPlan: Sendable, Equatable {

    /// `true` when the thorough path is wanted at all. When it is off, a scan is one pass over the
    /// whole gallery — the behaviour before this pipeline existed, and the fallback when the thorough
    /// path cannot produce anything.
    var isEnabled: Bool

    /// Photographs read on their own, from the front of the gallery. `0` means **every** photograph
    /// the lot carries, which is the app's default: how many photographs a lot has is the lot's
    /// business (deviation 24), and one request each is what reading a pallet properly costs. A
    /// positive number is a ceiling for a metered key.
    var perImageLimit: Int

    /// Photographs in flight at once. The `RequestPacer` inside a service still spaces the requests
    /// themselves, so this only decides how much of a slow provider's latency is hidden — one
    /// photograph at a time would leave the connection idle for most of a scan.
    var concurrency: Int

    /// Whether readings already on this machine may be reused.
    var reuseStored: Bool

    /// The model the requests will name. Part of the store's key, so readings are never reused across
    /// models.
    var modelID: String

    /// The thorough path switched off: one request over the whole gallery.
    static let disabled = PhotoScanPlan(
        isEnabled: false,
        perImageLimit: 0,
        concurrency: 1,
        reuseStored: false,
        modelID: ""
    )

    /// Photographs in flight by default. Three matches the batch width a run of **Price all** uses,
    /// and a provider that meters concurrency (DeepSeek) has room for it many times over.
    static let defaultConcurrency = 3

    /// The thorough path for a model, over every photograph or the first `perImageLimit` of them.
    static func thorough(
        modelID: String,
        perImageLimit: Int = 0,
        reuseStored: Bool = true,
        concurrency: Int = PhotoScanPlan.defaultConcurrency
    ) -> PhotoScanPlan {
        PhotoScanPlan(
            isEnabled: true,
            perImageLimit: max(0, perImageLimit),
            concurrency: max(1, concurrency),
            reuseStored: reuseStored,
            modelID: modelID
        )
    }

    /// How many photographs to read individually, out of a gallery of `imageCount`.
    func photoLimit(for imageCount: Int) -> Int {
        guard isEnabled else { return 0 }
        return perImageLimit <= 0 ? imageCount : min(perImageLimit, imageCount)
    }
}

/// One photograph, and everything the model needs to be asked about it.
struct PhotoReadingRequest: Sendable {

    /// The lot this photograph belongs to.
    var subject: ValuationSubject

    /// 1-based position in the gallery, so the reading and the prompt can both say which frame it is.
    var index: Int

    /// Size of the gallery, so a reading can say it is one of twelve rather than one of some.
    var imageCount: Int

    /// The photograph itself, downloaded and MIME-normalised.
    var image: LotImage

    /// The lot's listing text, exactly as the single-pass prompt formats it.
    var description: String

    /// What the app's own reader (`LotImageDigest`) made of **this** photograph — not of the gallery,
    /// which is the whole point: a barcode read off photograph 1 is not evidence about photograph 5.
    var localReading: LotImageEvidence

    /// `photograph 3 of 12`, the phrase the prompt opens with.
    var positionPhrase: String { "photograph \(index) of \(imageCount)" }
}

/// Everything the reconciliation request needs: the readings, and any photographs that were not read
/// one at a time.
struct PhotoAggregationRequest: Sendable {

    var subject: ValuationSubject
    var description: String

    /// The per-photograph readings, in gallery order.
    var readings: [PhotoReading]

    /// Photographs the ceiling kept out of the per-image path, attached so the reconciliation can
    /// still see them. Empty in the default configuration, where every photograph is read on its own.
    var leftoverImages: [LotImage]

    /// The app's own reading of the whole gallery (barcodes and printed identifiers), echoed so the
    /// reconciliation prices the same literal digits the single-pass prompt would have been given.
    var evidence: LotImageEvidence?
}

/// One step of a thorough scan, reported as it happens.
///
/// The pipeline cannot log — a `ValuationService` is a `Sendable` value with no idea what a console
/// is — so it reports, and `AnalysisCoordinator` turns these into console lines and into the live
/// note on the row being scanned.
enum PhotoScanEvent: Sendable, Equatable {

    /// A photograph is about to be read — or was restored from this machine's store instead.
    case reading(index: Int, of: Int, reused: Bool)

    /// A reading landed, with how many product groups it found.
    case read(index: Int, of: Int, objects: Int)

    /// A photograph could not be read. Never fatal on its own: the rest of the gallery still counts.
    case failed(index: Int, of: Int, reason: String)

    /// The reconciliation request is going out.
    case aggregating(photographs: Int, leftovers: Int)

    /// The reconciliation landed, with how many line items it produced.
    case aggregated(items: Int)

    /// The reconciliation failed and the readings were merged on this machine instead.
    case aggregatedLocally(reason: String)

    /// The thorough path produced no readings at all, so the scan is falling back to one pass over
    /// the whole gallery.
    case fallingBack(reason: String)

    /// The line the console prints for this step, without the lot number.
    var message: String {
        switch self {
        case .reading(let index, let of, let reused):
            reused
                ? "photograph \(index) of \(of): already read on this machine — reusing it, no request"
                : "reading photograph \(index) of \(of)"
        case .read(let index, let of, let objects):
            "photograph \(index) of \(of) read: \(objects) product group(s)"
        case .failed(let index, let of, let reason):
            "photograph \(index) of \(of) could not be read (\(reason)) — carrying on with the rest"
        case .aggregating(let photographs, let leftovers):
            leftovers > 0
                ? "reconciling \(photographs) reading(s) plus \(leftovers) unread photograph(s) into the pallet's line items"
                : "reconciling \(photographs) reading(s) into the pallet's line items"
        case .aggregated(let items):
            "reconciled into \(items) line item(s)"
        case .aggregatedLocally(let reason):
            "the reconciliation request failed (\(reason)) — merging the readings on this machine instead"
        case .fallingBack(let reason):
            "nothing could be read photograph by photograph (\(reason)) — falling back to one pass over the whole gallery"
        }
    }
}

/// One `PhotoScanEvent` with the lot it belongs to, which is what makes it loggable.
struct PhotoScanReport: Sendable, Equatable {

    var lotNumber: String
    var event: PhotoScanEvent

    /// `Lot 142: photograph 3 of 12 read: 5 product group(s)`.
    var logLine: String { "Lot \(lotNumber): \(event.message)" }

    /// The short note the row shows while it is being read. The row already prints the lot number, so
    /// the note leaves it out.
    var rowNote: String { event.message }
}

// MARK: - The pipeline

/// Runs one lot's thorough scan: reuse what this machine knows, read what it does not, store it, and
/// reconcile.
enum LotPhotoScan {

    /// What a completed thorough scan produced.
    struct Outcome: Sendable {

        /// The pallet's line items.
        var items: [DiscoveredItem]

        /// Every reading, in gallery order.
        var readings: [PhotoReading]

        /// Requests actually sent to the model: the photograph reads plus the reconciliation.
        var requests: Int

        /// Readings restored from this machine's store instead of being requested again.
        var reused: Int

        /// Photographs that could not be read, with the reason the provider gave.
        var failures: [String]

        /// Why the reconciliation had to be done on this machine, when it did.
        var aggregationFailure: String?

        /// `true` when `items` came from `PhotoReadingMerge` rather than from the model.
        var mergedLocally: Bool
    }

    /// How a thorough scan ended.
    ///
    /// Generic over what a completed scan produced so a service can map the readings onto its own
    /// outcome type without the pipeline knowing what a `ValuationOutcome` is: `run` yields
    /// `RunResult<Outcome>` and each transport wraps that in `RunResult<ValuationOutcome>`.
    enum RunResult<Outcome: Sendable>: Sendable {

        /// The thorough path is switched off; the caller does what it always did.
        case off

        /// The thorough path produced nothing usable, with the error that says why. The caller decides
        /// between falling back to a single pass over the gallery and failing the lot.
        case unavailable(Error)

        /// The scan produced a valuation.
        case completed(Outcome)
    }

    /// Reads a lot's photographs one at a time and reconciles them.
    ///
    /// - Parameters:
    ///   - images: the photographs that will travel, in gallery order, already downloaded and inside
    ///     the inline budget.
    ///   - labels: the app's own reading of each photograph, in the same order (`LotImageDigest`);
    ///     shorter than `images` when the reader stopped early, in which case the tail reads as empty.
    ///   - store: where readings are remembered between scans.
    ///   - read: how to ask about one photograph — the provider's transport.
    ///   - aggregate: how to ask for the reconciliation — the provider's transport.
    ///   - report: progress, as it happens. Called from whichever task is doing the work.
    static func run(
        subject: ValuationSubject,
        description: String,
        images: [LotImage],
        labels: [LotImageEvidence],
        plan: PhotoScanPlan,
        store: PhotoReadingStore,
        read: @escaping @Sendable (PhotoReadingRequest) async throws -> PhotoReading,
        aggregate: @escaping @Sendable (PhotoAggregationRequest) async throws -> [DiscoveredItem],
        report: @escaping @Sendable (PhotoScanReport) -> Void
    ) async -> RunResult<Outcome> {
        guard plan.isEnabled, !images.isEmpty else { return .off }

        let lotNumber = subject.lotNumber
        let galleryCount = images.count
        let limit = plan.photoLimit(for: galleryCount)
        guard limit > 0 else { return .off }

        var slots: [PhotoReading?] = Array(repeating: nil, count: limit)
        var reusedIDs: Set<String> = []
        var requests = 0
        var failures: [String] = []

        // 1. What this machine already knows.
        //
        // Matched by address rather than by position: a gallery that gained a photograph at the front
        // keeps the readings it had, and only frames the store has never seen are paid for.
        if plan.reuseStored, !plan.modelID.isEmpty {
            var byURL: [URL: PhotoReading] = [:]
            for stored in await store.readings(forLot: lotNumber, modelID: plan.modelID) {
                byURL[stored.imageURL] = stored
            }
            for slot in 0..<limit {
                guard let stored = byURL[images[slot].sourceURL] else { continue }
                var reading = stored
                reading.imageIndex = slot + 1
                reading.imageCount = galleryCount
                slots[slot] = reading
                reusedIDs.insert(reading.id)
                report(
                    PhotoScanReport(
                        lotNumber: lotNumber,
                        event: .reading(index: slot + 1, of: galleryCount, reused: true)
                    )
                )
            }
        }

        // 2. The photographs this machine has not read yet, a few at a time.
        let pending = (0..<limit).filter { slots[$0] == nil }
        if !pending.isEmpty {
            let width = min(max(plan.concurrency, 1), pending.count)

            await withTaskGroup(of: (Int, Result<PhotoReading, Error>).self) { group in
                var next = 0

                while next < pending.count {
                    if Task.isCancelled { break }
                    let slot = pending[next]
                    next += 1
                    let request = PhotoReadingRequest(
                        subject: subject,
                        index: slot + 1,
                        imageCount: galleryCount,
                        image: images[slot],
                        description: description,
                        localReading: slot < labels.count ? labels[slot] : LotImageEvidence()
                    )
                    group.addTask {
                        report(
                            PhotoScanReport(
                                lotNumber: lotNumber,
                                event: .reading(index: slot + 1, of: galleryCount, reused: false)
                            )
                        )
                        do {
                            return (slot, .success(try await read(request)))
                        } catch {
                            return (slot, .failure(error))
                        }
                    }
                    // Wait for a slot to free up once the window is full.
                    if next < pending.count, next % width == 0, let finished = await group.next() {
                        requests += 1
                        collect(
                            finished,
                            into: &slots,
                            failures: &failures,
                            lotNumber: lotNumber,
                            galleryCount: galleryCount,
                            report: report
                        )
                    }
                }

                if Task.isCancelled { group.cancelAll() }
                for await finished in group {
                    requests += 1
                    collect(
                        finished,
                        into: &slots,
                        failures: &failures,
                        lotNumber: lotNumber,
                        galleryCount: galleryCount,
                        report: report
                    )
                }
            }
        }

        // 3. Store what was read, before anything else can fail.
        //
        // Written even when the run was stopped half way: the readings that did land were paid for, and
        // the next scan of this lot starts from them.
        let readings = slots.compactMap { $0 }
        let fresh = readings.filter { !reusedIDs.contains($0.id) }
        await store.store(fresh, forLot: lotNumber, modelID: plan.modelID)

        if Task.isCancelled { return .unavailable(CancellationError()) }
        guard !readings.isEmpty else {
            return .unavailable(
                ValuationError.photographReadsFailed(
                    count: limit,
                    reason: failures.first ?? "no reason given"
                )
            )
        }

        // 4. One request reconciles the readings into the pallet's line items.
        //
        // The photographs a ceiling left out travel with it, so a scan never sees less of a lot than
        // the single-pass appraisal did — it just knows more about some of the frames than others.
        let leftovers = Array(images.dropFirst(limit))
        let request = PhotoAggregationRequest(
            subject: subject,
            description: description,
            readings: readings,
            leftoverImages: leftovers,
            evidence: LotImageDigest.merge(labels)
        )
        report(
            PhotoScanReport(
                lotNumber: lotNumber,
                event: .aggregating(photographs: readings.count, leftovers: leftovers.count)
            )
        )

        do {
            let items = try await aggregate(request)
            report(PhotoScanReport(lotNumber: lotNumber, event: .aggregated(items: items.count)))
            return .completed(
                Outcome(
                    items: items,
                    readings: readings,
                    requests: requests + 1,
                    reused: reusedIDs.count,
                    failures: failures,
                    aggregationFailure: nil,
                    mergedLocally: false
                )
            )
        } catch {
            guard !ValuationCancellation.isCancellation(error) else { return .unavailable(error) }
            let reason = ValuationError.describe(error)
            let merged = PhotoReadingMerge.items(from: readings)
            // Nothing to fall back to: the caller decides between a single pass and a failure.
            guard !merged.isEmpty else { return .unavailable(error) }
            report(PhotoScanReport(lotNumber: lotNumber, event: .aggregatedLocally(reason: reason)))
            return .completed(
                Outcome(
                    items: merged,
                    readings: readings,
                    requests: requests + 1,
                    reused: reusedIDs.count,
                    failures: failures,
                    aggregationFailure: reason,
                    mergedLocally: true
                )
            )
        }
    }

    /// Files one finished photograph read in its slot, or notes why it did not land.
    private static func collect(
        _ finished: (Int, Result<PhotoReading, Error>),
        into slots: inout [PhotoReading?],
        failures: inout [String],
        lotNumber: String,
        galleryCount: Int,
        report: @Sendable (PhotoScanReport) -> Void
    ) {
        let (slot, result) = finished
        switch result {
        case .success(let reading):
            guard slots.indices.contains(slot) else { return }
            slots[slot] = reading
            report(
                PhotoScanReport(
                    lotNumber: lotNumber,
                    event: .read(index: slot + 1, of: galleryCount, objects: reading.objects.count)
                )
            )
        case .failure(let error):
            let reason = ValuationError.describe(error)
            failures.append(reason)
            report(
                PhotoScanReport(
                    lotNumber: lotNumber,
                    event: .failed(index: slot + 1, of: galleryCount, reason: reason)
                )
            )
        }
    }
}

// MARK: - Merging the readings with no model at hand

/// Folds per-photograph readings into the pallet's line items, on this machine.
///
/// Two jobs, both of which have to happen whether or not the model is available:
///
/// * **The fallback valuation.** If the reconciliation request fails — a quota refusal, a gateway
///   hiccup, an answer that will not parse — a lot whose *n* photographs were read has still been paid
///   for, and those readings name products and prices. This turns them into line items rather than
///   throwing the scan away (see `LotPhotoScan.run`).
/// * **The hint that stops double counting.** The reconciliation prompt is told which product groups
///   were seen in more than one photograph, because a model reading six of them has no way of knowing
///   that readings 2, 4 and 6 show one carton from three angles (`repeatedPhrases`).
///
/// Its rule for "the same product" is deliberately conservative: two sightings match when they share a
/// barcode / model / SKU number, or when brand and name normalise to the same words. Two cartons of
/// the same candles whose labels read the same way therefore merge; two similar-looking products with
/// different identifiers do not.
enum PhotoReadingMerge {

    /// Most line items the local merge produces, matching the ceiling the model is asked for.
    static let maximumItems = 12

    /// Longest evidence string kept for a merged group.
    static let maximumEvidenceLength = 200

    /// Longest repeated-group list sent to the reconciliation prompt.
    static let maximumRepeatedGroups = 12

    /// A product group as several photographs saw it.
    struct Group: Hashable, Sendable {

        /// The key this group was first seen under: an identifier, or brand plus normalised name.
        var key: String
        var name: String
        var brand: String
        var category: String
        /// Units the pallet holds, as the readings support it — see `insert` for why this is a maximum
        /// rather than a sum.
        var quantity: Int
        var unitRetail: Double
        var unitResale: Double
        var confidence: DiscoveredItem.Confidence
        var identifiers: [String]
        var labelText: String
        var evidence: String
        /// 1-based gallery positions this group was seen in.
        var photos: [Int]
        /// How many photographic readings reported this group.
        var sightings: Int

        /// Units to price with, at least one.
        var units: Int { max(quantity, 1) }

        /// Retail for the whole group.
        var retailValue: Double { unitRetail * Double(units) }

        /// Resale for the whole group.
        var resaleValue: Double { unitResale * Double(units) }

        /// Name with the count, for the nested table.
        var displayName: String { quantity > 1 ? "\(name) ×\(quantity)" : name }

        /// What the merged line's evidence line says.
        var evidenceText: String {
            var parts: [String] = []
            if !identifiers.isEmpty { parts.append(identifiers.joined(separator: ", ")) }
            if !labelText.isEmpty { parts.append("label reads \"\(labelText)\"") }
            if !evidence.isEmpty { parts.append(evidence) }
            return parts.joined(separator: " · ").truncated(to: maximumEvidenceLength)
        }

        /// The line's `notes`: that the figure came from readings rather than from one model looking at
        /// the whole pallet, and which photographs it rests on.
        var mergeNote: String {
            let positions = photos.sorted().map(String.init).joined(separator: ", ")
            let scope = photos.isEmpty ? "" : " (photograph(s) \(positions))"
            return "Merged on this machine from \(sightings) photograph reading(s)\(scope)."
        }
    }

    /// Groups the readings' objects, merging the sightings that describe one product.
    ///
    /// Order is first-seen order, which — because the readings arrive in gallery order — is the order
    /// the pallet was photographed in.
    static func groups(from readings: [PhotoReading]) -> [Group] {
        var order: [String] = []
        var groups: [String: Group] = [:]
        var owners: [String: String] = [:]

        for reading in readings.inGalleryOrder {
            for object in reading.objects {
                let name = object.name.condensedWhitespace
                guard !name.isEmpty else { continue }
                let objectKeys = keys(for: object)
                guard !objectKeys.isEmpty else { continue }

                let existing = objectKeys.compactMap { owners[$0] }
                let target: String

                if let first = existing.first {
                    target = first
                    // An object carrying two keys can join two groups that were separate until now —
                    // the same label read on two photographs, once described by its barcode and once by
                    // its model number. One product, so fold them together.
                    for other in existing.dropFirst() where other != target {
                        guard let folded = groups.removeValue(forKey: other) else { continue }
                        if var survivor = groups[target] {
                            fold(folded, into: &survivor)
                            groups[target] = survivor
                        }
                        for (key, value) in owners where value == other { owners[key] = target }
                        order.removeAll { $0 == other }
                    }
                } else {
                    let key = objectKeys[0]
                    target = key
                    order.append(key)
                    groups[key] = Group(
                        key: key,
                        name: name,
                        brand: object.brand,
                        category: object.category,
                        quantity: 0,
                        unitRetail: 0,
                        unitResale: 0,
                        confidence: .low,
                        identifiers: [],
                        labelText: "",
                        evidence: "",
                        photos: [],
                        sightings: 0
                    )
                }

                if var group = groups[target] {
                    insert(object, named: name, seenIn: reading.imageIndex, into: &group)
                    groups[target] = group
                }
                for key in objectKeys { owners[key] = target }
            }
        }

        return order.compactMap { groups[$0] }
    }

    /// Files one sighting of a product into its group.
    ///
    /// `quantity` is a **maximum**, not a sum, and that is the most important line in this file: a
    /// gallery photographs the same pallet from several angles, so the same six cartons are reported
    /// by three readings. Adding those up would value the pallet at three times what is on it. The
    /// largest count any single frame supports is the defensible floor, and it is exactly the rule the
    /// reconciliation prompt is given for the same reason.
    private static func insert(
        _ object: PhotoObject,
        named name: String,
        seenIn photo: Int,
        into group: inout Group
    ) {
        group.sightings += 1
        // The longest name wins: a reading that got the whole label describes the product better than
        // one that got "candles".
        if name.count > group.name.count { group.name = name }
        if group.brand.isEmpty { group.brand = object.brand }
        if group.category.isEmpty { group.category = object.category }
        group.quantity = max(group.quantity, object.quantity)
        group.unitRetail = max(group.unitRetail, object.unitRetail)
        group.unitResale = max(group.unitResale, object.unitResale)
        if object.confidenceLevel.sortRank < group.confidence.sortRank {
            group.confidence = object.confidenceLevel
        }
        for identifier in object.identifiers where !group.identifiers.contains(where: {
            $0.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            group.identifiers.append(identifier)
        }
        if group.labelText.isEmpty { group.labelText = object.labelText }
        if group.evidence.isEmpty { group.evidence = object.evidence }
        if !group.photos.contains(photo) { group.photos.append(photo) }
    }

    /// Folds one group into another, on the same rules as `insert`.
    private static func fold(_ incoming: Group, into group: inout Group) {
        group.sightings += incoming.sightings
        if incoming.name.count > group.name.count { group.name = incoming.name }
        if group.brand.isEmpty { group.brand = incoming.brand }
        if group.category.isEmpty { group.category = incoming.category }
        group.quantity = max(group.quantity, incoming.quantity)
        group.unitRetail = max(group.unitRetail, incoming.unitRetail)
        group.unitResale = max(group.unitResale, incoming.unitResale)
        if incoming.confidence.sortRank < group.confidence.sortRank { group.confidence = incoming.confidence }
        for identifier in incoming.identifiers where !group.identifiers.contains(where: {
            $0.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            group.identifiers.append(identifier)
        }
        if group.labelText.isEmpty { group.labelText = incoming.labelText }
        if group.evidence.isEmpty { group.evidence = incoming.evidence }
        for photo in incoming.photos where !group.photos.contains(photo) {
            group.photos.append(photo)
        }
    }

    /// Line items from the readings alone — the fallback when the reconciliation request fails.
    ///
    /// Sorted by resale and capped like an answer from the model, so a fallback valuation looks and
    /// sorts like any other, with `notes` saying where it came from.
    static func items(from readings: [PhotoReading], limit: Int = maximumItems) -> [DiscoveredItem] {
        groups(from: readings)
            .sorted { left, right in
                left.resaleValue == right.resaleValue
                    ? left.retailValue > right.retailValue
                    : left.resaleValue > right.resaleValue
            }
            .prefix(max(0, limit))
            .map { group in
                DiscoveredItem(
                    itemName: group.displayName,
                    confidence: group.confidence.rawValue,
                    retailValue: group.retailValue,
                    resaleValue: group.resaleValue,
                    notes: group.mergeNote,
                    evidence: group.evidenceText,
                    quantity: group.quantity,
                    photos: group.photos.sorted()
                )
            }
    }

    /// The product groups more than one photograph reported, as lines for the reconciliation prompt.
    ///
    /// This is the prompt's defence against a model that cannot tell "the same carton from another
    /// angle" from "another carton": the sightings are counted here, exactly, and handed over as a fact
    /// rather than left to be inferred from six descriptions of one pallet.
    static func repeatedPhrases(from readings: [PhotoReading]) -> [String] {
        groups(from: readings)
            .filter { $0.sightings > 1 }
            .sorted { $0.sightings > $1.sightings }
            .prefix(maximumRepeatedGroups)
            .map { group in
                let positions = group.photos.sorted().map(String.init).joined(separator: ", ")
                return "- \(group.displayName) — \(group.sightings) sightings, in photograph(s) \(positions)"
            }
    }

    /// The keys one object can be matched on: its identifiers first (the strongest evidence a
    /// photograph can carry), then brand plus normalised name.
    static func keys(for object: PhotoObject) -> [String] {
        var keys: [String] = []

        for identifier in object.identifiers.prefix(4) {
            let value = normalised(identifier)
            guard !value.isEmpty else { continue }
            keys.append("id:\(value)")
        }

        let brand = normalised(object.brand)
        var name = normalised(object.name)
        // A name that opens with the brand says it twice — "Yankee Candle Yankee Candle 22 oz" — so the
        // brand comes off the front and goes back on as part of the key.
        if !brand.isEmpty, name.hasPrefix(brand) {
            name = normalised(String(name.dropFirst(brand.count)))
        }
        if !name.isEmpty {
            keys.append(brand.isEmpty ? "name:\(name)" : "name:\(brand)|\(name)")
        }

        return keys
    }

    /// Lower-cased, punctuation-free, single-spaced form used **only** to decide whether two sightings
    /// are the same product. Nothing is compared that a human could not see on the label: "Energizer
    /// MAX AA, 24-pack" and "energizer max aa 24 pack" normalise to the same words, while "Energizer
    /// MAX AAA" does not.
    static func normalised(_ text: String) -> String {
        let allowed = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character.isWhitespace ? character : " "
        }
        return String(allowed).condensedWhitespace
    }
}

