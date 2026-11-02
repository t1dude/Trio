import Foundation

/// Nightscout data used by the manual "Backfill Treatments" feature.
///
/// Nightscout holds whatever its uploaders wrote, and Trio, Loop, AndroidAPS and the careportal
/// each store the same therapy data differently. Backfill must not assume Trio's own format:
///
/// - **Boluses**: Trio uses `Bolus` / `SMB` / `External Insulin`. AndroidAPS uses `Correction Bolus`
///   or `Meal Bolus` and marks SMBs with `type: "SMB"` / `isSMB: true` instead of the event type.
///   AndroidAPS also uploads priming boluses (`type: "PRIMING"`), which never reach the body.
/// - **Extended boluses**: AndroidAPS and the careportal use `Combo Bolus` with `enteredinsulin`.
/// - **Bolus calculator records**: AndroidAPS uploads `Bolus Wizard` documents carrying a
///   `bolusCalculatorResult`; the bolus and carbs they describe are uploaded separately.
/// - **Temp basals**: AndroidAPS sets `durationInMilliseconds`, may send percent temps (`percent`
///   is the change from scheduled basal, so -100 is a zero temp), and represents pump suspensions as
///   zero temps (`type: "PUMP_SUSPEND"`). A temp with `duration: 0` cancels the running one.
/// - **Suspensions**: Trio writes `Note` documents whose `notes` are `PumpSuspend` / `PumpResume`;
///   Loop writes `Suspend Pump` / `Resume Pump`.
/// - **Carbs**: may come on `Carb Correction`, `Meal Bolus` (together with insulin), or anything
///   else with a `carbs` field. AndroidAPS extended carbs carry a `duration`.
/// - **Deletions**: documents uploaded through Nightscout API v3 stay with `isValid: false`.
/// - **Dates**: usually `created_at`, but API v3 documents may only carry `date` (epoch ms).
/// - **Numbers** are sometimes strings.
///
/// One unparseable document never fails the rest of the response.
enum NightscoutBackfill {
    // MARK: - Raw documents

    /// A treatments document, decoded field by field so one odd value never fails the whole response.
    struct TreatmentDocument: Decodable, Equatable {
        var nightscoutID: String?
        var identifier: String?
        var clientID: String?
        var eventType: String?
        var createdAtRaw: String?
        var date: Date?
        var insulin: Decimal?
        var enteredInsulin: Decimal?
        var carbs: Decimal?
        var fat: Decimal?
        var protein: Decimal?
        var absolute: Decimal?
        var rate: Decimal?
        var percent: Decimal?
        var durationMinutes: Double?
        var durationMilliseconds: Double?
        var type: String?
        var isSMB: Bool?
        var isValid: Bool?
        var notes: String?
        var enteredBy: String?
        var fpuID: String?
        var hasBolusCalculatorResult = false

        private enum CodingKeys: String, CodingKey {
            case nightscoutID = "_id"
            case identifier
            case clientID = "id"
            case eventType
            case createdAt = "created_at"
            case date
            case mills
            case timestamp
            case insulin
            case enteredInsulin = "enteredinsulin"
            case carbs
            case fat
            case protein
            case absolute
            case rate
            case percent
            case duration
            case durationInMilliseconds
            case type
            case isSMB
            case isValid
            case notes
            case enteredBy
            case fpuID
            case bolusCalculatorResult
        }

        init(
            nightscoutID: String? = nil,
            identifier: String? = nil,
            clientID: String? = nil,
            eventType: String? = nil,
            date: Date? = nil,
            insulin: Decimal? = nil,
            enteredInsulin: Decimal? = nil,
            carbs: Decimal? = nil,
            fat: Decimal? = nil,
            protein: Decimal? = nil,
            absolute: Decimal? = nil,
            rate: Decimal? = nil,
            percent: Decimal? = nil,
            durationMinutes: Double? = nil,
            durationMilliseconds: Double? = nil,
            type: String? = nil,
            isSMB: Bool? = nil,
            isValid: Bool? = nil,
            notes: String? = nil,
            enteredBy: String? = nil,
            fpuID: String? = nil,
            hasBolusCalculatorResult: Bool = false
        ) {
            self.nightscoutID = nightscoutID
            self.identifier = identifier
            self.clientID = clientID
            self.eventType = eventType
            self.date = date
            self.insulin = insulin
            self.enteredInsulin = enteredInsulin
            self.carbs = carbs
            self.fat = fat
            self.protein = protein
            self.absolute = absolute
            self.rate = rate
            self.percent = percent
            self.durationMinutes = durationMinutes
            self.durationMilliseconds = durationMilliseconds
            self.type = type
            self.isSMB = isSMB
            self.isValid = isValid
            self.notes = notes
            self.enteredBy = enteredBy
            self.fpuID = fpuID
            self.hasBolusCalculatorResult = hasBolusCalculatorResult
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nightscoutID = container.lenientString(.nightscoutID)
            identifier = container.lenientString(.identifier)
            clientID = container.lenientString(.clientID)
            eventType = container.lenientString(.eventType)
            createdAtRaw = container.lenientString(.createdAt)
            date = createdAtRaw.flatMap(NightscoutBackfill.parseDate)
                ?? container.lenientDate(.date)
                ?? container.lenientDate(.mills)
                ?? container.lenientDate(.timestamp)
            insulin = container.lenientDecimal(.insulin)
            enteredInsulin = container.lenientDecimal(.enteredInsulin)
            carbs = container.lenientDecimal(.carbs)
            fat = container.lenientDecimal(.fat)
            protein = container.lenientDecimal(.protein)
            absolute = container.lenientDecimal(.absolute)
            rate = container.lenientDecimal(.rate)
            percent = container.lenientDecimal(.percent)
            durationMinutes = container.lenientDecimal(.duration).map { Double(truncating: $0 as NSNumber) }
            durationMilliseconds = container.lenientDecimal(.durationInMilliseconds)
                .map { Double(truncating: $0 as NSNumber) }
            type = container.lenientString(.type)
            isSMB = container.lenientBool(.isSMB)
            isValid = container.lenientBool(.isValid)
            notes = container.lenientString(.notes)
            enteredBy = container.lenientString(.enteredBy)
            fpuID = container.lenientString(.fpuID)
            hasBolusCalculatorResult = container.contains(.bolusCalculatorResult)
                && !((try? container.decodeNil(forKey: .bolusCalculatorResult)) ?? true)
        }

        /// Stable across repeated fetches of the same document.
        var stableID: String? {
            [nightscoutID, identifier, clientID].compactMap { $0?.nonEmpty }.first
        }
    }

    /// A CGM entry (`/api/v1/entries`), decoded leniently like `TreatmentDocument`.
    struct GlucoseDocument: Decodable, Equatable {
        var date: Date?
        var sgv: Int?
        var direction: String?

        private enum CodingKeys: String, CodingKey {
            case date
            case dateString
            case sysTime
            case sgv
            case direction
        }

        init(date: Date?, sgv: Int?, direction: String? = nil) {
            self.date = date
            self.sgv = sgv
            self.direction = direction
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // `date` (epoch ms) is what every uploader sets; `dateString` formats vary by uploader
            date = container.lenientDate(.date)
                ?? container.lenientString(.dateString).flatMap(NightscoutBackfill.parseDate)
                ?? container.lenientString(.sysTime).flatMap(NightscoutBackfill.parseDate)
            sgv = container.lenientDecimal(.sgv).map { Int(truncating: $0 as NSNumber) }
            direction = container.lenientString(.direction)
        }
    }

    /// Decodes a JSON array, skipping (not failing on) elements that cannot be decoded.
    /// - Returns: the decoded elements, and how many elements the array held
    static func decodeLossy<T: Decodable>(_: T.Type, from data: Data) throws -> (items: [T], rawCount: Int) {
        let elements = try JSONDecoder().decode([Lossy<T>].self, from: data)
        return (elements.compactMap(\.value), elements.count)
    }

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }

    // MARK: - Normalized therapy data

    enum BolusKind: Equatable {
        case manual
        case smb
        case external
    }

    struct Bolus: Equatable {
        let id: String
        let date: Date
        let amount: Decimal
        let kind: BolusKind
    }

    struct TempBasal: Equatable {
        let id: String
        let start: Date
        /// 0 means the document cancelled the running temp basal.
        let durationMinutes: Double
        /// Absolute rate in U/h.
        let rate: Decimal

        var end: Date { start.addingTimeInterval(durationMinutes * 60) }
    }

    struct Carb: Equatable {
        let id: String
        let clientID: String?
        let date: Date
        let carbs: Decimal
        let fat: Decimal?
        let protein: Decimal?
        let note: String?
        let fpuID: String?
        let isFPU: Bool
    }

    struct Suspension: Equatable {
        let id: String
        let date: Date
        let isSuspend: Bool
    }

    struct Glucose: Equatable {
        let date: Date
        let value: Int
        let direction: String?
    }

    struct Batch: Equatable {
        var boluses: [Bolus] = []
        var tempBasals: [TempBasal] = []
        var carbs: [Carb] = []
        var suspensions: [Suspension] = []
        /// Insulin- or basal-bearing documents seen, before deduplication.
        var insulinDocumentCount = 0
    }

    /// Converts raw documents into therapy data, whichever uploader wrote them.
    /// - Parameter scheduledBasalRate: profile rate at a date, used to resolve percent temp basals
    static func normalize(
        _ documents: [TreatmentDocument],
        scheduledBasalRate: (Date) -> Decimal?
    ) -> Batch {
        var batch = Batch()

        for document in documents {
            guard document.isValid != false, let date = document.date else { continue }
            let eventType = document.eventType?.trimmingCharacters(in: .whitespaces) ?? ""
            let baseID = document.stableID
                ?? "\(eventType)-\(Int((date.timeIntervalSince1970 * 1000).rounded()))"

            // AndroidAPS bolus calculator records describe a bolus and carbs uploaded on their own documents
            let isCalculatorRecord = eventType == "Bolus Wizard" && document.hasBolusCalculatorResult

            if let suspension = suspension(from: document, eventType: eventType, date: date, id: baseID) {
                batch.suspensions.append(suspension)
            } else if isTempBasal(eventType) {
                if let tempBasal = tempBasal(from: document, date: date, id: baseID, scheduledBasalRate: scheduledBasalRate) {
                    batch.tempBasals.append(tempBasal)
                    batch.insulinDocumentCount += 1
                }
            } else if !isCalculatorRecord, let bolus = bolus(from: document, eventType: eventType, date: date, id: baseID) {
                batch.boluses.append(bolus)
                batch.insulinDocumentCount += 1
            }

            if !isCalculatorRecord, let carbs = document.carbs, carbs > 0 {
                batch.carbs.append(contentsOf: carbEntries(from: document, carbs: carbs, date: date, id: baseID))
            }
        }

        batch.boluses = deduplicated(batch.boluses.sorted { $0.date < $1.date }) {
            abs($0.date.timeIntervalSince($1.date)) < 2 && abs($0.amount - $1.amount) < 0.01
        }
        batch.tempBasals = deduplicated(batch.tempBasals.sorted { $0.start < $1.start }) {
            abs($0.start.timeIntervalSince($1.start)) < 2
        }
        batch.carbs = deduplicated(batch.carbs.sorted { $0.date < $1.date }) {
            abs($0.date.timeIntervalSince($1.date)) < 2 && $0.carbs == $1.carbs
        }
        batch.suspensions = deduplicated(batch.suspensions.sorted { $0.date < $1.date }) {
            abs($0.date.timeIntervalSince($1.date)) < 2 && $0.isSuspend == $1.isSuspend
        }
        return batch
    }

    static func glucose(from documents: [GlucoseDocument]) -> [Glucose] {
        let readings = documents.compactMap { document -> Glucose? in
            guard let date = document.date, let sgv = document.sgv, sgv > 0 else { return nil }
            return Glucose(date: date, value: sgv, direction: document.direction)
        }
        // several uploaders (e.g. AndroidAPS and xDrip) can upload the same reading
        return deduplicated(readings.sorted { $0.date < $1.date }) { abs($0.date.timeIntervalSince($1.date)) < 10 }
    }

    // MARK: - Classification

    private static func isTempBasal(_ eventType: String) -> Bool {
        eventType == "Temp Basal" || eventType == "TempBasal"
    }

    private static func suspension(
        from document: TreatmentDocument,
        eventType: String,
        date: Date,
        id: String
    ) -> Suspension? {
        switch eventType {
        case "Suspend Pump":
            return Suspension(id: id, date: date, isSuspend: true)
        case "Resume Pump":
            return Suspension(id: id, date: date, isSuspend: false)
        case "Note":
            switch document.notes?.trimmingCharacters(in: .whitespaces) {
            case PumpEventStored.EventType.pumpSuspend.rawValue: return Suspension(id: id, date: date, isSuspend: true)
            case PumpEventStored.EventType.pumpResume.rawValue: return Suspension(id: id, date: date, isSuspend: false)
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func bolus(from document: TreatmentDocument, eventType: String, date: Date, id: String) -> Bolus? {
        let subtype = document.type?.uppercased()
        // priming fills the cannula and never reaches the body
        guard subtype != "PRIMING", eventType != "Prime" else { return nil }

        let amount: Decimal?
        if eventType == "Combo Bolus" {
            // `enteredinsulin` is the whole combo; `insulin` may only be its immediate part
            amount = [document.enteredInsulin, document.insulin].compactMap { $0 }.first { $0 > 0 }
        } else {
            amount = document.insulin
        }
        guard let amount, amount > 0 else { return nil }

        let kind: BolusKind
        if eventType == "External Insulin" {
            kind = .external
        } else if eventType == "SMB" || document.isSMB == true || subtype == "SMB" {
            kind = .smb
        } else {
            kind = .manual
        }
        return Bolus(id: id, date: date, amount: amount, kind: kind)
    }

    private static func tempBasal(
        from document: TreatmentDocument,
        date: Date,
        id: String,
        scheduledBasalRate: (Date) -> Decimal?
    ) -> TempBasal? {
        let minutes: Double
        if let milliseconds = document.durationMilliseconds {
            minutes = milliseconds / 60000
        } else if let durationMinutes = document.durationMinutes {
            minutes = durationMinutes
        } else {
            return nil
        }
        guard minutes >= 0 else { return nil }

        let rate: Decimal?
        // `absolute`/`rate` were resolved by the uploader against the profile active at the time,
        // so they beat re-deriving a percent temp from today's profile
        if let absolute = document.absolute {
            rate = absolute
        } else if let documentRate = document.rate {
            rate = documentRate
        } else if let percent = document.percent {
            // percent temps are relative to the schedule: -100 is a zero temp, +50 is 150 %
            rate = scheduledBasalRate(date).map { $0 * (100 + percent) / 100 }
        } else if minutes == 0 {
            rate = 0 // cancel without a rate
        } else if ["PUMP_SUSPEND", "EMULATED_PUMP_SUSPEND"].contains(document.type?.uppercased() ?? "") {
            rate = 0
        } else {
            rate = nil
        }
        guard let rate, rate >= 0 else { return nil }
        return TempBasal(id: id, start: date, durationMinutes: minutes, rate: rate)
    }

    /// AndroidAPS extended carbs absorb over `duration`; spreading them keeps carbs-on-board realistic.
    private static func carbEntries(from document: TreatmentDocument, carbs: Decimal, date: Date, id: String) -> [Carb] {
        let isFPU = document.fpuID?.nonEmpty != nil && (document.fat ?? 0) == 0 && (document.protein ?? 0) == 0
        let durationMinutes = document.durationMinutes ?? 0
        let hasExtendedDuration = durationMinutes >= 60 && !isFPU && !isTempBasal(document.eventType ?? "")

        guard hasExtendedDuration else {
            return [Carb(
                id: "\(id)-carbs",
                clientID: document.clientID,
                date: date,
                carbs: carbs,
                fat: document.fat,
                protein: document.protein,
                note: document.notes,
                fpuID: document.fpuID?.nonEmpty,
                isFPU: isFPU
            )]
        }

        let chunkCount = max(1, Int(durationMinutes / 60))
        let chunk = (carbs / Decimal(chunkCount)).rounded(toPlaces: 1)
        return (0 ..< chunkCount).map { index in
            let isLast = index == chunkCount - 1
            return Carb(
                id: "\(id)-carbs-\(index)",
                clientID: index == 0 ? document.clientID : nil,
                date: date.addingTimeInterval(Double(index) * 3600),
                carbs: isLast ? carbs - chunk * Decimal(chunkCount - 1) : chunk,
                fat: index == 0 ? document.fat : nil,
                protein: index == 0 ? document.protein : nil,
                note: document.notes,
                fpuID: nil,
                isFPU: false
            )
        }
    }

    /// Drops elements a predicate considers equal to the previously kept one; input must be sorted by time.
    private static func deduplicated<T>(_ items: [T], isDuplicate: (T, T) -> Bool) -> [T] {
        var result: [T] = []
        for item in items {
            // sorted input: duplicates sit within a few seconds, so only the recent tail needs checking
            if result.suffix(4).contains(where: { isDuplicate($0, item) }) { continue }
            result.append(item)
        }
        return result
    }

    // MARK: - Dates

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Offsets without a colon (`+0200`) and timestamps without a zone (taken as UTC, like Nightscout does).
    private static let fallbackFormatters: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let date = isoFractional.date(from: trimmed) ?? isoPlain.date(from: trimmed) {
            return date
        }
        for formatter in fallbackFormatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        if let number = Double(trimmed) {
            return dateFromEpoch(number)
        }
        return nil
    }

    /// Nightscout epochs are milliseconds; a few uploaders send seconds.
    static func dateFromEpoch(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }
}

// MARK: - Lenient field decoding

private extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.rounded() == value ? String(Int64(value)) : String(value)
        }
        return nil
    }

    func lenientDecimal(_ key: Key) -> Decimal? {
        if let value = try? decodeIfPresent(Decimal.self, forKey: key) { return value }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return Decimal(string: string.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "en_US_POSIX"))
        }
        return nil
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            switch string.lowercased() {
            case "1",
                 "true",
                 "yes": return true
            case "0",
                 "false",
                 "no": return false
            default: return nil
            }
        }
        if let number = try? decodeIfPresent(Int.self, forKey: key) { return number != 0 }
        return nil
    }

    func lenientDate(_ key: Key) -> Date? {
        if let number = try? decodeIfPresent(Double.self, forKey: key) {
            return NightscoutBackfill.dateFromEpoch(number)
        }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return NightscoutBackfill.parseDate(string)
        }
        return nil
    }
}
