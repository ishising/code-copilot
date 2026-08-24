import AppKit
import CosmoRealtime

/// The mark, drawn on the real screen.
///
/// This is the thing a browser cannot do, and the whole reason for a native
/// app: a transparent, click-through window floating above every other
/// application, including Safari showing GitHub.
///
/// It never clicks. `cosmo_sdk_screen_highlight_element` is documented as "the
/// pointing sibling of `ScreenClickTool` — it marks the control and stops
/// there, so the user does the acting", which is exactly the arrangement
/// asked for: show me where, I'll click it.
@MainActor
public final class Overlay {

    /// Long enough to look where it pointed while it is still talking, short
    /// enough that a stale mark never outlives the moment it referred to.
    private static let lifetime: TimeInterval = 20

    private var window: NSWindow?
    private var dismiss: Task<Void, Never>?

    /// Where the last mark was drawn, in AppKit coordinates. Exposed because
    /// "did it draw, and where" is otherwise only answerable by looking at the
    /// screen — which is exactly what fails silently.
    public private(set) var lastDrawnFrame: CGRect?

    public init() {}

    /// The union of every display, used to reject frames that are scrolled far
    /// out of view before we draw somewhere nobody is looking.
    private var desktop: CGRect {
        NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    }

    /// Height of the display whose origin is (0, 0) — the one carrying the
    /// menu bar. This single number converts accessibility's top-left origin
    /// into AppKit's bottom-left one.
    private var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Mark an element the locator found. Returns false with a reason the
    /// agent can say out loud, rather than silently drawing nothing.
    @discardableResult
    public func mark(_ element: ScreenElement, label: String) -> (shown: Bool, reason: String?) {
        let flipped = Coordinates.flip(element.frame, primaryHeight: primaryHeight)
        guard Coordinates.isDrawable(flipped, within: desktop) else {
            return (
                false,
                "that element isn't visible on screen right now — ask them to scroll to it"
            )
        }
        draw(flipped, label: label)
        return (true, nil)
    }

    public func clear() {
        dismiss?.cancel()
        dismiss = nil
        window?.orderOut(nil)
        window = nil
        lastDrawnFrame = nil
    }

    // MARK: - drawing

    private func draw(_ rect: CGRect, label: String) {
        clear()

        // Padded so the border and the caption above it are inside the window;
        // a window sized exactly to the element clips both.
        let padding = NSEdgeInsets(top: 34, left: 6, bottom: 6, right: 6)
        let frame = CGRect(
            x: rect.minX - padding.left,
            y: rect.minY - padding.bottom,
            width: rect.width + padding.left + padding.right,
            height: rect.height + padding.top + padding.bottom
        )

        let panel = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above normal windows and full-screen apps, but click-through: the
        // user must be able to click the thing we are pointing at.
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let view = MarkView(
            frame: CGRect(origin: .zero, size: frame.size),
            target: CGRect(
                x: padding.left, y: padding.bottom, width: rect.width, height: rect.height),
            label: label
        )
        panel.contentView = view
        panel.orderFrontRegardless()
        window = panel
        lastDrawnFrame = rect

        dismiss = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Overlay.lifetime))
            guard !Task.isCancelled else { return }
            self?.clear()
        }
    }
}

/// The mark itself: a rounded outline around the element, with the caption
/// above it rather than over it — an overlay covers the very thing it is
/// drawing attention to.
private final class MarkView: NSView {
    private let target: CGRect
    private let label: String

    init(frame: CGRect, target: CGRect, label: String) {
        self.target = target
        self.label = label
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let amber = NSColor(calibratedRed: 1.0, green: 0.83, blue: 0.47, alpha: 1)

        let outline = NSBezierPath(roundedRect: target.insetBy(dx: -3, dy: -3), xRadius: 5, yRadius: 5)
        outline.lineWidth = 2.5
        amber.setStroke()
        outline.stroke()

        NSColor(calibratedRed: 1.0, green: 0.83, blue: 0.47, alpha: 0.13).setFill()
        outline.fill()

        guard !label.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor(calibratedRed: 0.1, green: 0.07, blue: 0, alpha: 1),
        ]
        let text = label as NSString
        let size = text.size(withAttributes: attributes)
        let caption = CGRect(
            x: target.minX - 3,
            y: min(target.maxY + 9, bounds.maxY - size.height - 5),
            width: size.width + 14,
            height: size.height + 5
        )

        amber.setFill()
        NSBezierPath(roundedRect: caption, xRadius: 4, yRadius: 4).fill()
        text.draw(
            at: CGPoint(x: caption.minX + 7, y: caption.minY + 2), withAttributes: attributes)
    }
}
