import CoreData
import SwiftUI

extension AutoHypoTempTarget {
    final class StateModel: BaseStateModel<Provider> {
        @Published var units: GlucoseUnits = .mgdL
        @Published var enabled: Bool = false
        @Published var presetName: String = ""
        @Published var bgThreshold: Decimal = 80
        @Published var presets: [TempTargetStored] = []

        override func subscribe() {
            units = settingsManager.settings.units
            Task { await loadPresets() }

            subscribeSetting(\.autoHypoTempTargetEnabled, on: $enabled) { enabled = $0 }
            subscribeSetting(\.autoHypoTempTargetPresetName, on: $presetName) { presetName = $0 }
            subscribeSetting(\.autoHypoTempTargetBGThreshold, on: $bgThreshold) { bgThreshold = $0 }
        }

        @MainActor
        private func loadPresets() async {
            do {
                let ids = try await provider.tempTargetsStorage.fetchForTempTargetPresets()
                let viewContext = CoreDataStack.shared.persistentContainer.viewContext
                presets = try ids.compactMap { try viewContext.existingObject(with: $0) as? TempTargetStored }
            } catch {
                debug(.default, "AutoHypoTempTarget: failed to load presets: \(error)")
            }
        }
    }
}

extension AutoHypoTempTarget.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
