import Testing
@testable import Cutmark

struct EditTimeMapTests {
    @Test func multipleSourcesReuseAndLeadShareOneClock() throws {
        let screen = EditTimeMap.Source(take: 2, kind: .screen)
        let camera = EditTimeMap.Source(take: 1, kind: .camera)
        let map = EditTimeMap(cuts: [
            .init(source: screen, in: 5, out: 7),
            .init(source: camera, in: 1, out: 4),
            .init(source: screen, in: 5.5, out: 6.5),
        ], lead: 0.1)

        #expect(map.spans.map(\.outputStart) == [0.1, 2.1, 5.1])
        #expect(abs(map.duration - 6.1) < 0.0001)
        #expect(map.outputTimes(source: screen, time: 6).map { ($0 * 10).rounded() / 10 } == [1.1, 5.6])
        let source = try #require(map.source(at: 3.1))
        #expect(source.source == camera)
        #expect(abs(source.time - 2) < 0.0001)
        let boundary = try #require(map.source(at: 2.1))
        #expect(boundary.source == camera && abs(boundary.time - 1) < 0.0001)
        #expect(map.outputTimes(source: screen, time: 7).isEmpty) // first span's end belongs to the next output span
        #expect(map.source(at: 0.05) == nil)
    }

    @Test func rateChangesOnlyOutputClock() throws {
        let source = EditTimeMap.Source(take: 1, kind: .camera)
        let map = EditTimeMap(cuts: [.init(source: source, in: 2, out: 6, rate: 2)])
        #expect(abs(map.duration - 2) < 0.0001)
        #expect(map.outputTimes(source: source, time: 4) == [1])
        let back = try #require(map.source(at: 1.5))
        #expect(abs(back.time - 5) < 0.0001)
    }
}
