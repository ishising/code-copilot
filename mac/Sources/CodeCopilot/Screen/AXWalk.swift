import ApplicationServices
import CoreGraphics
import CosmoRealtime

/// Reading the frontmost window's accessibility tree into the element list
/// `cosmo_screen_locate` grounds against.
///
/// This is the half that makes pointing at a GitHub tab work at all. A vision
/// model asked to find `auth.ts` in a screenshot of a file listing is guessing
/// at pixels; the accessibility tree simply *says* where that row is, with a
/// role and a frame. Browsers publish their whole rendered page through it.
///
/// The traversal itself needs a live app and cannot be unit tested, so every
/// decision it makes — what to keep, how to clamp it — lives in ``AXFilter``,
/// which can.
public enum AXWalk {

    /// A GitHub page is thousands of nodes deep in places. These caps keep one
    /// capture inside a conversational beat; without them the agent goes quiet
    /// mid-sentence while we enumerate a diff.
    public static let maxElements = 300
    public static let maxDepth = 40

    /// Elements of the frontmost window, in screen points with a top-left
    /// origin — the space `ScreenElement.frame` is documented in.
    ///
    /// Returns an empty list rather than throwing when the app publishes no
    /// usable tree: the caller still has a screenshot, and a capture with
    /// pixels but no elements is a worse locator, not a failed one.
    /// Whether the last walk found rendered web content.
    ///
    /// Chrome answers accessibility queries about its own toolbar and tabs
    /// whether or not the renderer is exposing anything, so "we got elements"
    /// is not the same as "we can see the page". Measured, and confirmed on
    /// this machine: a normal Chrome window yields ~58 nodes and no
    /// `AXWebArea`; the same page with `--force-renderer-accessibility`
    /// yields ~1,640 including 163 links and 38 rows.
    public private(set) nonisolated(unsafe) static var sawWebContent = false

    public static func elements(forPID pid: pid_t) -> [ScreenElement] {
        sawWebContent = false
        let app = AXUIElementCreateApplication(pid)
        requestWebAccessibility(app)

        guard let window = copy(app, kAXFocusedWindowAttribute) else { return [] }

        var out: [ScreenElement] = []
        visit(window as! AXUIElement, depth: 0, into: &out)

        // Chrome builds its tree lazily after being asked, so the first look
        // can come back empty even though the second will not. One short retry
        // is the difference between "Chrome is unsupported" and "Chrome needed
        // a moment".
        if out.isEmpty {
            Thread.sleep(forTimeInterval: 0.4)
            if let retry = copy(app, kAXFocusedWindowAttribute) {
                visit(retry as! AXUIElement, depth: 0, into: &out)
            }
        }
        return out
    }

    /// Ask a browser to turn its accessibility engine on.
    ///
    /// Chrome — and every Electron app — keeps the tree of its *web content*
    /// switched off until an assistive client asks for it, because building it
    /// costs memory. Without this the walk finds a window, a toolbar, and
    /// nothing of the page, so there is nothing on GitHub to point at and the
    /// agent falls back to describing things in words.
    ///
    /// Safari needs none of this, which is exactly why building against Safari
    /// hid the problem.
    ///
    /// Harmless where it is not understood: setting an unknown attribute on an
    /// app that ignores it fails quietly, and the result is unused.
    private static func requestWebAccessibility(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(
            app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // The older attribute VoiceOver sets; some Electron builds watch for
        // this one instead.
        AXUIElementSetAttributeValue(
            app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// The focused element and any selected text — what the user is pointing
    /// at. This is what turns "what's this?" from a guess into a fact.
    public static func focus(forPID pid: pid_t) -> (element: ScreenElement?, selectedText: String?) {
        let app = AXUIElementCreateApplication(pid)
        guard let focused = copy(app, kAXFocusedUIElementAttribute) else { return (nil, nil) }
        let element = focused as! AXUIElement

        let selected = string(element, kAXSelectedTextAttribute)
        return (describe(element, index: 0), selected?.isEmpty == false ? selected : nil)
    }

    // MARK: - traversal

    private static func visit(_ element: AXUIElement, depth: Int, into out: inout [ScreenElement]) {
        guard depth <= maxDepth, out.count < maxElements else { return }

        if let role = string(element, kAXRoleAttribute), role == "AXWebArea" {
            sawWebContent = true
        }

        if let described = describe(element, index: out.count),
            AXFilter.isWorthKeeping(role: described.role, frame: described.frame)
        {
            out.append(described)
        }

        guard let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children {
            if out.count >= maxElements { return }
            visit(child, depth: depth + 1, into: &out)
        }
    }

    private static func describe(_ element: AXUIElement, index: Int) -> ScreenElement? {
        guard let role = string(element, kAXRoleAttribute) else { return nil }
        let descriptors = AXFilter.clamp(
            role: role,
            title: string(element, kAXTitleAttribute),
            label: string(element, kAXDescriptionAttribute),
            value: string(element, kAXValueAttribute)
        )
        return ScreenElement(
            index: index,
            role: descriptors.role,
            title: descriptors.title,
            label: descriptors.label,
            value: descriptors.value,
            frame: frame(of: element)
        )
    }

    /// `AXPosition` is already top-left origin in global screen points, which
    /// is the space `ScreenElement.frame` wants — so nothing is flipped here.
    /// The flip happens once, at draw time, in ``Coordinates``.
    private static func frame(of element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let raw = copy(element, kAXPositionAttribute) {
            AXValueGetValue(raw as! AXValue, .cgPoint, &origin)
        }
        if let raw = copy(element, kAXSizeAttribute) {
            AXValueGetValue(raw as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - attribute plumbing

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }
}

/// Every judgement the walk makes, separated from the walk so it can be
/// tested without a running application.
public enum AXFilter {

    /// The SDK's descriptor budgets, mirroring the backend's `AXElement`. A
    /// descriptor is a *name* for a target; anything longer is a document the
    /// screenshot already shows.
    public static let roleMaxChars = 64
    public static let labelMaxChars = 512
    public static let valueMaxChars = 256

    /// Roles that can plausibly be pointed at on a web page. Everything else
    /// is layout scaffolding — keeping it crowds out the rows and links the
    /// model actually needs, since the element budget is finite.
    static let keepRoles: Set<String> = [
        "AXLink", "AXButton", "AXStaticText", "AXTextField", "AXTextArea",
        "AXRow", "AXCell", "AXHeading", "AXCheckBox", "AXPopUpButton",
        "AXMenuItem", "AXDisclosureTriangle", "AXImage", "AXTabButton",
        "AXRadioButton", "AXSearchField", "AXList",
    ]

    public static func isWorthKeeping(role: String, frame: CGRect) -> Bool {
        guard keepRoles.contains(role) else { return false }
        // A collapsed or zero-sized node cannot be marked, so carrying it only
        // spends budget the visible elements need.
        return frame.width > 1 && frame.height > 1
    }

    /// Clamp descriptors to the wire budgets, and drop empties so an element
    /// carries `nil` rather than `""` — the difference between "no title" and
    /// "a title that is blank" matters to the locator's matching.
    public static func clamp(
        role: String,
        title: String?,
        label: String?,
        value: String?
    ) -> (role: String, title: String?, label: String?, value: String?) {
        (
            role: String(role.prefix(roleMaxChars)),
            title: trimmed(title, to: labelMaxChars),
            label: trimmed(label, to: labelMaxChars),
            value: trimmed(value, to: valueMaxChars)
        )
    }

    private static func trimmed(_ text: String?, to limit: Int) -> String? {
        guard let text else { return nil }
        let squashed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !squashed.isEmpty else { return nil }
        return String(squashed.prefix(limit))
    }
}
