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
    /// Start of each 24-hour window whose import failed.
    let daysSkipped: [Date]
    /// Windows that were fetched successfully but had no bolus/temp-basal data, neither in Nightscout
    /// nor locally. A high count means Nightscout itself doesn't have insulin dosing history that far
    /// back (common if uploading only started recently), not a bug in the import — those windows'
    /// synthesized TDD is scheduled basal only, since there's nothing else to add.
    let daysWithNoTreatmentDataInNightscout: Int
}

protocol TreatmentsBackfillService {
    /// Fetches `days` × 24 hours of carb/bolus/temp-basal/glucose history from Nightscout, ending at the
    /// moment of the call, imports it into Core Data, and synthesizes dense `TDDStored` rows for each
    /// imported 24-hour window so Dynamic ISF's 7-day data requirement can be satisfied without waiting
    /// for real loop cycles to accrue.
    func backfill(days: Int, progress: @escaping (String) -> Void) async throws -> TreatmentsBackfillSummary
}

enum TreatmentsBackfillError: LocalizedError {
    case noPumpConfigured

    var errorDescription: String? {
        switch self {
        case .noPumpConfigured:
            return String(localized: "Pair a pump before backfilling treatments.")
        }
    }
}

final class BaseTreatmentsBackfillService: TreatmentsBackfillService, Injectable {
    @Injected() private var nightscoutManager: NightscoutManager!
    @Injected() private var tddStorage: TDDStorage!
    @Injected() private var apsManager: APSManager!
    @Injected() private var storage: FileStorage!

    private let makeContext: () -> NSManagedObjectContext

    init(resolver: Resolver, contextProvider: (() -> NSManagedObjectContext)? = nil) {
        makeContext = contextProvider ?? { CoreDataStack.shared.newTaskContext() }
        injectServices(resolver)
    }

    static let maxDays = 90
    static let windowLength: TimeInterval = 24 * 60 * 60
    /// Temp basals and suspensions started this long before a window can still be running inside it.
    static let lookback: TimeInterval = 6 * 60 * 60
    static let tddRowSpacing: TimeInterval = 5 * 60
    /// CGM algorithmic floor, as `GlucoseStorage` clamps it
    static let minimumGlucose = 39
    static let importNote = "Imported from Nightscout"
    private static let windowAnchorPrefix = "tdd-backfill-window-anchor-"

    func backfill(days: Int, progress: @escaping (String) -> Void) async throws -> TreatmentsBackfillSummary {
        guard let pumpManager = apsManager.pumpManager else {
            throw TreatmentsBackfillError.noPumpConfigured
        }

        let basalProfile = await storage
            .retrieveAsync(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ??
            [BasalProfileEntry](from: OpenAPS.defaults(for: OpenAPS.Settings.basalProfile)) ??
            []

        // One fixed "now" for the whole run, so the newest window ends exactly when backfill was started
        let windows = Self.windows(endingAt: Date(), days: days)

        var carbsImported = 0
        var bolusesImported = 0
        var tempBasalsImported = 0
        var glucoseImported = 0
        var daysSynthesized = 0
        var daysSkipped: [Date] = []
        var daysWithNoTreatmentData = 0

        // Oldest first: each window's TDD reads temp basals the previous window imported.
        for (index, window) in windows.enumerated() {
            let label = "\(index + 1) of \(windows.count)"
            progress(String(localized: "Fetching day \(label)…"))

            do {
                let documents = try await nightscoutManager.fetchTreatmentsForBackfill(
                    sinceDate: window.start.addingTimeInterval(-Self.lookback),
                    untilDate: window.end
                )
                let batch = NightscoutBackfill.normalize(documents) { date in
                    findBasalRateForOffset(for: Self.minutesOfDay(date), in: basalProfile)
                }
                let imported = try await persist(batch, in: window)
                carbsImported += imported.carbs
                bolusesImported += imported.boluses
                tempBasalsImported += imported.tempBasals

                progress(String(localized: "Calculating TDD for day \(label)…"))
                let history = try await localPumpHistory(
                    from: window.start.addingTimeInterval(-Self.lookback),
                    to: window.end
                )
                let windowHistory = Self.pumpHistory(for: window, from: history, basalProfile: basalProfile)
                if !windowHistory
                    .contains(where: { $0.type == .bolus || ($0.type == .tempBasal && $0.isScheduledBasal != true) })
                {
                    daysWithNoTreatmentData += 1
                }

                let tddResult = try await tddStorage.calculateTDD(
                    pumpManager: pumpManager,
                    pumpHistory: windowHistory,
                    basalProfile: basalProfile,
                    now: window.end
                )
                try await writeSyntheticTDDRows(for: window, result: tddResult)
                daysSynthesized += 1
            } catch {
                warning(.nightscout, "Treatments backfill failed for \(window)", error: error)
                daysSkipped.append(window.start)
                progress(String(localized: "Day \(label) failed, continuing…"))
            }

            // Glucose is independent of TDD synthesis, so a glucose failure doesn't skip the window above.
            do {
                let documents = try await nightscoutManager.fetchGlucoseForBackfill(
                    sinceDate: window.start,
                    untilDate: window.end
                )
                glucoseImported += try await persistGlucose(NightscoutBackfill.glucose(from: documents), in: window)
            } catch {
                warning(.nightscout, "Glucose backfill failed for \(window)", error: error)
            }
        }

        return TreatmentsBackfillSummary(
            carbsImported: carbsImported,
            bolusesImported: bolusesImported,
            tempBasalsImported: tempBasalsImported,
            glucoseImported: glucoseImported,
            daysSynthesized: daysSynthesized,
            daysSkipped: daysSkipped,
            daysWithNoTreatmentDataInNightscout: daysWithNoTreatmentData
        )
    }

    // MARK: - Windows

    /// Consecutive 24-hour windows, oldest first, the newest ending at `now`.
    ///
    /// Rolling windows rather than calendar days: the newest data is the most valuable (it feeds IOB,
    /// COB and the 2-hour TDD average right away), and each window matches what a real loop cycle
    /// stores — the TDD of the 24 hours before it.
    static func windows(endingAt now: Date, days: Int) -> [DateInterval] {
        let count = min(max(days, 1), maxDays)
        return (0 ..< count).reversed().map { offset in
            let end = now.addingTimeInterval(-Double(offset) * windowLength)
            return DateInterval(start: end.addingTimeInterval(-windowLength), end: end)
        }
    }

    private static func minutesOfDay(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    // MARK: - Persist treatments

    private struct ImportCounts {
        var boluses = 0
        var tempBasals = 0
        var carbs = 0
    }

    /// Imports a window's treatments, skipping any already stored locally — from real pump use, or this
    /// same Nightscout data imported by an earlier window or run.
    ///
    /// Temp basals and suspensions from the lookback are imported too, so a temp running into the
    /// oldest window is known; boluses and carbs only count inside the window.
    private func persist(_ batch: NightscoutBackfill.Batch, in window: DateInterval) async throws -> ImportCounts {
        let lookbackStart = window.start.addingTimeInterval(-Self.lookback)
        let boluses = batch.boluses.filter { $0.date >= window.start && $0.date < window.end }
        let carbs = batch.carbs.filter { $0.date >= window.start && $0.date < window.end }
        let tempBasals = batch.tempBasals.filter { $0.start >= lookbackStart && $0.start < window.end }
        let suspensions = batch.suspensions.filter { $0.date >= lookbackStart && $0.date < window.end }

        let context = makeContext()
        context.name = "TreatmentsBackfillService.persist"

        return try await context.perform {
            var counts = ImportCounts()
            let margin: TimeInterval = 120

            let pumpRequest: NSFetchRequest<PumpEventStored> = PumpEventStored.fetchRequest()
            pumpRequest.predicate = NSPredicate(
                format: "timestamp >= %@ AND timestamp < %@",
                lookbackStart.addingTimeInterval(-margin) as NSDate,
                window.end.addingTimeInterval(margin) as NSDate
            )
            pumpRequest.relationshipKeyPathsForPrefetching = ["bolus", "tempBasal"]
            var existing = try context.fetch(pumpRequest).compactMap(LocalEvent.init)

            for bolus in boluses {
                let id = "ns-\(bolus.id)"
                guard !existing.contains(where: { $0.isDuplicate(ofBolus: bolus, id: id) }) else { continue }

                let pumpEvent = Self.makePumpEvent(id: id, type: .bolus, timestamp: bolus.date, in: context)
                let stored = BolusStored(context: context)
                stored.amount = NSDecimalNumber(decimal: bolus.amount)
                stored.programmedAmount = NSDecimalNumber(decimal: bolus.amount)
                // History, statistics and the NS upload mapping read the kind from these flags;
                // the event type stays "Bolus", which is all getPumpHistory() feeds to IOB and TDD.
                stored.isSMB = bolus.kind == .smb
                stored.isExternal = bolus.kind == .external
                stored.pumpEvent = pumpEvent

                existing.append(LocalEvent(id: id, kind: .bolus, date: bolus.date, amount: bolus.amount))
                counts.boluses += 1
            }

            for tempBasal in tempBasals {
                let id = "ns-\(tempBasal.id)"
                guard !existing.contains(where: { $0.isDuplicate(ofTempBasal: tempBasal, id: id) }) else { continue }

                let pumpEvent = Self.makePumpEvent(id: id, type: .tempBasal, timestamp: tempBasal.start, in: context)
                let stored = TempBasalStored(context: context)
                stored.rate = NSDecimalNumber(decimal: tempBasal.rate)
                stored.duration = Int16(clamping: Int(tempBasal.durationMinutes.rounded()))
                stored.tempType = TempType.absolute.rawValue
                stored.startDate = tempBasal.start
                stored.endDate = tempBasal.end
                stored.isScheduledBasal = false
                stored.pumpEvent = pumpEvent

                existing.append(LocalEvent(id: id, kind: .tempBasal, date: tempBasal.start, amount: tempBasal.rate))
                if tempBasal.start >= window.start { counts.tempBasals += 1 }
            }

            for suspension in suspensions {
                let id = "ns-\(suspension.id)"
                let kind: LocalEvent.Kind = suspension.isSuspend ? .suspend : .resume
                guard !existing.contains(where: {
                    $0.id == id || ($0.kind == kind && abs($0.date.timeIntervalSince(suspension.date)) < 30)
                }) else { continue }

                _ = Self.makePumpEvent(
                    id: id,
                    type: suspension.isSuspend ? .pumpSuspend : .pumpResume,
                    timestamp: suspension.date,
                    in: context
                )
                existing.append(LocalEvent(id: id, kind: kind, date: suspension.date, amount: nil))
            }

            if carbs.isNotEmpty {
                counts.carbs = try Self.persistCarbs(carbs, in: window, context: context)
            }

            guard context.hasChanges else { return counts }
            try context.save()
            return counts
        }
    }

    private static func makePumpEvent(
        id: String,
        type: PumpEventStored.EventType,
        timestamp: Date,
        in context: NSManagedObjectContext
    ) -> PumpEventStored {
        let pumpEvent = PumpEventStored(context: context)
        pumpEvent.id = id
        pumpEvent.syncIdentifier = id
        // final: never purged as a stale pending pump report
        pumpEvent.isMutable = false
        pumpEvent.timestamp = timestamp
        pumpEvent.type = type.rawValue
        pumpEvent.note = importNote
        // already in Nightscout, and must not be written to Apple Health or Tidepool as new doses
        pumpEvent.isUploadedToNS = true
        pumpEvent.isUploadedToHealth = true
        pumpEvent.isUploadedToTidepool = true
        return pumpEvent
    }

    /// A stored pump event, reduced to what deduplication compares.
    private struct LocalEvent {
        enum Kind { case bolus, tempBasal, suspend, resume }

        let id: String?
        let kind: Kind
        let date: Date
        let amount: Decimal?

        init(id: String?, kind: Kind, date: Date, amount: Decimal?) {
            self.id = id
            self.kind = kind
            self.date = date
            self.amount = amount
        }

        init?(_ event: PumpEventStored) {
            guard let timestamp = event.timestamp else { return nil }
            switch event.type {
            case PumpEventStored.EventType.bolus.rawValue,
                 PumpEventStored.EventType.isExternal.rawValue,
                 PumpEventStored.EventType.smb.rawValue:
                self.init(id: event.id, kind: .bolus, date: timestamp, amount: event.bolus?.amount as Decimal?)
            case PumpEventStored.EventType.tempBasal.rawValue:
                // scheduled-basal reports aren't temp basals; an imported temp at the same time is still new
                guard event.tempBasal?.isScheduledBasal != true else { return nil }
                self.init(id: event.id, kind: .tempBasal, date: timestamp, amount: event.tempBasal?.rate as Decimal?)
            case PumpEventStored.EventType.pumpSuspend.rawValue:
                self.init(id: event.id, kind: .suspend, date: timestamp, amount: nil)
            case PumpEventStored.EventType.pumpResume.rawValue:
                self.init(id: event.id, kind: .resume, date: timestamp, amount: nil)
            default:
                return nil
            }
        }

        /// The same dose uploaded by this or another Trio, possibly with a slightly different timestamp
        /// (sub-second precision) or a finalized amount that differs from the programmed one.
        func isDuplicate(ofBolus bolus: NightscoutBackfill.Bolus, id: String) -> Bool {
            if self.id == id { return true }
            guard kind == .bolus else { return false }
            let seconds = abs(date.timeIntervalSince(bolus.date))
            if seconds < 5 { return true }
            guard seconds < 60, let amount else { return false }
            return abs(amount - bolus.amount) < 0.05
        }

        func isDuplicate(ofTempBasal tempBasal: NightscoutBackfill.TempBasal, id: String) -> Bool {
            if self.id == id { return true }
            return kind == .tempBasal && abs(date.timeIntervalSince(tempBasal.start)) < 30
        }
    }

    // MARK: - Persist carbs

    private static func persistCarbs(
        _ carbs: [NightscoutBackfill.Carb],
        in window: DateInterval,
        context: NSManagedObjectContext
    ) throws -> Int {
        let margin: TimeInterval = 120
        let request: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND date < %@",
            window.start.addingTimeInterval(-margin) as NSDate,
            window.end.addingTimeInterval(margin) as NSDate
        )
        var existing: [(id: UUID?, date: Date, carbs: Double)] = try context.fetch(request).compactMap { entry in
            entry.date.map { (entry.id, $0, entry.carbs) }
        }

        var inserted = 0
        for carb in carbs {
            let clientUUID = carb.clientID.flatMap(UUID.init(uuidString:))
            let amount = Double(truncating: NSDecimalNumber(decimal: carb.carbs))
            let isDuplicate = existing.contains { entry in
                if let clientUUID, entry.id == clientUUID { return true }
                let seconds = abs(entry.date.timeIntervalSince(carb.date))
                return seconds < 5 || (seconds < 60 && abs(entry.carbs - amount) < 0.5)
            }
            guard !isDuplicate else { continue }

            let entry = CarbEntryStored(context: context)
            // keeping Trio's own id lets a later deletion here remove the Nightscout document too
            entry.id = clientUUID ?? UUID()
            entry.date = carb.date
            entry.carbs = amount
            entry.fat = Double(truncating: NSDecimalNumber(decimal: carb.fat ?? 0))
            entry.protein = Double(truncating: NSDecimalNumber(decimal: carb.protein ?? 0))
            entry.note = carb.note
            entry.isFPU = carb.isFPU
            entry.fpuID = carb.fpuID.flatMap(UUID.init(uuidString:))
            entry.isUploadedToNS = true
            entry.isUploadedToHealth = true
            entry.isUploadedToTidepool = true

            existing.append((entry.id, carb.date, amount))
            inserted += 1
        }
        return inserted
    }

    // MARK: - Persist glucose

    /// Stores readings directly rather than through `GlucoseStorage`, which marks them for upload:
    /// they came from Nightscout and must not go back there, nor to Apple Health or Tidepool.
    private func persistGlucose(_ readings: [NightscoutBackfill.Glucose], in window: DateInterval) async throws -> Int {
        guard readings.isNotEmpty else { return 0 }

        let context = makeContext()
        context.name = "TreatmentsBackfillService.persistGlucose"

        return try await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "GlucoseStored")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["date"]
            request.predicate = NSPredicate(
                format: "date >= %@ AND date < %@",
                window.start.addingTimeInterval(-60) as NSDate,
                window.end.addingTimeInterval(60) as NSDate
            )
            var existingDates = try context.fetch(request).compactMap { $0["date"] as? Date }.sorted()

            var inserted = 0
            for reading in readings where reading.date >= window.start && reading.date < window.end {
                // the same reading from another uploader or the local CGM; 20 s still separates 1-minute CGMs
                guard !Self.hasDate(near: reading.date, within: 20, in: existingDates) else { continue }

                let entry = GlucoseStored(context: context)
                entry.id = UUID()
                entry.glucose = Int16(clamping: max(reading.value, Self.minimumGlucose))
                entry.date = reading.date
                entry.direction = reading.direction.flatMap { BloodGlucose.Direction(from: $0) }?.rawValue
                entry.isManual = false
                entry.isUploadedToNS = true
                entry.isUploadedToHealth = true
                entry.isUploadedToTidepool = true

                let insertAt = existingDates.firstIndex { $0 > reading.date } ?? existingDates.endIndex
                existingDates.insert(reading.date, at: insertAt)
                inserted += 1
            }

            guard context.hasChanges else { return inserted }
            try context.save()
            return inserted
        }
    }

    /// `dates` must be sorted ascending.
    static func hasDate(near date: Date, within tolerance: TimeInterval, in dates: [Date]) -> Bool {
        var low = 0
        var high = dates.count
        while low < high {
            let mid = (low + high) / 2
            if dates[mid] < date.addingTimeInterval(-tolerance) { low = mid + 1 } else { high = mid }
        }
        return low < dates.count && dates[low] <= date.addingTimeInterval(tolerance)
    }

    // MARK: - TDD synthesis

    /// Pump history between two dates, mapped like `PumpHistoryStorage.getPumpHistory()` (newest first).
    private func localPumpHistory(from start: Date, to end: Date) async throws -> [PumpHistoryEvent] {
        let context = makeContext()
        context.name = "TreatmentsBackfillService.localPumpHistory"

        return try await context.perform {
            let request: NSFetchRequest<PumpEventStored> = PumpEventStored.fetchRequest()
            request.predicate = NSPredicate(format: "timestamp >= %@ AND timestamp < %@", start as NSDate, end as NSDate)
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            request.relationshipKeyPathsForPrefetching = ["bolus", "tempBasal"]

            return try context.fetch(request).compactMap { event -> PumpHistoryEvent? in
                guard let timestamp = event.timestamp else { return nil }
                let id = event.id ?? UUID().uuidString
                switch event.type {
                case PumpEventStored.EventType.bolus.rawValue,
                     PumpEventStored.EventType.isExternal.rawValue,
                     PumpEventStored.EventType.smb.rawValue:
                    return PumpHistoryEvent(id: id, type: .bolus, timestamp: timestamp, amount: event.bolus?.amount as Decimal?)
                case PumpEventStored.EventType.tempBasal.rawValue:
                    return PumpHistoryEvent(
                        id: id,
                        type: .tempBasal,
                        timestamp: timestamp,
                        amount: event.tempBasal?.rate as Decimal?,
                        duration: Int(event.tempBasal?.duration ?? 0),
                        isScheduledBasal: event.tempBasal?.isScheduledBasal ?? false,
                        deliveredUnits: event.tempBasal?.deliveredUnits as Decimal?
                    )
                case PumpEventStored.EventType.pumpSuspend.rawValue:
                    return PumpHistoryEvent(id: id, type: .pumpSuspend, timestamp: timestamp)
                case PumpEventStored.EventType.pumpResume.rawValue:
                    return PumpHistoryEvent(id: id, type: .pumpResume, timestamp: timestamp)
                default:
                    return nil
                }
            }
        }
    }

    /// Clips pump history to one window, so `calculateTDD(…, now: window.end)` counts exactly the insulin
    /// delivered inside it.
    ///
    /// - A temp basal running into the window from before it is cut to start at the window start.
    /// - A temp basal running past the window end is cut there.
    /// - Clipped temps drop `deliveredUnits`, which covers the whole temp, so their insulin comes from
    ///   rate × time inside the window instead.
    /// - A zero-width scheduled-basal point at the window start makes scheduled-basal inference cover
    ///   the window from its first minute rather than from its first event.
    /// - A pump that was suspended when the window opened gets a suspend at the window start.
    ///
    /// - Returns: newest first, like `getPumpHistory()`
    static func pumpHistory(
        for window: DateInterval,
        from events: [PumpHistoryEvent],
        basalProfile: [BasalProfileEntry]
    ) -> [PumpHistoryEvent] {
        var result: [PumpHistoryEvent] = []
        let ascending = events.sorted { $0.timestamp < $1.timestamp }
        let isInside: (Date) -> Bool = { $0 >= window.start && $0 < window.end }

        // boluses and scheduled-basal reports are instants
        result += ascending.filter { event in
            switch event.type {
            case .bolus: return isInside(event.timestamp)
            case .tempBasal: return event.isScheduledBasal == true && isInside(event.timestamp)
            default: return false
            }
        }

        let temps = ascending.filter { $0.type == .tempBasal && $0.isScheduledBasal != true }
        for (index, temp) in temps.enumerated() {
            guard temp.timestamp < window.end else { break }
            let minutes = Double(temp.duration ?? 0)
            var end = temp.timestamp.addingTimeInterval(minutes * 60)
            // a newer temp basal supersedes this one
            if index + 1 < temps.count { end = min(end, temps[index + 1].timestamp) }

            if temp.timestamp >= window.start {
                if end <= window.end {
                    result.append(temp)
                } else {
                    result.append(clipped(temp, start: temp.timestamp, end: window.end))
                }
            } else if end > window.start {
                result.append(clipped(temp, start: window.start, end: min(end, window.end)))
            }
        }

        let suspensions = ascending.filter { $0.type == .pumpSuspend || $0.type == .pumpResume }
        if suspensions.last(where: { $0.timestamp < window.start })?.type == .pumpSuspend {
            result.append(PumpHistoryEvent(
                id: "\(windowAnchorPrefix)suspend-\(window.start.timeIntervalSince1970)",
                type: .pumpSuspend,
                timestamp: window.start
            ))
        }
        result += suspensions.filter { isInside($0.timestamp) }

        result.append(PumpHistoryEvent(
            id: "\(windowAnchorPrefix)\(window.start.timeIntervalSince1970)",
            type: .tempBasal,
            timestamp: window.start,
            amount: findBasalRateForOffset(for: minutesOfDay(window.start), in: basalProfile) ?? 0,
            duration: 0,
            isScheduledBasal: true
        ))

        return result.sorted { $0.timestamp > $1.timestamp }
    }

    private static func clipped(_ temp: PumpHistoryEvent, start: Date, end: Date) -> PumpHistoryEvent {
        PumpHistoryEvent(
            id: temp.id,
            type: .tempBasal,
            timestamp: start,
            amount: temp.amount,
            duration: max(0, Int((end.timeIntervalSince(start) / 60).rounded())),
            isScheduledBasal: false,
            deliveredUnits: nil
        )
    }

    /// Writes one row every 5 minutes across the window so `hasSufficientTDD()`'s density check
    /// (≥ 75 % of 288 rows a day over the trailing 7 days) is met by loop-cadence-shaped data, without
    /// touching that gate. Replaces rows earlier backfill runs wrote into this window, and leaves out
    /// slots a real loop cycle already filled, so the weighted average Dynamic ISF uses isn't
    /// double-counted.
    private func writeSyntheticTDDRows(for window: DateInterval, result: TDDResult) async throws {
        let context = makeContext()
        context.name = "TreatmentsBackfillService.writeSyntheticTDDRows"
        let tolerance = Self.tddRowSpacing / 2

        try await context.perform {
            let staleRequest: NSFetchRequest<TDDStored> = TDDStored.fetchRequest()
            staleRequest.predicate = NSPredicate(
                format: "date >= %@ AND date < %@ AND isBackfilled == YES",
                window.start as NSDate,
                window.end as NSDate
            )
            for stale in try context.fetch(staleRequest) {
                context.delete(stale)
            }

            let realRequest = NSFetchRequest<NSDictionary>(entityName: "TDDStored")
            realRequest.resultType = .dictionaryResultType
            realRequest.propertiesToFetch = ["date"]
            realRequest.predicate = NSPredicate(
                format: "date >= %@ AND date < %@ AND isBackfilled == NO",
                window.start.addingTimeInterval(-tolerance) as NSDate,
                window.end.addingTimeInterval(tolerance) as NSDate
            )
            let realDates = try context.fetch(realRequest).compactMap { $0["date"] as? Date }.sorted()

            let total = NSDecimalNumber(decimal: result.total)
            let bolus = NSDecimalNumber(decimal: result.bolus)
            let tempBasal = NSDecimalNumber(decimal: result.tempBasal)
            let scheduledBasal = NSDecimalNumber(decimal: result.scheduledBasal)
            let weightedAverage = result.weightedAverage.map { NSDecimalNumber(decimal: $0) }

            var timestamp = window.start
            while timestamp < window.end {
                defer { timestamp = timestamp.addingTimeInterval(Self.tddRowSpacing) }
                guard !Self.hasDate(near: timestamp, within: tolerance, in: realDates) else { continue }

                let row = TDDStored(context: context)
                row.id = UUID()
                row.date = timestamp
                row.total = total
                row.bolus = bolus
                row.tempBasal = tempBasal
                row.scheduledBasal = scheduledBasal
                row.weightedAverage = weightedAverage
                row.isBackfilled = true
            }

            guard context.hasChanges else { return }
            try context.save()
        }
    }
}
