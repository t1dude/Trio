import SwiftUI
import Swinject

extension QuickBolus {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private var bolusFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumIntegerDigits = 2
            formatter.maximumFractionDigits = 2
            return formatter
        }

        var body: some View {
            Form {
                Section(
                    header: Text("Quick Bolus"),
                    footer: Text("Set two preset bolus amounts available via long-press on the + button.")
                ) {
                    HStack {
                        Text("Preset 1")
                        Spacer()
                        TextFieldWithToolBar(
                            text: $state.quickBolusAmount1,
                            placeholder: "0",
                            maxLength: 5,
                            numberFormatter: bolusFormatter,
                            unitsText: String(localized: "U", comment: "Insulin units")
                        )
                    }
                    HStack {
                        Text("Preset 2")
                        Spacer()
                        TextFieldWithToolBar(
                            text: $state.quickBolusAmount2,
                            placeholder: "0",
                            maxLength: 5,
                            numberFormatter: bolusFormatter,
                            unitsText: String(localized: "U", comment: "Insulin units")
                        )
                    }
                }
                .listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Quick Bolus")
            .navigationBarTitleDisplayMode(.automatic)
            .onAppear(perform: configureView)
        }
    }
}
