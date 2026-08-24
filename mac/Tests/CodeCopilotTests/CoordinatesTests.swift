import CoreGraphics
import Testing

@testable import CodeCopilot

@Suite("Coordinate conversion")
struct CoordinatesTests {

    /// A 1440-point-tall primary display, the common case.
    let primary: CGFloat = 1440

    @Test("a rect at the top in AX space lands at the top in AppKit space")
    func topOfScreen() {
        // AX: 20 points down from the top, 100 tall.
        let ax = CGRect(x: 300, y: 20, width: 400, height: 100)
        let appKit = Coordinates.flip(ax, primaryHeight: primary)
        // AppKit measures up from the bottom: 1440 - 20 - 100 = 1320.
        #expect(appKit == CGRect(x: 300, y: 1320, width: 400, height: 100))
    }

    @Test("a rect at the bottom in AX space lands at the bottom in AppKit space")
    func bottomOfScreen() {
        let ax = CGRect(x: 0, y: 1340, width: 200, height: 100)
        let appKit = Coordinates.flip(ax, primaryHeight: primary)
        #expect(appKit.origin.y == 0)
    }

    @Test("flipping twice returns the original — the conversion is its own inverse")
    func involution() {
        let cases = [
            CGRect(x: 0, y: 0, width: 10, height: 10),
            CGRect(x: 812.5, y: 233.25, width: 91.5, height: 18.75),
            CGRect(x: -1920, y: 400, width: 300, height: 40),
        ]
        for rect in cases {
            let round = Coordinates.flip(
                Coordinates.flip(rect, primaryHeight: primary),
                primaryHeight: primary
            )
            #expect(round == rect)
        }
    }

    @Test("x is untouched, including a display left of the primary one")
    func negativeXSurvives() {
        // A second display to the left gives negative global x.
        let ax = CGRect(x: -1600, y: 100, width: 250, height: 30)
        #expect(Coordinates.flip(ax, primaryHeight: primary).origin.x == -1600)
    }

    @Test("a display above the primary one gives negative AX y, and still round-trips")
    func negativeYSurvives() {
        let ax = CGRect(x: 40, y: -900, width: 250, height: 30)
        let appKit = Coordinates.flip(ax, primaryHeight: primary)
        // Above the primary display's top edge, so beyond its height in AppKit space.
        #expect(appKit.origin.y == primary + 900 - 30)
        #expect(Coordinates.flip(appKit, primaryHeight: primary) == ax)
    }

    // MARK: - drawability

    let desktop = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    @Test("a normal rect is drawable")
    func drawable() {
        #expect(Coordinates.isDrawable(CGRect(x: 10, y: 10, width: 100, height: 20), within: desktop))
    }

    @Test("collapsed and hairline rects are refused")
    func rejectsDegenerate() {
        #expect(!Coordinates.isDrawable(.zero, within: desktop))
        #expect(!Coordinates.isDrawable(CGRect(x: 5, y: 5, width: 300, height: 0), within: desktop))
        #expect(!Coordinates.isDrawable(CGRect(x: 5, y: 5, width: 1, height: 1), within: desktop))
    }

    @Test("a rect scrolled far off the desktop is refused")
    func rejectsOffscreen() {
        #expect(!Coordinates.isDrawable(CGRect(x: 0, y: 90_000, width: 100, height: 20), within: desktop))
    }

    @Test("non-finite geometry is refused rather than drawn")
    func rejectsNonFinite() {
        #expect(!Coordinates.isDrawable(
            CGRect(x: CGFloat.nan, y: 10, width: 100, height: 20), within: desktop))
        #expect(!Coordinates.isDrawable(
            CGRect(x: 10, y: 10, width: CGFloat.infinity, height: 20), within: desktop))
    }

    @Test("a rect straddling the desktop edge is still drawable")
    func partiallyVisible() {
        #expect(Coordinates.isDrawable(
            CGRect(x: 2500, y: 700, width: 400, height: 30), within: desktop))
    }
}
