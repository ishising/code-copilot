import AppKit
import ApplicationServices
import CosmoRealtime
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The snapshot `cosmo_screen_locate` grounds against: a screenshot plus the
/// accessibility elements of whatever the user is looking at.
///
/// The server matches the model's description ("the file called login") against
/// both, and hands back a handle the renderer resolves. Pixels alone would put
/// us back where the browser version failed — a vision model guessing at
/// coordinates in a code listing. The element list is what makes it exact.
public enum Capture {

    /// Both permissions this needs, and whether they are granted.
    ///
    /// Neither can be granted from code — TCC requires the user to do it in
    /// System Settings — so the app's job is to say clearly which is missing.
    public struct Permissions: Sendable {
        public let screenRecording: Bool
        public let accessibility: Bool

        public var allGranted: Bool { screenRecording && accessibility }

        public var missingDescription: String {
            var missing: [String] = []
            if !screenRecording { missing.append("Screen Recording") }
            if !accessibility { missing.append("Accessibility") }
            return missing.joined(separator: " and ")
        }
    }

    public static func permissions() -> Permissions {
        Permissions(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted()
        )
    }

    /// Ask for both. Screen Recording shows a system prompt once; Accessibility
    /// opens System Settings, because macOS has no prompt for it.
    public static func requestPermissions() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !AXIsProcessTrusted() {
            // The literal key rather than `kAXTrustedCheckOptionPrompt`: that
            // symbol is a global `var`, which Swift 6 refuses to read across
            // concurrency domains. Its value is this string and is API-stable.
            let options = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
    }

    /// One snapshot for the locator.
    ///
    /// `request.wantsElements` is honoured rather than ignored: a pixels-only
    /// capture must not pay for the accessibility walk, which is the expensive
    /// half and the one that can stall a conversation.
    public static func snapshot(_ request: ScreenCaptureRequest) async throws -> ScreenCapture {
        let granted = permissions()
        guard granted.screenRecording else {
            // A benign decline: the agent hears the reason and can say it out
            // loud, rather than the session dying on an unexpected throw.
            throw ScreenCaptureUnavailable(
                message: "I don't have Screen Recording permission yet — grant it to "
                    + "Code Copilot in System Settings under Privacy & Security, then "
                    + "restart me.")
        }

        let target = await MainActor.run { subject() }
        let pid = target?.processIdentifier

        let jpeg = try await screenshot()

        var elements: [ScreenElement] = []
        if request.wantsElements {
            guard granted.accessibility else {
                throw ScreenCaptureUnavailable(
                    message: "I can see the screen but not read it — grant Accessibility "
                        + "to Code Copilot in System Settings, then restart me. Without it "
                        + "I can't point at anything reliably.")
            }
            if let pid { elements = AXWalk.elements(forPID: pid) }

            // A browser that answers about its toolbar but exposes no page is
            // the single most confusing failure here: the capture "works",
            // returns elements, and none of them are the user's code. Chrome
            // is in this state by default. Say so rather than letting the
            // agent quietly fall back to describing things in words.
            let name = target?.localizedName ?? ""
            let isBrowser = ["Chrome", "Edge", "Brave", "Arc", "Vivaldi", "Opera"]
                .contains { name.contains($0) }
            if isBrowser && !AXWalk.sawWebContent {
                throw ScreenCaptureUnavailable(
                    message: "\(name) isn't letting me read the page — only its toolbar. "
                        + "It needs to be started with accessibility enabled. Tell the user "
                        + "to quit \(name) and reopen it by running chrome-with-accessibility.sh, "
                        + "or to use Safari instead, which needs no such thing.")
            }
        }

        let name = target?.localizedName ?? "an unknown app"
        await MainActor.run {
            lastLook = request.wantsElements
                ? "looked at \(name) — \(elements.count) things it can point at (\(lastShot))"
                : "looked at \(name) — image only (\(lastShot))"
        }

        return ScreenCapture(
            imageJPEG: jpeg,
            elements: elements,
            // Carried so a handle minted against this snapshot can be refused
            // if the user has since switched to another app — a mark drawn
            // into the wrong window is worse than no mark.
            context: ScreenCaptureContext(appPID: pid, windowFrame: focusedWindowFrame(pid: pid))
        )
    }

    /// Which application the agent is actually looking at.
    ///
    /// Not simply `frontmostApplication`: this app has a window of its own,
    /// and the moment the user clicks the panel — or right after launch — we
    /// are frontmost. Walking our own accessibility tree finds none of their
    /// code, so the agent has nothing to point at and silently falls back to
    /// describing things in words.
    ///
    /// So: the frontmost application unless that is us, in which case the most
    /// recently active other application.
    @MainActor
    static func subject() -> NSRunningApplication? {
        let mine = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
            front.processIdentifier != mine
        {
            return front
        }
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != mine }
            .max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) })
    }

    /// What the last capture saw, for the activity panel. A look that found
    /// nothing is otherwise indistinguishable from a look that never happened.
    @MainActor
    public private(set) static var lastLook: String = "nothing yet"

    // MARK: - pixels

    private static func screenshot() async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw ScreenCaptureUnavailable(message: "No display to capture.")
        }

        // Capture at the size the model actually looks at, not the size of the
        // display. The SDK is explicit about this: "both providers normalize a
        // frame before they look at it, so pixels above their working
        // resolution are discarded — they buy no comprehension and cost
        // bandwidth, chunking round-trips, and base64's 4/3 inflation."
        //
        // Capturing a Retina display at full resolution meant sending roughly
        // seven times the pixels the model would keep, on every look, while the
        // conversation waited. `ImageDownscale.recommendedMaxLongEdge` is 1280.
        //
        // The precise pointing does not depend on these pixels — the
        // accessibility element list carries the exact frames. The image is for
        // context. If grounding ever suffers, raise this deliberately and
        // measure, which is what the SDK advises.
        let longEdge = Double(max(display.width, display.height))
        let scale = min(1.0, Double(ImageDownscale.recommendedMaxLongEdge) / longEdge)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int((Double(display.width) * scale).rounded())
        config.height = Int((Double(display.height) * scale).rounded())

        let started = Date()
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)

        guard let data = jpeg(from: image, quality: ImageDownscale.recommendedQuality) else {
            throw ScreenCaptureUnavailable(message: "Could not encode the screenshot.")
        }

        let elapsed = Date().timeIntervalSince(started)
        await MainActor.run {
            lastShot = String(
                format: "%dx%d, %.0f KB, %.1fs",
                config.width, config.height, Double(data.count) / 1024, elapsed)
        }
        return data
    }

    /// Size and cost of the last screenshot, for the activity panel. Latency
    /// here is felt as the agent going silent mid-conversation, so it should be
    /// visible rather than guessed at.
    @MainActor
    public private(set) static var lastShot: String = "none yet"

    private static func jpeg(from image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    // MARK: - freshness

    /// The focused window's frame in top-left global points, matching the
    /// space `ScreenElement.frame` uses.
    private static func focusedWindowFrame(pid: pid_t?) -> CGRect? {
        guard let pid, AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                app, kAXFocusedWindowAttribute as CFString, &window) == .success,
            let focused = window
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focused as! AXUIElement, kAXPositionAttribute as CFString, &raw) == .success,
            let raw
        {
            AXValueGetValue(raw as! AXValue, .cgPoint, &origin)
        }
        raw = nil
        if AXUIElementCopyAttributeValue(
            focused as! AXUIElement, kAXSizeAttribute as CFString, &raw) == .success,
            let raw
        {
            AXValueGetValue(raw as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }
}
