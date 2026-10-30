import Foundation

/// "Last checked …" in the Updates card. `now` is injected so the label is a pure function of its
/// inputs; a bundle that never checked says so in words.
nonisolated struct UpdateCheckPresentation: Sendable, Hashable {
    let lastCheck: Date?
    let now: Date
    var locale: Locale = .current

    var label: String {
        guard let lastCheck else { return "Never checked" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = locale
        return "Last checked \(formatter.localizedString(for: lastCheck, relativeTo: now))"
    }
}
