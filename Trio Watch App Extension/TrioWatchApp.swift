import SwiftUI
import UserNotifications
import WatchKit

@main struct TrioWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @WKApplicationDelegateAdaptor private var delegate: TrioWatchAppDelegate

    init() {
        _ = WatchState.shared
        // restores the watch's own link to the sensor
        _ = WatchCGMHost.shared
        WatchNotificationHandler.shared.configure()
        WatchLogger.shared.info(.lifecycle, "App launched")
    }

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            if newScenePhase == .background {
                WatchLogger.shared.info(.lifecycle, "App moved to background")
                WatchLogger.shared.didEnterBackground()
                WatchBackgroundRefresh.schedule()
            } else if newScenePhase == .active {
                // looking at the watch is a wake that is not the sensor's own
                WatchCGMHost.shared.recheckAcquisition()
                // the watch's own reading may have aged out while the app was suspended
                WatchState.shared.refreshShownReading()
            }
        }
    }
}

/// The watch's background refreshes, run by `TrioWatchAppDelegate`. Each one brings the phone's latest state into the
/// complications and is also the CGM's acquisition backstop (`WatchCGMHost`).
@MainActor enum WatchBackgroundRefresh {
    private static let interval: TimeInterval = 15 * 60
    private static let settleTimeout: TimeInterval = 5
    private static let settlePoll: TimeInterval = 0.25
    /// watchOS keeps one scheduled refresh and a later request replaces it: the CGM's backstop a minute out and the
    /// complications' quarter hour share it, so a request never pushes out an earlier one.
    private static var scheduledFor: Date?

    static func schedule(in delay: TimeInterval = interval) {
        let date = Date(timeIntervalSinceNow: delay)
        if let scheduledFor, scheduledFor > Date(), scheduledFor <= date { return }
        scheduledFor = date
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: date,
            userInfo: nil
        ) { error in
            if let error = error {
                WatchLogger.shared.warning(.lifecycle, "Background refresh scheduling failed", error: error)
            }
        }
    }

    static func refresh(_ state: WatchState) async {
        WatchLogger.shared.info(.lifecycle, "Background refresh ran")
        scheduledFor = nil
        schedule()
        await settle(state)
        state.ingestReceivedApplicationContext()
        await settle(state)
    }

    static func settle(_ state: WatchState) async {
        let deadline = Date(timeIntervalSinceNow: settleTimeout)
        repeat {
            do {
                try await Task.sleep(for: .seconds(settlePoll))
            } catch {
                return
            }
        } while state.isAwaitingDelivery && Date() < deadline
    }
}
