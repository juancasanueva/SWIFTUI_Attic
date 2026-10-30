import Foundation
import Observation

/// Port for everything the app asks of an updater. `SparkleUpdateChecker` is the adapter; Settings only
/// sees this, and tests drive it with an in-memory fake.
///
/// Main-actor because the real updater is; `AnyObject` so every surface observes the same instance;
/// `Observable` so a view holding `any AppUpdating` still re-renders.
@MainActor
protocol AppUpdating: AnyObject, Observable {
    /// False only while a check is already running.
    var canCheckForUpdates: Bool { get }
    /// Whether the updater checks on its own. The app's own preference (`AutomaticUpdateChecks`) is
    /// written to it at every launch.
    var automaticallyChecksForUpdates: Bool { get set }
    /// When the last check completed, or `nil` if there has never been one.
    var lastUpdateCheckDate: Date? { get }
    /// Starts exactly one check.
    func checkForUpdates()
}
