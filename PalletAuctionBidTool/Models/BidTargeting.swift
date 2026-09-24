//
//  BidTargeting.swift
//  PalletAuctionBidTool
//
//  The two pricing policies the lot table applies to a row: the percentage-of-resale bid ceiling
//  behind the **Max bid** column, and the dollar line above which a single line item counts as an
//  anchor worth calling out.
//
//  Deliberately SwiftUI-free so the rules are compiled into the offline harness and checked
//  without a window: see `Tools/free-tier-harness`.
//

import Foundation

// MARK: - Bid ceiling

/// Percentage-of-resale ceilings the app turns into a per-lot **Max bid**.
///
/// How high a lot is worth bidding depends on how well the pallet is understood: a listing the
/// engine is sure about can be bid closer to resale than one it had to guess at. The three
/// percentages are stored per confidence level so the operator can tune them, and each one is
/// clamped into `percentRange` — a ceiling of 0% would silently refuse every lot, and one above
/// 95% would leave nothing for fees, freight and the odd mis-read pallet.
struct BidTargetPolicy: Equatable, Sendable {

    /// Percent of resale worth bidding when the valuation is High confidence.
    var highConfidencePercent: Int

    /// Percent of resale worth bidding on a Med-confidence valuation.
    var mediumConfidencePercent: Int

    /// Percent of resale worth bidding when the engine had to guess.
    var lowConfidencePercent: Int

    /// The shipped policy: 60% of a confident resale figure, 50% of a reasonable one, 35% of a
    /// guess.
    static let standard = BidTargetPolicy()

    /// Range every percentage is clamped into.
    static let percentRange = 5...95

    init(
        highConfidencePercent: Int = 60,
        mediumConfidencePercent: Int = 50,
        lowConfidencePercent: Int = 35
    ) {
        self.highConfidencePercent = Self.clamp(highConfidencePercent)
        self.mediumConfidencePercent = Self.clamp(mediumConfidencePercent)
        self.lowConfidencePercent = Self.clamp(lowConfidencePercent)
    }

    /// Ceiling for one confidence level.
    func percent(for level: DiscoveredItem.Confidence) -> Int {
        switch level {
        case .high: highConfidencePercent
        case .medium: mediumConfidencePercent
        case .low: lowConfidencePercent
        }
    }

    /// The bid ceiling for a resale estimate, rounded to whole dollars so the table never suggests
    /// a bid nobody can place.
    func maxBid(againstResale resale: Double, level: DiscoveredItem.Confidence) -> Double {
        guard resale > 0 else { return 0 }
        return (resale * Double(percent(for: level)) / 100).rounded()
    }

    private static func clamp(_ percent: Int) -> Int {
        min(max(percent, percentRange.lowerBound), percentRange.upperBound)
    }
}

/// One lot's evaluated bid ceiling — what the **Max bid** column renders.
struct BidTarget: Equatable, Sendable {

    /// Highest bid worth placing, in whole dollars.
    var maxBid: Double

    /// Percent of resale the ceiling came from, so the column can explain itself.
    var percent: Int

    /// The resale figure the ceiling was derived from: the appraised total, or the pre-price's
    /// guess while the lot is still waiting to be scanned. Quoted back in the column's tooltip.
    var resale: Double

    /// Confidence behind the resale figure the ceiling was derived from. A lot carries the
    /// *weakest* line item's confidence, because one shaky row is enough to sink a pallet.
    var confidence: DiscoveredItem.Confidence

    /// `true` when the resale figure came from the cheap text-only pre-price rather than a
    /// photographed valuation, so the table can present the ceiling as a first look.
    var isProvisional: Bool

    /// The live bid the lot is sitting at.
    var currentBid: Double

    /// How much more could be bid before the ceiling is reached; negative once the lot is past it.
    var headroom: Double { maxBid - currentBid }

    /// `true` once the live bid has passed the ceiling.
    var isOverTarget: Bool { maxBid > 0 && currentBid > maxBid }
}

extension LotItem {

    /// The lot's bid ceiling, or `nil` while nothing has been priced at all.
    ///
    /// A full valuation wins: its totals and its weakest line item's confidence are what the
    /// operator is actually bidding on. Until one exists the cheap pre-price's numbers stand in and
    /// the result is flagged `isProvisional`, which is what the table renders in italics.
    func bidTarget(using policy: BidTargetPolicy) -> BidTarget? {
        if hasValuation {
            let level = lowestConfidence
            return BidTarget(
                maxBid: policy.maxBid(againstResale: totalResale, level: level),
                percent: policy.percent(for: level),
                resale: totalResale,
                confidence: level,
                isProvisional: false,
                currentBid: currentBid
            )
        }
        guard hasProvisionalValue else { return nil }
        let level = provisionalConfidence
        return BidTarget(
            maxBid: policy.maxBid(againstResale: provisionalResale, level: level),
            percent: policy.percent(for: level),
            resale: provisionalResale,
            confidence: level,
            isProvisional: true,
            currentBid: currentBid
        )
    }
}

// MARK: - Anchor items

/// The dollar line above which one line item is treated as an **anchor**: the product or two that
/// carry the pallet's value.
///
/// A pallet is often one or two good items plus filler. Those rows decide the bid, so the nested
/// table flags them instead of leaving them to be spotted by eye in a list of twelve.
enum AnchorItem {

    /// Threshold a fresh install starts with.
    static let defaultThreshold: Double = 100

    /// Range the operator's threshold is clamped into.
    static let thresholdRange: ClosedRange<Double> = 25...1_000

    /// Clamps a stored or typed threshold into `thresholdRange`.
    static func clamped(_ threshold: Double) -> Double {
        min(max(threshold, thresholdRange.lowerBound), thresholdRange.upperBound)
    }

    /// `true` when a line item worth `retail` is at or above `threshold`. A row priced at zero is
    /// never an anchor, however low the threshold goes.
    static func isAnchor(retail: Double, threshold: Double) -> Bool {
        retail > 0 && retail >= threshold
    }
}

extension DiscoveredItem {

    /// `true` when this line item alone justifies the pallet.
    func isAnchor(threshold: Double) -> Bool {
        AnchorItem.isAnchor(retail: retailValue, threshold: threshold)
    }

    /// The ceiling this line item supports on its own confidence, before it is rolled up into the
    /// lot's total.
    func maxBid(using policy: BidTargetPolicy) -> Double {
        policy.maxBid(againstResale: resaleValue, level: confidenceLevel)
    }
}

extension LotItem {

    /// How many line items are anchors at `threshold`.
    func anchorItemCount(threshold: Double) -> Int {
        discoveredItems.filter { $0.isAnchor(threshold: threshold) }.count
    }

    /// Retail credited to the anchor items — the part of the pallet that actually carries value.
    func anchorRetailTotal(threshold: Double) -> Double {
        discoveredItems
            .filter { $0.isAnchor(threshold: threshold) }
            .reduce(0) { $0 + $1.retailValue }
    }
}
