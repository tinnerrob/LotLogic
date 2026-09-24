//
//  ValuationProvider.swift
//  PalletAuctionBidTool
//
//  Which back end appraises a lot, and everything the UI needs to describe it.
//

import Foundation

/// The valuation back ends the operator can choose between.
///
/// Only the wire format and the credentials differ: both providers receive the same prompt, the
/// same scraped text and the same photographs, and both must return the same JSON shape (see
/// `LotValuationPrompt`). Adding a third means conforming to `ValuationService` and extending
/// this enum — nothing in the coordinator or the table changes.
enum ValuationProvider: String, CaseIterable, Identifiable, Sendable {

    /// Google AI Studio key against `:generateContent`. The only provider with a free tier.
    case gemini

    /// DeepSeek's OpenAI-compatible `/chat/completions`. Cheaper per token than paid Gemini, but
    /// **not** free: it draws on a prepaid balance.
    case deepSeek = "deepseek"

    var id: String { rawValue }

    /// Name used in the UI, the run log and error text.
    var displayName: String {
        switch self {
        case .gemini: "Gemini"
        case .deepSeek: "DeepSeek"
        }
    }

    /// The model used when the stored choice is empty or unknown.
    var defaultModelID: String {
        switch self {
        case .gemini: GeminiValuationService.defaultModelID
        case .deepSeek: DeepSeekValuationService.defaultModelID
        }
    }

    /// Models offered in the picker.
    ///
    /// Every entry must be multimodal: the valuation step sends photographs, so a text-only model
    /// cannot do this job. `deepseek-v4-pro`, for instance, is deliberately absent — DeepSeek
    /// documents its input modalities as `["text"]` only, and it would silently appraise every lot
    /// from listing text alone.
    var availableModelIDs: [String] {
        switch self {
        case .gemini: GeminiValuationService.availableModelIDs
        case .deepSeek: DeepSeekValuationService.availableModelIDs
        }
    }

    // MARK: - Settings labels

    /// Label for the credential field.
    var keyLabel: String {
        switch self {
        case .gemini: "Gemini key"
        case .deepSeek: "DeepSeek key"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .gemini: "AIza…"
        case .deepSeek: "sk-…"
        }
    }

    var keyHelp: String {
        switch self {
        case .gemini:
            "Sent as the x-goog-api-key header. A free-tier AI Studio key (no billing account) is enough. Stored in this app's UserDefaults domain — see the README."
        case .deepSeek:
            "Sent as an Authorization: Bearer header. Needs a topped-up DeepSeek balance — there is no free tier. Stored in this app's UserDefaults domain — see the README."
        }
    }

    /// Help text under **Requests / min**, which means different things per provider.
    var pacingHelp: String {
        switch self {
        case .gemini:
            """
            Upper bound on Gemini calls per minute. Keep it inside your project's quota \
            (10–15/min on the free tier) or the API answers with HTTP 429; 0 disables \
            pacing entirely. See ai.google.dev/gemini-api/docs/rate-limits.
            """
        case .deepSeek:
            """
            Upper bound on DeepSeek calls per minute. DeepSeek meters concurrency (2500 \
            requests in flight for deepseek-flash) rather than requests per minute, so pacing \
            is optional here — raise it, or set 0 to send as fast as the lots allow.
            """
        }
    }
}
