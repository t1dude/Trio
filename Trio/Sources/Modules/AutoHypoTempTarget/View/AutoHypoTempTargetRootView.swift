import SwiftUI
import Swinject

extension AutoHypoTempTarget {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()
        @State private var shouldDisplayHint: Bool = false
        @State var hintDetent = PresentationDetent.large
        @State var selectedVerboseHint: AnyView?
        @State var hintLabel: String?
        @State private var decimalPlaceholder: Decimal = 0.0
        @State private var booleanPlaceholder: Bool = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private let bgThresholdValues: [Decimal] = stride(from: 60, through: 120, by: 5).map { Decimal($0) }

        var body: some View {
            Form {
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.enabled,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Automatic Hypo Temp Target")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Enable Automatic Hypo Temp Target"),
                    miniHint: String(localized: "Automatically activates a temp target when glucose drops below a set level."),
                    verboseHint: VStack(alignment: .leading, spacing: 10) {
                        Text("Default: OFF").bold()
                        Text(
                            "When enabled, Trio will automatically activate a predefined temp target when your glucose falls at or below the threshold you set. This raises the algorithm's glucose target and reduces insulin delivery to help counteract a developing low."
                        )
                        Text(
                            "The temp target only activates if no other temp target is already running. Once triggered, it will not re-trigger until its full duration has elapsed, even if you cancel it manually."
                        )
                        Text(
                            "Create temp target presets in Adjustments before enabling this feature."
                        )
                    }
                )
                .listRowBackground(Color.chart)

                if state.enabled {
                    Section(header: Text("Temp Target Preset")) {
                        if state.presets.isEmpty {
                            Text("No temp target presets found. Create one in the Adjustments section first.")
                                .foregroundColor(.secondary)
                                .font(.footnote)
                        } else {
                            Picker(String(localized: "Preset"), selection: $state.presetName) {
                                ForEach(state.presets, id: \.name) { preset in
                                    if let name = preset.name, let target = preset.target {
                                        let targetDecimal = target.decimalValue
                                        let targetDisplay = state.units == .mgdL
                                            ? "\(Int(targetDecimal)) \(state.units.rawValue)"
                                            : "\(targetDecimal.formattedAsMmolL) \(state.units.rawValue)"
                                        let duration = Int(preset.duration?.decimalValue ?? 0)
                                        Text("\(name) – \(targetDisplay), \(duration) min").tag(name)
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.chart)

                    Section(
                        header: Text("BG Trigger Threshold"),
                        footer: Text("The temp target activates when glucose is at or below this level.")
                    ) {
                        Picker(
                            state.units == .mgdL
                                ? String(localized: "Threshold (mg/dL)")
                                : String(localized: "Threshold (mmol/L)"),
                            selection: $state.bgThreshold
                        ) {
                            ForEach(bgThresholdValues, id: \.self) { value in
                                Text(
                                    state.units == .mgdL
                                        ? "\(Int(value)) \(state.units.rawValue)"
                                        : "\(value.formattedAsMmolL) \(state.units.rawValue)"
                                ).tag(value)
                            }
                        }
                    }
                    .listRowBackground(Color.chart)
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle(String(localized: "Auto Hypo Temp Target"))
            .navigationBarTitleDisplayMode(.automatic)
            .sheet(isPresented: $shouldDisplayHint) {
                SettingInputHintView(
                    hintDetent: $hintDetent,
                    shouldDisplayHint: $shouldDisplayHint,
                    hintLabel: hintLabel ?? "",
                    hintText: selectedVerboseHint ?? AnyView(EmptyView()),
                    sheetTitle: String(localized: "Help", comment: "Help sheet title")
                )
            }
        }
    }
}
