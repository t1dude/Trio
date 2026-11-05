import Foundation

extension Adjustments.Provider {
    /// The real (non-Weekend) basal schedule -- used only to prefill Weekend Profile's own
    /// schedule the first time someone opens the editor, so they start from a sensible copy of
    /// their actual settings instead of an empty list. Same lookup `BasalProfileEditorProvider`
    /// uses for the real editor.
    var currentBasalProfile: [BasalProfileEntry] {
        storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)
            ?? [BasalProfileEntry](from: OpenAPS.defaults(for: OpenAPS.Settings.basalProfile))
            ?? []
    }

    /// The real (non-Weekend) ISF schedule -- same prefill purpose as `currentBasalProfile`.
    /// Same lookup `ISFEditorProvider` uses for the real editor.
    var currentInsulinSensitivities: InsulinSensitivities {
        storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
            ?? InsulinSensitivities(from: OpenAPS.defaults(for: OpenAPS.Settings.insulinSensitivities))
            ?? InsulinSensitivities(units: .mgdL, userPreferredUnits: .mgdL, sensitivities: [])
    }

    /// The connected pump's real supported basal rate increments -- same lookup
    /// `BasalProfileEditorProvider` uses for the real editor. `nil` when no pump is connected.
    /// Used to bound Weekend Profile's basal schedule editor so it can't offer rates the pump
    /// can't actually be asked to approximate.
    var supportedBasalRates: [Decimal]? {
        // Drops 0 even where the pump accepts it: oref rejects a schedule containing a 0 rate,
        // same reasoning as the real editor.
        deviceManager.pumpManager?.supportedBasalRates
            .filter { $0 > 0 }
            .map { Decimal($0) }
    }

    /// The user's configured Max Basal safety setting -- an independent ceiling from what the
    /// pump can mechanically do, so Weekend Profile's editor clamps to this too, not just to
    /// `supportedBasalRates`. Same lookup/fallback chain `AlgorithmAdvancedSettingsProvider`
    /// uses for the real Max Basal setting.
    var maxBasalRate: Decimal {
        (storage.retrieve(OpenAPS.Settings.settings, as: PumpSettings.self)
            ?? PumpSettings(from: OpenAPS.defaults(for: OpenAPS.Settings.settings))
            ?? PumpSettings(insulinActionCurve: 10.0, maxBolus: 10, maxBasal: 2)).maxBasal
    }
}
