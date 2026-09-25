//
//  LotPageSheetView.swift
//  PalletAuctionBidTool
//
//  One lot's own page, read in the window instead of in the operator's browser.
//

import AppKit
import SwiftUI
import WebKit

/// One lot page, asked for from a row.
///
/// `Identifiable` because the table presents it with `.sheet(item:)`, which makes the sheet's content
/// a function of the thing that was asked for. The identity is the address rather than the lot number:
/// a lot re-listed under a new number shares one page, and what is being identified here is the page,
/// not the row that asked for it.
struct LotPageRequest: Identifiable, Equatable {

    /// The lot's own page, as the listing exposed it.
    let url: URL
    /// The lot number, for the sheet's title. Carried rather than read back off the address: the
    /// header is the only thing tying the page to the row it was opened from.
    let lotNumber: String

    var id: String { url.absoluteString }

    init(url: URL, lotNumber: String) {
        self.url = url
        self.lotNumber = lotNumber
    }

    /// The request a row makes, or `nil` for a lot whose card exposed no address — the same test that
    /// decides whether the row draws an **Open** button at all.
    ///
    /// Main-actor bound because `LotItem` is: the row already has the lot in hand, so there is nothing
    /// to hop for.
    @MainActor
    init?(lot: LotItem) {
        guard let url = lot.detailURL else { return nil }
        self.init(url: url, lotNumber: lot.lotNumber)
    }
}

/// A lot's own page as a sheet: the photographs, the full description and the bid history **Price**
/// reads, for the operator to look at, with nothing spent to see them.
///
/// **Why a sheet rather than the operator's browser.** Safari is a context switch: the table being
/// read is left behind, and a page asked for from row 142 opens into whichever window happened to be
/// in front. The page belongs to the row that asked for it, so it is drawn over the table and leaves
/// with a keystroke — the same shape as the window's own **Page** panel.
///
/// **Why not that panel.** `BrowserPanelView` reparents the scraper's live `WKWebView`, a captcha
/// hand-off being the whole reason it exists: pointing *that* at a lot page would take the automation
/// off the results page it is working on. This sheet builds a second web view instead, on the same
/// default `WKWebsiteDataStore` the scraper uses (see `AuctionScraperService`), so the page arrives
/// signed in with the session the run just earned while the automation's page never moves. A challenge
/// answered in here is answered for the next run too, because both web views read one cookie jar.
struct LotPageSheetView: View {

    let request: LotPageRequest

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    /// The session this sheet is reading through. Made here rather than in the view's `init` because
    /// the handle is cheap and has no side effects, while the web view it fills in is neither: a view
    /// may be initialised several times over one presentation and only the first `@State` value is
    /// kept, so the load belongs to `LotPageSurface`, which SwiftUI calls exactly once.
    @State private var page = LotPageHandle()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack(alignment: .top) {
                // Size comes from `WebPageSheetSize` and the drag: the area starts at the size this
                // sheet has always opened at, pins the smallest worth reading, and takes whatever the
                // operator drags the window out to.
                LotPageSurface(url: request.url, page: page)
                    .frame(
                        minWidth: WebPageSheetSize.minimum.width,
                        idealWidth: WebPageSheetSize.ideal.width,
                        maxWidth: .infinity,
                        minHeight: WebPageSheetSize.minimum.height,
                        idealHeight: WebPageSheetSize.ideal.height,
                        maxHeight: .infinity
                    )
                if let failure = page.failureText {
                    failureBanner(failure)
                }
            }
        }
        // The page is read, not glanced at: a gallery, a long description and a bid history in a sheet
        // the size of the table's own default are worth being able to grow.
        .resizableSheetWindow()
    }

    /// The same header the page panel carries, for the same reason: what is on screen, where it came
    /// from, and the way out. The one addition is **Open in Browser**, which is where the row's
    /// **Open** button used to go — handing the page to Safari is still sometimes what is wanted
    /// (printing, a site that behaves badly in a web view), so it stays one click away rather than
    /// being the only thing a click can do.
    private var header: some View {
        HStack(spacing: 10) {
            Label("Lot \(request.lotNumber)", systemImage: "safari")
                .microCaps(false)

            Text(page.address ?? request.url.absoluteString)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(page.address ?? request.url.absoluteString)

            if page.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer(minLength: 12)

            Text("Opening this page costs nothing — nothing is sent to the valuation provider.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Reload") { page.reload() }
                .help("Load the page again — after signing in, or after the site stopped answering.")

            Button {
                openURL(page.currentURL ?? request.url)
            } label: {
                Label("Open in Browser", systemImage: "arrow.up.forward.square")
            }
            .help("Hand this page to Safari instead.")

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.rowInset + 4)
        .padding(.vertical, Theme.headerPadding)
        .background(.bar)
    }

    /// What a web view shows when a load fails is an empty window, so the reason is drawn over it: an
    /// expired session and a host that is not answering are the two failures this sheet actually
    /// sees, and neither is visible from the page itself.
    private func failureBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Reload") { page.reload() }
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.rowInset + 4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }
}

/// The sheet's web view and what it is doing.
///
/// Split in two on purpose. This half is built with the sheet's `@State` — no web view, no network,
/// nothing that has to happen exactly once — and `LotPageSurface` hands over the web view the first
/// time SwiftUI builds the view hierarchy. The header reads the load state from here, which is why
/// the address, the spinner and a failed load are `@Observable` rather than being pushed at the view
/// by a delegate it would have to keep alive itself (`WKNavigationDelegate` is held weakly).
@MainActor
@Observable
final class LotPageHandle: NSObject, WKNavigationDelegate {

    /// The page's live address, which changes as links inside it are followed.
    private(set) var address: String?
    private(set) var isLoading = true
    /// Set when the page itself would not load. See `failureBanner`.
    private(set) var failureText: String?

    private var webView: WKWebView?

    /// The address on screen, for **Open in Browser**.
    var currentURL: URL? { webView?.url }

    /// Takes the web view `LotPageSurface` built and starts the load.
    fileprivate func adopt(_ webView: WKWebView, url: URL) {
        self.webView = webView
        webView.navigationDelegate = self
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func reload() {
        failureText = nil
        isLoading = true
        webView?.reload()
    }

    /// A web view that shares the scraper's session, for the reason given on `LotPageSheetView`.
    ///
    /// The desktop-Safari agent is the service's own constant: several liquidation hosts serve a
    /// reduced or blocked layout to the stock `WKWebView` agent string, and a lot page that arrived
    /// without its gallery would make this modal a worse answer than the browser it replaced.
    fileprivate static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = AuctionScraperService.desktopUserAgent
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        failureText = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        address = webView.url?.absoluteString ?? address
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        address = webView.url?.absoluteString ?? address
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(with: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failed(with: error)
    }

    private func failed(with error: Error) {
        let error = error as NSError
        // A cancelled load is what a redirect, or a request the page itself superseded, looks like
        // from here — not a page that refused to arrive, and not something worth a banner.
        guard error.code != NSURLErrorCancelled else { return }
        isLoading = false
        failureText = "This page would not load: \(error.localizedDescription)"
    }
}

/// Hands the sheet its own web view.
///
/// Deliberately *not* `BrowserPanelView`'s reparenting surface: that one adopts the scraper's live
/// page, where this one builds a page of its own and lets it go when the sheet closes. Nothing is
/// shared but the cookie jar, and that is the point.
private struct LotPageSurface: NSViewRepresentable {

    let url: URL
    let page: LotPageHandle

    func makeNSView(context: Context) -> WKWebView {
        let webView = LotPageHandle.makeWebView()
        page.adopt(webView, url: url)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

#Preview {
    LotPageSheetView(
        request: LotPageRequest(url: URL(string: "https://example.com/lot/142")!, lotNumber: "142")
    )
}
