import Testing
@testable import TradePulse

@MainActor
struct SmokeTests {
    @Test func appModuleBuilds() {
        let viewModel = SkeletonViewModel()
        #expect(viewModel.rows.count == 3)
        #expect(viewModel.rows.allSatisfy { $0.state == .pending })
    }
}
