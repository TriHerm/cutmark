import AppKit
import SwiftUI
import Testing
@testable import Cutmark

@MainActor
struct AboutTests {
    @Test func identityPointsAtCutmarkAndTriHermLabs() {
        #expect(About.repo.absoluteString == "https://github.com/TriHerm/cutmark")
        #expect(Product.organization == "TriHerm Labs")
        #expect(Product.creator == "Fernando Abishai")
        #expect(BrandMark.image("github") != nil)
    }
}
