import Foundation
import Darwin

/// Byte transport under PadConnection: a TCP socket (Wi-Fi) or USB bulk endpoints (Android Open Accessory).
protocol LinkIO: AnyObject {
    var isUSB: Bool { get }
    /// > 0: bytes read; 0: nothing arrived within ~1 s; < 0: link closed or failed.
    func read(into buf: UnsafeMutableRawPointer, count: Int) -> Int
    func writeAll(_ buf: UnsafeRawPointer, count: Int) -> Bool
    func close()
}

// MARK: - Wi-Fi

final class TCPIO: LinkIO {
    let isUSB = false
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func connect(host: String, port: UInt16, timeout: Double) -> TCPIO? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 && errno != EINPROGRESS { Darwin.close(fd); return nil }
        if rc != 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { Darwin.close(fd); return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { Darwin.close(fd); return nil }
        }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

        func setInt(_ level: Int32, _ name: Int32, _ value: Int32) {
            var v = value
            setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size))
        }
        setInt(IPPROTO_TCP, TCP_NODELAY, 1)
        setInt(SOL_SOCKET, SO_NOSIGPIPE, 1)
        // Keep the kernel queue short: backlog should build up where we can see (and drop) it.
        setInt(SOL_SOCKET, SO_SNDBUF, 512 * 1024)
        // Interactive video service class -> Wi-Fi WMM video access category.
        setInt(SOL_SOCKET, 0x1116 /* SO_NET_SERVICE_TYPE */, 3 /* NET_SERVICE_TYPE_VI */)
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var stv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &stv, socklen_t(MemoryLayout<timeval>.size))
        return TCPIO(fd: fd)
    }

    func read(into buf: UnsafeMutableRawPointer, count: Int) -> Int {
        let n = recv(fd, buf, count, 0)
        if n > 0 { return n }
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return 0 }
        return -1
    }

    func writeAll(_ buf: UnsafeRawPointer, count: Int) -> Bool {
        var off = 0
        while off < count {
            let n = Darwin.send(fd, buf + off, count - off, 0)
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    func close() {
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

// MARK: - USB (Android Open Accessory)

final class USBIO: LinkIO {
    let isUSB = true
    let name: String
    private let handle: OpaquePointer
    private let epIn: UInt8
    private let epOut: UInt8
    private var inBuf = [UInt8](repeating: 0, count: 64 * 1024)
    private var inPos = 0, inLen = 0
    private let lock = NSLock()
    private var closed = false

    init(handle: OpaquePointer, epIn: UInt8, epOut: UInt8, name: String) {
        self.handle = handle
        self.epIn = epIn
        self.epOut = epOut
        self.name = name
    }

    func read(into buf: UnsafeMutableRawPointer, count: Int) -> Int {
        if inPos >= inLen {
            var got: Int32 = 0
            let rc = inBuf.withUnsafeMutableBufferPointer {
                libusb_bulk_transfer(handle, epIn, $0.baseAddress, Int32($0.count), &got, 1000)
            }
            if got > 0 {
                inPos = 0
                inLen = Int(got)
            } else if rc == LIBUSB_ERROR_TIMEOUT.rawValue {
                return 0
            } else {
                return -1
            }
        }
        let k = min(count, inLen - inPos)
        inBuf.withUnsafeBufferPointer { buf.copyMemory(from: $0.baseAddress! + inPos, byteCount: k) }
        inPos += k
        return k
    }

    func writeAll(_ buf: UnsafeRawPointer, count: Int) -> Bool {
        var off = 0
        while off < count {
            var sent: Int32 = 0
            let chunk = min(count - off, 1 << 20)
            let rc = libusb_bulk_transfer(handle, epOut, UnsafeMutablePointer(mutating: buf.assumingMemoryBound(to: UInt8.self)) + off,
                                          Int32(chunk), &sent, 3000)
            if rc != 0 && sent == 0 { return false }
            off += Int(sent)
        }
        return true
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if closed { return }
        closed = true
        libusb_release_interface(handle, 0)
        libusb_close(handle)
    }
}

/// Watches USB for Android tablets. A tablet in normal mode is asked to switch to accessory mode
/// (Android then offers to open "Mac 副屏"); a tablet already in accessory mode is opened as a link.
final class USBWatcher {
    var onLink: ((USBIO) -> Void)?
    var enabled = true
    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "padlink.usb")
    private var timer: DispatchSourceTimer?
    private var asked: [String: Date] = [:]
    private(set) var busy = false     // an accessory link is open

    // Vendors that ship Android tablets/phones (Xiaomi, Google, Samsung, Huawei, Honor, OPPO, vivo, OnePlus, Lenovo, Motorola).
    private let androidVendors: Set<UInt16> = [0x2717, 0x18D1, 0x04E8, 0x12D1, 0x339B, 0x22D9, 0x2D95, 0x2A70, 0x17EF, 0x22B8]

    func start() {
        guard libusb_init(&ctx) == 0 else { Log.info("usb: libusb_init failed"); return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func linkClosed() { queue.async { self.busy = false } }

    private func poll() {
        guard enabled, !busy, let ctx else { return }
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let n = libusb_get_device_list(ctx, &list)
        guard n >= 0, let list else { return }
        defer { libusb_free_device_list(list, 1) }
        var present = Set<String>()
        for i in 0..<Int(n) {
            guard let dev = list[i] else { continue }
            var d = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &d) == 0 else { continue }
            let key = "\(libusb_get_bus_number(dev))-\(libusb_get_port_number(dev))-\(String(d.idVendor, radix: 16)):\(String(d.idProduct, radix: 16))"
            present.insert(key)
            if d.idVendor == 0x18D1 && (0x2D00...0x2D05).contains(d.idProduct) {
                if let io = openAccessory(dev) {
                    busy = true
                    Log.info("usb: accessory link open (\(key))")
                    DispatchQueue.main.async { self.onLink?(io) }
                    return
                }
            } else if androidVendors.contains(d.idVendor), asked[key] == nil {
                asked[key] = Date()
                requestAccessoryMode(dev, key: key)
            }
        }
        asked = asked.filter { present.contains($0.key) }
    }

    private func requestAccessoryMode(_ dev: OpaquePointer, key: String) {
        var h: OpaquePointer?
        guard libusb_open(dev, &h) == 0, let h else { Log.info("usb: cannot open \(key)"); return }
        defer { libusb_close(h) }
        var ver: [UInt8] = [0, 0]
        let rc = libusb_control_transfer(h, 0xC0, 51, 0, 0, &ver, 2, 1000)
        guard rc == 2 else { Log.info("usb: \(key) does not speak AOA (\(rc))"); return }
        let strings = ["PadLink", "PadLink Mac Host", "把平板用作 Mac 的触控副屏", "1.0", "https://github.com/bobmcmxciv/padlink", "PADLINK-MAC"]
        for (i, s) in strings.enumerated() {
            var bytes = Array(s.utf8) + [0]
            _ = libusb_control_transfer(h, 0x40, 52, 0, UInt16(i), &bytes, UInt16(bytes.count), 1000)
        }
        let start = libusb_control_transfer(h, 0x40, 53, 0, 0, nil, 0, 1000)
        Log.info("usb: \(key) AOA v\(Int(ver[0]) | Int(ver[1]) << 8), switch to accessory mode -> \(start)")
    }

    private func openAccessory(_ dev: OpaquePointer) -> USBIO? {
        var h: OpaquePointer?
        guard libusb_open(dev, &h) == 0, let h else { return nil }
        var cfg: UnsafeMutablePointer<libusb_config_descriptor>?
        guard libusb_get_active_config_descriptor(dev, &cfg) == 0, let cfg else { libusb_close(h); return nil }
        defer { libusb_free_config_descriptor(cfg) }
        var epIn: UInt8 = 0, epOut: UInt8 = 0
        let iface = cfg.pointee.interface[0].altsetting[0]
        for e in 0..<Int(iface.bNumEndpoints) {
            let ep = iface.endpoint[e]
            guard ep.bmAttributes & 0x3 == 2 else { continue }   // bulk
            if ep.bEndpointAddress & 0x80 != 0 { epIn = ep.bEndpointAddress } else { epOut = ep.bEndpointAddress }
        }
        guard epIn != 0, epOut != 0, libusb_claim_interface(h, 0) == 0 else {
            Log.info("usb: accessory interface unavailable")
            libusb_close(h)
            return nil
        }
        return USBIO(handle: h, epIn: epIn, epOut: epOut, name: "USB")
    }
}
