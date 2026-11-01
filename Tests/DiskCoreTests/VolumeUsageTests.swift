import Testing
@testable import DiskCore

@Suite struct VolumeUsageTests {
    @Test func usedFractionIsTheShareOfTheVolumeThatIsNotFree() throws {
        let usage = try #require(VolumeUsage(total: 1_000, available: 250))

        #expect(usage.usedFraction == 0.75)
    }

    @Test func usedFractionStaysInRangeWhenAvailableExceedsTotal() throws {
        // Important-usage capacity counts purgeable space, so it can overshoot the total.
        let usage = try #require(VolumeUsage(total: 1_000, available: 1_500))

        #expect(usage.usedFraction == 0)
    }

    @Test func usageIsUnknownWithoutUsableCapacities() {
        #expect(VolumeUsage(total: nil, available: 250) == nil)
        #expect(VolumeUsage(total: 1_000, available: nil) == nil)
        #expect(VolumeUsage(total: 0, available: 0) == nil)
    }
}
