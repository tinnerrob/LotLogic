//
//  PhotoFrameGrouping.swift
//  PalletAuctionBidTool
//
//  Which photographs of a lot show the same thing, and are therefore worth reading once.
//
//  A lot's gallery is not a set of different subjects. It is one pallet photographed from the front,
//  from the side, and again with the flap of the same carton lifted — and the thorough scan
//  (`LotPhotoScan`) reads every frame it is handed, which means paying for the same carton three
//  times: three requests, three readings describing one thing, and then a reconciliation whose whole
//  job is to work out that they were one thing after all.
//
//  So before any request is made the frames are grouped. A frame that shows what an earlier frame
//  showed is not read on its own: the earlier frame's reading stands for both, and the frame itself
//  travels with the reconciliation request as an image, so the pallet is still seen by everything the
//  single-pass appraisal saw (rule 1 of `LotPhotoScan`). What is saved is the *reading* of a frame
//  whose content is already in hand — never a photograph.
//
//  Two signals decide it, and both are literal facts about the frames rather than guesses about the
//  goods on them:
//
//  * **The same picture.** Every frame is reduced to a small average-luma fingerprint and compared
//    bit for bit. Repeated bytes — a gallery that lists one photograph twice, which auction layouts do
//    whenever a lot is re-listed or the same zoom image is served at two addresses — land on an
//    identical fingerprint, while two photographs of one pallet do not.
//  * **The same decoded barcode.** `LotImageDigest` reads UPC/EAN codes off the frames on this
//    machine for nothing; a frame whose decoded barcode *set* equals another frame's shows the same
//    product, so one reading of it is enough. The whole set has to match: a frame carrying one
//    barcode and a frame carrying that barcode *plus* a second one are not the same view, because the
//    second frame holds something the first does not, and folding it in would lose it.
//
//  Nothing here is a similarity judgement. Two angles of one carton are *not* grouped — they are
//  different pictures, and the model is asked about both — which is the point: this pass stops paying
//  twice for what is provably the same frame, it does not guess at what looks alike.
//

import CoreGraphics
import Foundation
import ImageIO

/// One frame of a gallery, and the frames read as it.
///
/// A view is what a scan actually pays for: one request, one reading, and however many frames that
/// reading covers. Nothing about the pallet is decided here — a view is a claim about *photographs*
/// ("these are the same picture"), and the reconciliation still does the work of deciding what the
/// pallet holds (`LotPhotoScan`).
struct PhotoView: Sendable, Equatable {

    /// Why two frames are one view.
    enum Reason: Sendable, Equatable, Hashable {

        /// The same photograph: the same pixels, at whatever size they arrived.
        case samePicture

        /// The same decoded barcode, sorted, so the same product photographed again.
        case sameBarcode([String])

        /// How the claim reads after `photograph(s) 5 `: `are the same picture as photograph 2`.
        ///
        /// Plural on purpose, and by the same convention the scan's own console lines use: a view with
        /// one fold and a view with four read alike, so no sentence has to agree with a count.
        func claim(as photograph: Int) -> String {
            switch self {
            case .samePicture:
                "are the same picture as photograph \(photograph)"
            case .sameBarcode(let codes):
                "carry the same decoded barcode as photograph \(photograph) "
                    + "(\(codes.joined(separator: ", ")))"
            }
        }

        /// What the reconciliation is told the frames have in common, as a fact it can lean on.
        ///
        /// The two cases promise different things and are therefore worded differently: the same
        /// pixels mean the other frame's reading is *complete* evidence about this frame, while the
        /// same barcode means it covers that one product and nothing else the frame may show.
        func promptNote(as photograph: Int, frames: [Int]) -> String {
            let list = frames.map(String.init).joined(separator: ", ")
            switch self {
            case .samePicture:
                return "Photograph(s) \(list) — \(claim(as: photograph)), to the pixel — were not read "
                    + "on their own: photograph \(photograph)'s reading already covers everything in "
                    + "them, and they are attached below for completeness."
            case .sameBarcode:
                return "Photograph(s) \(list) — \(claim(as: photograph)), so the same goods — were not "
                    + "read on their own: photograph \(photograph)'s reading covers that product. They "
                    + "are attached below; check them for units of it that the reading's count missed "
                    + "rather than counting the same stack twice."
            }
        }
    }

    /// One frame that was not read on its own, and why not.
    struct Fold: Sendable, Equatable, Hashable {

        /// 1-based gallery position of the frame.
        var frame: Int

        var reason: Reason
    }

    /// 1-based gallery position of the frame that was actually read.
    var representative: Int

    /// The frames read as it, in gallery order.
    var folds: [Fold]

    /// Every frame this view stands for, the one that was read first.
    var frames: [Int] { [representative] + folds.map(\.frame) }

    /// The frames read as it, split by why — so a view whose folds do not share one reason still says
    /// exactly what it can support.
    var byReason: [(reason: Reason, frames: [Int])] {
        var order: [Reason] = []
        var grouped: [Reason: [Int]] = [:]
        for fold in folds {
            if grouped[fold.reason] == nil { order.append(fold.reason) }
            grouped[fold.reason, default: []].append(fold.frame)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    /// `photograph(s) 5, 9 are the same picture as photograph 2`, one clause per reason.
    var phrase: String {
        byReason.map { reason, frames in
            "photograph(s) \(frames.map(String.init).joined(separator: ", ")) "
                + reason.claim(as: representative)
        }.joined(separator: "; ")
    }

    /// The console's and the row's line for this view: the claim, plus where the folded frames went.
    /// Says what was saved — a request — rather than what was dropped, because nothing was.
    var logPhrase: String {
        "\(phrase) — read once, and the extra frame(s) travel with the reconciliation instead"
    }

    /// The same claim for the **batched** route, where there is no reconciliation for a repeated frame
    /// to travel with (`DeepSeekValuationService.manifestRoute`).
    ///
    /// An identical picture is the only fold that route makes — a frame folded on its decoded barcode is
    /// still sent, because its pixels are the only place a count of the goods can come from — so what
    /// this says is that one photograph is not being bought twice, not that a view was skipped.
    var batchLogPhrase: String {
        "\(phrase) — read once, and the repeated frame(s) are left out of the batches rather than sent again"
    }

    /// What the reconciliation prompt is told about this view, one line per reason.
    var promptNotes: [String] {
        byReason.map { $0.reason.promptNote(as: representative, frames: $0.frames) }
    }

    /// The view narrowed to the frames in `unread` — the ones the reconciliation still has to be told
    /// about, since a frame a stored reading already covers explains itself.
    ///
    /// - Returns: `nil` when this machine already had a reading for every frame of the view, in which
    ///   case there is nothing to explain.
    func narrowed(to unread: Set<Int>) -> PhotoView? {
        let remaining = folds.filter { unread.contains($0.frame) }
        guard !remaining.isEmpty else { return nil }
        var view = self
        view.folds = remaining
        return view
    }
}

/// Groups a gallery's frames before the scan reads them, so no frame is paid for twice.
///
/// Everything here runs on the machine, over frames the previous pass has already decoded: the whole
/// pass is cheaper than one photograph's request, so a grouping that saves nothing costs time a scan
/// of three or more frames spends on its first request anyway.
enum PhotoFrameGrouping {

    /// Side of the little grayscale square a frame is reduced to before it is compared.
    ///
    /// Small enough that two encodings of one photograph land on the same square, large enough that
    /// two photographs of one pallet do not: frames of one pallet differ across hundreds of these 256
    /// cells, while re-encoding and re-sizing noise moves single digits.
    static let fingerprintSide = 16

    /// How many distinct gray levels a frame has to hold to be compared at all.
    ///
    /// A flat frame — a blank slide, a solid colour, a white label photographed straight on — reduces
    /// to one flat square whatever else is in the gallery, so comparing it matches everything. Those
    /// frames get no fingerprint and are read on their own.
    static let minimumDetail = 8

    /// What one gallery's grouping came to.
    struct Grouping: Sendable, Equatable {

        /// One entry per view that has a frame folded into it, in gallery order.
        var views: [PhotoView]

        /// Covered frame -> the frame read for it.
        ///
        /// The scan uses this to know which frames it may skip, and a reading row uses it to say what a
        /// frame's reading came from.
        var leaders: [Int: Int]

        /// `true` when no two frames showed the same thing, which is the common case.
        var isEmpty: Bool { views.isEmpty }

        /// The frame a folded frame was read as, or `nil` for a frame that was read itself.
        func representative(of frame: Int) -> Int? { leaders[frame] }

        static let none = Grouping(views: [], leaders: [:])
    }

    /// Groups the frames of one gallery.
    ///
    /// - Parameters:
    ///   - images: the photographs, in gallery order.
    ///   - labels: the app's own reading of each frame (`LotImageDigest.readEach`), in the same order.
    ///   - limit: how many frames the scan is willing to read (`PhotoScanPlan.photoLimit`). Frames past
    ///     the ceiling are attached without being read, so grouping them would save nothing.
    /// - Returns: the views, and which frame each folded frame is read as.
    static func group(images: [LotImage], labels: [LotImageEvidence], limit: Int) async -> Grouping {
        let window = min(max(limit, 0), images.count)
        guard window > 1 else { return .none }

        let codes = barcodeSets(labels: labels, frames: window)
        let prints = await fingerprints(of: Array(images.prefix(window)))

        var leaders: [Int: Int] = [:]
        var reasons: [Int: PhotoView.Reason] = [:]
        var owners: [String: Int] = [:]

        // One pass in gallery order: the first frame carrying a signal owns it, and every later frame
        // carrying the same signal is read as it. A folded frame never becomes an owner itself, so a
        // chain of look-alikes all point at the one frame that was actually read.
        for slot in 0..<window {
            guard let signal = signal(slot: slot, prints: prints, codes: codes) else { continue }
            let frame = slot + 1
            if let owner = owners[signal.key] {
                leaders[frame] = owner
                reasons[frame] = signal.reason
            } else {
                owners[signal.key] = frame
            }
        }

        var folds: [Int: [PhotoView.Fold]] = [:]
        for (frame, owner) in leaders.sorted(by: { $0.key < $1.key }) {
            guard let reason = reasons[frame] else { continue }
            folds[owner, default: []].append(PhotoView.Fold(frame: frame, reason: reason))
        }

        return Grouping(
            views: folds.keys.sorted().map { PhotoView(representative: $0, folds: folds[$0] ?? []) },
            leaders: leaders
        )
    }

    /// The signal a frame is grouped by, or `nil` for a frame that is read on its own.
    ///
    /// The picture is asked first because it is the stronger claim: the same pixels mean the same
    /// photograph, whatever else happens to be in the frame.
    static func signal(
        slot: Int,
        prints: [Data?],
        codes: [[String]]
    ) -> (key: String, reason: PhotoView.Reason)? {
        if slot < prints.count, let print = prints[slot] {
            return ("picture:" + print.base64EncodedString(), .samePicture)
        }
        let barcodes = slot < codes.count ? codes[slot] : []
        guard !barcodes.isEmpty else { return nil }
        return ("barcode:" + barcodes.joined(separator: "+"), .sameBarcode(barcodes))
    }

    /// The decoded barcodes of the first `frames` photographs, sorted, empty where a frame carried
    /// none.
    ///
    /// Sorted so two frames carrying the same codes are recognised however the reader happened to
    /// report them. The *set* is the signal, not any one code: a frame holding one barcode and a frame
    /// holding that barcode plus a second one show different things.
    static func barcodeSets(labels: [LotImageEvidence], frames: Int) -> [[String]] {
        (0..<frames).map { slot in
            guard slot < labels.count else { return [] }
            return labels[slot].barcodes.sorted()
        }
    }

    /// A fingerprint of each frame, `nil` where a frame could not be decoded or holds too little
    /// detail to be a picture at all.
    ///
    /// The same photograph, re-encoded or served at another size, lands on the same fingerprint:
    /// ImageIO's own scaler does the reduction, and the gray levels are compared as one bit per cell,
    /// so the small differences between two encodings sit either side of the same average.
    static func fingerprints(of images: [LotImage]) async -> [Data?] {
        // Decoding and resampling are CPU-bound, so they are pushed off whatever actor asked — the
        // same thing `LotImageDigest.read` does with its own work.
        await Task.detached { decodeFingerprints(images) }.value
    }

    private static func decodeFingerprints(_ images: [LotImage]) -> [Data?] {
        images.map { image in
            guard let data = Data(base64Encoded: image.base64),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let square = CGImageSourceCreateThumbnailAtIndex(
                      source,
                      0,
                      [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: fingerprintSide,
                          kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary
                  )
            else { return nil }
            return fingerprint(of: square)
        }
    }

    /// One frame as 256 gray levels, one bit each — `nil` when the frame is too flat to be told from
    /// anything else.
    private static func fingerprint(of picture: CGImage) -> Data? {
        var cells = [UInt8](repeating: 0, count: fingerprintSide * fingerprintSide)
        let drawn = cells.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: fingerprintSide,
                height: fingerprintSide,
                bitsPerComponent: 8,
                bytesPerRow: fingerprintSide,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(picture, in: CGRect(x: 0, y: 0, width: fingerprintSide, height: fingerprintSide))
            return true
        }
        guard drawn else { return nil }

        // A frame with almost no variation is a blank slide or a flat colour, and every one of its
        // cells sits on its average: it would match every other flat frame in the gallery and fold a
        // photograph away for nothing. `minimumDetail` gray levels is a floor no photograph of goods
        // falls to and no flat frame passes.
        guard Set(cells).count >= minimumDetail else { return nil }

        let average = cells.reduce(0) { $0 + Int($1) } / cells.count
        var bits = Data(count: cells.count / 8)
        for (index, cell) in cells.enumerated() where Int(cell) >= average {
            bits[index / 8] |= UInt8(1 << (7 - index % 8))
        }
        return bits
    }
}
