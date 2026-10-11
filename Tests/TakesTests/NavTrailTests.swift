import Foundation
import Testing
@testable import Takes

@Suite struct NavTrailTests {
    let a = NavSpot(session: URL(fileURLWithPath: "/a"), tab: "record")
    let b = NavSpot(session: URL(fileURLWithPath: "/a"), tab: "assets")
    let plan = NavSpot(board: .plugin("plan"))

    @Test func backAndForwardWalkTheTrail() {
        var t = NavTrail()
        t.visit(a); t.visit(b); t.visit(plan)
        #expect(t.goBack() == b)
        #expect(t.goBack() == a)
        #expect(t.goBack() == nil)
        #expect(t.goForward() == b)
        #expect(t.goForward() == plan)
        #expect(t.goForward() == nil)
    }

    @Test func goingSomewhereNewDropsForward() {
        var t = NavTrail()
        t.visit(a); t.visit(b)
        _ = t.goBack()
        t.visit(plan)
        #expect(t.forward.isEmpty)
        #expect(t.goBack() == a)
    }

    @Test func theSameSpotTwiceIsOneStep() {
        var t = NavTrail()
        t.visit(a); t.visit(a)
        #expect(t.back.isEmpty)
    }

    @Test func goneSpotsAreSkipped() {
        var t = NavTrail()
        t.visit(a); t.visit(plan); t.visit(b)
        #expect(t.goBack(keep: { $0.board == nil }) == a)
        #expect(t.forward == [b])
    }

    @Test func theTrailKeepsFifty() {
        var t = NavTrail()
        for i in 0..<80 { t.visit(NavSpot(session: URL(fileURLWithPath: "/\(i)"))) }
        #expect(t.back.count == NavTrail.most)
    }
}
