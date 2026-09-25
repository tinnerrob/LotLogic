//
//  BrowserPanelView.swift
//  PalletAuctionBidTool
//
//  The one place the hidden WKWebView is made visible: captcha / MFA hand-off.
//

import AppKit
import SwiftUI
import WebKit

/// Sheet that reparents the scraper's live `WKWebView` into the window.
///
/// The scraper normally works off-screen. Some hosts interpose a captcha or an MFA prompt that
/// only a human can clear, so the very same page — cookies, session and all — is presented here.
/// Nothing about the automation changes: the injected script keeps running while the sheet is up,
/// and because the service reuses one web view, solving a challenge by hand once is enough for
/// every later run.
struct BrowserPanelView: View {

    let webView: WKWebView

    @Environment(\.dismiss) private var dismiss
    @State private var address = "about:blank"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Same size story as `LotPageSheetView`: the live page starts where it always has, and the
            // operator drags the sheet out to whatever a challenge screen needs.
            PageSurfaceView(webView: webView)
                .frame(
                    minWidth: WebPageSheetSize.minimum.width,
                    idealWidth: WebPageSheetSize.ideal.width,
                    maxWidth: .infinity,
                    minHeight: WebPageSheetSize.minimum.height,
                    idealHeight: WebPageSheetSize.ideal.height,
                    maxHeight: .infinity
                )
        }
        .resizableSheetWindow()
        .task {
            while !Task.isCancelled {
                let current = webView.url?.absoluteString
                address = (current?.isEmpty == false ? current : nil) ?? "about:blank"
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Live auction page", systemImage: "safari")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(address)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(address)

            Spacer(minLength: 12)

            Text("Solve any captcha here, then press Done and run again.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Reload") { webView.reload() }
                .help("Reload the current page.")

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Hands an existing `WKWebView` to SwiftUI.
///
/// A view can only have one superview, and this web view outlives the sheet, so it is detached
/// before being adopted. That keeps a single live page (and its running automation) across
/// repeated presentations.
private struct PageSurfaceView: NSViewRepresentable {

    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView.removeFromSuperview()
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

#Preview {
    BrowserPanelView(webView: WKWebView())
}
