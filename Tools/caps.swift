import Foundation
import VideoToolbox
import CoreMedia

let sizes: [(String, Int, Int)] = [
    ("1080p",      1920, 1080),
    ("1440p",      2560, 1440),
    ("4K UHD",     3840, 2160),
    ("4096x2304",  4096, 2304),
    ("4480x2520",  4480, 2520),
    ("5K",         5120, 2880),
    ("6K",         6016, 3384),
    ("8K",         7680, 4320),
]
let codecs: [(String, CMVideoCodecType)] = [
    ("H.264", kCMVideoCodecType_H264),
    ("HEVC",  kCMVideoCodecType_HEVC),
]

func tryEncode(_ codec: CMVideoCodecType, _ w: Int, _ h: Int, hw: Bool) -> (Bool, Int32, Bool) {
    var spec: [CFString: Any] = [:]
    if hw {
        spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
    }
    var s: VTCompressionSession?
    let st = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault, width: Int32(w), height: Int32(h),
        codecType: codec, encoderSpecification: spec.isEmpty ? nil : spec as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &s)
    guard st == noErr, let s else { return (false, st, false) }
    // Confirm it really is hardware, not a software fallback.
    var isHW: CFTypeRef?
    VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                          allocator: kCFAllocatorDefault, valueOut: &isHW)
    let hardware = (isHW as? Bool) ?? false
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    let prep = VTCompressionSessionPrepareToEncodeFrames(s)
    VTCompressionSessionInvalidate(s)
    return (prep == noErr, prep, hardware)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
print("=== ENCODE capability on this Mac ===")
print(pad("size", 18) + pad("codec", 8) + pad("hw-only", 14) + "any")
for (name, w, h) in sizes {
    for (cname, codec) in codecs {
        let (okHW, stHW, isHW) = tryEncode(codec, w, h, hw: true)
        let (okAny, stAny, _)  = tryEncode(codec, w, h, hw: false)
        let hwTxt  = okHW  ? (isHW ? "YES hw" : "YES (sw?)") : "no (\(stHW))"
        let anyTxt = okAny ? "YES" : "no (\(stAny))"
        print(pad("\(name) \(w)x\(h)", 18) + pad(cname, 8) + pad(hwTxt, 14) + anyTxt)
    }
}
