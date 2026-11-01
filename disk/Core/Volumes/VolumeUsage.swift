/// How full a mounted volume is.
nonisolated struct VolumeUsage: Hashable, Sendable {
    let usedFraction: Double

    /// Returns nil when the volume does not report usable capacities.
    init?(total: Int?, available: Int64?) {
        guard let total, total > 0, let available else { return nil }
        // Important-usage capacity counts purgeable space, so it can overshoot the total.
        let free = min(Double(available) / Double(total), 1)
        usedFraction = 1 - max(free, 0)
    }
}
