import AppKit
import AVFoundation
import CoreMedia
import RDCore

/// A view backed by AVSampleBufferDisplayLayer, which decodes H.264 in
/// hardware and draws it. We only rebuild sample buffers from packets.
final class VideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var formatDescription: CMVideoFormatDescription?
    private var waitingForKeyframe = true

    /// Called when the view needs a fresh keyframe from the host.
    var onNeedKeyframe: (() -> Void)?
    /// Called when the stream's pixel size is first known or changes.
    var onVideoSize: ((CGSize) -> Void)?
    /// Called with each mouse/keyboard event to send to the host.
    var onInput: ((InputEvent) -> Void)?
    private var videoSize: CGSize?
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer = displayLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Must be called on the main thread.
    func display(_ packet: VideoFramePacket) {
        if displayLayer.status == .failed {
            displayLayer.flush()
            waitingForKeyframe = true
            onNeedKeyframe?()
        }

        if packet.isKeyframe, !packet.parameterSets.isEmpty {
            guard let format = Self.makeFormat(packet.parameterSets) else { return }
            if formatDescription == nil || !CMFormatDescriptionEqual(format, otherFormatDescription: formatDescription) {
                formatDescription = format
                let dims = CMVideoFormatDescriptionGetDimensions(format)
                let size = CGSize(width: Int(dims.width), height: Int(dims.height))
                videoSize = size
                onVideoSize?(size)
            }
            waitingForKeyframe = false
        }
        // P-frames are useless until we have a keyframe to decode them against.
        guard !waitingForKeyframe, let formatDescription,
              let sample = Self.makeSampleBuffer(packet.avccData, format: formatDescription)
        else { return }
        displayLayer.enqueue(sample)
    }

    // MARK: - Input capture

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Maps a window point to 0...1 across the video, which is letterboxed
    /// inside the view (aspect fit). Origin is top-left like the host's.
    private func normalized(_ event: NSEvent) -> (x: Float, y: Float)? {
        guard let videoSize else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let rect = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = (p.x - rect.minX) / rect.width
        let y = isFlipped ? (p.y - rect.minY) / rect.height : (rect.maxY - p.y) / rect.height
        return (Float(min(max(x, 0), 1)), Float(min(max(y, 0), 1)))
    }

    private func sendMove(_ event: NSEvent) {
        guard let p = normalized(event) else { return }
        onInput?(.mouseMove(x: p.x, y: p.y))
    }

    private func sendButton(_ button: MouseButton, down: Bool, _ event: NSEvent) {
        guard let p = normalized(event) else { return }
        let clicks = UInt8(clamping: max(1, event.clickCount))
        onInput?(.mouseButton(button: button, down: down, clickCount: clicks, x: p.x, y: p.y))
    }

    private func sendKey(_ event: NSEvent, down: Bool) {
        guard videoSize != nil else { return }
        let flags = UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
        onInput?(.key(keyCode: event.keyCode, down: down, flags: flags))
    }

    override func mouseMoved(with event: NSEvent) { sendMove(event) }
    override func mouseDragged(with event: NSEvent) { sendMove(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMove(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMove(event) }
    override func mouseDown(with event: NSEvent) { sendButton(.left, down: true, event) }
    override func mouseUp(with event: NSEvent) { sendButton(.left, down: false, event) }
    override func rightMouseDown(with event: NSEvent) { sendButton(.right, down: true, event) }
    override func rightMouseUp(with event: NSEvent) { sendButton(.right, down: false, event) }
    override func otherMouseDown(with event: NSEvent) { sendButton(.other, down: true, event) }
    override func otherMouseUp(with event: NSEvent) { sendButton(.other, down: false, event) }

    override func scrollWheel(with event: NSEvent) {
        guard videoSize != nil else { return }
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            // Classic mouse wheels report lines, not pixels.
            dx *= 10
            dy *= 10
        }
        onInput?(.scroll(dx: Float(dx), dy: Float(dy)))
    }

    override func keyDown(with event: NSEvent) { sendKey(event, down: true) }
    override func keyUp(with event: NSEvent) { sendKey(event, down: false) }

    override func flagsChanged(with event: NSEvent) {
        let flag: NSEvent.ModifierFlags
        switch event.keyCode {
        case 56, 60: flag = .shift
        case 59, 62: flag = .control
        case 58, 61: flag = .option
        case 54, 55: flag = .command
        case 57: flag = .capsLock
        case 63: flag = .function
        default: return
        }
        sendKey(event, down: event.modifierFlags.contains(flag))
    }

    /// Command-key combos such as Cmd+C arrive here instead of keyDown, and
    /// AppKit doesn't send their keyUp, so send press and release together.
    /// (macOS keeps system shortcuts like Cmd+Tab for itself.)
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard videoSize != nil, window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        sendKey(event, down: true)
        sendKey(event, down: false)
        return true
    }

    // MARK: - Decoding helpers

    private static func makeFormat(_ sets: [Data]) -> CMVideoFormatDescription? {
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: p, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: sets.count,
            parameterSetPointers: pointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }

    private static func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let length = data.count
        guard length > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        var sizes = [length]
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        // Show each frame as soon as it's decoded instead of scheduling by timestamp.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
