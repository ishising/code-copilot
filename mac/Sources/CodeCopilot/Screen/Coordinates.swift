import CoreGraphics

/// Converting between the two coordinate spaces macOS hands you.
///
/// The accessibility API — and therefore `ScreenElement.frame`, which the SDK
/// documents as "screen points (top-left origin)" — measures down from the
/// top-left corner of the primary display. AppKit measures **up** from that
/// display's bottom-left corner. Both are global spaces spanning every
/// display, and both are anchored to the primary display, which is why one
/// number (its height) converts between them.
///
/// Getting this wrong does not fail loudly. The mark lands on screen, looks
/// deliberate, and is wrong by most of a screen height — so this lives in its
/// own file as a pure function and is tested before anything draws.
public enum Coordinates {

    /// Flip a rectangle between top-left-origin and bottom-left-origin space.
    ///
    /// The conversion is its own inverse: applying it twice returns the
    /// original rectangle, which is what makes it safe to use in both
    /// directions.
    ///
    /// - Parameters:
    ///   - rect: the rectangle to convert, in either space.
    ///   - primaryHeight: height in points of the display whose origin is
    ///     `(0, 0)` — the one carrying the menu bar, `NSScreen.screens.first`.
    ///     Passed in rather than read here so the maths can be tested without
    ///     a display attached.
    public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Whether a rectangle is worth drawing: real area, finite numbers, and
    /// somewhere within the desktop's bounds.
    ///
    /// The accessibility tree readily reports zero-sized frames for collapsed
    /// nodes and wildly out-of-range ones for elements scrolled far out of
    /// view. Drawing those produces an invisible mark or one stranded off in
    /// the corner, both of which read to the user as "it didn't point".
    public static func isDrawable(_ rect: CGRect, within desktop: CGRect) -> Bool {
        guard rect.width > 1, rect.height > 1 else { return false }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite else { return false }
        guard rect.width.isFinite, rect.height.isFinite else { return false }
        return desktop.intersects(rect)
    }
}
