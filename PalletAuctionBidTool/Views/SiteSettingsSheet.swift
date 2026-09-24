//
//  SiteSettingsSheet.swift
//  PalletAuctionBidTool
//
//  The modal behind the panel's gear icon: site credentials, provider, model and API key.
//

import SwiftUI

/// **Site login & valuation**, as a modal rather than a card in the control panel.
///
/// These fields used to sit in an expandable section above the table, which meant the table lost
/// roughly 120 points of height for the sake of four fields that are set once per install. Behind a
/// gear they cost nothing at all, and the panel keeps a one-line summary plus the gear's own warning
/// dot, so the state they describe is still visible without opening anything.
///
/// Fields write straight into `AppSettings` as they are typed — there is no OK/Cancel — so the
/// footer's button is labelled **Done** and the footnotes say as much. That is deliberate: the value
/// of a half-typed API key is nothing, and a modal that silently discarded edits on Escape would be
/// a worse trap than one that always applies them.
struct SiteSettingsSheet: View {

    @Bindable var settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.groupSpacing) {
            header
            Divider().opacity(0.6)
            siteSessionRow
            valuationRow
            warning
            footnotes
            Divider().opacity(0.6)
            footer
        }
        .padding(Theme.panelPadding + 2)
        .frame(width: 640)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("Site login & valuation", systemImage: "person.badge.key")
                .font(.headline)

            Spacer(minLength: 12)

            statusPill
        }
    }

    /// The same question the panel's readiness pill answers, answered for this modal's fields alone:
    /// is anything set up to appraise a lot?
    private var statusPill: some View {
        let ready = settings.hasAPIKey
        let text = ready ? "\(settings.provider.displayName) ready" : "No API key yet"
        let tint: Color = ready ? .green : .orange

        return Label(text, systemImage: ready ? "checkmark.circle" : "key")
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .help(
                "Run tuning decides how far a run walks and how fast it calls out; this modal "
                    + "supplies the credential those calls are made with."
            )
    }

    // MARK: - Fields

    /// Row one: the site session, two half-width fields so both stay usable at any window size.
    private var siteSessionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.controlSpacing) {
                SettingsFieldRow(label: "Site email") {
                    TextField("you@example.com", text: $settings.email)
                }
                .frame(maxWidth: .infinity)

                SettingsFieldRow(label: "Site password") {
                    SecureField("Password", text: $settings.password)
                }
                .frame(maxWidth: .infinity)
            }

            Text(
                "Leave both blank to scrape anonymously or to reuse the session this app has already "
                    + "stored. They are only needed when the auction site hides its lots behind a login."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Row two: who appraises — provider and model on one line, the credential on its own below.
    ///
    /// The key gets a full-width line on purpose: it is a long opaque string that is pasted, not
    /// typed, and a 100-point box beside two pickers shows six characters of it.
    private var valuationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.controlSpacing) {
                SettingsFieldRow(label: "Provider") {
                    Picker("Provider", selection: $settings.provider) {
                        ForEach(ValuationProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Which service appraises lots. Gemini has a free tier; DeepSeek is paid per token.")
                }
                .frame(width: 230)

                SettingsFieldRow(label: "Model") {
                    Picker("Model", selection: modelBinding) {
                        ForEach(settings.provider.availableModelIDs, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Only multimodal models are listed: Price sends the lot's photographs.")
                }
                .frame(maxWidth: .infinity)
            }

            SettingsFieldRow(label: settings.provider.keyLabel) {
                SecureField(settings.provider.keyPlaceholder, text: keyBinding)
                    .help(settings.provider.keyHelp)
            }

            Text("Each provider keeps its own key and model, so switching back and forth is lossless.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Shown only when the combination is actually a problem: no key, so nothing can be appraised.
    @ViewBuilder
    private var warning: some View {
        if !settings.hasAPIKey {
            Label(
                "Paste a \(settings.provider.displayName) API key above and the table's Eval and "
                    + "Price buttons light up.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnotes: some View {
        Text(
            "Edits apply as you type — there is no Cancel. Keys stay in this Mac's UserDefaults and "
                + "are sent only to the provider you picked."
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(settings.provider.keyHelp)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)

            Spacer(minLength: 12)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Provider bindings

    /// The model field follows the selected provider: it reads `activeModelID` (which falls back to
    /// that provider's default when nothing is stored) and writes the provider's own key.
    private var modelBinding: Binding<String> {
        Binding(
            get: { settings.activeModelID },
            set: { newValue in
                switch settings.provider {
                case .gemini: settings.modelID = newValue
                case .deepSeek: settings.deepSeekModelID = newValue
                }
            }
        )
    }

    /// Same idea for the credential field: one visible field, two stored keys.
    private var keyBinding: Binding<String> {
        Binding(
            get: { settings.activeAPIKey },
            set: { newValue in
                switch settings.provider {
                case .gemini: settings.apiKey = newValue
                case .deepSeek: settings.deepSeekAPIKey = newValue
                }
            }
        )
    }
}

#Preview("Settings") {
    SiteSettingsSheet(settings: AppSettings())
}
