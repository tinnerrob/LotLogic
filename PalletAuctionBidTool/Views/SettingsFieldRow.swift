//
//  SettingsFieldRow.swift
//  PalletAuctionBidTool
//
//  One labelled setting: the row both settings surfaces are built from.
//

import SwiftUI

/// A settings row: a caption on the left, the control filling whatever is left of the width.
///
/// Shared by the control panel and the settings modal so a field looks and behaves the same in both,
/// which matters because the two surfaces hold the *same* settings — the panel's Run Tuning and the
/// modal's provider and login fields.
///
/// `hidesControlLabel` is *on* by default — a text field's own string is a prompt rather than a
/// caption, and a picker's repeats the field label beside it — but a `Stepper` carries its current
/// value in its label view, so hiding it there left the run-tuning steppers showing bare +/- buttons
/// with no number between them. Callers that pass a stepper turn it off.
struct SettingsFieldRow<Content: View>: View {

    let label: String
    var hidesControlLabel: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Theme.labelWidth, alignment: .leading)

            content
                .modifier(OptionalLabelHiding(isHidden: hidesControlLabel))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Applies `.labelsHidden()` only when asked: SwiftUI has no conditional form of it, and
/// `SettingsFieldRow` needs the labels *visible* for steppers, whose label carries the current value.
private struct OptionalLabelHiding: ViewModifier {

    let isHidden: Bool

    func body(content: Content) -> some View {
        if isHidden {
            content.labelsHidden()
        } else {
            content
        }
    }
}
