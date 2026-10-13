import Foundation

/// Message link to the tablet over a LinkIO (Wi-Fi or USB). One reader thread, one writer thread.
/// Video frames are counted while queued so the capture side can drop frames *before* encoding
/// when the link falls behind, instead of letting latency pile up in buffers.
final class PadConnection {
    let peer: String
    let isUSB: Bool
    private let io: LinkIO
    private let cond = NSCondition()
    private var queue: [Outgoing] = []
    private var closed = false
    private var pending = 0
    private var lastRxNs = hostNowNs()
    private var receivedAny = false

    var onMessage: ((MsgType, Data) -> Void)?
    var onClose: ((String) -> Void)?

    private enum Outgoing {
        case message(Data)
        case frame(captureNs: UInt64, flags: UInt8, payload: Data, counted: Bool)
    }

    init(io: LinkIO, peer: String) {
        self.io = io
        self.peer = peer
        self.isUSB = io.isUSB
    }

    static func connect(host: String, port: UInt16, timeout: Double) -> PadConnection? {
        guard let io = TCPIO.connect(host: host, port: port, timeout: timeout) else { return nil }
        return PadConnection(io: io, peer: "\(host):\(port)")
    }

    /// Encoded frames waiting to be written.
    var pendingFrames: Int {
        cond.lock(); defer { cond.unlock() }
        return pending
    }

    var isClosed: Bool {
        cond.lock(); defer { cond.unlock() }
        return closed
    }

    func start() {
        let reader = Thread { [weak self] in self?.readLoop() }
        reader.name = "padlink.reader"
        reader.qualityOfService = .userInteractive
        reader.start()
        let writer = Thread { [weak self] in self?.writeLoop() }
        writer.name = "padlink.writer"
        writer.qualityOfService = .userInteractive
        writer.start()
    }

    func send(_ type: MsgType, _ payload: Data = Data()) {
        var w = ByteWriter()
        w.u8(type.rawValue)
        w.u32(UInt32(payload.count))
        w.bytes(payload)
        cond.lock()
        if !closed {
            queue.append(.message(w.data))
            cond.signal()
        }
        cond.unlock()
    }

    /// `counted` frames are tracked in `pendingFrames` until fully written.
    func sendFrame(captureNs: UInt64, flags: UInt8, payload: Data, counted: Bool) {
        cond.lock()
        if !closed {
            if counted { pending += 1 }
            queue.append(.frame(captureNs: captureNs, flags: flags, payload: payload, counted: counted))
            cond.signal()
        }
        cond.unlock()
    }

    func close(_ reason: String) {
        cond.lock()
        if closed { cond.unlock(); return }
        closed = true
        queue.removeAll()
        cond.broadcast()
        cond.unlock()
        io.close()
        Log.info("connection \(peer) closed: \(reason)")
        onClose?(reason)
    }

    private func frameWritten() { cond.lock(); pending = max(0, pending - 1); cond.unlock() }

    private func writeLoop() {
        while true {
            cond.lock()
            while queue.isEmpty && !closed { cond.wait() }
            if closed { cond.unlock(); return }
            let item = queue.removeFirst()
            cond.unlock()

            var bytes: Data
            var counted = false
            switch item {
            case .message(let d):
                bytes = d
            case .frame(let captureNs, let flags, let payload, let c):
                counted = c
                var w = ByteWriter()
                w.u8(MsgType.frame.rawValue)
                w.u32(UInt32(17 + payload.count))
                w.u64(captureNs)
                w.u64(hostNowNs())
                w.u8(flags)
                w.data.append(payload)
                bytes = w.data
            }
            // A USB bulk transfer that is a whole number of packets has no short packet to end it, and the
            // tablet's read would wait for more data: append an empty no-op message in that case.
            if io.isUSB && bytes.count % 512 == 0 { bytes.append(contentsOf: [0, 0, 0, 0, 0]) }
            let ok = bytes.withUnsafeBytes { io.writeAll($0.baseAddress!, count: $0.count) }
            if counted { frameWritten() }
            if !ok { close("write failed"); return }
        }
    }

    private func readFully(_ count: Int) -> Data? {
        var buf = Data(count: count)
        var off = 0
        while off < count {
            let n = buf.withUnsafeMutableBytes { io.read(into: $0.baseAddress! + off, count: count - off) }
            if n > 0 {
                off += n
                lastRxNs = hostNowNs()
                receivedAny = true
            } else if n == 0 {
                if isClosed { return nil }
                // The tablet pings every second. A USB link stays quiet until the user accepts Android's
                // "open Mac 副屏?" prompt, so silence only counts once the tablet has spoken.
                if (!isUSB || receivedAny) && hostNowNs() - lastRxNs > 6_000_000_000 { close("tablet silent for 6s"); return nil }
            } else {
                close(isClosed ? "closed" : "tablet closed the connection")
                return nil
            }
        }
        return buf
    }

    private func readLoop() {
        while let header = readFully(5) {
            var r = ByteReader(header)
            let rawType = r.u8()
            let length = Int(r.u32())
            guard length <= 4 * 1024 * 1024 else { close("bad message length \(length)"); return }
            guard let payload = length > 0 ? readFully(length) : Data() else { return }
            if let type = MsgType(rawValue: rawType) {
                onMessage?(type, payload)
            }
        }
    }
}
