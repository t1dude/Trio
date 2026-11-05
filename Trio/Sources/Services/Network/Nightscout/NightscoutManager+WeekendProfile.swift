extension BaseNightscoutManager {
    /// Posts a Weekend Profile run to Nightscout as an "Exercise" event -- the same eventType
    /// Trio's own Overrides use (see `OverrideStorage`/`NightscoutExercise`) -- so any
    /// Nightscout-based viewer that already understands Overrides (Loop Follow included) shows it
    /// automatically, with the profile's name as the note. `event.enteredBy` is expected to carry a
    /// marker distinct from a real Override's so it can still be told apart downstream.
    ///
    /// Weekend Profile has no fixed duration -- it's started and stopped by hand. It's started with
    /// an indefinite ~30-day duration (matching the exact convention Trio's own indefinite Overrides
    /// use, see `OverrideStorage.getOverrideRunsNotYetUploadedToNightscout`), then this is called
    /// again when it's stopped with `replacingPrevious: true` and the real elapsed duration: this
    /// deletes the original entry (matched by its `created_at`, which is unchanged between the two
    /// calls) and reposts it with the corrected duration -- the same delete+repost trick Trio's own
    /// Override system uses (`OverrideStorage.checkIfShouldDeleteNightscoutOverrideEntry`) to force
    /// Nightscout-based viewers to re-render instead of keeping the stale indefinite duration.
    func uploadWeekendProfileEvent(_ event: NightscoutExercise, replacingPrevious: Bool) async {
        guard let nightscout = nightscoutAPI, isUploadEnabled else { return }

        do {
            if replacingPrevious, let createdAtString = event.created_at as? String {
                // Best-effort: if the original indefinite-duration entry never made it up (e.g. the
                // device was offline when Weekend Profile started), there's nothing to delete -- the
                // repost below still leaves Nightscout with one correct entry either way.
                try? await nightscout.deleteNightscoutOverride(withCreatedAt: createdAtString)
            }
            try await nightscout.uploadOverrides([event])
            debug(.nightscout, "Weekend Profile Nightscout event uploaded")
        } catch {
            debug(.nightscout, "Weekend Profile Nightscout upload failed: \(error)")
        }
    }
}
