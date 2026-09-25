//
//  ResizableSheetWindow.swift
//  PalletAuctionBidTool
//
//  Lets the sheet showing a web page be dragged to the size the operator wants.
//

import AppKit
import SwiftUI

/// The size a sheet showing a web page opens at, and the smallest page area worth reading.
///
/// One decision in one place because two sheets are built from it — a lot's own page behind the row's
/// **Open** button, and the window's live **Page** panel — and they should not drift apart. These are
/// the *page area*: the header sits outside them, so the sheet is one header taller than the height
/// here.
enum WebPageSheetSize {

    /// Below this the page is being clipped rather than read, which is why the content pins it.
    static let minimum = CGSize(width: 940, height: 620)

    /// What the page area asks for, and therefore the size the sheet opens at.
    static let ideal = CGSize(width: 1180, height: 760)
}

extension View {

    /// Lets the sheet this view fills be resized by dragging its edges.
    ///
    /// A SwiftUI sheet on macOS arrives as a title-bar-less **docModal** window — measured rather
    /// than assumed: a plain `.sheet` comes up with `styleMask` `65` (`titled | docModal`) and
    /// **without** `.resizable`, so its edges are not drag handles. Beyond that mask, SwiftUI owns the
    /// window's minimum and maximum and keeps rewriting them from the content's own frames, so
    /// nothing the content does can widen the window it sits in either; adding `.resizable` to the
    /// content *is* the way to give the operator control, and it is the one window property SwiftUI
    /// does not touch. The content above is then built with `maxWidth: .infinity` so it takes whatever
    /// room the drag leaves it.
    ///
    /// The alternative — hosting an `NSWindow` sheet by hand — buys the same dragging at the price of
    /// the `.sheet(item:)` identity and dismissal two views already rely on, and of reimplementing
    /// the **Done** button and the escape key.
    ///
    /// A window a drag can shrink past the content's own minimum clips that content rather than
    /// bouncing back: SwiftUI's rewrite of `minSize` wins, so the floor is the content's, not the
    /// window's. Dragging back out restores it, and the page area is the only thing that clips.
    func resizableSheetWindow() -> some View {
        background(SheetWindowResizer())
    }
}

/// Adds the missing bit to the window it lands in, and does nothing else.
///
/// Deliberately a plain `NSView` rather than an `NSViewRepresentable` that sets the mask in
/// `makeNSView`: at that point the view is not in the sheet's window yet, while
/// `viewDidMoveToWindow()` is AppKit saying that it now is. (`updateNSView` would not do either — the
/// sheet's content never changes, so SwiftUI never calls it.)
private struct SheetWindowResizer: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView { SheetWindowResizerView() }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SheetWindowResizerView: NSView {

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.styleMask.insert(.resizable)
    }
}
