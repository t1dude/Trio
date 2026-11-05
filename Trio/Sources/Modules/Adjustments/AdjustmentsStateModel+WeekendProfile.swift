import Foundation

extension Adjustments.StateModel {
    /// Starts Weekend Profile: records the real start time -- both locally, so the run can be
    /// anchored in History > Adjustments and its real duration computed when it's stopped, and on
    /// Nightscout, as an "Exercise" event (Trio's own Override eventType) with an indefinite
    /// ~30-day duration. Reusing "Exercise" means Loop Follow (and any Nightscout-based viewer that
    /// already understands Trio Overrides) picks this up automatically, with the profile's name as
    /// the note; `weekendProfileEnteredBy` is a marker distinct from a real Override's "Trio" so it
    /// can still be told apart downstream and shown with its own color.
    func startWeekendProfile() {
        let start = Date()
        WeekendProfileStore.activeStartDate = start
        let nightscoutDuration = WeekendProfileStore.nightscoutStartDurationMinutes(start: start)
        debug(.treatments, "Profile started (in app): \(WeekendProfileStore.logDescription)")
        Task {
            let event = NightscoutExercise(
                duration: nightscoutDuration,
                eventType: .nsExercise,
                createdAt: start,
                enteredBy: weekendProfileEnteredBy,
                notes: WeekendProfileStore.name
            )
            await nightscoutManager.uploadWeekendProfileEvent(event, replacingPrevious: false)
        }
    }

    /// Stops Weekend Profile: records the completed run locally (so it's anchored in History >
    /// Adjustments with its real start/end, like an Override or Temp Target) and corrects the
    /// Nightscout entry `startWeekendProfile` posted from its indefinite duration to the real
    /// elapsed one, so Loop Follow (and any other Nightscout-based viewer) shows the real end time
    /// instead of ~30 days out.
    func stopWeekendProfile() {
        let end = Date()
        let name = WeekendProfileStore.name
        guard let start = WeekendProfileStore.activeStartDate else {
            // Nothing to close out -- e.g. Weekend Profile was already active before this version's
            // start-tracking existed. Nothing was recorded to correct on Nightscout either.
            debug(.treatments, "Profile stopped (in app) but its start time was missing -- nothing to record or correct")
            return
        }
        WeekendProfileStore.activeStartDate = nil
        debug(.treatments, "Profile stopped (in app): ran \(start) - \(end)")
        WeekendProfileStore.recordCompletedRun(name: name, start: start, end: end)

        let elapsedMinutes = max(1, Int(end.timeIntervalSince(start) / 60))
        Task {
            let event = NightscoutExercise(
                duration: elapsedMinutes,
                eventType: .nsExercise,
                createdAt: start,
                enteredBy: weekendProfileEnteredBy,
                notes: name
            )
            await nightscoutManager.uploadWeekendProfileEvent(event, replacingPrevious: true)
        }
    }

    /// The real basal schedule, exposed only so `WeekendProfileSection` can prefill its own draft
    /// the first time the editor is opened (see `WeekendProfileStore.isConfigured`). Never written
    /// to -- Weekend Profile's schedule lives entirely in `WeekendProfileStore`.
    var currentBasalProfileForWeekendPrefill: [BasalProfileEntry] { provider.currentBasalProfile }

    /// The real ISF schedule -- same prefill purpose as `currentBasalProfileForWeekendPrefill`.
    var currentInsulinSensitivitiesForWeekendPrefill: InsulinSensitivities { provider.currentInsulinSensitivities }

    /// Basal rate values Weekend Profile's schedule editor is allowed to offer. Prefers the
    /// connected pump's real supported increments (same source the real Basal Profile Editor
    /// uses) so a Weekend schedule can't drift from what the pump can actually approximate; falls
    /// back to the same generous default the real editor uses when no pump is connected. Either
    /// way, capped at the user's configured Max Basal safety setting -- that's an independent
    /// ceiling from what the pump can mechanically do, and Weekend Profile's substituted schedule
    /// feeds `currentBasal`/`maxDailyBasal` in the dosing algorithm (see `OpenAPS.createProfiles()`
    /// and `TempBasalFunctions.getMaxSafeBasalRate()`), so keeping the raw schedule values
    /// themselves within Max Basal avoids skewing that math even though delivered temp basals were
    /// always separately capped there regardless.
    var weekendBasalRateValues: [Decimal] {
        // `??` only substitutes on nil -- `pumpManager?.supportedBasalRates` can come back as a
        // real, non-nil EMPTY array (a pump reporting no supported rates yet, or every rate
        // filtered out), which used to sail straight through as `values = []` and defeat the
        // "never empty" guard below before it ever ran. Treat nil and empty the same way here.
        let supported = provider?.supportedBasalRates
        let values = (supported?.isEmpty == false ? supported : nil)
            ?? stride(from: 5.0, to: 1001.0, by: 5.0).map { (Decimal($0)) / 100 }
        let maxBasal = provider?.maxBasalRate ?? 2
        let capped = values.filter { $0 <= maxBasal }
        // Never return an empty list -- if Max Basal is set below every available increment,
        // offering the uncapped list is safer than leaving the picker with no options at all.
        return capped.isEmpty ? values : capped
    }

    /// Persists a full Weekend Profile draft in one shot -- the only place that writes
    /// `WeekendProfileStore`'s configurable fields, called from `WeekendProfileSection`'s Save
    /// button. Also posts a Nightscout Note so a schedule change is visible on the chart, and marks
    /// the profile as configured so the next time the editor opens it loads these saved values
    /// instead of prefilling from real settings again.
    func saveWeekendProfile(
        name: String,
        target: Decimal,
        smbMinutes: Decimal,
        uamMinutes: Decimal,
        basalProfile: [BasalProfileEntry],
        insulinSensitivities: InsulinSensitivities
    ) {
        WeekendProfileStore.name = name
        WeekendProfileStore.target = target
        WeekendProfileStore.smbMinutes = smbMinutes
        WeekendProfileStore.uamMinutes = uamMinutes
        WeekendProfileStore.basalProfile = basalProfile
        WeekendProfileStore.insulinSensitivities = insulinSensitivities
        let wasConfigured = WeekendProfileStore.isConfigured
        WeekendProfileStore.isConfigured = true
        Foundation.NotificationCenter.default.post(name: .didUpdateWeekendProfileConfiguration, object: nil)

        Task {
            await nightscoutManager.uploadNoteTreatment(
                note: wasConfigured ? "\(name) updated" : "\(name) configured"
            )
        }
    }
}

/// Distinguishes a Weekend Profile run from a real Override on Nightscout even though both share
/// the "Exercise" eventType and Trio's usual `enteredBy` of "Trio".
private let weekendProfileEnteredBy = "Trio Weekend Profile"
