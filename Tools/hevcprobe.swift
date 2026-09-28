import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

// ---------- ENCODE side: produce real 5K HEVC parameter sets + one keyframe ----------
func encodeSample(width: Int, height: Int, to path: String) {
    var session: VTCompressionSession?
    let st = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
        width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
        encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard st == noErr, let session else { print("encode session failed \(st)"); exit(1) }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTCompressionSessionPrepareToEncodeFrames(session)

    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    guard let pixelBuffer = pb else { print("pixel buffer failed"); exit(1) }

    let sem = DispatchSemaphore(value: 0)
    var out = Data()
    VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
        presentationTimeStamp: CMTime(value: 0, timescale: 60), duration: .invalid,
        frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary,
        infoFlagsOut: nil) { status, _, sample in
            defer { sem.signal() }
            guard status == noErr, let sample,
                  let desc = CMSampleBufferGetFormatDescription(sample) else { return }
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(desc, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            var header = Data()
            header.append(UInt8(count))
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?; var n = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(desc, parameterSetIndex: i,
                       parameterSetPointerOut: &p, parameterSetSizeOut: &n,
                       parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p {
                    var len = UInt32(n).bigEndian
                    withUnsafeBytes(of: &len) { header.append(contentsOf: $0) }
                    header.append(Data(bytes: p, count: n))
                }
            }
            var length = 0; var ptr: UnsafeMutablePointer<Int8>?
            if let bb = CMSampleBufferGetDataBuffer(sample),
               CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                           totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
               let ptr {
                var flen = UInt32(length).bigEndian
                withUnsafeBytes(of: &flen) { header.append(contentsOf: $0) }
                header.append(Data(bytes: ptr, count: length))
            }
            out = header
        }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    sem.wait()
    guard !out.isEmpty else { print("no encoded output"); exit(1) }
    try! out.write(to: URL(fileURLWithPath: path))
    print("wrote \(out.count) bytes of \(width)x\(height) HEVC to \(path)")
}

// ---------- DECODE side ----------
func decodeTest(path: String, width: Int, height: Int) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { print("no file"); exit(1) }
    var i = data.startIndex
    let count = Int(data[i]); i += 1
    var sets: [Data] = []
    for _ in 0..<count {
        let n = Int(data[i..<i+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }); i += 4
        sets.append(data.subdata(in: i..<(i+n))); i += n
    }
    let flen = Int(data[i..<i+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }); i += 4
    let frame = data.subdata(in: i..<(i+flen))
    print("parameter sets: \(sets.count), frame: \(frame.count) bytes")

    var bufs: [UnsafeMutablePointer<UInt8>] = []; var sizes: [Int] = []
    for s in sets {
        let b = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count)
        s.copyBytes(to: b, count: s.count); bufs.append(b); sizes.append(s.count)
    }
    defer { bufs.forEach { $0.deallocate() } }
    let ptrs = bufs.map { UnsafePointer($0) }
    var desc: CMVideoFormatDescription?
    let dst = ptrs.withUnsafeBufferPointer { pb in sizes.withUnsafeBufferPointer { sb in
        CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
            parameterSetCount: pb.count, parameterSetPointers: pb.baseAddress!,
            parameterSetSizes: sb.baseAddress!, nalUnitHeaderLength: 4,
            extensions: nil, formatDescriptionOut: &desc) } }
    guard dst == noErr, let desc else { print("format description FAILED (\(dst))"); exit(1) }
    let dims = CMVideoFormatDescriptionGetDimensions(desc)
    print("format description OK: \(dims.width)x\(dims.height)")
    print("VTIsHardwareDecodeSupported(HEVC): \(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))")

    for requireHW in [true, false] {
        var spec: [CFString: Any] = [:]
        if requireHW { spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true }
        var session: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
            formatDescription: desc, decoderSpecification: spec.isEmpty ? nil : spec as CFDictionary,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
        let label = requireHW ? "hardware-only" : "any (sw ok)"
        guard st == noErr, let session else { print(pad(label, 16) + "session FAILED (\(st))"); continue }
        // Actually decode the frame, not just create the session.
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: frame.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: frame.count, flags: 0, blockBufferOut: &block)
        _ = frame.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!,
                                          offsetIntoDestination: 0, dataLength: raw.count) }
        var sample: CMSampleBuffer?; var sz = frame.count
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: 0, timescale: 60),
                                        decodeTimeStamp: .invalid)
        CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block!,
            formatDescription: desc, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sz,
            sampleBufferOut: &sample)
        var decodedW = 0, decodedH = 0
        let sem = DispatchSemaphore(value: 0)
        var decodeStatus: OSStatus = -1
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample!,
            flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { st2, _, image, _, _ in
                decodeStatus = st2
                if let image { decodedW = CVPixelBufferGetWidth(image); decodedH = CVPixelBufferGetHeight(image) }
                sem.signal()
            }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        _ = sem.wait(timeout: .now() + 5)
        VTDecompressionSessionInvalidate(session)
        let verdict = decodeStatus == noErr && decodedW > 0
            ? "DECODED \(decodedW)x\(decodedH)" : "decode failed (\(decodeStatus))"
        print(pad(label, 16) + "session ok · " + verdict)
    }
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "encode"
let w = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 5120
let h = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4])! : 2880
let file = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/hevc5k.bin"
if mode == "encode" { encodeSample(width: w, height: h, to: file) } else { decodeTest(path: file, width: w, height: h) }
