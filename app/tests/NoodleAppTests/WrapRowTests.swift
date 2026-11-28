import CoreGraphics
import Testing
@testable import NoodleApp

@Suite struct WrapRowTests {
    @Test func wrapsWhenTheNextItemWouldOverflow() {
        let sizes = [CGSize(width: 40, height: 20), CGSize(width: 40, height: 10), CGSize(width: 40, height: 20)]
        let frames = WrapRow.frames(sizes, width: 90, spacing: 5, lineSpacing: 4)
        #expect(frames[0] == CGRect(x: 0, y: 0, width: 40, height: 20))
        #expect(frames[1] == CGRect(x: 45, y: 5, width: 40, height: 10), "centred in the line")
        #expect(frames[2] == CGRect(x: 0, y: 24, width: 40, height: 20), "moved to a second line")
    }

    @Test func anItemWiderThanTheRowGetsItsOwnLine() {
        let frames = WrapRow.frames([CGSize(width: 200, height: 10), CGSize(width: 10, height: 10)], width: 50, spacing: 5, lineSpacing: 0)
        #expect(frames.map(\.minY) == [0, 10])
    }
}
