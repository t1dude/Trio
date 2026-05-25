import Foundation

struct DeterminationData {
    let cob: Int
    let tdd: Decimal
    let tddCalendarDay: Decimal
    let target: Decimal
    let date: Date?
    let eventualBG: Decimal
    let minForecast: [Int]
    let maxForecast: [Int]
    let forecastLines: [(type: String, values: [Int])]
}
