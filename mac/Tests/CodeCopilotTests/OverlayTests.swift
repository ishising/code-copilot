import AppKit
import CosmoRealtime
import Testing

@testable import CodeCopilot

/// Does the mark actually get drawn, and in the right place?
///
/// The failure this guards against is silent: the agent says "it's this file",
/// the highlight tool reports success, and nothing appears — or appears a
/// screen-height away from where it belongs.
@MainActor
@Suite("Overlay drawing")
struct OverlayTests {

    private func element(frame: CGRect) -> ScreenElement {
        ScreenElement(
            index: 0, role: "AXLink", title: "login.ts", label: nil, value: nil, frame: frame)
    }

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    @Test("a visible element is drawn, flipped into AppKit coordinates")
    func drawsVisibleElement() throws {
        try #require(primaryHeight > 0, "no display attached")
        let overlay = Overlay()
        defer { overlay.clear() }

        // 200 points down from the top of the screen in accessibility space.
        let ax = CGRect(x: 400, y: 200, width: 260, height: 22)
        let outcome = overlay.mark(element(frame: ax), label: "this one")

        #expect(outcome.shown, "refused to draw: \(outcome.reason ?? "no reason")")
        let drawn = try #require(overlay.lastDrawnFrame)
        #expect(drawn.origin.x == ax.origin.x)
        #expect(drawn.origin.y == primaryHeight - ax.origin.y - ax.height)
        #expect(drawn.size == ax.size)
    }

    @Test("an element scrolled off the desktop is refused, with a reason to say out loud")
    func refusesOffscreen() {
        let overlay = Overlay()
        defer { overlay.clear() }

        let outcome = overlay.mark(
            element(frame: CGRect(x: 0, y: 90_000, width: 200, height: 20)), label: "far away")

        #expect(!outcome.shown)
        #expect(outcome.reason?.isEmpty == false)
        #expect(overlay.lastDrawnFrame == nil)
    }

    @Test("a collapsed element is refused rather than drawn invisibly")
    func refusesCollapsed() {
        let overlay = Overlay()
        defer { overlay.clear() }
        let outcome = overlay.mark(
            element(frame: CGRect(x: 10, y: 10, width: 0, height: 0)), label: "nothing")
        #expect(!outcome.shown)
    }

    @Test("clearing removes the mark")
    func clears() throws {
        try #require(primaryHeight > 0, "no display attached")
        let overlay = Overlay()
        _ = overlay.mark(element(frame: CGRect(x: 100, y: 100, width: 200, height: 20)), label: "x")
        #expect(overlay.lastDrawnFrame != nil)
        overlay.clear()
        #expect(overlay.lastDrawnFrame == nil)
    }
}
