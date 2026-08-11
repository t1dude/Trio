import SwiftUI

struct QuickPickTreatmentsView: View {
    let state: WatchState
    let bolusSuggestions: [Decimal]
    let carbSuggestions: [Decimal]
    /// Callback fired after the amounts are written into `state`; `didSelectBolus` tells the caller
    /// whether to route into the crown-confirm bolus flow or send the carbs-only request directly.
    var onEnact: (_ didSelectBolus: Bool) -> Void

    @State private var selectedCarbAmount: Decimal?
    @State private var selectedBolusAmount: Decimal?

    private var hasSuggestions: Bool {
        !bolusSuggestions.isEmpty || !carbSuggestions.isEmpty
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 8) {
                if hasSuggestions {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if !carbSuggestions.isEmpty {
                                suggestionSection(
                                    title: String(localized: "Carbs", comment: "Watch Quick-Pick carb suggestions section title"),
                                    amounts: carbSuggestions,
                                    selection: $selectedCarbAmount,
                                    color: .orange,
                                    label: carbLabel
                                )
                            }

                            if !bolusSuggestions.isEmpty {
                                suggestionSection(
                                    title: String(localized: "Bolus", comment: "Watch Quick-Pick bolus suggestions section title"),
                                    amounts: bolusSuggestions,
                                    selection: $selectedBolusAmount,
                                    color: .insulin,
                                    label: bolusLabel
                                )
                            }
                        }
                        .padding(.horizontal)
                    }

                    Button(String(localized: "Enact", comment: "Watch Quick-Pick enact button")) {
                        enact()
                    }
                    .buttonStyle(.bordered)
                    .tint(.loopGreen)
                    .disabled(selectedCarbAmount == nil && selectedBolusAmount == nil)
                    .padding(.bottom, 4)
                } else {
                    Spacer()
                    Text("No Recent Treatments")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(
                        "Log a few carbs or boluses on your phone and Quick-Pick will suggest amounts here.",
                        comment: "Watch Quick-Pick empty-state explanation"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    Spacer()
                }
            }
            .navigationTitle(String(localized: "Quick Pick", comment: "Watch Quick-Pick screen title"))
        }
    }

    private func suggestionSection(
        title: String,
        amounts: [Decimal],
        selection: Binding<Decimal?>,
        color: Color,
        label: (Decimal) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 6) {
                ForEach(amounts, id: \.self) { amount in
                    let isSelected = selection.wrappedValue == amount
                    Button(label(amount)) {
                        selection.wrappedValue = isSelected ? nil : amount
                    }
                    .buttonStyle(.bordered)
                    .tint(isSelected ? color : .gray)
                    .font(.caption2)
                }
            }
        }
    }

    private func carbLabel(_ amount: Decimal) -> String {
        "\(NSDecimalNumber(decimal: amount).intValue)\(String(localized: "g", comment: "gram of carbs"))"
    }

    private func bolusLabel(_ amount: Decimal) -> String {
        String(format: "%.2f\(String(localized: "U", comment: "Insulin unit"))", NSDecimalNumber(decimal: amount).doubleValue)
    }

    private func enact() {
        let didSelectBolus = selectedBolusAmount != nil

        if let carbAmount = selectedCarbAmount {
            let cappedCarbs = min(carbAmount, state.maxCarbs)
            state.carbsAmount = NSDecimalNumber(decimal: cappedCarbs).intValue
        } else {
            // Avoid carrying over a stale carbsAmount from a previous meal-bolus-combo flow.
            state.carbsAmount = 0
        }

        if let bolusAmount = selectedBolusAmount {
            let cappedBolus = min(bolusAmount, state.maxBolus)
            state.bolusAmount = NSDecimalNumber(decimal: cappedBolus).doubleValue
        }

        onEnact(didSelectBolus)
    }
}

/// A minimal wrapping HStack-like layout so pills of varying widths flow onto multiple lines
/// instead of being clipped or forced to shrink on the watch's narrow screen.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let maxWidth = proposal.width ?? bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
