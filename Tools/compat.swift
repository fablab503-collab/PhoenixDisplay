// Phoenix Display compatibility probe.
// Run on ANY Mac to find out exactly what it can do as a sender and a receiver.
// Nothing here is taken from a spec sheet — every answer is measured.
import Foundation
import VideoToolbox
import CoreMedia
import CoreGraphics

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func line(_ c: String = "-") { print(String(repeating: c, count: 64)) }

let sizes: [(String, Int, Int)] = [
    ("1280x720", 1280, 720), ("1920x1080", 1920, 1080), ("2560x1440", 2560, 1440),
    ("3840x2160", 3840, 2160), ("4096x2304", 4096, 2304), ("5120x2880", 5120, 2880),
]

func canEncode(_ codec: CMVideoCodecType, _ w: Int, _ h: Int) -> Bool {
    let spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    var s: VTCompressionSession?
    guard VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(w), height: Int32(h),
            codecType: codec, encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &s) == noErr, let s else { return false }
    let ok = VTCompressionSessionPrepareToEncodeFrames(s) == noErr
    VTCompressionSessionInvalidate(s)
    return ok
}

var model = [CChar](repeating: 0, count: 64); var len = 64
sysctlbyname("hw.model", &model, &len, nil, 0)
let os = ProcessInfo.processInfo.operatingSystemVersion

line("=")
print("Phoenix Display - compatibility probe")
line("=")
print("machine        \(String(cString: model))")
print("macOS          \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
#if arch(arm64)
print("architecture   arm64 (Apple silicon)")
#else
print("architecture   x86_64 (Intel)")
#endif
print("minimum 13.0   \(os.majorVersion >= 13 ? "OK" : "TOO OLD - the app will not run")")

line()
print("AS A SENDER - hardware encode")
print(pad("  size", 16) + pad("H.264", 10) + "HEVC")
var maxH264 = (0, 0), maxHEVC = (0, 0)
for (name, w, h) in sizes {
    let a = canEncode(kCMVideoCodecType_H264, w, h)
    let b = canEncode(kCMVideoCodecType_HEVC, w, h)
    if a { maxH264 = (w, h) }
    if b { maxHEVC = (w, h) }
    print(pad("  " + name, 16) + pad(a ? "yes" : "no", 10) + (b ? "yes" : "no"))
}
print("  largest H.264 \(maxH264.0)x\(maxH264.1)   largest HEVC \(maxHEVC.0)x\(maxHEVC.1)")
let canSend5K = maxHEVC.0 >= 5120
print("  can SEND a 5K desktop: \(canSend5K ? "YES" : "no")")

line()
print("AS A RECEIVER - hardware decode")
print("  H.264  \(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) ? "yes" : "no")")
let hevcDec = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
print("  HEVC   \(hevcDec ? "yes" : "no")")
print("  can RECEIVE a 5K desktop: \(hevcDec ? "YES" : "no - falls back to H.264 at 4096x2304")")

line()
print("EXTEND MODE - private CGVirtualDisplay")
let classes = ["CGVirtualDisplay", "CGVirtualDisplayDescriptor",
               "CGVirtualDisplayMode", "CGVirtualDisplaySettings"]
var missing: [String] = []
for c in classes where NSClassFromString(c) == nil { missing.append(c) }
if missing.isEmpty {
    let d = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type
    let probe = d?.init()
    let hasWide = probe?.responds(to: NSSelectorFromString("setMaxPixelsWide:")) ?? false
    let hasHigh = (probe?.responds(to: NSSelectorFromString("setMaxPixelsHigh:")) ?? false)
               || (probe?.responds(to: NSSelectorFromString("setMaxPixelsTall:")) ?? false)
    print("  all four classes present")
    print("  setMaxPixelsWide:      \(hasWide ? "yes" : "MISSING")")
    print("  setMaxPixelsHigh/Tall: \(hasHigh ? "yes" : "MISSING")")
    print("  extend mode: \(hasWide && hasHigh ? "should work" : "UNAVAILABLE - mirror only")")
} else {
    print("  MISSING: \(missing.joined(separator: ", "))")
    print("  extend mode: UNAVAILABLE on this macOS - mirror still works")
}

line()
print("DISPLAYS")
var ids = [CGDirectDisplayID](repeating: 0, count: 16); var count: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &count)
for i in 0..<Int(count) {
    let d = ids[i]
    let mode = CGDisplayCopyDisplayMode(d)
    let px = mode.map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "?"
    print("  id=\(d)  \(CGDisplayPixelsWide(d))x\(CGDisplayPixelsHigh(d)) points, \(px) pixels" +
          (CGDisplayIsBuiltin(d) != 0 ? "  built-in" : "") +
          (CGDisplayIsMain(d) != 0 ? "  MAIN" : ""))
}

line("=")
print("VERDICT")
print("  sender:   " + (canSend5K ? "5K capable" : "up to \(maxHEVC.0)x\(maxHEVC.1) HEVC"))
print("  receiver: " + (hevcDec ? "5K capable" : "H.264 only"))
line("=")
