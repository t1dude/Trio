import Foundation
import SwiftUI

extension QuickBolus {
    final class StateModel: BaseStateModel<Provider> {
        @Published var quickBolusAmount1: Decimal = 1.0
        @Published var quickBolusAmount2: Decimal = 2.0

        override func subscribe() {
            subscribeSetting(\.quickBolusAmount1, on: $quickBolusAmount1) { self.quickBolusAmount1 = $0 }
            subscribeSetting(\.quickBolusAmount2, on: $quickBolusAmount2) { self.quickBolusAmount2 = $0 }
        }
    }
}
