import Foundation
@testable import DiskCore

extension CleanEnvironment {
    /// A home folder in a test directory: no installed apps, nothing ever opened, a fixed "now".
    static func testing(
        home: URL, now: Date = Date(timeIntervalSince1970: 1_793_804_400), installedApps: [InstalledApp] = [],
        lastOpened: @escaping @Sendable (URL) -> Date? = { _ in nil },
        isScreenCapture: @escaping @Sendable (URL) -> Bool = { _ in false }
    ) -> CleanEnvironment {
        CleanEnvironment(
            home: home, applicationFolders: [home.appending(path: "Applications")], now: now,
            installedApps: installedApps, ownBundleID: "com.juancasanueva.attic",
            lastOpened: lastOpened, isScreenCapture: isScreenCapture)
    }
}
