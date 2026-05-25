import Foundation
import SwiftUI
import WidgetKit

struct LiveActivityGlucoseForecastView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var additionalState: LiveActivityAttributes.ContentAdditionalState

    private var displayValue: String {
        guard additionalState.eventualBG > 0 else { return "--" }
        let isMgdL = context.state.unit == "mg/dL"
        if isMgdL {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return formatter.string(from: additionalState.eventualBG as NSDecimalNumber) ?? "--"
        } else {
            return additionalState.eventualBG.formattedAsMmolL
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(displayValue)
                .fontWeight(.bold)
                .font(.title3)
                .foregroundStyle(context.isStale ? .secondary : .primary)
                .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

            Text("Forecast")
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}
