import Foundation
import Testing

@testable import Trio

@Suite("Nightscout Backfill Tests") struct NightscoutBackfillTests {
    private func decode(_ json: String) throws -> [NightscoutBackfill.TreatmentDocument] {
        try NightscoutBackfill.decodeLossy(NightscoutBackfill.TreatmentDocument.self, from: Data(json.utf8)).items
    }

    private func normalize(_ json: String, scheduledRate: Decimal = 1) throws -> NightscoutBackfill.Batch {
        NightscoutBackfill.normalize(try decode(json)) { _ in scheduledRate }
    }

    private let flatProfile = [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1.0)]

    // MARK: - AndroidAPS

    @Test("AndroidAPS boluses: SMB by subtype, priming skipped, calculator records skipped") func testAndroidAPSBoluses() throws {
        let batch = try normalize("""
        [
          {"_id":"a1","eventType":"Correction Bolus","created_at":"2026-10-30T10:00:00.000Z","date":1793354400000,
           "insulin":0.4,"type":"SMB","isSMB":true,"isValid":true,"enteredBy":"openaps://AndroidAPS"},
          {"_id":"a2","eventType":"Meal Bolus","created_at":"2026-10-30T12:00:00.000Z","insulin":5.5,"type":"NORMAL",
           "carbs":45,"isValid":true},
          {"_id":"a3","eventType":"Correction Bolus","created_at":"2026-10-30T13:00:00.000Z","insulin":0.7,"type":"PRIMING"},
          {"_id":"a4","eventType":"Bolus Wizard","created_at":"2026-10-30T12:00:00.000Z","insulin":5.5,"carbs":45,
           "bolusCalculatorResult":"{}"},
          {"_id":"a5","eventType":"Correction Bolus","created_at":"2026-10-30T14:00:00.000Z","insulin":1.0,"isValid":false}
        ]
        """)

        #expect(batch.boluses.map(\.amount) == [0.4, 5.5])
        #expect(batch.boluses.map(\.kind) == [.smb, .manual])
        #expect(batch.carbs.map(\.carbs) == [45])
    }

    @Test("AndroidAPS temp basals: ms duration, absolute over percent, suspend as zero temp") func testAndroidAPSTempBasals() throws {
        let batch = try normalize(
            """
            [
              {"_id":"t1","eventType":"Temp Basal","created_at":"2026-10-30T10:00:00.000Z","duration":30,
               "durationInMilliseconds":1770000,"rate":1.6,"absolute":1.6,"type":"NORMAL"},
              {"_id":"t2","eventType":"Temp Basal","created_at":"2026-10-30T11:00:00.000Z","duration":60,
               "percent":-50,"rate":0.45,"type":"NORMAL"},
              {"_id":"t3","eventType":"Temp Basal","created_at":"2026-10-30T12:00:00.000Z","duration":60,
               "percent":-100,"type":"NORMAL"},
              {"_id":"t4","eventType":"Temp Basal","created_at":"2026-10-30T13:00:00.000Z","duration":120,
               "type":"PUMP_SUSPEND"},
              {"_id":"t5","eventType":"Temp Basal","created_at":"2026-10-30T15:30:00.000Z","duration":0}
            ]
            """,
            scheduledRate: 0.8
        )

        #expect(batch.tempBasals.count == 5)
        #expect(batch.tempBasals[0].durationMinutes == 29.5)
        #expect(batch.tempBasals[0].rate == 1.6)
        // the uploader's own absolute rate beats re-deriving the percent from today's profile
        #expect(batch.tempBasals[1].rate == 0.45)
        // percent-only: -100 % of the schedule is a zero temp
        #expect(batch.tempBasals[2].rate == 0)
        #expect(batch.tempBasals[3].rate == 0)
        #expect(batch.tempBasals[4].durationMinutes == 0)
    }

    @Test("Percent temp basal without a rate resolves against the schedule") func testPercentTempBasal() throws {
        let batch = try normalize(
            """
            [{"eventType":"Temp Basal","created_at":"2026-10-30T10:00:00Z","duration":30,"percent":50}]
            """,
            scheduledRate: 0.8
        )
        #expect(batch.tempBasals.first?.rate == 1.2)
    }

    @Test("API v3 documents without created_at use the epoch date") func testEpochDate() throws {
        let batch = try normalize("""
        [{"identifier":"v3-1","eventType":"Correction Bolus","date":1793354400000,"insulin":"1.25"}]
        """)
        #expect(batch.boluses.first?.date == Date(timeIntervalSince1970: 1_793_354_400))
        #expect(batch.boluses.first?.amount == 1.25)
        #expect(batch.boluses.first?.id == "v3-1")
    }

    @Test("Extended carbs spread over their duration") func testExtendedCarbs() throws {
        let batch = try normalize("""
        [{"_id":"c1","eventType":"Carb Correction","created_at":"2026-10-30T10:00:00.000Z","carbs":30,"duration":180}]
        """)
        #expect(batch.carbs.map(\.carbs) == [10, 10, 10])
        #expect(batch.carbs.last?.date == NightscoutBackfill.parseDate("2026-10-30T12:00:00.000Z"))
    }

    @Test("Combo bolus counts its entered insulin") func testComboBolus() throws {
        let batch = try normalize("""
        [{"_id":"e1","eventType":"Combo Bolus","created_at":"2026-10-30T10:00:00.000Z","insulin":1,
          "enteredinsulin":3,"duration":120,"splitNow":33,"splitExt":67}]
        """)
        #expect(batch.boluses.map(\.amount) == [3])
    }

    @Test("Duplicate uploads of the same dose collapse") func testDuplicates() throws {
        let batch = try normalize("""
        [
          {"_id":"d1","eventType":"Correction Bolus","created_at":"2026-10-30T10:00:00.000Z","insulin":0.3,"isSMB":true},
          {"_id":"d2","eventType":"Correction Bolus","created_at":"2026-10-30T10:00:00.400Z","insulin":0.3,"isSMB":true}
        ]
        """)
        #expect(batch.boluses.count == 1)
    }

    // MARK: - Trio and Loop

    @Test("Trio uploads: SMB and external event types, suspend notes, FPU carbs") func testTrioUploads() throws {
        let batch = try normalize("""
        [
          {"_id":"n1","id":"local-1","eventType":"SMB","created_at":"2026-10-30T10:00:00.000Z","insulin":0.2,"enteredBy":"Trio"},
          {"_id":"n2","eventType":"External Insulin","created_at":"2026-10-30T11:00:00.000Z","insulin":2},
          {"_id":"n3","eventType":"Note","created_at":"2026-10-30T12:00:00.000Z","notes":"PumpSuspend"},
          {"_id":"n4","eventType":"Note","created_at":"2026-10-30T12:30:00.000Z","notes":"PumpResume"},
          {"_id":"n5","eventType":"Carb Correction","created_at":"2026-10-30T14:00:00.000Z","carbs":12,
           "fpuID":"9D4C1F6E-8B0B-4E7A-9C51-1D2F3A4B5C6D"},
          {"_id":"n6","eventType":"Note","created_at":"2026-10-30T15:00:00.000Z","notes":"Trio connected"}
        ]
        """)
        #expect(batch.boluses.map(\.kind) == [.smb, .external])
        #expect(batch.suspensions.map(\.isSuspend) == [true, false])
        #expect(batch.carbs.first?.isFPU == true)
    }

    @Test("Loop suspend and resume event types") func testLoopSuspend() throws {
        let batch = try normalize("""
        [
          {"_id":"l1","eventType":"Suspend Pump","created_at":"2026-10-30T12:00:00Z"},
          {"_id":"l2","eventType":"Resume Pump","created_at":"2026-10-30T12:30:00Z"}
        ]
        """)
        #expect(batch.suspensions.map(\.isSuspend) == [true, false])
    }

    @Test("An undecodable document doesn't fail the response") func testLossyDecoding() throws {
        let documents = try decode("""
        [
          "not an object",
          {"_id":"ok","eventType":"Meal Bolus","created_at":"2026-10-30T10:00:00+0200","insulin":2}
        ]
        """)
        #expect(documents.count == 1)
        #expect(documents.first?.date == NightscoutBackfill.parseDate("2026-10-30T08:00:00Z"))
    }

    @Test("Glucose uses epoch dates and drops duplicate uploads") func testGlucose() throws {
        let documents = try NightscoutBackfill.decodeLossy(
            NightscoutBackfill.GlucoseDocument.self,
            from: Data("""
            [
              {"sgv":120,"date":1793354400000,"dateString":"2026-10-30T11:00:00.000+0100","direction":"Flat"},
              {"sgv":121,"date":1793354403000,"direction":"Flat"},
              {"sgv":0,"date":1793354700000}
            ]
            """.utf8)
        ).items
        let readings = NightscoutBackfill.glucose(from: documents)
        #expect(readings.map(\.value) == [120])
    }

    // MARK: - Windows

    @Test("Windows are consecutive 24 h spans ending now") func testWindows() {
        let now = Date()
        let windows = BaseTreatmentsBackfillService.windows(endingAt: now, days: 7)
        #expect(windows.count == 7)
        #expect(windows.last?.end == now)
        #expect(windows.first?.start == now.addingTimeInterval(-7 * 24 * 3600))
        #expect(zip(windows, windows.dropFirst()).allSatisfy { $0.end == $1.start })
    }

    @Test("Temp basals are clipped to the window") func testClipping() {
        let windowStart = Date(timeIntervalSince1970: 1_793_300_000)
        let window = DateInterval(start: windowStart, duration: 24 * 3600)
        let events = [
            // started 20 min before the window, 60 min long: 40 min inside
            PumpHistoryEvent(
                id: "before",
                type: .tempBasal,
                timestamp: windowStart.addingTimeInterval(-20 * 60),
                amount: 2,
                duration: 60,
                deliveredUnits: 2
            ),
            // superseded before the window opened: nothing inside
            PumpHistoryEvent(
                id: "superseded",
                type: .tempBasal,
                timestamp: windowStart.addingTimeInterval(-90 * 60),
                amount: 3,
                duration: 120
            ),
            // runs 10 min past the window end
            PumpHistoryEvent(
                id: "after",
                type: .tempBasal,
                timestamp: window.end.addingTimeInterval(-20 * 60),
                amount: 1.5,
                duration: 30,
                deliveredUnits: 0.75
            ),
            PumpHistoryEvent(id: "bolus-out", type: .bolus, timestamp: windowStart.addingTimeInterval(-60), amount: 1),
            PumpHistoryEvent(id: "bolus-in", type: .bolus, timestamp: windowStart.addingTimeInterval(60), amount: 1)
        ]

        let history = BaseTreatmentsBackfillService.pumpHistory(for: window, from: events, basalProfile: flatProfile)
        let temps = history.filter { $0.type == .tempBasal && $0.isScheduledBasal != true }

        #expect(temps.count == 2)
        let clippedStart = temps.first { $0.id == "before" }
        #expect(clippedStart?.timestamp == windowStart)
        #expect(clippedStart?.duration == 40)
        #expect(clippedStart?.deliveredUnits == nil)
        let clippedEnd = temps.first { $0.id == "after" }
        #expect(clippedEnd?.duration == 20)
        #expect(clippedEnd?.deliveredUnits == nil)
        #expect(history.filter { $0.type == .bolus }.map(\.id) == ["bolus-in"])
        // newest first, like getPumpHistory()
        #expect(history == history.sorted { $0.timestamp > $1.timestamp })
    }

    @Test("Scheduled basal for a past window stops at the window end") func testScheduledBasalBoundedByWindow() {
        let windowStart = Date().addingTimeInterval(-5 * 24 * 3600)
        let window = DateInterval(start: windowStart, duration: 24 * 3600)
        let events = [
            PumpHistoryEvent(
                id: "temp",
                type: .tempBasal,
                timestamp: windowStart.addingTimeInterval(3600),
                amount: 0,
                duration: 60
            )
        ]

        let history = BaseTreatmentsBackfillService.pumpHistory(for: window, from: events, basalProfile: flatProfile)
        let segments = ScheduledBasalInference.segments(
            events: BaseTDDStorage.timelineEvents(from: history),
            profile: flatProfile,
            now: window.end
        )
        let scheduledHours = segments.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 3600

        // 24 h window minus the 1 h zero temp, from the window's first minute, never past its end
        #expect(abs(scheduledHours - 23) < 0.01)
        #expect(segments.first?.start == windowStart)
        #expect(segments.allSatisfy { $0.end <= window.end })
    }

    @Test("A pump suspended when the window opens stays suspended") func testSuspendedAtWindowStart() {
        let windowStart = Date().addingTimeInterval(-3 * 24 * 3600)
        let window = DateInterval(start: windowStart, duration: 24 * 3600)
        let events = [
            PumpHistoryEvent(id: "s", type: .pumpSuspend, timestamp: windowStart.addingTimeInterval(-30 * 60)),
            PumpHistoryEvent(id: "r", type: .pumpResume, timestamp: windowStart.addingTimeInterval(30 * 60))
        ]

        let history = BaseTreatmentsBackfillService.pumpHistory(for: window, from: events, basalProfile: flatProfile)
        let segments = ScheduledBasalInference.segments(
            events: BaseTDDStorage.timelineEvents(from: history),
            profile: flatProfile,
            now: window.end
        )
        let scheduledHours = segments.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 3600
        #expect(abs(scheduledHours - 23.5) < 0.01)
    }

    @Test("Nearby-date lookup") func testHasDateNear() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let dates = [base, base.addingTimeInterval(300), base.addingTimeInterval(600)]
        #expect(BaseTreatmentsBackfillService.hasDate(near: base.addingTimeInterval(140), within: 150, in: dates))
        #expect(!BaseTreatmentsBackfillService.hasDate(near: base.addingTimeInterval(160), within: 10, in: dates))
        #expect(!BaseTreatmentsBackfillService.hasDate(near: base, within: 10, in: []))
    }
}
