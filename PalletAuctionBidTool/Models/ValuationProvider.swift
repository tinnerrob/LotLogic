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

    // MARK: - Where the key comes from

    /// What a key costs, in the words the settings sheet and the About box both print.
    var keyCostNote: String {
        switch self {
        case .gemini: "Free — an AI Studio key needs no billing account."
        case .deepSeek: "Paid — a prepaid balance, with no free tier."
        }
    }

    /// The site a key is claimed or bought from, named the way that site names itself.
    ///
    /// The app used to say "paste an API key" and stop there, which left the operator to find the
    /// right page by search — and a key from the wrong page is an install that cannot appraise
    /// anything. This is the name those instructions use.
    var keySourceName: String {
        switch self {
        case .gemini: "Google AI Studio"
        case .deepSeek: "DeepSeek Platform"
        }
    }

    /// The page a key is created on.
    var keySignupURL: URL {
        switch self {
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")!
        }
    }

    /// The link as it is printed: the page without its scheme, so a caption line stays a caption
    /// line. Derived from the URL rather than typed again, so the two cannot disagree.
    var keySignupLabel: String {
        keySignupURL.absoluteString.replacingOccurrences(of: "https://", with: "")
    }

    /// How to get one, in order, as the About box prints it.
    ///
    /// Held here rather than written into the About sheet so that the transport, the key's prefix,
    /// the page and the steps all describe the *same* provider: adding a third back end means
    /// filling in this file, not hunting for prose in a view. Plain sentences on purpose — the About
    /// box renders them as plain text, so emphasis markup would show up as asterisks.
    var keySteps: [String] {
        switch self {
        case .gemini: [
            "Sign in at Google AI Studio with any Google account — no billing account and no card.",
            "Press Create API key, pick or create a project, and copy the string that starts AIza.",
            "Paste it into the Gemini section of Account (⌘,). The model beside it is the one a scan names."
        ]
        case .deepSeek: [
            "Sign in at the DeepSeek Platform and open API keys.",
            "Top up the balance first: DeepSeek has no free tier, and an empty balance is refused mid-run.",
            "Press Create new API key, copy the string that starts sk-, and paste it into the DeepSeek section of Account."
        ]
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

/// Which service **reads a lot's photographs**, when the operator wants somebody other than the appraiser
/// doing it.
///
/// The two halves of a photographed appraisal want different things from a model: reading a carton's printed
/// model number, barcode digits and count off a photograph is a **vision** problem, while pricing that
/// barcode afterwards is a lookup that pixels cannot improve. So the photographs can be pointed at either
/// provider while the prices stay where they are (`AppSettings.photoProvider`), and the invoices land on the
/// two keys the two sections of Account name.
///
/// **Both directions work, and each one is a manifest.** Whichever provider reads the gallery, its batches
/// are folded into an inventory on this machine (`LotManifestScan`) and that inventory is priced by the
/// **appraiser** (`ManifestPricingService`) — so a Gemini-priced run buys its photographs from DeepSeek
/// exactly as a DeepSeek-priced run buys them from Gemini. Nothing about the two routes drifts apart to make
/// that work: the reading half and the pricing half are roles, and each transport fills both.
///
/// What the setting cannot do is invent a manifest where none can run. Naming a provider changes nothing
/// until a width is set on Run Tuning's **Photos / request** row, because a batch is the thing a manifest is
/// read in (`AppSettings.batchesPhotographs`).
///
/// Gemini is the one provider with a photograph route that is not the batched one: while Gemini is *both*
/// appraiser and reader, a gallery is read frame by frame — or in one whole-gallery request
/// (`AppSettings.readsWholeGalleryInOneRequest`) — because that is the route Gemini has. **Photos /
/// request** is inert there rather than a second, silent route.
enum PhotoProvider: String, CaseIterable, Identifiable, Sendable {

    /// One provider for both jobs: whoever appraises a lot also reads its photographs. The default, and
    /// what every install did before the split existed.
    case same

    /// Gemini reads the gallery — with whichever model its own section in Account names, so the reading half
    /// is bought on its own key and its own model, current or not.
    case gemini

    /// DeepSeek reads the gallery, in batches of whatever **Photos / request** is set to. Spelled out rather
    /// than folded into `.same` so that the choice survives switching **Appraise with** to Gemini and back.
    case deepSeek = "deepseek"

    var id: String { rawValue }

    /// The picker's own wording. `.same` names the appraiser it will follow, because *Same* alone
    /// does not say what it is the same as.
    func displayName(fallingBackTo pricing: ValuationProvider) -> String {
        switch self {
        case .same: "Same as appraiser (\(pricing.displayName))"
        case .gemini: "Gemini"
        case .deepSeek: "DeepSeek"
        }
    }

    /// The provider that fills the identity role, given the one appraising the lot.
    func provider(fallingBackTo pricing: ValuationProvider) -> ValuationProvider {
        switch self {
        case .same: pricing
        case .gemini: .gemini
        case .deepSeek: .deepSeek
        }
    }
}

/// One provider with the state that decides whether it can spend anything, as one row.
///
/// Two surfaces speak about *both* providers at once — the Account sheet's own header and the panel's
/// **Account** tooltip — and they have to agree about the order and the wording. Pairing them here
/// means each view asks once and neither can invent its own phrase for "no key yet".
struct ProviderKeyState: Identifiable, Sendable, Equatable {

    let provider: ValuationProvider

    /// `true` when this provider has a non-blank key stored, which is what `hasAPIKey` means for it.
    let isReady: Bool

    /// The model this provider would use, already fallen back to its default when nothing is stored.
    let modelID: String

    var id: ValuationProvider.ID { provider.id }

    /// `Gemini · gemini-3.8-flash · key set` — the panel tooltip's own phrase, one provider per part.
    var summary: String {
        "\(provider.displayName) · \(modelID) · \(isReady ? "key set" : "no key")"
    }
}
