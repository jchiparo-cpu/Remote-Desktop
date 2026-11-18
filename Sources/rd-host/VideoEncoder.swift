import CoreMedia
import Foundation
import RDCore
import VideoToolbox

/// Hardware H.264 encoder tuned for low latency (no B-frames, real-time mode).
final class VideoEncoder {
    struct Config {
        var width: Int
        var height: Int
        var bitrate: Int
        var framesPerSecond: Int
    }

    /// Called on a VideoToolbox thread once per submitted frame: the encoded
    /// packet, or nil if that frame failed or was dropped by the encoder.
    var onPacket: ((VideoFramePacket?) -> Void)?
    private var session: VTCompressionSession?

    init(config: Config) throws {
        var session: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(config.width),
            height: Int32(config.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not create H.264 encoder (\(status))"])
        }

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: config.bitrate))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: config.framesPerSecond))
        // Periodic keyframes let a client recover from loss even if it never asks.
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 10))
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, forceKeyframe: Bool) {
        guard let session else { return }
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        let options = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: options,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else {
                self?.onPacket?(nil)
                return
            }
            self?.onPacket?(Self.packet(from: sampleBuffer))
        }
    }

    private static func packet(from sampleBuffer: CMSampleBuffer) -> VideoFramePacket? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        var parameterSets: [Data] = []
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if st == noErr, let pointer {
                    parameterSets.append(Data(bytes: pointer, count: size))
                }
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000)) : 0
        return VideoFramePacket(
            isKeyframe: isKeyframe,
            presentationTimeMicros: micros,
            parameterSets: parameterSets,
            avccData: data
        )
    }
}
