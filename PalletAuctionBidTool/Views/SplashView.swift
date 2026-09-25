//
//  SplashView.swift
//  PalletAuctionBidTool
//
//  The launch splash: the app's own artwork on a page of its own, over the window it is about to
//  hand back.
//

import SwiftUI

/// **The launch splash** — `SplashArt` centred on a plain page, gone in a moment.
///
/// The window behind it is a dense operator tool, so this is the one surface with nothing to do: it
/// is brand, not progress. Nothing is read, scraped or appraised while it is up (see
/// `Theme.splashDwell`), which is why it is timed rather than tied to work — and why a click takes
/// it away at once for an operator who has seen it before.
///
/// It is drawn over `ContentView` rather than as a sheet or a second window: nothing about the
/// launch is modal — the panel underneath is live the whole time — and an overlay is what makes the
/// splash dissolve into the window instead of sliding off it.
///
/// The art carries the product's own name and tagline, so no text is drawn here; the two lines are
/// the same words as `Theme.appName` and `Theme.tagline`, and `SplashArt` swaps to its dark
/// appearance variant (type re-inked light) against `Theme.splashPageDark`.
struct SplashView: View {

    /// Whether the splash is up. The splash owns its own exit — both the timer and the click write
    /// here — so the one place that animates it away is `dismiss()`.
    @Binding var isPresented: Bool

    /// Which page the art is drawn on. The art itself follows the appearance from the asset
    /// catalogue; only the fill has to be told.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            page

            Image("SplashArt")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: Theme.splashArtWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole splash is the dismiss target, not just the art: there is nothing else on the page
        // to click, and an operator reaching for the window should never miss.
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        // One label for the two lines of art, so the splash is also readable to VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Theme.appName). \(Theme.tagline)")
        .task {
            try? await Task.sleep(for: .seconds(Theme.splashDwell))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    /// The splash's own paper: near-white in a light appearance, deep green in a dark one.
    private var page: some View {
        (colorScheme == .dark ? Theme.splashPageDark : Theme.splashPageLight)
            .ignoresSafeArea()
    }

    /// Fades the splash out. The transition is applied where the splash is presented (`ContentView`).
    private func dismiss() {
        withAnimation(.easeOut(duration: Theme.splashFade)) {
            isPresented = false
        }
    }
}

#Preview("Splash — light") {
    SplashView(isPresented: .constant(true))
        .frame(width: 900, height: 560)
        .preferredColorScheme(.light)
}

#Preview("Splash — dark") {
    SplashView(isPresented: .constant(true))
        .frame(width: 900, height: 560)
        .preferredColorScheme(.dark)
}
