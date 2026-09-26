//
//  AboutSheet.swift
//  PalletAuctionBidTool
//
//  The modal behind the titlebar's About button: what the app is, and how to work it.
//

import SwiftUI

/// **About** — the app's name and tagline, then what it is for and how a session goes.
///
/// The window is dense and its buttons are terse, so this is the one place that spells the workflow
/// out in prose: set an account up, scrape a listing, appraise the lots worth a second look, then
/// read the money columns. It was reached as **Help** and is now the about box it always read like —
/// same tour, under the name and the tagline that belong above it. It is deliberately a sheet rather
/// than the system's own About panel: that panel holds a name, a version and a line of copyright, and
/// has no room for the prose this window actually needs.
struct AboutSheet: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.groupSpacing) {
            header
            brand
            Divider().opacity(0.6)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.groupSpacing) {
                    topics
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            .frame(height: 380)

            Divider().opacity(0.6)
            footer
        }
        .padding(Theme.panelPadding + 2)
        .frame(width: 640)
    }

    // MARK: - Topics

    /// The about itself, in reading order: what the app is, the three steps of a session, where the
    /// two API keys come from, and the two rooms the operator has to know about — the sheet where a
    /// run is tuned, and the table's own toolbar.
    @ViewBuilder
    private var topics: some View {
        topic(
            "What it does",
            "\(Theme.appName) reads the lot listing of a liquidation auction you sign into, then "
                + "appraises the pallets worth a second look with an AI model — Gemini by default, "
                + "DeepSeek as an alternative. Nothing is appraised behind your back: scraping makes "
                + "no API calls, and every price is a button you press."
        )

        bullets(
            "Getting started",
            [
                "Open Account (⌘,) and set the site's email and password, then paste a key into the "
                    + "provider section you mean to use — the Gemini one is free, the DeepSeek one "
                    + "draws on a prepaid balance. Only a key is required — leave the login blank to "
                    + "scrape anonymously.",
                "Paste the page that already lists the lots into the Auction URL field and press "
                    + "Scrape Lots. The app walks the number of result pages set under Tuning and "
                    + "fills the table. Stop cancels the scrape and every scan in flight.",
                "Appraise what matters: Eval is a cheap text-only guess from a lot's listing copy, "
                    + "Price is a scan built from its photographs — batched into a manifest and "
                    + "priced, on DeepSeek; frame by frame and reconciled, on Gemini — and Eval all / "
                    + "Price all do that for every lot with no figure yet."
            ]
        )

        keySources

        topic(
            "Reading the table",
            "One row per lot carries the current bid, the ceiling this app would pay (Max bid), "
                + "quantity, retail and resale value, profit, ROI, the reward-to-risk ratio, the "
                + "model's confidence and the site's own status. A lot the site marks sold is kept — "
                + "its Active chip turns red — and can still be priced. Sort from any column header, "
                + "narrow the rows with the search box, and choose which columns are drawn from the "
                + "gear in the table's toolbar."
        )

        topic(
            "Tuning a run",
            "The Tuning button holds how far a run walks (Pages), how fast it is allowed to call out "
                + "(Requests / min, so a metered key is paced rather than refused), how a lot's "
                + "photographs are read — in batches of a few frames (Photos / request, DeepSeek) or "
                + "one at a time (Photos / scan, Gemini) — and the bid "
                + "percentages and anchor threshold behind the Max bid column and the anchor flags "
                + "in an expanded row."
        )

        topic(
            "Cost and privacy",
            "Every scan is on demand, so not pressing a button is the off switch. The Gemini key is "
                + "free and the DeepSeek one is not — Getting an API key above has both — and Account "
                + "keeps each provider's key and model separately, so switching back and forth is "
                + "lossless. Its Forget button drops the photograph readings cached on this machine; "
                + "readings are what a re-scan with the same model reuses, so forgetting them makes "
                + "the next scan pay for each photograph again. Keys stay in this Mac's UserDefaults "
                + "and are sent only to the provider they belong to."
        )

        topic(
            "Where things live",
            "The activity console along the bottom logs what a run is doing; its own chevron folds "
                + "it away. The progress modal — raised while a run or a scan is working, and reached "
                + "again with the row's Progress button — shows the walk's pages, the step the row in "
                + "hand is on, that row's own open bid, retail, resale and profit, and the Stop that "
                + "ends the work. Almost every control also carries its own explanation in a tooltip "
                + "— hover it."
        )
    }

    /// **Getting an API key** — the two pages an operator has to find, and what each costs.
    ///
    /// The app used to name a provider and ask for a key and leave it there, so a first run ended in a
    /// search engine: nothing in it said where a key comes from. Both are documented here, in order,
    /// with the page itself as a link — and the steps, the cost line and the link all come from
    /// `ValuationProvider`, so this box and the Account sheet cannot send the operator to two
    /// different places.
    private var keySources: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Getting an API key")
                .font(.subheadline.weight(.semibold))

            Text(
                "Each service keeps its own key and both can be set at once: Account (⌘,) has a section "
                    + "for each, with its own model, and Appraise with decides which one prices lots."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(ValuationProvider.allCases) { provider in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(provider.displayName) — \(provider.keyCostNote)")
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(provider.keySteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("\(index + 1).")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)

                            Text(step)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Link(destination: provider.keySignupURL) {
                        Text("Open \(provider.keySourceName) — \(provider.keySignupLabel)")
                    }
                    .font(.caption)
                    .help("Opens \(provider.keySignupURL.absoluteString) in your browser.")
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("About", systemImage: "info.circle")
                .font(.headline)

            Spacer(minLength: 12)

            Text(versionText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// The app's name over its tagline — the two lines an about box exists to say, in `Theme` so the
    /// titlebar's own title and this cannot spell the name two ways.
    private var brand: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Theme.appName)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

            Text(Theme.tagline)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `Version 1.0 (1)`, read off the bundle rather than typed here, so it cannot drift from the
    /// build. A preview runs from the preview host's bundle, which carries no marketing version, so
    /// the fallback is the number the project sets.
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard let build = info?["CFBundleVersion"] as? String, build != short else {
            return "Version \(short)"
        }
        return "Version \(short) (\(build))"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("The README beside the project covers the same ground in more detail.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)

            Spacer(minLength: 12)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Sections

    /// A titled paragraph.
    private func topic(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A titled list, one bullet per step.
    private func bullets(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("•")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Text(item)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("About") {
    AboutSheet()
}
