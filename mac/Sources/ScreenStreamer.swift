import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox

/// Captures one display with ScreenCaptureKit and streams it as low-latency H.264/HEVC.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let fps: Int
    let hevc: Bool
    let bitrate: Int
    var onStop: ((String) -> Void)?

    private weak var conn: PadConnection?
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private let queue = DispatchQueue(label: "padlink.capture", qos: .userInteractive)
    private var refreshTimer: DispatchSourceTimer?

    // State below is only touched on `queue`.
    private var forceKeyframe = true
    private var lastBuffer: CVPixelBuffer?
    private var lastSubmitNs: UInt64 = 0
    private var refreshesLeft = 0
    private var lastPts = CMTime.zero
    private var stopped = false
    private let encLock = NSLock()
    private var inEncoder = 0
    private var statFrames = 0, statDropped = 0, statBytes = 0, statKeyframes = 0
    private var statEncodeNs: [UInt64] = []
    private var statSince = hostNowNs()
    private var statCaptured: [Int: Int] = [:]   // SCFrameStatus raw value -> count
    private var statEncoderDropped = 0

    init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, hevc: Bool, bitrateMbps: Double, connection: PadConnection) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
        self.hevc = hevc
        self.bitrate = Int(bitrateMbps * 1_000_000)
        self.conn = connection
    }

    var codecMime: String { hevc ? "video/hevc" : "video/avc" }

    /// Synthetic moving frames instead of screen capture: exercises encode, network and decode
    /// without the Screen Recording permission.
    var testPattern = false
    private var patternTimer: DispatchSourceTimer?
    private var patternPool: CVPixelBufferPool?
    private var patternIndex = 0

    func start() async throws {
        if testPattern {
            try queue.sync { try createEncoder() }
            startPattern()
            Log.info("streaming TEST PATTERN (width)x(height)@(fps) (codecMime) (bitrate / 1_000_000)Mbps")
            return
        }
        var scDisplay: SCDisplay?
        for _ in 0..<40 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            scDisplay = content.displays.first { $0.displayID == displayID }
            if scDisplay != nil { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        guard let scDisplay else { throw NSError(domain: "PadLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "display \(displayID) not visible to ScreenCaptureKit"]) }

        try queue.sync { try createEncoder() }

        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.queueDepth = 5
        cfg.showsCursor = true
        cfg.capturesAudio = false
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(30), repeating: .milliseconds(30))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        refreshTimer = t
        Log.info("streaming display \(displayID) \(width)x\(height)@\(fps) \(codecMime) \(bitrate / 1_000_000)Mbps")
    }

    func stop() {
        queue.sync {
            stopped = true
            refreshTimer?.cancel()
            refreshTimer = nil
            patternTimer?.cancel()
            patternTimer = nil
            lastBuffer = nil
            if let e = encoder {
                VTCompressionSessionInvalidate(e)
                encoder = nil
            }
        }
        if let s = stream {
            stream = nil
            s.stopCapture { _ in }
        }
    }

    func requestKeyframe() {
        queue.async {
            self.forceKeyframe = true
            if let b = self.lastBuffer { self.encode(b, captureNs: hostNowNs()) }
        }
    }

    private func startPattern() {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &patternPool)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps))
        t.setEventHandler { [weak self] in self?.patternFrame() }
        t.resume()
        patternTimer = t
    }

    private func patternFrame() {
        guard !stopped, let pool = patternPool else { return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let pb = out else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.setFillColor(CGColor(red: 0.12, green: 0.14, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            let x = (patternIndex * 24) % width
            ctx.fill(CGRect(x: x, y: 0, width: 48, height: height))
            for bit in 0..<16 where (patternIndex >> bit) & 1 == 1 {
                ctx.setFillColor(CGColor(red: 1, green: 0.6, blue: 0.1, alpha: 1))
                ctx.fill(CGRect(x: 100 + bit * 120, y: height / 2 - 50, width: 100, height: 100))
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        patternIndex += 1
        encode(pb, captureNs: hostNowNs())
    }

    // MARK: SCStream

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int else { return }
        statCaptured[rawStatus, default: 0] += 1
        guard SCFrameStatus(rawValue: rawStatus) == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lastBuffer = pb
        refreshesLeft = 3
        encode(pb, captureNs: hostNs(CMSampleBufferGetPresentationTimeStamp(sb)))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("capture stopped: \(error.localizedDescription)")
        onStop?(error.localizedDescription)
    }

    // MARK: Encoding

    /// When the screen goes still, re-encode the last frame a few times so the encoder can
    /// refine quality (text sharpness) and so frames dropped under backpressure are not lost.
    private func tick() {
        guard !stopped, let b = lastBuffer, refreshesLeft > 0 else { maybeLogStats(); return }
        if hostNowNs() - lastSubmitNs > 70_000_000 {
            refreshesLeft -= 1
            encode(b, captureNs: hostNowNs())
        }
        maybeLogStats()
    }

    private func encode(_ pb: CVPixelBuffer, captureNs: UInt64) {
        guard !stopped, let enc = encoder, let conn = conn, !conn.isClosed else { return }
        encLock.lock(); let busy = inEncoder; encLock.unlock()
        if busy >= 2 || conn.pendingFrames >= 2 {
            statDropped += 1
            refreshesLeft = max(refreshesLeft, 1)
            return
        }
        var pts = CMTime(value: CMTimeValue(captureNs / 1000), timescale: 1_000_000)
        if pts <= lastPts { pts = CMTimeAdd(lastPts, CMTime(value: 1, timescale: 1_000_000)) }
        lastPts = pts
        var props: CFDictionary?
        if forceKeyframe {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceKeyframe = false
        }
        encLock.lock(); inEncoder += 1; encLock.unlock()
        lastSubmitNs = hostNowNs()
        let submitNs = lastSubmitNs
        let status = VTCompressionSessionEncodeFrame(enc, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                                     frameProperties: props, infoFlagsOut: nil) { [weak self, weak conn] status, flags, sbuf in
            guard let self else { return }
            self.encLock.lock(); self.inEncoder -= 1; self.encLock.unlock()
            guard let conn, status == noErr, let sbuf, !flags.contains(.frameDropped),
                  CMSampleBufferGetDataBuffer(sbuf) != nil else {
                self.queue.async { self.statEncoderDropped += 1 }
                return
            }
            self.emit(sbuf, captureNs: captureNs, submitNs: submitNs, conn: conn)
        }
        if status != noErr {
            encLock.lock(); inEncoder -= 1; encLock.unlock()
            Log.info("encode error \(status)")
        }
    }

    private func emit(_ sbuf: CMSampleBuffer, captureNs: UInt64, submitNs: UInt64, conn: PadConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sbuf), let fmt = CMSampleBufferGetFormatDescription(sbuf) else { return }
        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = arr.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        avcc.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }

        let startCode: [UInt8] = [0, 0, 0, 1]
        var annexB = Data(capacity: length + 64)
        var nalHeaderLen: Int32 = 4
        if isKey {
            var config = Data()
            var count = 0
            var i = 0
            repeat {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let st = hevc
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLen)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLen)
                guard st == noErr, let ptr else { break }
                config.append(contentsOf: startCode)
                config.append(ptr, count: size)
                i += 1
            } while i < count
            conn.sendFrame(captureNs: captureNs, flags: FrameFlags.codecConfig, payload: config, counted: false)
        }
        let hl = Int(nalHeaderLen)
        avcc.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var off = 0
            while off + hl <= p.count {
                var n = 0
                for k in 0..<hl { n = n << 8 | Int(p[off + k]) }
                off += hl
                guard n > 0, off + n <= p.count else { break }
                annexB.append(contentsOf: startCode)
                annexB.append(p.baseAddress! + off, count: n)
                off += n
            }
        }
        conn.sendFrame(captureNs: captureNs, flags: isKey ? FrameFlags.keyframe : 0, payload: annexB, counted: true)
        let encNs = hostNowNs() - submitNs
        queue.async {
            self.statFrames += 1
            self.statBytes += annexB.count
            if isKey { self.statKeyframes += 1 }
            self.statEncodeNs.append(encNs)
        }
    }

    private func maybeLogStats() {
        let now = hostNowNs()
        guard now - statSince >= 10_000_000_000 else { return }
        let secs = Double(now - statSince) / 1e9
        let enc = statEncodeNs.sorted()
        let p50 = enc.isEmpty ? 0 : Double(enc[enc.count / 2]) / 1e6
        Log.info(String(format: "mac: %.1f fps sent, %d dropped, %d keyframes, %.1f Mbps, encode p50 %.1f ms",
                        Double(statFrames) / secs, statDropped, statKeyframes, Double(statBytes) * 8 / secs / 1e6, p50))
        Log.info("mac: capture callbacks by status (0 complete, 1 idle, 2 blank, 3 suspended, 4 started, 5 stopped): \(statCaptured.sorted { $0.key < $1.key })")
        statCaptured.removeAll()
        if statEncoderDropped > 0 { Log.info("mac: encoder dropped \(statEncoderDropped) frames") }
        statEncoderDropped = 0
        statFrames = 0; statDropped = 0; statBytes = 0; statKeyframes = 0; statEncodeNs.removeAll(); statSince = now
    }

    /// Measured on M5 at 3200x2136 (encoder idle): HEVC real-time ~7 ms/frame, H.264 real-time ~12 ms,
    /// both codecs with low-latency rate control ~15 ms. So the default is HEVC without it, with a
    /// short-window data rate cap to keep frame sizes (and network queueing) bounded.
    var lowLatencyRateControl = false
    var expectedRate: Int?

    private func createEncoder() throws {
        let codec = hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var session: VTCompressionSession?
        var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        if lowLatencyRateControl { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
                                            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if st != noErr && lowLatencyRateControl {
            lowLatencyRateControl = false
            spec.removeValue(forKey: kVTVideoEncoderSpecification_EnableLowLatencyRateControl)
            st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
                                            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        }
        guard st == noErr, let session else {
            throw NSError(domain: "PadLink", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed \(st)"])
        }
        func set(_ key: CFString, _ value: CFTypeRef) {
            let r = VTSessionSetProperty(session, key: key, value: value)
            if r != noErr { Log.info("encoder property \(key) rejected (\(r))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        if !lowLatencyRateControl {
            set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
            // At most the average rate in any 250 ms window.
            set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bitrate / 8 / 4), NSNumber(value: 0.25)] as CFArray)
        }
        // A higher expected rate makes the encoder finish each frame sooner (measured: 60 -> 14.8 ms, 120 -> 9.7 ms).
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: expectedRate ?? fps))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 1_000_000))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 3600))
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        Log.info("encoder ready: \(hevc ? "HEVC" : "H.264") low-latency rate control \(lowLatencyRateControl ? "on" : "off")")
    }
}
