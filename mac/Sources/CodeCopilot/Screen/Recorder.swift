import CoreMedia
import CosmoRealtime
import Foundation
import ScreenCaptureKit

/// A continuous screen capture, published to the session so the recording
/// Cosmo keeps has picture as well as sound.
///
/// Separate from `Capture`, deliberately. That one takes a single still to
/// ground a `screen_locate` call and is sized for what the model reads —
/// `ImageDownscale.recommendedMaxLongEdge`, because pixels above a provider's
/// working resolution are discarded and cost latency the user hears as
/// silence. This is the opposite job: nobody's turn is waiting on it, it is
/// encoded by WebRTC rather than base64'd into a prompt, and it is meant to be
/// watched back by a person. So it captures at a legible size and a modest
/// frame rate, and shares none of that file's tuning.
public final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {

    /// Frames per second. Low on purpose: this records someone reading code on
    /// a mostly static page, where the interesting events are a scroll and a
    /// mark appearing. Screen content encodes cheaply when little moves, and a
    /// higher rate would spend bandwidth on nothing.
    static let framesPerSecond = 5

    /// Long edge for the recording. Large enough that code in the captured
    /// browser is readable on playback, which is the entire point of keeping
    /// it — a recording of unreadable text records nothing.
    static let maxLongEdge = 1920

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "codecopilot.recorder")
    /// Fed every frame. Held for the life of the capture.
    private var sink: (@Sendable (CMSampleBuffer) -> Void)?

    /// Begin capturing the main display. Throws if no display is available or
    /// Screen Recording permission is absent — the caller decides whether that
    /// is worth interrupting the session for. It is not.
    public func start(into sink: @escaping @Sendable (CMSampleBuffer) -> Void) async throws {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw ScreenCaptureUnavailable(message: "No display to record.")
        }

        let longEdge = Double(max(display.width, display.height))
        let scale = min(1.0, Double(Self.maxLongEdge) / longEdge)

        let config = SCStreamConfiguration()
        config.width = Int((Double(display.width) * scale).rounded())
        config.height = Int((Double(display.height) * scale).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.framesPerSecond))
        // The agent's own panel is in the recording too. That is deliberate:
        // played back, the transcript beside the code is what makes the walk
        // followable.
        config.showsCursor = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        self.sink = sink
        self.stream = stream
        try await stream.startCapture()
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        self.sink = nil
        try? await stream.stopCapture()
    }

    /// Size of what is being recorded, for the activity panel.
    public private(set) var describe: String = "not recording"

    // MARK: - SCStreamOutput

    public func stream(
        _ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard type == .screen, let sink else { return }
        // ScreenCaptureKit emits frames for status changes as well as content,
        // and an incomplete one has no image attached. Pushing it publishes a
        // blank frame rather than nothing.
        guard buffer.isValid, CMSampleBufferGetImageBuffer(buffer) != nil else { return }
        sink(buffer)
    }
}
