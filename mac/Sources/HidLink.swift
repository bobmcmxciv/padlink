import AppKit
import Foundation

/// Drives the tablet with the Mac's own mouse and keyboard when it is not used as a display.
/// Two transports, both making Android see a real USB mouse and keyboard:
///  - USB cable: Android Open Accessory HID (no adb needed),
///  - otherwise adb: HidServer runs on the tablet as the shell user and creates /dev/uhid devices.
/// The adb transport also carries the clipboard both ways.
final class HidLink {
    static let mouseID: UInt16 = 1, keyboardID: UInt16 = 2

    var onClipboard: ((String) -> Void)?
    var onState: ((String) -> Void)?
    /// Tablet screen size in pixels, landscape (from the tablet when known).
    private(set) var tabletSize = CGSize(width: 2560, height: 1600)

    private let usb: USBWatcher
    private let queue = DispatchQueue(label: "padlink.hid")
    private var enabled = false
    private var adbProcess: Process?
    private var io: TCPIO?
    private let writeLock = NSLock()
    /// IP addresses of tablets found over Bonjour; the adb device must be one of them when known.
    var tabletHosts: () -> [String] = { [] }
    private var lastReport = ""

    init(usb: USBWatcher) {
        self.usb = usb
    }

    var isUSB: Bool { usb.hidReady }
    var isReady: Bool { usb.hidReady || io != nil }

    func start() {
        guard !enabled else { return }
        enabled = true
        usb.hidWanted = true
        queue.async { self.adbLoop() }
    }

    func stop() {
        enabled = false
        usb.hidWanted = false
        queue.async {
            self.io?.close(); self.io = nil
            self.adbProcess?.terminate(); self.adbProcess = nil
        }
    }

    // MARK: Reports

    /// buttons: bit0 left, bit1 right, bit2 middle.
    func mouse(buttons: UInt8, dx: Int, dy: Int, wheel: Int = 0, pan: Int = 0) {
        var r = Data([buttons])
        for v in [dx, dy] {
            let c = Int16(clamping: v)
            r.append(UInt8(truncatingIfNeeded: c)); r.append(UInt8(truncatingIfNeeded: c >> 8))
        }
        r.append(UInt8(bitPattern: Int8(clamping: wheel)))
        r.append(UInt8(bitPattern: Int8(clamping: pan)))
        send(type: 1, id: Self.mouseID, report: r)
    }

    func keyboard(modifiers: UInt8, usages: [UInt8]) {
        var r = Data([modifiers, 0])
        r.append(contentsOf: usages.prefix(6))
        while r.count < 8 { r.append(0) }
        send(type: 2, id: Self.keyboardID, report: r)
    }

    func sendClipboard(_ text: String) {
        guard let io else { return }
        let d = Data(text.utf8.prefix(60_000))
        write(io, type: 3, payload: d)
    }

    private func send(type: UInt8, id: UInt16, report: Data) {
        if usb.hidReady {
            usb.sendHID(id: id, report: report)
        } else if let io {
            write(io, type: type, payload: report)
        }
    }

    private func write(_ io: TCPIO, type: UInt8, payload: Data) {
        var d = Data([type, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        d.append(payload)
        writeLock.lock()
        let ok = d.withUnsafeBytes { io.writeAll($0.baseAddress!, count: $0.count) }
        writeLock.unlock()
        if !ok { io.close() }
    }

    // MARK: adb transport

    private static func adbPath() -> String? {
        let candidates = [NSHomeDirectory() + "/android-sdk/platform-tools/adb", NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
                          "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private func run(_ adb: String, _ args: [String], timeout: Double = 10) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func adbLoop() {
        while enabled {
            if usb.hidReady || io != nil { sleep(2); continue }
            guard let adb = Self.adbPath() else { report("未找到 adb，鼠标穿越仅可用 USB"); sleep(10); continue }
            let devices = run(adb, ["devices"]).split(separator: "\n").compactMap { line -> String? in
                let f = line.split(separator: "\t")
                return f.count == 2 && f[1] == "device" ? String(f[0]) : nil
            }
            // Other phones may be on the same adb server: only a device with the app, and the Bonjour address if known.
            let hosts = tabletHosts()
            let ordered = devices.filter { d in hosts.contains { d.hasPrefix($0 + ":") } } + (hosts.isEmpty ? devices : [])
            var picked: (String, String)?
            for serial in ordered {
                let path = run(adb, ["-s", serial, "shell", "pm", "path", "com.bob.padlink"])
                    .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "package:", with: "")
                if path.hasSuffix(".apk") { picked = (serial, path); break }
            }
            guard let (serial, apk) = picked else { report("未找到装有「Mac 副屏」的 adb 设备"); sleep(5); continue }
            run(adb, ["-s", serial, "shell", "pkill", "-f", "com.bob.padlink.HidServer"])
            let p = Process()
            p.executableURL = URL(fileURLWithPath: adb)
            p.arguments = ["-s", serial, "shell", "CLASSPATH=\(apk)", "app_process", "/", "com.bob.padlink.HidServer"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { sleep(5); continue }
            adbProcess = p
            sleep(2)
            run(adb, ["-s", serial, "forward", "tcp:27184", "localabstract:padlink-hid"])
            guard let c = TCPIO.connect(host: "127.0.0.1", port: 27184, timeout: 3) else {
                p.terminate(); adbProcess = nil; report("平板 HID 服务连接失败，重试中"); sleep(3); continue
            }
            io = c
            Log.info("hid: adb link to \(serial)")
            report("鼠标穿越就绪（adb）")
            readLoop(c)
            io = nil
            p.terminate()
            adbProcess = nil
            Log.info("hid: adb link closed")
            if enabled { report("平板 HID 连接断开，重连中"); sleep(2) }
        }
    }

    private func readLoop(_ c: TCPIO) {
        func readFully(_ n: Int) -> Data? {
            var buf = Data(count: n), off = 0, idle = 0
            while off < n {
                let r = buf.withUnsafeMutableBytes { c.read(into: $0.baseAddress! + off, count: n - off) }
                if r > 0 { off += r; idle = 0 } else if r == 0 { if !enabled { return nil }; idle += 1 } else { return nil }
            }
            return buf
        }
        while enabled, let h = readFully(3) {
            let len = Int(h[1]) << 8 | Int(h[2])
            guard let body = len > 0 ? readFully(len) : Data() else { break }
            let text = String(decoding: body, as: UTF8.self)
            switch h[0] {
            case 4:
                let wh = text.split(separator: " ").compactMap { Double($0) }
                if wh.count == 2 { tabletSize = CGSize(width: wh[0], height: wh[1]) }
            case 3:
                DispatchQueue.main.async { self.onClipboard?(text) }
            default:
                break
            }
        }
        c.close()
    }

    private func report(_ s: String) {
        if s != lastReport { Log.info("hid: " + s); lastReport = s }
        DispatchQueue.main.async { self.onState?(s) }
    }
}

/// macOS virtual key code -> USB HID keyboard usage.
enum HIDKeys {
    static let usage: [CGKeyCode: UInt8] = [
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A, 0x04: 0x0B, 0x22: 0x0C,
        0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13, 0x0C: 0x14, 0x0F: 0x15,
        0x01: 0x16, 0x11: 0x17, 0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B, 0x10: 0x1C, 0x06: 0x1D,
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25, 0x19: 0x26, 0x1D: 0x27,
        0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C, 0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F, 0x1E: 0x30,
        0x2A: 0x31, 0x29: 0x33, 0x27: 0x34, 0x32: 0x35, 0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38, 0x39: 0x39, 0x0A: 0x64,
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40, 0x64: 0x41, 0x65: 0x42,
        0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45, 0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x77: 0x4D, 0x79: 0x4E,
        0x7C: 0x4F, 0x7B: 0x50, 0x7D: 0x51, 0x7E: 0x52, 0x4C: 0x58, 0x66: 0x91, 0x68: 0x90,
    ]

    /// Mac modifiers -> HID modifier byte. Command becomes Ctrl so Cmd+C/V/Z/A behave as on the Mac.
    static func modifiers(_ f: CGEventFlags) -> UInt8 {
        var m: UInt8 = 0
        if f.contains(.maskCommand) || f.contains(.maskControl) { m |= 0x01 }
        if f.contains(.maskShift) { m |= 0x02 }
        if f.contains(.maskAlternate) { m |= 0x04 }
        return m
    }
}
