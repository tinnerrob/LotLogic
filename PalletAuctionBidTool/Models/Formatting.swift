//
//  Formatting.swift
//  PalletAuctionBidTool
//
//  Shared presentation helpers plus the money parsing used to turn scraped bid
//  strings ("Current bid: $1,275.50 USD") into `Double` values.
//

import Foundation

extension Double {

    /// `$1,234.56`
    var currencyText: String {
        formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// `$1,235` used for the compact totals chip in each lot row.
    var currencyWholeText: String {
        formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    /// `62%` — used for the resale/retail margin and bid ROI read-outs.
    var percentText: String {
        formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Best-effort currency extraction from scraped auction text.
///
/// Auction pages render bids in dozens of shapes (`$1,275.50`, `USD 1,275.50`,
/// `Current Bid: 1275.5`, `1250 (12 bids)`), so the parser prefers a number that is
/// glued to a currency marker and only falls back to "largest number on the line".
enum PriceParsing {

    // Constant, developer-authored patterns: a failure here is a programming error.
    private static let currencyLeading = try! NSRegularExpression(
        pattern: #"(?:[$€£]|USD|usd|CAD|cad)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)"#
    )
    private static let currencyTrailing = try! NSRegularExpression(
        pattern: #"([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*(?:USD|usd|dollars|\$)"#
    )
    private static let anyNumber = try! NSRegularExpression(
        pattern: #"([0-9][0-9,]*(?:\.[0-9]{1,2})?)"#
    )

    /// First currency-looking amount in `raw`, or `nil` when there is no number at all.
    static func firstNumber(in raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        for expression in [currencyLeading, currencyTrailing] {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = expression.firstMatch(in: text, options: [], range: range),
               let value = value(of: match, in: text) {
                return value
            }
        }

        // No currency marker: use the largest number (bids are the biggest figure on a card).
        return allNumbers(in: text).max()
    }

    /// Every numeric amount in `raw`, used when a card holds bid + shipping + bid count.
    static func allNumbers(in raw: String) -> [Double] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return anyNumber.matches(in: text, options: [], range: range).compactMap { value(of: $0, in: text) }
    }

    private static func value(of match: NSTextCheckingResult, in text: String) -> Double? {
        guard match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let digits = text[range].replacingOccurrences(of: ",", with: "")
        return Double(digits)
    }
}

/// Collapses runs of whitespace so scraped DOM text is safe to render in a single-line cell.
extension String {

    var condensedWhitespace: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Truncates on a word boundary, appending an ellipsis when shortened.
    func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        let head = prefix(max(0, limit - 1))
        if let lastSpace = head.lastIndex(of: " "), lastSpace > head.startIndex {
            return head[head.startIndex..<lastSpace] + "…"
        }
        return head + "…"
    }
}
