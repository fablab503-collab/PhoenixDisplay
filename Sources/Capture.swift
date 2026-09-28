import Foundation
import ScreenCaptureKit
import CoreMedia
import VideoToolbox
import CoreVideo

/// Captures one CGDirectDisplay with ScreenCaptureKit.
/// Reports permission failures as text instead of dying silently.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private(set) var capturedDisplayID: CGDirectDisplayID = 0
    private let queue = DispatchQueue(label: "phoenix.capture")

    var onFrame: ((CMSampleBuffer) -> Void)?
    var onError: ((String) -> Void)?

    /// Starts capture. `displayID` 0 means the main display.
    /// Creating a virtual display leaves the display configuration in flux for
    /// a moment; ScreenCaptureKit asked too early returns an empty content list
    /// and the stream dies with "Failed to find any displays or windows to
    /// capture". So the content list is re-read until the display shows up.
    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async {
        stop()
        var lastProblem = "no displays were offered for capture"
        for attempt in 0..<12 {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
                if content.displays.isEmpty {
                    lastProblem = "ScreenCaptureKit offered no displays at all"
                } else {
                    let target: SCDisplay? = displayID == 0
                        ? content.displays.first
                        : content.displays.first { $0.displayID == displayID }
                    if let display = target {
                        await begin(display: display, width: width, height: height, fps: fps)
                        return
                    }
                    let offered = content.displays.map { String($0.displayID) }.joined(separator: ", ")
                    lastProblem = "display \(displayID) is not capturable yet (ScreenCaptureKit offers: \(offered))"
                }
            } catch {
                lastProblem = Self.explain(error)
                // A permission failure will never fix itself by retrying.
                if lastProblem.contains("Screen Recording") { onError?(lastProblem); return }
            }
            try? await Task.sleep(nanoseconds: UInt64(120_000_000 + attempt * 60_000_000))
        }
        onError?(lastProblem)
    }

    private func begin(display: SCDisplay, width: Int, height: Int, fps: Int) async {
        do {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width  = width
            cfg.height = height
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            cfg.queueDepth = 6
            cfg.showsCursor = true
            cfg.scalesToFit = true

            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            capturedDisplayID = display.displayID
        } catch {
            onError?(Self.explain(error))
        }
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        Task { try? await s.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only complete frames carry an image buffer.
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        onFrame?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(Self.explain(error))
    }

    /// ScreenCaptureKit's permission error is opaque; say what to do about it.
    static func explain(_ error: Error) -> String {
        let ns = error as NSError
        let text = ns.localizedDescription
        if text.contains("TCC") || text.contains("declined") || ns.code == -3801 {
            return "Screen Recording permission is off for Phoenix Display. Turn it on in System Settings ▸ Privacy & Security ▸ Screen Recording, then reopen the app."
        }
        return text
    }
}

/// Hardware video encoder. H.264 stops at 4096x2304 on Apple silicon, which is
/// why a real 5K desktop needs HEVC — measured, not assumed, in EncodeCapability.
final class VideoEncoder: @unchecked Sendable {
    static let maxWidth  = 4096      // H.264 ceiling, kept for the H.264 path
    static let maxHeight = 2304

    private(set) var codec: VideoCodec = .h264

    private var session: VTCompressionSession?
    private var lastKeyframe = Date.distantPast
    /// Set when a viewer attaches so it gets a picture immediately.
    var forceNextKeyframe = true

    var onFormat: ((Data) -> Void)?             // parameter sets
    var onFrame: ((Data, Bool) -> Void)?        // AU + isKeyframe
    var onError: ((String) -> Void)?

    private var sentFormat = false

    func start(width: Int, height: Int, fps: Int, bitrate: Int, codec: VideoCodec) {
        stop()
        self.codec = codec
        var s: VTCompressionSession?
        let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: type,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let session = s else {
            onError?("The \(codec.displayName) encoder refused \(width)×\(height) (status \(status)).")
            return
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel
                                                   : kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 8) as CFNumber)
        // Tag colour explicitly. HEVC range/matrix defaults differ between an
        // Apple silicon encoder and an older Intel decoder, and the result is a
        // washed-out desktop that looks like a gamma bug.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries,
                             value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction,
                             value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix,
                             value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        // Cap bursts so a keyframe can't blow the link out and stall the stream.
        // 1.8x the average over one second: enough headroom for a keyframe
        // without letting a burst swamp the link.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [NSNumber(value: Int(Double(bitrate) * 1.8 / 8.0)),
                                     NSNumber(value: 1.0)] as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                             value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        sentFormat = false
        forceNextKeyframe = true
    }

    func stop() {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
        session = nil
        sentFormat = false
    }

    func encode(_ sample: CMSampleBuffer) {
        guard let session, let image = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        // Force a keyframe every couple of seconds so a receiver that joins
        // late gets a picture quickly.
        var props: CFDictionary? = nil
        if forceNextKeyframe || Date().timeIntervalSince(lastKeyframe) > 8 {
            forceNextKeyframe = false
            lastKeyframe = Date()
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(session, imageBuffer: image,
                                        presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, buffer in
            guard let self, status == noErr, let buffer else { return }
            self.handle(buffer)
        }
    }

    private func handle(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }

        if !sentFormat, let desc = CMSampleBufferGetFormatDescription(sample) {
            // HEVC carries VPS, SPS and PPS — three sets, not two.
            let sets = codec == .hevc ? Self.hevcParameterSets(desc) : Self.h264ParameterSets(desc)
            if !sets.isEmpty { onFormat?(ParameterSets.encode(sets)); sentFormat = true }
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>? = nil
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer else { return }

        let isKey = Self.isKeyframe(sample)
        onFrame?(Data(bytes: dataPointer, count: length), isKey)
    }

    private static func h264ParameterSets(_ desc: CMFormatDescription) -> [Data] {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(desc, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>? = nil
            var size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(desc, parameterSetIndex: i,
                   parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                   parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                sets.append(Data(bytes: ptr, count: size))
            }
        }
        return sets
    }

    private static func hevcParameterSets(_ desc: CMFormatDescription) -> [Data] {
        var count = 0
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(desc, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>? = nil
            var size = 0
            if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(desc, parameterSetIndex: i,
                   parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                   parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                sets.append(Data(bytes: ptr, count: size))
            }
        }
        return sets
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else { return true }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        guard let raw = CFDictionaryGetValue(dict as CFDictionary, key) else { return true }
        return !CFBooleanGetValue(unsafeBitCast(raw, to: CFBoolean.self))
    }
}
