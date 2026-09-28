import Foundation
import VideoToolbox
import CoreMedia

/// What this Mac can actually decode, measured rather than assumed.
/// The 2017 iMac turns out to decode 5120x2880 HEVC in hardware, which a spec
/// sheet would not have told you — so the app asks VideoToolbox directly.
enum DecodeCapability {
    static let maxProbedWidth = 5120
    static let maxProbedHeight = 2880

    static func local() -> Capabilities {
        var codecs: [VideoCodec] = [.h264]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            codecs.append(.hevc)
        }
        // H.264 decode is fine well past 4K; the encoder is the side that
        // caps out, so advertise the HEVC ceiling when HEVC is available.
        let maxW = codecs.contains(.hevc) ? maxProbedWidth : 4096
        let maxH = codecs.contains(.hevc) ? maxProbedHeight : 2304
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return Capabilities(codecs: codecs.map(\.rawValue),
                            maxWidth: maxW, maxHeight: maxH,
                            appVersion: version)
    }
}

/// What this Mac can encode, again measured. Used to cap the resolution list.
enum EncodeCapability {
    private static var cache: [VideoCodec: (Int, Int)] = [:]

    /// Largest frame this Mac will hardware-encode with the given codec.
    /// Probed once by actually asking VideoToolbox to create a session.
    static func maxSize(for codec: VideoCodec) -> (width: Int, height: Int) {
        if let c = cache[codec] { return c }
        let candidates = [(7680, 4320), (6016, 3384), (5120, 2880), (4096, 2304), (3840, 2160), (1920, 1080)]
        let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var found = (1920, 1080)
        for (w, h) in candidates {
            if canEncode(type, w, h) { found = (w, h); break }
        }
        cache[codec] = found
        return found
    }

    private static func canEncode(_ type: CMVideoCodecType, _ w: Int, _ h: Int) -> Bool {
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        var session: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(w), height: Int32(h),
            codecType: type, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard st == noErr, let session else { return false }
        let ready = VTCompressionSessionPrepareToEncodeFrames(session) == noErr
        VTCompressionSessionInvalidate(session)
        return ready
    }

    static var supportsHEVC: Bool {
        let (w, _) = maxSize(for: .hevc)
        return w >= 3840
    }
}
