import Testing

@testable import AetherTunnelSupport

@Test func moduleIdentity() {
    #expect(AetherTunnelSupportModule.name == "AetherTunnelSupport")
    #expect(AetherTunnelSupportModule.dependencies.count == 2)
}

@Test func hevStatisticsAreZeroBeforeStart() {
    #expect(HevTunnel.statistics == HevTunnel.Statistics(txPackets: 0, txBytes: 0, rxPackets: 0, rxBytes: 0))
}
