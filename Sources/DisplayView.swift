import SwiftUI
import AVFoundation
import CoreMedia
import AppKit

/// Renders the incoming H.264 stream. AVSampleBufferDisplayLayer decodes in
/// hardware for us, so there is no separate decoder to go wrong.
final class VideoLayerView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var formatDescription: CMVideoFormatDescription?
    private(set) var lastError: String?
    private(set) var activeCodec: VideoCodec = .h264
    private(set) var enqueued = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-HOSTING, not layer-backed: the layer must be assigned BEFORE
        // wantsLayer. The other order lets AppKit manage (and replace) the
        // layer, which quietly drops this sublayer — the picture never draws.
        let host = CALayer()
        host.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        host.addSublayer(displayLayer)
        self.layer = host
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    /// Surfaced so the UI can say why nothing is showing.
    var hasFormat: Bool { formatDescription != nil }

    var renderStatusText: String {
        switch displayLayer.status {
        case .rendering: return "rendering"
        case .failed:    return "failed: \(displayLayer.error?.localizedDescription ?? "unknown")"
        case .unknown:   return "idle"
        @unknown default: return "?"
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    func setParameterSets(_ data: Data, codec: VideoCodec) {
        let sets = ParameterSets.decode(data)
        // H.264 sends SPS+PPS (2). HEVC sends VPS+SPS+PPS (3).
        let needed = codec == .hevc ? 3 : 2
        guard sets.count >= needed else {
            lastError = "\(codec.displayName) needs \(needed) parameter sets, got \(sets.count)"
            return
        }
        // withUnsafeBytes pointers are only valid INSIDE the closure. Collecting
        // them and using them afterwards is undefined behaviour — that is why
        // the format description was never built and nothing ever rendered.
        // Copy into buffers we own for the duration of the call instead.
        var buffers: [UnsafeMutablePointer<UInt8>] = []
        var sizes: [Int] = []
        for set in sets {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: buf, count: set.count)
            buffers.append(buf)
            sizes.append(set.count)
        }
        defer { buffers.forEach { $0.deallocate() } }

        let pointers = buffers.map { UnsafePointer($0) }
        var desc: CMVideoFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pb in
            sizes.withUnsafeBufferPointer { sb in
                codec == .hevc
                ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pb.count,
                    parameterSetPointers: pb.baseAddress!,
                    parameterSetSizes: sb.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &desc)
                : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pb.count,
                    parameterSetPointers: pb.baseAddress!,
                    parameterSetSizes: sb.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc)
            }
        }
        if status == noErr, let desc {
            formatDescription = desc
            activeCodec = codec
            lastError = nil
            flush()
        } else {
            lastError = "\(codec.displayName) format description failed (status \(status))"
        }
    }

    func enqueue(_ au: Data, isKeyframe: Bool) {
        guard let formatDescription else { return }
        if displayLayer.status == .failed {
            lastError = displayLayer.error?.localizedDescription ?? "renderer failed"
            displayLayer.flush()
        }

        // The block buffer must OWN its bytes. Pointing it at a local Data with
        // kCFAllocatorNull left it referencing freed memory the moment this
        // function returned — which decodes as nothing, i.e. a black picture.
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: au.count, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: au.count,
                flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        let copied = au.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                                                 offsetIntoDestination: 0,
                                                 dataLength: raw.count) == noErr
        }
        guard copied else { return }

        var sample: CMSampleBuffer?
        var size = au.count
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: formatDescription, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr,
              let sample else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        displayLayer.enqueue(sample)
        enqueued &+= 1
    }

    func flush() { displayLayer.flush() }

    /// Drops the current format description so the next parameter sets are
    /// adopted cleanly after a codec or resolution change.
    func resetFormat() {
        formatDescription = nil
        lastError = nil
        displayLayer.flush()
    }
}

struct VideoView: NSViewRepresentable {
    @ObservedObject var pipe: VideoPipe

    func makeNSView(context: Context) -> VideoLayerView {
        let v = VideoLayerView()
        pipe.view = v
        return v
    }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {
        pipe.view = nsView
    }
}

/// Bridges packets from the network to the layer on the main thread.
@MainActor
final class VideoPipe: ObservableObject {
    weak var view: VideoLayerView?
    @Published var framesReceived = 0
    @Published var senderInfo = ""
    private(set) var negotiatedCodec: VideoCodec = .h264

    func handle(_ type: PacketType, _ payload: Data) {
        switch type {
        case .hello:
            if let h = try? JSONDecoder().decode(Hello.self, from: payload) {
                let incoming = VideoCodec(rawValue: h.codec ?? "h264") ?? .h264
                if incoming != negotiatedCodec {
                    // The sender switched codec mid-stream. The existing format
                    // description belongs to the old one and would decode the
                    // new frames into nothing.
                    view?.resetFormat()
                }
                negotiatedCodec = incoming
                senderInfo = "\(h.name) · \(h.width)×\(h.height) · \(negotiatedCodec.displayName)"
            }
        case .format:
            view?.setParameterSets(payload, codec: negotiatedCodec)
        case .frame:
            guard payload.count > 1 else { return }
            let isKey = payload[payload.startIndex] == 1
            let au = payload.dropFirst()
            view?.enqueue(Data(au), isKeyframe: isKey)
            framesReceived &+= 1
        default:
            break
        }
    }

    func reset() { view?.flush(); framesReceived = 0 }
}
