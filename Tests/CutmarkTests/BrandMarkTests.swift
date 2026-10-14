import Testing
@testable import Cutmark

@MainActor
@Suite struct BrandMarkTests {
    @Test func everyRealLogoDraws() {
        for name in ["linkedin", "x", "youtube", "tiktok", "instagram"] {
            #expect(BrandMark.image(name) != nil, "\(name)")
        }
        #expect(BrandMark.image("vertical") == nil)
    }
}
