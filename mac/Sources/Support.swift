import Foundation
import CoreMedia

// MARK: - Logging

enum Log {
    private static let queue = DispatchQueue(label: "padlink.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let handle: FileHandle? = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PadLink.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber, size.intValue > 8_000_000 {
            try? Data().write(to: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()

    static func info(_ message: String) {
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now)) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            FileHandle.standardError.write(data)
            handle?.write(data)
        }
    }
}

// MARK: - Clock
// Host time in nanoseconds; the same timebase as ScreenCaptureKit presentation timestamps.

@inline(__always) func hostNowNs() -> UInt64 {
    hostNs(CMClockGetTime(CMClockGetHostTimeClock()))
}

@inline(__always) func hostNs(_ t: CMTime) -> UInt64 {
    let s = CMTimeGetSeconds(t)
    return s.isFinite && s > 0 ? UInt64(s * 1_000_000_000) : 0
}

// MARK: - Wire protocol
// Every message: [u8 type][u32 big-endian payload length][payload].

enum MsgType: UInt8 {
    // tablet -> mac
    case hello = 0x01
    case input = 0x02
    case ping = 0x03
    case stats = 0x04
    case keyframeRequest = 0x05
    // mac -> tablet
    case config = 0x81
    case frame = 0x82
    case pong = 0x83
    case status = 0x84
    case show = 0x85              // bring the display to the front on the tablet
}

enum FrameFlags {
    static let codecConfig: UInt8 = 1
    static let keyframe: UInt8 = 2
}

struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
    mutating func bytes(_ d: Data) { data.append(d) }
}

struct ByteReader {
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = data }
    var remaining: Int { data.count - offset }
    mutating func u8() -> UInt8 {
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }
    mutating func u16() -> UInt16 { UInt16(u8()) << 8 | UInt16(u8()) }
    mutating func u32() -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 { v = v << 8 | UInt32(u8()) }
        return v
    }
    mutating func u64() -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<8 { v = v << 8 | UInt64(u8()) }
        return v
    }
    mutating func f32() -> Float { Float(bitPattern: u32()) }
}

func jsonData(_ obj: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
}

// MARK: - Configuration
// Command line flags override `defaults write com.bob.padlink.host <key> <value>`.

struct Config {
    var padHost: String?
    var port: UInt16 = 27183
    var codec = "hevc"            // hevc | h264
    var lowLatencyRC = false      // VideoToolbox low-latency rate control (slower per frame on M5)
    var fps = 120
    var fpsOverridden = false     // --fps given: ignore the menu setting
    var bitrateMbps = 40.0
    var graceSeconds = 10.0
    var testPattern = false        // synthetic frames instead of screen capture (diagnostics)
    var checkOnly = false          // print permission state and exit

    static func load() -> Config {
        var c = Config()
        let d = UserDefaults.standard
        if let v = d.string(forKey: "pad"), !v.isEmpty { c.padHost = v }
        if let v = d.string(forKey: "codec") { c.codec = v }
        if d.object(forKey: "llrc") != nil { c.lowLatencyRC = d.bool(forKey: "llrc") }
        if d.object(forKey: "fps") != nil { c.fps = d.integer(forKey: "fps") }
        if d.object(forKey: "bitrate") != nil { c.bitrateMbps = d.double(forKey: "bitrate") }
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--pad": c.padHost = it.next()
            case "--port": c.port = UInt16(it.next() ?? "") ?? c.port
            case "--codec": c.codec = it.next() ?? c.codec
            case "--llrc": c.lowLatencyRC = true
            case "--fps": c.fps = Int(it.next() ?? "") ?? c.fps; c.fpsOverridden = true
            case "--bitrate": c.bitrateMbps = Double(it.next() ?? "") ?? c.bitrateMbps
            case "--test-pattern": c.testPattern = true
            case "--check": c.checkOnly = true
            default: break
            }
        }
        if let h = c.padHost, let colon = h.lastIndex(of: ":"), let p = UInt16(h[h.index(after: colon)...]) {
            c.padHost = String(h[..<colon])
            c.port = p
        }
        c.fps = min(max(c.fps, 30), 120)
        return c
    }
}
