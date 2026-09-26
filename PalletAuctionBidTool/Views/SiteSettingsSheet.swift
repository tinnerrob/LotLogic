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
///
/// The appraiser is chosen here as well, but no longer *above* a single credential field: **Gemini**
/// and **DeepSeek** own a section each, both drawn, each holding its own key, its own model and the
/// page its key comes from. A field whose contents swapped as a different control moved read as
/// though the other key had been thrown away — and with two keys that are pasted once and re-read
/// months later, "did it keep the other one?" is the one question this sheet must never leave open.
/// The choice that remains is which service appraises a lot, and it is a segmented control because it
/// is a choice the app genuinely has: the two routes differ (see `batchesPhotographs`).
struct SiteSettingsSheet: View {

    @Bindable var settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    /// How many lots this machine has readings for (`PhotoReadingStore`), and whether a **Forget** is
    /// in flight. Loaded when the sheet opens, because the store is an actor and the count is a file
    /// listing — not something to do while drawing a modal.
    @State private var storedLots = 0
    @State private var isForgetting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.groupSpacing) {
            header
            Divider().opacity(0.6)
            siteSessionRow
            appraiserRow
            photoRow
            keySections
            readingsRow
            warning
            footnotes
            Divider().opacity(0.6)
            footer
        }
        .padding(Theme.panelPadding + 2)
        .frame(width: 640)
        .task { await refreshStoredLots() }
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

    /// The question the orange dot on the titlebar's **Account** button raises, answered for both
    /// providers at once: which of them could appraise a lot right now?
    ///
    /// It counts keys rather than naming the armed one alone, because the sheet now shows both — an
    /// operator who pasted a Gemini key and then armed DeepSeek needs to see that Gemini's key is the
    /// only one there. The tint still follows the *armed* provider, because that is the one the
    /// table's **Eval** and **Price** buttons will use.
    private var statusPill: some View {
        let ready = settings.providerKeyStates.filter(\.isReady).map(\.provider.displayName)
        let readyText = ready.isEmpty ? "No API key yet" : ready.joined(separator: " + ") + " ready"
        let tint: Color = settings.hasAPIKey ? .green : .orange

        return Label(readyText, systemImage: settings.hasAPIKey ? "checkmark.circle" : "key")
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .help(
                "Green once every key the next run needs is set — the appraiser's, and, when a batched "
                    + "run reads its manifests elsewhere, the identity provider's too. Each service keeps "
                    + "its own, in its own section below."
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

    /// Row two: which service appraises a lot.
    ///
    /// This was the **Provider** menu that sat above the credential field, and it is now two visible
    /// buttons because it is a real choice with two real answers: DeepSeek sends a gallery in batches
    /// into a manifest, Gemini reads it frame by frame, and Run Tuning's photograph controls follow
    /// whichever is armed. What it no longer does is decide *which key you can see* — that was the
    /// menu's only harmful job, and the sections below do it instead.
    private var appraiserRow: some View {
        SettingsFieldRow(label: "Appraise with") {
            Picker("Appraise with", selection: $settings.provider) {
                ForEach(ValuationProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .help(
                "Which service appraises lots. Gemini reads a gallery frame by frame and has a free "
                    + "tier; DeepSeek sends it in batches from a prepaid balance."
            )
        }
    }

    /// Row three: **who reads a lot's photographs**, which may be somebody other than the appraiser
    /// (Tier 5 of `docs/manifest-identity-plan.md`).
    ///
    /// Drawn always rather than only while it applies, because a preference an operator has read about
    /// should be findable when they go looking — but inert, and *said* to be inert, while there is no
    /// manifest to read: a manifest is read in batches, so a run needs a width in Run Tuning's **Photos /
    /// request** before the route exists at all, and until one does no second provider is asked for
    /// anything (`AppSettings.runsSplitPhotos`).
    ///
    /// Enabled on that *width* rather than on `batchesPhotographs`, and deliberately: with Gemini appraising,
    /// naming DeepSeek here is exactly what turns the batched route on, so a row disabled by the thing it is
    /// about could never be turned on.
    ///
    /// This is the row that makes the two model menus below mean different things, so its help names
    /// them: reading a carton's printed code and count off a photograph is a vision job, and pricing
    /// that code afterwards is a lookup pixels cannot improve.
    private var photoRow: some View {
        SettingsFieldRow(label: "Evaluate photos with") {
            Picker("Evaluate photos with", selection: $settings.photoProvider) {
                ForEach(PhotoProvider.allCases) { choice in
                    Text(choice.displayName(fallingBackTo: settings.provider)).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .disabled(!settings.canNamePhotoProvider)
            .help(photoHelp)
        }
    }

    /// What the photograph picker is for, in the state it is actually in.
    ///
    /// Four answers, because the setting has four states and three of them are inert for different reasons —
    /// no width to read a manifest in, a width but no manifest route on this combination, and a split that
    /// has been chosen but resolved back to the appraiser (*Same as appraiser*). Naming the row that has to
    /// change (*Photos / request*, **Appraise with**) is what makes a disabled menu forgivable; see
    /// `LotManifestScan` for the route itself.
    private var photoHelp: String {
        guard settings.canNamePhotoProvider else {
            return "Who reads a lot's photographs. Inert for now: a manifest is read in batches, so pick a "
                + "width on Run Tuning's Photos / request row for this to matter."
        }
        guard settings.batchesPhotographs else {
            return "Who reads a lot's photographs. Inert while \(settings.provider.displayName) both "
                + "appraises and reads: its own route is a gallery read frame by frame on Photos / scan. "
                + "Naming DeepSeek here reads the gallery in batches instead — the width above is what sizes "
                + "them — and prices the manifest it produces on \(settings.provider.displayName)."
        }
        guard settings.runsSplitPhotos else {
            return "Who reads the batches a run sends, which is \(settings.provider.displayName) itself "
                + "today: \(settings.activeModelID) reads each lot's photographs and prices what it read. "
                + "Naming the other provider spends a second key on the reading half — its own section's "
                + "model is the one that gets the photographs — while the prices keep coming from "
                + "\(settings.provider.displayName)."
        }
        return "\(settings.manifestProvider.displayName) \(settings.manifestModelID) reads each lot's "
            + "photographs into a manifest; \(settings.provider.displayName) \(settings.activeModelID) "
            + "prices it. Both keys are needed, and each is sent only its own half."
    }

    /// Row four: one section per provider, both always drawn.
    ///
    /// A pair rather than one field, so "which keys do I have?" is one glance and "paste the other
    /// one" is one click. The spacing is tighter than `Theme.groupSpacing` because these two read as
    /// one control with two halves.
    private var keySections: some View {
        VStack(spacing: 10) {
            ForEach(ValuationProvider.allCases) { provider in
                keySection(provider)
            }
        }
    }

    /// One provider's own section: its key, its model, and where its key comes from.
    ///
    /// The label, the placeholder and the help all come from the provider itself, so a section cannot
    /// describe the wrong service's key — and the get-a-key line is the page the About sheet sends the
    /// operator to, from the same property.
    private func keySection(_ provider: ValuationProvider) -> some View {
        let armed = settings.provider == provider
        let ready = settings.hasAPIKey(for: provider)
        // The photograph half, when it is this section's provider doing it: the chip is what stops the
        // model menu below from reading as the appraiser's model when it is in fact the reader's.
        let readsPhotographs = settings.runsSplitPhotos && settings.manifestProvider == provider

        return VStack(alignment: .leading, spacing: Theme.fieldSpacing) {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.subheadline.weight(.semibold))

                Label(
                    ready ? "key set" : "no key yet",
                    systemImage: ready ? "checkmark.circle.fill" : "key"
                )
                .chipStyle(tint: ready ? .green : .orange)

                if armed {
                    Text("appraises lots").chipStyle(tint: .accentColor)
                }

                if readsPhotographs {
                    Text("reads photographs").chipStyle(tint: .accentColor)
                }

                Spacer(minLength: 8)

                // The cost rides on the header rather than under the field: it is the one fact that
                // differs between the two sections, and a line of its own under each would make the
                // pair a scroll taller for no more information.
                Text(provider.keyCostNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            SettingsFieldRow(label: provider.keyLabel) {
                SecureField(provider.keyPlaceholder, text: apiKeyBinding(provider))
                    .help(provider.keyHelp)
            }

            SettingsFieldRow(label: "Model") {
                Picker("Model", selection: modelBinding(provider)) {
                    ForEach(provider.availableModelIDs, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .help(modelHelp(for: provider))
            }

            Link(destination: provider.keySignupURL) {
                Text("Get a key from \(provider.keySourceName) — \(provider.keySignupLabel)")
            }
            .font(.caption2)
            .lineLimit(1)
            .help("Opens \(provider.keySignupURL.absoluteString) in your browser.")
        }
        .padding(10)
        .cardStyle()
    }

    /// What one section's **Model** menu is choosing — which changes meaning when a split is on.
    ///
    /// Without a split every model in the app is the appraiser's, so the note is about modality. With
    /// one, the reading section's model is the model that *reads* — in batches, either provider — and the
    /// appraiser's is the one that *prices*: two different jobs whose best answers are not the same model,
    /// which is the whole reason the split exists.
    private func modelHelp(for provider: ValuationProvider) -> String {
        guard settings.runsSplitPhotos else {
            return "Only multimodal models are listed: a scan sends the lot's photographs."
        }
        return provider == settings.provider
            ? "The model that prices each lot from the manifest. The photographs are read by "
                + "\(settings.manifestProvider.displayName) — see Evaluate photos with above."
            : "The model that reads each lot's photographs into its manifest. The prices come back from "
                + "\(settings.provider.displayName) \(settings.activeModelID)."
    }

    /// Row five: the readings this machine has already paid for.
    ///
    /// A thorough scan buys an answer about each photograph and keeps it, so re-scanning a lot with the
    /// same model costs the reconciliation rather than the whole gallery — and that only works while the
    /// readings stay behind. Forgetting them is therefore a deliberate act with a price, which is why it
    /// is a button with the count beside it rather than housekeeping that happens on its own.
    private var readingsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.controlSpacing) {
                Label("Stored readings", systemImage: "photo.stack")
                    .font(.caption.weight(.medium))
                Text(storedLotsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer(minLength: 12)

                Button("Forget") { forgetReadings() }
                    .disabled(storedLots == 0 || isForgetting)
                    .help(
                        "Readings are what a photograph-by-photograph scan cost. Forgetting them makes "
                            + "the next scan of every lot read and pay for each photograph again."
                    )
            }

            Text(
                "What each photograph showed, kept per lot and per model. Re-scanning a lot with the same "
                    + "model reuses them, so only the reconciliation is sent. Changing model, or "
                    + "suspecting a bad read, is what this button is for."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var storedLotsText: String {
        storedLots == 0 ? "none yet" : "\(storedLots) lot(s)"
    }

    private func refreshStoredLots() async {
        storedLots = await PhotoReadingStore.shared.storedLotCount()
    }

    private func forgetReadings() {
        isForgetting = true
        Task {
            await PhotoReadingStore.shared.forgetAll()
            await refreshStoredLots()
            isForgetting = false
        }
    }

    /// Shown only when the combination is actually a problem: a key the next run needs is not set, so
    /// nothing can be appraised.
    ///
    /// It names the section that needs the key rather than the provider in the abstract — the sheet
    /// has two boxes that look alike, and "paste a DeepSeek API key" is a riddle when neither section
    /// is labelled with that sentence. When the *other* provider already has a key it says so, because
    /// switching appraisers is a one-click answer that needs no key at all.
    ///
    /// The split added a second way to be unready, and it is a different fix: a batched run whose
    /// manifest would be read by a provider with no key can be repaired either by pasting that key or by
    /// putting the **Evaluate photos with** row back on *Same as appraiser*, so the note says both. Which of
    /// the two boxes the key belongs in is not something this view works out — `missingKeyProvider`
    /// already knows.
    ///
    /// The switching hint that follows the other sentence is deliberately absent when the *reading* key is
    /// the missing one: it answers "which appraiser could run instead", and the appraiser is not what is
    /// missing.
    @ViewBuilder
    private var warning: some View {
        if let missing = settings.missingKeyProvider {
            let standby = settings.providerKeyStates
                .first { $0.provider != settings.provider && $0.isReady }
            let tail = standby.map {
                " \($0.provider.displayName) already has one, so Appraise with can switch to it now."
            } ?? ""

            if settings.runsSplitPhotos && missing == settings.manifestProvider {
                warningLabel(
                    "Nothing can be appraised yet: this run would read each lot's photographs on "
                        + "\(missing.displayName) and price them on \(settings.provider.displayName), and "
                        + "the \(missing.displayName) section above has no key. Paste one there, or set "
                        + "Evaluate photos with to Same as appraiser to read the photographs on "
                        + "\(settings.provider.displayName) itself."
                )
            } else {
                warningLabel(
                    "Nothing can be appraised yet: the \(missing.displayName) section above has "
                        + "no key." + tail
                )
            }
        }
    }

    /// One warning line's chrome, shared by the two sentences above so a note about a missing key looks
    /// the same whichever half of a split it is about.
    private func warningLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footnotes: some View {
        Text(
            "Edits apply as you type — there is no Cancel. Keys stay in this Mac's UserDefaults, are sent "
                + "only to the provider they belong to, and switching between them is lossless."
                + splitFootnote
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The sentence a split run adds to the footnote above: which key sees what.
    ///
    /// Empty when there is no split, because the footnote already says the lossless thing and a
    /// paragraph about a setting that is off is how a footnote becomes unread. When there *is* one it
    /// has to be said plainly — two keys, one run, and each provider is handed only the half it is being
    /// paid for: the reader its photographs, the appraiser the manifest it prices. Which provider is which
    /// is read off the setting rather than assumed, so the sentence is the same one in both directions.
    private var splitFootnote: String {
        guard settings.runsSplitPhotos else { return "" }
        return " With Evaluate photos with set to \(settings.manifestProvider.displayName), the "
            + "\(settings.manifestProvider.displayName) key is sent each lot's photographs and the "
            + "\(settings.provider.displayName) key the manifest they were read into, plus the listing "
            + "text — neither key sees the other's half, and both are needed before a scan can run."
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(
                "Appraising with \(settings.provider.displayName) · \(settings.activeModelID)"
                    + "\(settings.identityRouteSummary)"
            )
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

    /// The credential field for one *named* provider.
    ///
    /// One binding per provider rather than one that follows `settings.provider`: both sections are on
    /// screen together, so each writes its own key and neither can overwrite the other — which is the
    /// bug the old single field invited.
    private func apiKeyBinding(_ provider: ValuationProvider) -> Binding<String> {
        Binding(
            get: { settings.apiKey(for: provider) },
            set: { settings.setAPIKey($0, for: provider) }
        )
    }

    /// The model field for one named provider, read through `modelID(for:)` so an empty stored value
    /// shows the provider's default instead of leaving the picker blank.
    private func modelBinding(_ provider: ValuationProvider) -> Binding<String> {
        Binding(
            get: { settings.modelID(for: provider) },
            set: { settings.setModelID($0, for: provider) }
        )
    }
}

#Preview("Settings") {
    SiteSettingsSheet(settings: AppSettings())
}
