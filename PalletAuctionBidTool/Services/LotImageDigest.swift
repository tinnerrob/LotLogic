//
//  LotImageDigest.swift
//  PalletAuctionBidTool
//
//  On-device reading of the photographs a scan is about to send.
//
//  A valuation is only as good as what the model can see, and the two things that pin a pallet's
//  price to an *exact* product — the barcode digits and the model/part number printed on the label —
//  are exactly the two things a general vision model is worst at reading off a photograph. They are
//  also the two things macOS can read natively. So the pictures are read twice: once here, on this
//  machine and for nothing, and once by the provider. What this pass finds is handed to the model as
//  already-verified text (see `LotImageEvidence.promptLines`), and the same strings are logged, so
//  the operator can see what a price was built on instead of trusting a black box (deviation 25).
//

import CoreGraphics
import Foundation
import ImageIO
import Vision

/// What the on-device reader found on one lot's photographs.
///
/// Both lists are literal: no interpretation, no normalisation beyond what is needed to compare two
/// readings of the same barcode. That is the point — the model is the interpreter, and it is only
/// useful to it if the digits are the digits that were printed.
struct LotImageEvidence: Sendable, Hashable {

    /// Barcode payloads the reader decoded, in the order the photographs were read.
    ///
    /// A UPC/EAN/GTIN names one exact product in one exact size, which is a far stronger pricing
    /// anchor than the shape of a carton: `0123456789012` is a specific 24-pack of a specific brand,
    /// and it has a market price that does not need to be guessed at.
    var barcodes: [String] = []

    /// Text on the packaging that looks like a catalogue identifier: a model, part, SKU or item
    /// number, or a GTIN printed as digits beside a barcode the reader could not decode.
    var identifiers: [String] = []

    /// Photographs the reader could open at all, out of the ones the request carries. A scan whose
    /// gallery is mostly unreadable says so through this number rather than silently reporting none.
    var imagesRead: Int = 0

    /// `true` when nothing legible was found — the ordinary case for a pallet of loose household
    /// goods, and not a problem: the model still has the photographs.
    var isEmpty: Bool { barcodes.isEmpty && identifiers.isEmpty }

    /// What the model is told about the reading, or an empty list when there is nothing to tell.
    var promptLines: [String] {
        guard !isEmpty else { return [] }
        var lines = [
            "A text and barcode reader on the app's own machine has already run over these same "
                + "\(imagesRead) photograph(s), and reports its literal output:"
        ]
        if !barcodes.isEmpty {
            lines.append("Decoded barcodes: \(barcodes.joined(separator: ", "))")
        }
        if !identifiers.isEmpty {
            lines.append("Printed identifiers (model / part / SKU / item numbers): \(identifiers.joined(separator: ", "))")
        }
        lines.append(
            "Treat those as already read: match each one to the product it belongs to, call that "
                + "product by the name the identifier belongs to, and price that exact model and size "
                + "rather than a category average. Quote the identifier in `evidence` exactly as it "
                + "appears above, and do not put a barcode or model number in `evidence` that is not "
                + "in this list unless you can read it yourself in the photographs."
        )
        return lines
    }

    /// One line for the activity console: what was read, in the same literal form.
    var logPhrase: String {
        guard !isEmpty else {
            return "nothing legible on \(imagesRead) photograph(s) — priced from what is visible"
        }
        var parts: [String] = []
        if !barcodes.isEmpty { parts.append("barcode(s) \(barcodes.joined(separator: ", "))") }
        if !identifiers.isEmpty { parts.append("identifier(s) \(identifiers.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }
}

/// Reads barcodes and identifier-looking label text out of the photographs a scan is about to send.
///
/// ## Why on-device
/// `VNDetectBarcodesRequest` decodes a UPC/EAN the way a till does — from the bars, not from the
/// photograph's appearance — and `VNRecognizeTextRequest` reads a printed model number off a carton
/// far more reliably than a multimodal model reading the same photograph. Both run locally, cost
/// nothing and need no key, so the only thing a scan gives up is a little time.
///
/// ## What it does not do
/// It prices nothing, and it does not decide what an identifier *means*. A pallet's worth of label
/// text is noisy — freight labels, receipt tape, a courier's tracking barcode — so the reader reports
/// literals and the prompt tells the model which of them to trust (an identifier that matches a
/// product in the photograph beats one stapled to the outside of the shrink wrap).
///
/// ## Deprecation
/// The `VN*` request classes are marked deprecated against the macOS 15 SDK in favour of the new
/// Swift `Vision` request types, which need macOS 15. This app supports macOS 14, so the classic
/// requests are used deliberately: they still work, and the alternative is an availability split for
/// no behavioural gain.
enum LotImageDigest {

    /// Photographs looked at per scan. A gallery is usually a handful of angles over the same few
    /// labels, so the first dozen finds what there is to find; the model still receives all of them.
    static let maximumImages = 12

    /// Identifiers that end the text pass early. Recognising text is the expensive half of a reading —
    /// barcode decoding is a scan for the bars — so once a few identifiers have been read, the rest of
    /// the gallery is the same cartons from another angle and is not worth the time. Barcodes keep
    /// being decoded on every photograph regardless: that half is cheap.
    static let enoughIdentifiers = 4

    /// Cap on each list, so a pallet of shrink-wrapped cartons cannot fill the prompt with label noise
    /// and crowd out the listing text.
    static let maximumBarcodes = 8
    static let maximumIdentifiers = 12

    /// Barcode kinds worth decoding. The linear product codes carry a product identifier, as do the
    /// GS1 2-D kinds; QR is left out on purpose, because on an auction photograph a QR is far more
    /// often the site's own sign or a URL than a product code.
    static let readSymbologies: [VNBarcodeSymbology] = [
        .ean13, .ean8, .upce, .itf14, .code128, .code39, .code93, .dataMatrix, .pdf417
    ]

    /// Words that make a short run of digits worth keeping. Without one of these, a bare four- to
    /// seven-digit number is as likely to be a price, a quantity or a year as a catalogue number.
    static let identifierHints = [
        "sku", "upc", "ean", "gtin", "isbn", "model", "mod.", "part", "p/n", "item", "ref", "no.", "code", "asin"
    ]

    /// Reads the photographs the request carries, best effort.
    ///
    /// - Parameter images: the images that will be inlined into the request, already downloaded and
    ///   MIME-normalised. Only what is sent is read, so the evidence can never describe a photograph
    ///   the model was not shown.
    /// - Returns: the literal readings, empty when nothing could be read. Never an error: a pallet
    ///   whose photographs are unreadable is a normal pallet, not a failed scan.
    static func read(_ images: [LotImage]) async -> LotImageEvidence {
        // Vision and CoreGraphics work is CPU-bound and can take a noticeable slice of a second per
        // photograph, so it is pushed off whatever actor asked for it.
        await Task.detached { decode(images) }.value
    }

    private static func decode(_ images: [LotImage]) -> LotImageEvidence {
        var evidence = LotImageEvidence()

        for image in images.prefix(maximumImages) {
            guard let data = Data(base64Encoded: image.base64),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let picture = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { continue }

            evidence.imagesRead += 1
            let handler = VNImageRequestHandler(cgImage: picture, options: [:])

            // Barcodes first, and on every photograph: decoding a UPC is a scan for the bars, which is
            // cheap, and a code is the single most valuable thing on a pallet photograph.
            let barcodeRequest = VNDetectBarcodesRequest()
            barcodeRequest.symbologies = readSymbologies
            _ = try? handler.perform([barcodeRequest])
            for observation in barcodeRequest.results ?? [] {
                guard let payload = observation.payloadStringValue,
                      let value = normalise(barcode: payload)
                else { continue }
                append(value, to: &evidence.barcodes, limit: maximumBarcodes)
            }

            // Text recognition is the expensive half, so it stops once the reading has something to
            // work with. The requests are separate for the same reason: a refusal in one cannot cost
            // the other its readings.
            guard evidence.identifiers.count < enoughIdentifiers else { continue }
            let textRequest = VNRecognizeTextRequest()
            // Accurate, not fast: the whole point is the digits of a model number, and language
            // correction is off because it is a spelling model, and "DCS620D" is not a word.
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = false
            _ = try? handler.perform([textRequest])
            let lines = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            for identifier in identifiers(in: lines) {
                append(identifier, to: &evidence.identifiers, limit: maximumIdentifiers)
            }
        }

        return evidence
    }

    /// The identifier-shaped tokens in a block of recognised text.
    ///
    /// Kept separate from `decode(_:)` — and free of any Vision type — so the rule that decides what
    /// counts as an identifier can be checked without an image, which is what the offline harness
    /// does. It is a deliberately conservative rule: a false positive sends the model off to price the
    /// wrong product, while a false negative only leaves the model where it would have been.
    ///
    /// - Parameter lines: recognised text lines, one per line of a label as read.
    /// - Returns: distinct tokens, in the order they were seen, capped at `maximumIdentifiers`.
    static func identifiers(in lines: [String]) -> [String] {
        var found: [String] = []

        for line in lines {
            // A line that names itself as carrying an identifier lowers the bar for the digits on it.
            let lowered = line.lowercased()
            let hinted = identifierHints.contains { lowered.contains($0) }

            // Labels punctuate identifiers as often as they space them — "SKU:4711", "UPC#0123…" — so a
            // colon or a hash separates tokens just as a space does.
            let tokens = line.split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "#" })
            for token in tokens {
                guard let identifier = normalise(token: String(token), hinted: hinted) else { continue }
                append(identifier, to: &found, limit: maximumIdentifiers)
            }
        }

        return found
    }

    /// Trims a barcode payload down to what is worth keeping, or rejects it.
    ///
    /// Symbologies like Code 128 can carry free text, so the rule is deliberately loose — anything
    /// alphanumeric between six and twenty-four characters long is a plausible product code — but a
    /// payload with no digit in it, or with almost no variety, is dropped.
    static func normalise(barcode payload: String) -> String? {
        let trimmed = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isWhitespace }
        let upper = trimmed.uppercased()
        guard (6...24).contains(trimmed.count),
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              trimmed.contains(where: \.isNumber),
              Set(upper).count >= 3
        else { return nil }
        return upper
    }

    /// Keeps a token when it looks like a catalogue identifier, and normalises what it keeps.
    ///
    /// - Parameters:
    ///   - raw: one token of a recognised text line, split on whitespace and on the colons and hashes
    ///     labels punctuate identifiers with.
    ///   - hinted: `true` when that line said "SKU", "UPC", "part number" or the like, which is what
    ///     lets a short bare number through.
    /// - Returns: the token, upper-cased, or `nil` when it is not identifier-shaped.
    static func normalise(token raw: String, hinted: Bool) -> String? {
        let token = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}<>\"'`|/\\*+~=·•$#"))
            .uppercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))

        let digits = token.filter(\.isNumber)
        let letters = token.filter(\.isLetter)
        let separators = token.filter { $0 == "-" || $0 == "_" || $0 == "." }

        guard (4...24).contains(token.count),
              digits.count + letters.count + separators.count == token.count,
              !digits.isEmpty,
              Set(token).count >= 3
        else { return nil }

        // Two shapes are worth keeping: a mixed model/SKU-style code, which needs enough characters to
        // be one ("20V", "2PK" and "5X7" are measurements, not part numbers), and a bare GTIN, which is
        // 8-14 digits (EAN-8 8, UPC-A 12, EAN-13 13, ITF-14 14).
        if !letters.isEmpty { return token.count >= 5 ? token : nil }
        if (8...14).contains(digits.count) { return token }
        return hinted && (4...7).contains(digits.count) ? token : nil
    }

    /// Appends a reading once, case-insensitively, and never past the cap.
    private static func append(_ value: String, to list: inout [String], limit: Int) {
        guard list.count < limit else { return }
        guard !list.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        list.append(value)
    }
}
