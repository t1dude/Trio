import CoreData
import Foundation

// Fetch Data for Glucose and Determination from Core Data and map them to the Structs in order to pass them thread safe to the glucoseDidUpdate/ pushUpdate function

@available(iOS 16.2, *)
extension LiveActivityManager {
    func fetchAndMapGlucose() async throws -> [GlucoseData] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.predicateForSixHoursAgo,
            key: "date",
            ascending: false
        )

        return try await context.perform {
            guard let glucoseResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return glucoseResults.map {
                GlucoseData(glucose: Int($0.glucose), date: $0.date ?? Date(), direction: $0.directionEnum)
            }
        }
    }

    // TODO: extract logic or at least rename function appropiately
    func fetchAndMapDetermination() async throws -> DeterminationData? {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OrefDetermination.self,
            onContext: context,
            predicate: NSPredicate.predicateFor30MinAgoForDetermination,
            key: "deliverAt",
            ascending: false,
            fetchLimit: 1,
            relationshipKeyPathsForPrefetching: ["forecasts", "forecasts.forecastValues"]
        )

        let tddResults = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: TDDStored.self,
            onContext: context,
            predicate: NSPredicate.predicateFor30MinAgo,
            key: "date",
            ascending: false,
            fetchLimit: 1,
            propertiesToFetch: ["total"]
        )

        let tddCalendarDay = try await fetchTodayTDD()

        return try await context.perform {
            guard let determinationResults = results as? [OrefDetermination],
                  let tddResults = tddResults as? [[String: Any]]
            else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            guard let determination = determinationResults.first else {
                return nil
            }

            let tddValue = (tddResults.first?["total"] as? NSDecimalNumber)?.decimalValue ?? 0

            // Compute cone bounds and per-type lines from forecast relationships (cap at 24 values = 2h)
            var allForecastValues = [[Int]]()
            var forecastLines = [(type: String, values: [Int])]()

            if let forecasts = determination.forecasts {
                for forecast in forecasts.sorted(by: { ($0.type ?? "") < ($1.type ?? "") }) {
                    let values = forecast.forecastValuesArray.prefix(24).map { Int($0.value) }
                    guard !values.isEmpty else { continue }
                    allForecastValues.append(Array(values))
                    if let type = forecast.type {
                        forecastLines.append((type: type, values: Array(values)))
                    }
                }
            }

            let minCount = allForecastValues.map(\.count).min() ?? 0
            var minForecast = [Int]()
            var maxForecast = [Int]()

            for index in 0 ..< minCount {
                let col = allForecastValues.compactMap { $0.indices.contains(index) ? $0[index] : nil }
                minForecast.append(col.min() ?? 0)
                maxForecast.append(col.max() ?? 0)
            }

            return DeterminationData(
                cob: Int(determination.cob),
                tdd: tddValue,
                tddCalendarDay: tddCalendarDay,
                target: determination.currentTarget?.decimalValue ?? 0,
                date: determination.deliverAt,
                eventualBG: determination.eventualBG?.decimalValue ?? 0,
                minForecast: minForecast,
                maxForecast: maxForecast,
                forecastLines: forecastLines
            )
        }
    }

    /// Calculates TDD for the current calendar day (00:00 → now) from raw pump events,
    /// using the same pattern as the Stats feature's hourly TDD calculation.
    ///
    /// Actual temp-basal duration is derived from the time to the next event (not the
    /// planned duration field), which is correct for closed-loop systems that issue a new
    /// temp basal every few minutes and cancel the previous one.  A one-hour pre-midnight
    /// buffer is included so a temp basal that started just before midnight is clipped
    /// correctly to [00:00, now].
    private func fetchTodayTDD() async throws -> Decimal {
        let startOfToday = Date.startOfToday
        let now = Date()

        let bolusResults = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: BolusStored.self,
            onContext: context,
            predicate: NSPredicate(
                format: "pumpEvent.timestamp >= %@ AND pumpEvent.timestamp <= %@",
                startOfToday as NSDate, now as NSDate
            ),
            key: "pumpEvent.timestamp",
            ascending: true
        )

        // Include basals starting up to one hour before midnight so any basal crossing
        // midnight is clipped correctly to [00:00, now]
        let tempBasalWindowStart = startOfToday.addingTimeInterval(-3600)
        let tempBasalResults = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: TempBasalStored.self,
            onContext: context,
            predicate: NSPredicate(
                format: "pumpEvent.timestamp >= %@ AND pumpEvent.timestamp <= %@",
                tempBasalWindowStart as NSDate, now as NSDate
            ),
            key: "pumpEvent.timestamp",
            ascending: true
        )

        return try await context.perform {
            guard let boluses = bolusResults as? [BolusStored],
                  let tempBasals = tempBasalResults as? [TempBasalStored]
            else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            let bolusTotal = boluses.reduce(Decimal(0)) { $0 + ($1.amount?.decimalValue ?? 0) }

            let sorted = tempBasals.sorted {
                ($0.pumpEvent?.timestamp ?? .distantPast) < ($1.pumpEvent?.timestamp ?? .distantPast)
            }

            var tempBasalTotal: Decimal = 0
            for (index, tempBasal) in sorted.enumerated() {
                guard let eventStart = tempBasal.pumpEvent?.timestamp,
                      let rate = tempBasal.rate?.decimalValue
                else { continue }

                // Actual duration = time to next event; planned duration for the last event.
                let actualSeconds: TimeInterval
                if index < sorted.count - 1, let nextStart = sorted[index + 1].pumpEvent?.timestamp {
                    actualSeconds = nextStart.timeIntervalSince(eventStart)
                } else {
                    actualSeconds = Double(tempBasal.duration) * 60
                }

                let windowStart = max(eventStart, startOfToday)
                let windowEnd = min(eventStart.addingTimeInterval(actualSeconds), now)
                guard windowEnd > windowStart else { continue }

                let hours = Decimal(windowEnd.timeIntervalSince(windowStart) / 3600)
                tempBasalTotal += rate * hours
            }

            return bolusTotal + tempBasalTotal
        }
    }

    func fetchAndMapTempTarget() async throws -> TempTargetData? {
        try await fetchAndMapLatest(
            ofType: TempTargetStored.self,
            predicate: .predicateForOneDayAgo,
            key: "date",
            propertiesToFetch: ["enabled", "name", "target", "date", "duration"]
        ) { row in
            TempTargetData(
                isActive: row["enabled"] as? Bool ?? false,
                tempTargetName: row["name"] as? String ?? "Temp Target",
                date: row["date"] as? Date ?? Date(),
                duration: row["duration"] as? Decimal ?? 0,
                target: row["target"] as? Decimal ?? 0
            )
        }
    }

    func fetchAndMapOverride() async throws -> OverrideData? {
        try await fetchAndMapLatest(
            ofType: OverrideStored.self,
            predicate: .predicateForOneDayAgo,
            key: "date",
            propertiesToFetch: ["enabled", "name", "target", "date", "duration"]
        ) { row in
            OverrideData(
                isActive: row["enabled"] as? Bool ?? false,
                overrideName: row["name"] as? String ?? "Override",
                date: row["date"] as? Date ?? Date(),
                duration: row["duration"] as? Decimal ?? 0,
                target: row["target"] as? Decimal ?? 0
            )
        }
    }

    private func fetchAndMapLatest<Entity: NSManagedObject, Output>(
        ofType type: Entity.Type,
        predicate: NSPredicate,
        key: String,
        propertiesToFetch: [String],
        map: @escaping ([String: Any]) -> Output
    ) async throws -> Output? {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: type,
            onContext: context,
            predicate: predicate,
            key: key,
            ascending: false,
            fetchLimit: 1,
            propertiesToFetch: propertiesToFetch
        )

        return try await context.perform {
            guard let rows = results as? [[String: Any]] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return rows.first.map(map)
        }
    }
}
