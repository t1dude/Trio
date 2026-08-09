import CoreData
import SwiftUI
import Swinject

extension NightscoutConfig {
    struct RootView: BaseView {
        let resolver: Resolver
        let displayClose: Bool
        @StateObject var state = StateModel()
        @State var hintDetent = PresentationDetent.large
        @State private var hintPayload: HintPayload?
        @State private var decimalPlaceholder: Decimal = 0.0
        @State private var booleanPlaceholder: Bool = false
        @State var backfillAlert: Alert?
        @State var isBackfillAlertPresented = false
        @State var treatmentsBackfillAlert: Alert?
        @State var isTreatmentsBackfillAlertPresented = false

        private struct HintPayload: Identifiable {
            let id = UUID()
            let label: String
            let content: AnyView
        }

        private var shouldDisplayHintBinding: Binding<Bool> {
            Binding(
                get: { hintPayload != nil },
                set: { newValue in if !newValue { hintPayload = nil } }
            )
        }

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            ZStack {
                List {
                    Section(
                        header: Text("Nightscout Integration"),
                        content: {
                            NavigationLink(destination: NightscoutConnectView(state: state), label: {
                                HStack {
                                    Text("Connect")
                                    ZStack {
                                        if state.isConnectedToNS {
                                            Image(systemName: "network")
                                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption2)
                                                .offset(x: 9, y: 6)
                                        } else {
                                            Image(systemName: "network.slash")
                                        }
                                    }
                                }
                            })
                            NavigationLink("Upload", destination: NightscoutUploadView(state: state))
                            NavigationLink("Fetch", destination: NightscoutFetchView(state: state))
                        }
                    ).listRowBackground(Color.chart)

                    Section(
                        content:
                        {
                            VStack {
                                Button {
                                    Task {
                                        await state.backfillGlucose()
                                        if !state.message.isEmpty && state.message.hasPrefix("Error:") {
                                            DispatchQueue.main.async {
                                                backfillAlert = Alert(
                                                    title: Text("Backfill Failed"),
                                                    message: Text(state.message),
                                                    dismissButton: .default(Text("OK"))
                                                )
                                                isBackfillAlertPresented = true
                                            }
                                        }
                                    }
                                } label: {
                                    Text("Backfill Glucose")
                                        .font(.title3) }
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .buttonStyle(.bordered)
                                    .disabled(state.url.isEmpty || state.connecting || state.backfilling)

                                HStack(alignment: .center) {
                                    Text(
                                        "Backfill missing glucose data from Nightscout."
                                    )
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .lineLimit(nil)
                                    Spacer()
                                    Button(
                                        action: {
                                            hintPayload = HintPayload(
                                                label: String(localized: "Backfill Glucose from Nightscout"),
                                                content: AnyView(
                                                    Text(
                                                        "This will backfill 24 hours of glucose data from your connected Nightscout URL to Trio"
                                                    )
                                                )
                                            )
                                        },
                                        label: {
                                            HStack {
                                                Image(systemName: "questionmark.circle")
                                            }
                                        }
                                    ).buttonStyle(BorderlessButtonStyle())
                                        .alert(isPresented: $isBackfillAlertPresented) {
                                            backfillAlert ?? Alert(title: Text("Unknown Error"))
                                        }
                                }.padding(.top)
                            }.padding(.vertical)
                        }
                    ).listRowBackground(Color.chart)

                    Section(
                        content:
                        {
                            VStack {
                                HStack {
                                    Text("Backfill")
                                    TextField("", value: $state.backfillTreatmentsDays, format: .number)
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 50)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: state.backfillTreatmentsDays) {
                                            state.backfillTreatmentsDays = min(max(state.backfillTreatmentsDays, 1), 90)
                                        }
                                    Text("day(s)")
                                    Spacer()
                                    Stepper("", value: $state.backfillTreatmentsDays, in: 1 ... 90)
                                        .labelsHidden()
                                }

                                Text(
                                    "This creates synthetic Total Daily Dose (TDD) history so Dynamic ISF's 7-day data requirement can be satisfied immediately. Intended to be run once, typically right after a fresh install."
                                )
                                .font(.footnote)
                                .foregroundColor(.orange)
                                .lineLimit(nil)
                                .padding(.top, 4)

                                Button {
                                    Task {
                                        await state.backfillTreatments()
                                        if !state.treatmentsBackfillMessage.isEmpty {
                                            let isError = state.treatmentsBackfillMessage.hasPrefix("Error:")
                                            DispatchQueue.main.async {
                                                treatmentsBackfillAlert = Alert(
                                                    title: Text(isError ? "Backfill Failed" : "Backfill Complete"),
                                                    message: Text(state.treatmentsBackfillMessage),
                                                    dismissButton: .default(Text("OK"))
                                                )
                                                isTreatmentsBackfillAlertPresented = true
                                            }
                                        }
                                    }
                                } label: {
                                    if state.backfillingTreatments {
                                        HStack {
                                            ProgressView()
                                            Text(
                                                state.backfillTreatmentsProgress.isEmpty
                                                    ? String(localized: "Backfilling…")
                                                    : state.backfillTreatmentsProgress
                                            )
                                        }
                                    } else {
                                        Text("Backfill Treatments")
                                            .font(.title3)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .buttonStyle(.bordered)
                                .disabled(
                                    state.url.isEmpty || state.connecting || state.backfilling || state
                                        .backfillingTreatments
                                )
                                .padding(.top)

                                HStack(alignment: .center) {
                                    Text(
                                        "Backfill carbs, boluses, temp basals, and glucose from Nightscout."
                                    )
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .lineLimit(nil)
                                    Spacer()
                                    Button(
                                        action: {
                                            hintPayload = HintPayload(
                                                label: String(localized: "Backfill Treatments from Nightscout"),
                                                content: AnyView(
                                                    Text(
                                                        "This fetches carb entries, boluses, temp basals, and glucose readings from your connected Nightscout URL for the selected number of days, imports them into Trio, and computes Total Daily Dose history from them so Dynamic ISF can activate right away instead of waiting a week.\n\nRequires a paired pump. Imported doses may show as active insulin-on-board immediately after backfilling, since they reflect real insulin you already took. Safe to rerun; it will not duplicate already-imported data. If Nightscout has no bolus/temp-basal history for a given day, that day's TDD will only reflect scheduled basal."
                                                    )
                                                )
                                            )
                                        },
                                        label: {
                                            HStack {
                                                Image(systemName: "questionmark.circle")
                                            }
                                        }
                                    ).buttonStyle(BorderlessButtonStyle())
                                        .alert(isPresented: $isTreatmentsBackfillAlertPresented) {
                                            treatmentsBackfillAlert ?? Alert(title: Text("Unknown Error"))
                                        }
                                }.padding(.top)
                            }.padding(.vertical)
                        }
                    ).listRowBackground(Color.chart)
                }
                .listSectionSpacing(sectionSpacing)
            }
            .sheet(item: $hintPayload) { payload in
                SettingInputHintView(
                    hintDetent: $hintDetent,
                    shouldDisplayHint: shouldDisplayHintBinding,
                    hintLabel: payload.label,
                    hintText: payload.content,
                    sheetTitle: String(localized: "Help", comment: "Help sheet title")
                )
            }
            .navigationBarTitle("Nightscout")
            .navigationBarTitleDisplayMode(.automatic)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
        }
    }
}
