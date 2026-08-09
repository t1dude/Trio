import CoreData
import Foundation
import LoopKitUI
import Swinject

/// Summary of a completed (or partially completed) treatments backfill run.
struct TreatmentsBackfillSummary {
    let carbsImported: Int
    let bolusesImported: Int
    let tempBasalsImported: Int
    let glucoseImported: Int
    let daysSynthesized: Int
    let daysSkipped: [Date]
    /// Days that were fetched successfully but had zero bolus/temp-basal treatments found in Nightscout.
    /// A high count here means Nightscout itself doesn't have insulin dosing history that far back
    /// (common if AID looping/uploading only started recently), not a bug in the import — those days'
    /// synthesized TDD will be flat (scheduled-basal only) since there's nothing else to add.
    let daysWithNoTreatmentDataInNightscout: Int
}

protocol TreatmentsBackfillService {
    /// Fetches `days` of carb/bolus/temp-basal history from Nightscout (ending the day before today),
    /// imports it into Core Data, and synthesizes dense `TDDStored` rows for each imported day so that
    /// Dynamic ISF's 7-day data requirement can be satisfied without waiting for real loop cycles to accrue.
    func backfill(days: Int, progress: @escaping (String) -> Void) async throws -> TreatmentsBackfillSummary
}

enum TreatmentsBackfillError: LocalizedError {
    case noPumpConfigured

    var errorDescription: String? {
        switch self {
        case .noPumpConfigured:
            return "Pair a pump before backfilling treatments."
        }
    }
}

final class BaseTreatmentsBackfillService: TreatmentsBackfillService, Injectable {
    @Injected() private var nightscoutManager: NightscoutManager!
    @Injected() private var tddStorage: TDDStorage!
    @Injected() private var apsManager: APSManager!
    @Injected() private var storage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!

    private let makeContext: () -> NSManagedObjectContext

    init(resolver: Resolver, contextProvider: (() -> NSManagedObjectContext)? = nil) {
        makeContext = contextProvider ?? { CoreDataStack.shared.newTaskContext() }
        injectServices(resolver)
    }

    /// One calendar day's worth of fetched Nightscout data, kept in memory so TDD synthesis
    /// doesn't need to round-trip through Core Data.
    private struct DayFetch {
        let dayStart: Date
        let dayEnd: Date
        let carbs: [CarbsEntry]
        let insulinTreatments: [NightscoutTreatment]
        let tempBasalTreatments: [NightscoutTreatment]
    }

    func backfill(days: Int, progress: @escaping (String) -> Void) async throws -> TreatmentsBackfillSummary {
        guard let pumpManager = apsManager.pumpManager else {
            throw TreatmentsBackfillError.noPumpConfigured
        }

        let clampedDays = min(max(days, 1), 90)
        let basalProfile = await storage
            .retrieveAsync(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ??
            [BasalProfileEntry](from: OpenAPS.defaults(for: OpenAPS.Settings.basalProfile)) ??
            []

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var carbsImported = 0
        var bolusesImported = 0
        var tempBasalsImported = 0
        var glucoseImported = 0
        var daysSynthesized = 0
        var daysSkipped: [Date] = []
        var daysWithNoTreatmentDataInNightscout = 0

        // Oldest day first: dayIndex = clampedDays means the oldest day, dayIndex = 1 means yesterday.
        for dayIndex in stride(from: clampedDays, through: 1, by: -1) {
            guard let dayStart = calendar.date(byAdding: .day, value: -dayIndex, to: today),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else { continue }

            let dayNumber = clampedDays - dayIndex + 1
            progress("Fetching day \(dayNumber) of \(clampedDays)…")

            do {
                let dayFetch = try await fetchDay(dayStart: dayStart, dayEnd: dayEnd)

                let carbCount = try await persistCarbs(dayFetch)
                let (bolusCount, tempBasalCount) = try await persistPumpEvents(dayFetch)

                carbsImported += carbCount
                bolusesImported += bolusCount
                tempBasalsImported += tempBasalCount
                if dayFetch.insulinTreatments.isEmpty, dayFetch.tempBasalTreatments.isEmpty {
                    daysWithNoTreatmentDataInNightscout += 1
                }

                progress("Synthesizing TDD for \(dayFormatter.string(from: dayStart))…")
                try await synthesizeTDD(
                    for: dayFetch,
                    pumpManager: pumpManager,
                    basalProfile: basalProfile
                )
                daysSynthesized += 1
            } catch {
                warning(.nightscout, "Treatments backfill failed for day \(dayStart): \(error)")
                daysSkipped.append(dayStart)
                progress("Day \(dayNumber) of \(clampedDays) failed, continuing…")
            }

            // Glucose is independent of TDD synthesis, so a glucose-fetch failure shouldn't skip the
            // rest of this day's (already-succeeded) carb/insulin/temp-basal import above.
            do {
                let glucose = try await nightscoutManager.fetchGlucoseForBackfill(sinceDate: dayStart, untilDate: dayEnd)
                if glucose.isNotEmpty {
                    try await glucoseStorage.storeGlucose(glucose)
                    glucoseImported += glucose.count
                }
            } catch {
                warning(.nightscout, "Glucose backfill failed for day \(dayStart): \(error)")
            }
        }

        return TreatmentsBackfillSummary(
            carbsImported: carbsImported,
            bolusesImported: bolusesImported,
            tempBasalsImported: tempBasalsImported,
            glucoseImported: glucoseImported,
            daysSynthesized: daysSynthesized,
            daysSkipped: daysSkipped,
            daysWithNoTreatmentDataInNightscout: daysWithNoTreatmentDataInNightscout
        )
    }

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    // MARK: - Fetch

    private func fetchDay(dayStart: Date, dayEnd: Date) async throws -> DayFetch {
        async let carbs = nightscoutManager.fetchCarbsForBackfill(sinceDate: dayStart, untilDate: dayEnd)
        async let insulin = nightscoutManager.fetchInsulinForBackfill(sinceDate: dayStart, untilDate: dayEnd)
        async let tempBasals = nightscoutManager.fetchTempBasalsForBackfill(sinceDate: dayStart, untilDate: dayEnd)

        return try await DayFetch(
            dayStart: dayStart,
            dayEnd: dayEnd,
            carbs: carbs,
            insulinTreatments: insulin,
            tempBasalTreatments: tempBasals
        )
    }

    // MARK: - Persist carbs

    private func persistCarbs(_ dayFetch: DayFetch) async throws -> Int {
        guard dayFetch.carbs.isNotEmpty else { return 0 }

        let context = makeContext()
        context.name = "TreatmentsBackfillService.persistCarbs"

        return try await context.perform {
            let fetchRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(
                format: "date >= %@ AND date < %@",
                dayFetch.dayStart as NSDate,
                dayFetch.dayEnd as NSDate
            )
            let existing = try context.fetch(fetchRequest)
            let existingTimestamps = Set(existing.compactMap(\.date))

            var insertedCount = 0
            for entry in dayFetch.carbs {
                let entryDate = entry.actualDate ?? entry.createdAt
                guard !existingTimestamps.contains(entryDate) else { continue }

                let newItem = CarbEntryStored(context: context)
                newItem.date = entryDate
                newItem.carbs = Double(truncating: NSDecimalNumber(decimal: entry.carbs))
                newItem.fat = Double(truncating: NSDecimalNumber(decimal: entry.fat ?? 0))
                newItem.protein = Double(truncating: NSDecimalNumber(decimal: entry.protein ?? 0))
                newItem.note = entry.note
                newItem.id = UUID()
                newItem.isFPU = false
                newItem.isUploadedToNS = true
                newItem.isUploadedToHealth = true
                newItem.isUploadedToTidepool = true
                insertedCount += 1
            }

            guard context.hasChanges else { return insertedCount }
            try context.save()
            return insertedCount
        }
    }

    // MARK: - Persist boluses & temp basals

    private func persistPumpEvents(_ dayFetch: DayFetch) async throws -> (boluses: Int, tempBasals: Int) {
        guard dayFetch.insulinTreatments.isNotEmpty || dayFetch.tempBasalTreatments.isNotEmpty else { return (0, 0) }

        let context = makeContext()
        context.name = "TreatmentsBackfillService.persistPumpEvents"

        return try await context.perform {
            let candidateIds = (dayFetch.insulinTreatments + dayFetch.tempBasalTreatments)
                .map { Self.stablePumpEventID(for: $0) }

            let idFetchRequest: NSFetchRequest<PumpEventStored> = PumpEventStored.fetchRequest()
            idFetchRequest.predicate = NSPredicate(format: "id IN %@", candidateIds)
            let existingIDs = Set(try context.fetch(idFetchRequest).compactMap(\.id))

            // Nightscout treatments here don't reliably carry the app's own `enteredBy` tag (this server
            // doesn't return matches for that filter at all when combined with a day-bounded date range —
            // see the comment in NightscoutAPI.fetchInsulin), so a treatment already tracked locally
            // (from real device usage, or a prior backfill run whose id happened to differ) could otherwise
            // be re-imported as a second row and double-count insulin. Cross-check by exact timestamp too.
            let dayFetchRequest: NSFetchRequest<PumpEventStored> = PumpEventStored.fetchRequest()
            dayFetchRequest.predicate = NSPredicate(
                format: "timestamp >= %@ AND timestamp < %@",
                dayFetch.dayStart as NSDate,
                dayFetch.dayEnd as NSDate
            )
            let existingTimestamps = Set(try context.fetch(dayFetchRequest).compactMap(\.timestamp))

            var bolusCount = 0
            for treatment in dayFetch.insulinTreatments {
                guard let insulin = treatment.insulin, let createdAt = treatment.createdAt else { continue }
                let stableID = Self.stablePumpEventID(for: treatment)
                guard !existingIDs.contains(stableID), !existingTimestamps.contains(createdAt) else { continue }

                let isExternal = treatment.eventType == .isExternal
                let isSMB = treatment.eventType == .smb

                let pumpEvent = PumpEventStored(context: context)
                pumpEvent.id = stableID
                pumpEvent.timestamp = createdAt
                // Genuinely NS-tagged "External Insulin"/"SMB" treatments keep their real type; every other
                // insulin-bearing eventType (Bolus/Correction Bolus/Meal Bolus/…) is a normal pump delivery.
                // isSMB/isExternal (not `type`) are what the History and Statistics views key off of to label
                // a bolus "Manual" vs "SMB" vs "External" — both must be set correctly, not just `type`.
                if isExternal {
                    pumpEvent.type = PumpEventStored.EventType.isExternal.rawValue
                } else if isSMB {
                    pumpEvent.type = PumpEventStored.EventType.smb.rawValue
                } else {
                    pumpEvent.type = PumpEventStored.EventType.bolus.rawValue
                }
                pumpEvent.note = "Imported from Nightscout"
                pumpEvent.isUploadedToNS = true
                pumpEvent.isUploadedToHealth = true
                pumpEvent.isUploadedToTidepool = true

                let bolus = BolusStored(context: context)
                bolus.amount = NSDecimalNumber(decimal: insulin)
                bolus.isExternal = isExternal
                bolus.isSMB = isSMB
                bolus.pumpEvent = pumpEvent

                bolusCount += 1
            }

            var tempBasalCount = 0
            for treatment in dayFetch.tempBasalTreatments {
                guard let createdAt = treatment.createdAt,
                      let rate = treatment.absolute ?? treatment.rate,
                      let durationMin = treatment.duration
                else { continue }
                let stableID = Self.stablePumpEventID(for: treatment)
                guard !existingIDs.contains(stableID), !existingTimestamps.contains(createdAt) else { continue }

                let pumpEvent = PumpEventStored(context: context)
                pumpEvent.id = stableID
                pumpEvent.timestamp = createdAt
                // Native `.tempBasal` (not the NS-wire `.nsTempBasal`), so this row is treated identically
                // to a pump-sourced temp basal by getPumpHistory()/IOB/TDD calculations going forward.
                pumpEvent.type = PumpEventStored.EventType.tempBasal.rawValue
                pumpEvent.note = "Imported from Nightscout"
                pumpEvent.isUploadedToNS = true
                pumpEvent.isUploadedToHealth = true
                pumpEvent.isUploadedToTidepool = true

                let tempBasal = TempBasalStored(context: context)
                tempBasal.rate = NSDecimalNumber(decimal: rate)
                tempBasal.duration = Int16(clamping: durationMin)
                tempBasal.tempType = TempType.absolute.rawValue
                tempBasal.pumpEvent = pumpEvent

                tempBasalCount += 1
            }

            guard context.hasChanges else { return (bolusCount, tempBasalCount) }
            try context.save()
            return (bolusCount, tempBasalCount)
        }
    }

    /// Nightscout treatments carry a client-generated `id` (used elsewhere in this app for delete-by-id
    /// calls), which is stable across repeated fetches of the same document. Falls back to a deterministic
    /// id derived from timestamp+eventType for the rare treatment that lacks one, so dedup still degrades
    /// gracefully instead of crashing or duplicating on every rerun.
    private static let dayAnchorPrefix = "tdd-backfill-day-anchor-"

    private static func stablePumpEventID(for treatment: NightscoutTreatment) -> String {
        if let id = treatment.id, id.isNotEmpty {
            return "ns-\(id)"
        }
        let timestamp = treatment.createdAt?.timeIntervalSince1970 ?? 0
        return "ns-\(treatment.eventType.rawValue)-\(timestamp)"
    }

    // MARK: - TDD synthesis

    private func synthesizeTDD(
        for dayFetch: DayFetch,
        pumpManager: any PumpManagerUI,
        basalProfile: [BasalProfileEntry]
    ) async throws {
        var pumpHistory: [PumpHistoryEvent] = []

        for treatment in dayFetch.insulinTreatments {
            guard let insulin = treatment.insulin, let createdAt = treatment.createdAt else { continue }
            pumpHistory.append(PumpHistoryEvent(
                id: Self.stablePumpEventID(for: treatment),
                type: .bolus,
                timestamp: createdAt,
                amount: insulin
            ))
        }

        for treatment in dayFetch.tempBasalTreatments {
            guard let createdAt = treatment.createdAt,
                  let rate = treatment.absolute ?? treatment.rate,
                  let durationMin = treatment.duration
            else { continue }
            pumpHistory.append(PumpHistoryEvent(
                id: Self.stablePumpEventID(for: treatment),
                type: .tempBasal,
                timestamp: createdAt,
                amount: rate,
                duration: durationMin
            ))
        }

        // `calculateTDD`'s internal `findBasalGaps` anchors its day-boundary math to the *first* temp-basal
        // event's timestamp; when it finds none at all, it falls back to `Calendar.current.startOfDay(for:
        // Date())` — i.e. *today*, not this historical day. On a day with zero fetched temp basal treatments
        // (e.g. no oref deviations that day) that fallback would silently compute scheduled-basal insulin
        // against today's elapsed hours instead of this historical day. A single 1-minute, zero-rate
        // placeholder anchors the day correctly (contributes ~0 insulin itself) without touching that
        // private, unmodified function.
        if pumpHistory.first(where: { $0.type == .tempBasal }) == nil {
            pumpHistory.append(PumpHistoryEvent(
                id: "\(Self.dayAnchorPrefix)\(dayFetch.dayStart.timeIntervalSince1970)",
                type: .tempBasal,
                timestamp: dayFetch.dayStart,
                amount: 0,
                duration: 1
            ))
        }

        // calculateTDD sorts internally assuming a descending feed (mirrors pumpHistoryStorage.getPumpHistory()).
        pumpHistory.sort { $0.timestamp > $1.timestamp }

        let tddResult = try await tddStorage.calculateTDD(
            pumpManager: pumpManager,
            pumpHistory: pumpHistory,
            basalProfile: basalProfile
        )

        try await writeSyntheticTDDRows(for: dayFetch.dayStart, dayEnd: dayFetch.dayEnd, result: tddResult)
    }

    /// Writes ~288 rows (5-minute spacing) for the day so `hasSufficientTDD()`'s density check
    /// (≥75% of 288 rows/day over the trailing 7 days) is satisfied by real loop-cadence-shaped data,
    /// without touching that gate's logic at all. Deletes any previously-synthesized rows for this
    /// exact day first so rerunning the backfill can't double-count in the weighted-average feed that
    /// powers Dynamic ISF's live formula.
    private func writeSyntheticTDDRows(for dayStart: Date, dayEnd: Date, result: TDDResult) async throws {
        let context = makeContext()
        context.name = "TreatmentsBackfillService.writeSyntheticTDDRows"

        try await context.perform {
            let fetchRequest: NSFetchRequest<TDDStored> = TDDStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(
                format: "date >= %@ AND date < %@ AND isBackfilled == YES",
                dayStart as NSDate,
                dayEnd as NSDate
            )
            for stale in try context.fetch(fetchRequest) {
                context.delete(stale)
            }

            let total = NSDecimalNumber(decimal: result.total)
            let bolus = NSDecimalNumber(decimal: result.bolus)
            let tempBasal = NSDecimalNumber(decimal: result.tempBasal)
            let scheduledBasal = NSDecimalNumber(decimal: result.scheduledBasal)
            let weightedAverage = result.weightedAverage.map { NSDecimalNumber(decimal: $0) }

            var timestamp = dayStart
            while timestamp < dayEnd {
                let row = TDDStored(context: context)
                row.id = UUID()
                row.date = timestamp
                row.total = total
                row.bolus = bolus
                row.tempBasal = tempBasal
                row.scheduledBasal = scheduledBasal
                row.weightedAverage = weightedAverage
                row.isBackfilled = true
                timestamp = timestamp.addingTimeInterval(300)
            }

            guard context.hasChanges else { return }
            try context.save()
        }
    }
}
