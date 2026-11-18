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
                onVideoSize?(CGSize(width: Int(dims.width), height: Int(dims.height)))
            }
            waitingForKeyframe = false
        }
        // P-frames are useless until we have a keyframe to decode them against.
        guard !waitingForKeyframe, let formatDescription,
              let sample = Self.makeSampleBuffer(packet.avccData, format: formatDescription)
        else { return }
        displayLayer.enqueue(sample)
    }

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
