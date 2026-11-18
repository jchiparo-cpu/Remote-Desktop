import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures the main display with ScreenCaptureKit. ScreenCaptureKit only
/// delivers frames when something on screen changes, so an idle screen
/// costs almost nothing.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Config {
        var maxWidth: Int
        var framesPerSecond: Int
    }

    private(set) var width = 0
    private(set) var height = 0
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStop: ((Error) -> Void)?

    private let config: Config
    private let captureQueue = DispatchQueue(label: "rd.capture", qos: .userInteractive)
    private var stream: SCStream?

    init(config: Config) {
        self.config = config
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw NSError(domain: "rd-host", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        // display.width/height are in points; use the real pixel size, then
        // scale down to maxWidth to keep bandwidth reasonable.
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        var w = mode?.pixelWidth ?? display.width
        var h = mode?.pixelHeight ?? display.height
        if w > config.maxWidth {
            h = h * config.maxWidth / w
            w = config.maxWidth
        }
        width = w & ~1 // H.264 needs even dimensions
        height = h & ~1

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.framesPerSecond))
        streamConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        streamConfig.showsCursor = true
        streamConfig.queueDepth = 5

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only "complete" frames carry new pixels; idle/blank ones don't.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        onFrame?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
