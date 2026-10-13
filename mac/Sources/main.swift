import AppKit
import CoreGraphics
import Network
import ServiceManagement

/// Owns the tablet connection lifecycle: find the tablet (Bonjour or USB), connect, create the virtual
/// display, stream it, inject input. On a dropped link the display is kept for a grace period so a brief
/// Wi-Fi hiccup does not throw all windows back to the main screen.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct Pad { var host: String; var port: UInt16; var want: Bool }

    let config = Config.load()
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var browser: NWBrowser?
    private var discovered: [String: Pad] = [:]
    private let usb = USBWatcher()
    private var connecting = false
    private var state = "等待平板"
    private var statsLine = ""

    /// Bonjour name the user picked in the menu; reconnect to it after link errors.
    private var manualTarget: String?
    /// Pads the user disconnected from the menu: no auto-connect until they reopen the app on the tablet.
    private var suppressed = Set<String>()

    private var conn: PadConnection?
    private var connName = ""
    private var streamer: ScreenStreamer?
    private let injectorLock = NSLock()
    private var _injector: InputInjector?
    /// Read on the connection's reader thread, written on main.
    private var injector: InputInjector? {
        get { injectorLock.lock(); defer { injectorLock.unlock() }; return _injector }
        set { injectorLock.lock(); _injector = newValue; injectorLock.unlock() }
    }
    private var display: PadVirtualDisplay?
    private var displayKey = ""
    private var teardown: DispatchWorkItem?

    private var autoConnect: Bool {
        get { defaults.object(forKey: "autoConnect") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoConnect") }
    }
    private var usbAuto: Bool {
        get { defaults.object(forKey: "usbAuto") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "usbAuto"); usb.enabled = newValue }
    }
    private var fps: Int { config.fpsOverridden ? config.fps : (defaults.object(forKey: "fps") as? Int ?? config.fps) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest-inject") {
            InputInjector.selfTest { exit(0) }
            return
        }
        if config.checkOnly {
            let line = "screen=\(CGPreflightScreenCaptureAccess()) input=\(CGPreflightPostEventAccess())\n"
            try? line.write(toFile: "/tmp/padlink-check.txt", atomically: true, encoding: .utf8)
            exit(0)
        }
        Log.info("PadLink starting; pad=\(config.padHost ?? "auto") codec=\(config.codec) fps=\(fps) bitrate=\(config.bitrateMbps)\(config.testPattern ? " TEST-PATTERN" : "")")
        setupStatusItem()
        requestPermissions()
        startBrowsing()
        usb.enabled = usbAuto
        usb.onLink = { [weak self] io in self?.attachUSB(io) }
        usb.start()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tryConnect() }
        tryConnect()
    }

    // MARK: Permissions

    private var screenAllowed: Bool { CGPreflightScreenCaptureAccess() }
    private var inputAllowed: Bool { CGPreflightPostEventAccess() }

    private func requestPermissions() {
        Log.info("permissions: screen recording \(screenAllowed), input (accessibility) \(inputAllowed)")
        if !screenAllowed { CGRequestScreenCaptureAccess() }
        if !inputAllowed { CGRequestPostEventAccess() }
    }

    private func sendStatus(_ extra: String? = nil) {
        var msg: [String] = []
        if !screenAllowed { msg.append("Mac 未授予 PadLink「屏幕与系统录音」权限，画面无法传输") }
        if !inputAllowed { msg.append("Mac 未授予 PadLink「辅助功能」权限，触控无法操作 Mac") }
        if let extra { msg.append(extra) }
        conn?.send(.status, jsonData(["screen": screenAllowed, "input": inputAllowed, "message": msg.joined(separator: "\n")]))
    }

    // MARK: Discovery / connect

    private func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_padlink._tcp", domain: nil), using: params)
        b.stateUpdateHandler = { state in Log.info("bonjour browser: \(state)") }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [String: Pad] = [:]
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint, case let .bonjour(txt) = r.metadata,
                      let ip = txt["ip"], let port = UInt16(txt["port"] ?? "") else { continue }
                found[name] = Pad(host: ip, port: port, want: txt["want"] == "1")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (name, pad) in found where !pad.want { self.suppressed.remove(name) }
                self.discovered = found
                Log.info("bonjour: \(found.map { "\($0.key)=\($0.value.host) want=\($0.value.want)" }.joined(separator: ", "))")
                self.tryConnect()
            }
        }
        b.start(queue: .main)
        browser = b
    }

    private func tryConnect() {
        guard conn == nil, !connecting else { return }
        var target: (name: String, host: String, port: UInt16)?
        if let h = config.padHost {
            target = (h, h, config.port)
        } else if let m = manualTarget, let p = discovered[m] {
            target = (m, p.host, p.port)
        } else if autoConnect, let (name, p) = discovered.first(where: { $0.value.want && !suppressed.contains($0.key) }) {
            target = (name, p.host, p.port)
        }
        guard let target else {
            if display == nil { setState(discovered.isEmpty ? "未发现平板" : "待命") }
            return
        }
        connecting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let c = PadConnection.connect(host: target.host, port: target.port, timeout: 2)
            DispatchQueue.main.async {
                guard let self else { return }
                self.connecting = false
                if let c {
                    if self.conn != nil { c.close("already connected") } else { self.attach(c, name: target.name) }
                }
            }
        }
    }

    private func attachUSB(_ io: USBIO) {
        if let c = conn, !c.isUSB { c.close("switching to USB") }
        if conn != nil { io.close(); usb.linkClosed(); return }
        attach(PadConnection(io: io, peer: "USB"), name: "USB")
    }

    // MARK: Session

    private func attach(_ c: PadConnection, name: String) {
        Log.info("connected to \(c.peer)")
        conn = c
        connName = name
        statsLine = ""
        setState(c.isUSB ? "USB 已连接，等待平板确认…" : "正在连接 \(name)…")
        c.onMessage = { [weak self, weak c] type, payload in
            guard let self, let c else { return }
            switch type {
            case .input:
                self.injector?.handle(payload)
            case .ping:
                var w = ByteWriter()
                w.bytes(payload.prefix(8))
                w.u64(hostNowNs())
                c.send(.pong, w.data)
            case .keyframeRequest:
                DispatchQueue.main.async { self.streamer?.requestKeyframe() }
            case .stats:
                Log.info("pad: \(String(decoding: payload, as: UTF8.self))")
                DispatchQueue.main.async { self.onStats(payload) }
            case .hello:
                DispatchQueue.main.async { self.onHello(payload, from: c) }
            default:
                break
            }
        }
        c.onClose = { [weak self, weak c] reason in
            DispatchQueue.main.async {
                guard let self, let c, self.conn === c else { return }
                self.detach(reason, usb: c.isUSB)
            }
        }
        c.start()
        // USB: Android shows "open Mac 副屏 for this accessory?" first; give the user time to answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + (c.isUSB ? 120 : 4)) { [weak self, weak c] in
            guard let self, let c, self.conn === c, self.streamer == nil else { return }
            c.close("no hello from tablet")
        }
    }

    private func onHello(_ payload: Data, from c: PadConnection) {
        guard conn === c, streamer == nil else { return }
        guard let hello = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let w = hello["width"] as? Int, let h = hello["height"] as? Int, w > 0, h > 0 else {
            c.close("bad hello"); return
        }
        let name = hello["name"] as? String ?? "Android Pad"
        connName = c.isUSB ? name : connName
        let codecs = hello["codecs"] as? [String] ?? ["video/avc"]
        let hevc = config.codec == "hevc" && codecs.contains("video/hevc")
        let fps = self.fps
        Log.info("hello: \(name) \(w)x\(h) refresh=\(hello["refresh"] ?? "?") codecs=\(codecs) link=\(c.isUSB ? "usb" : "wifi")")
        sendStatus()

        teardown?.cancel()
        teardown = nil
        let key = "\(name)|\(w)x\(h)@\(fps)"
        if display == nil || displayKey != key {
            display = nil
            display = PadVirtualDisplay(name: name, pixelWidth: w, pixelHeight: h, refreshRate: Double(fps),
                                        xdpi: hello["xdpi"] as? Double ?? 0, ydpi: hello["ydpi"] as? Double ?? 0,
                                        serial: PadVirtualDisplay.serial(for: name))
            displayKey = key
        }
        guard let display else { c.close("virtual display creation failed"); return }

        injector = InputInjector(displayID: display.displayID)
        let s = ScreenStreamer(displayID: display.displayID, width: w, height: h, fps: fps, hevc: hevc,
                               bitrateMbps: config.bitrateMbps, connection: c)
        s.testPattern = config.testPattern
        s.lowLatencyRateControl = config.lowLatencyRC
        if let r = defaults.object(forKey: "expectedRate") as? Int { s.expectedRate = r }
        s.onStop = { [weak c] reason in
            DispatchQueue.main.async { c?.close("capture stopped: \(reason)") }
        }
        streamer = s
        c.send(.config, jsonData(["codec": s.codecMime, "width": w, "height": h, "fps": fps]))
        setState("已连接 \(name) · \(c.isUSB ? "USB" : "Wi-Fi") · \(fps)Hz \(hevc ? "HEVC" : "H.264")")
        Task {
            do {
                try await s.start()
            } catch {
                Log.info("capture start failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.sendStatus("Mac 屏幕采集启动失败：\(error.localizedDescription)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { c.close("capture start failed") }
                }
            }
        }
    }

    private func onStats(_ payload: Data) {
        guard let j = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let p50 = j["total_p50"] as? Double, p50 >= 0 else { statsLine = ""; return }
        statsLine = String(format: "延迟 %.0f ms（采集→解码中位数） · %.0f fps · %.1f Mbps", p50, j["fps"] as? Double ?? 0, j["mbps"] as? Double ?? 0)
    }

    private func detach(_ reason: String, usb wasUSB: Bool) {
        streamer?.stop()
        streamer = nil
        injector?.releaseAll()
        injector = nil
        conn = nil
        statsLine = ""
        if wasUSB {
            // Accessory mode stays on until the cable is pulled; do not hammer a tablet that left the app.
            DispatchQueue.main.asyncAfter(deadline: .now() + (reason == "no hello from tablet" ? 10 : 2)) { self.usb.linkClosed() }
        }
        // The tablet closing the link on purpose ends a manual session; errors keep it for reconnection.
        if reason == "tablet closed the connection" { manualTarget = nil }
        setState("已断开（\(reason)）")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.conn == nil else { return }
            self.display = nil
            self.setState("待命")
        }
        teardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.graceSeconds, execute: work)
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "ipad.landscape", accessibilityDescription: "PadLink")
            button.toolTip = "PadLink 平板副屏"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, _ rep: Any? = nil, on: Bool = false, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = rep
            item.state = on ? .on : .off
            item.isEnabled = enabled && action != nil
            menu.addItem(item)
        }
        let header = NSMenuItem(title: "平板副屏", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        var names = Set(discovered.keys)
        if let c = conn, c.isUSB { names.insert("USB") }
        if names.isEmpty {
            add("未发现平板 — 在平板上打开「Mac 副屏」或插上 USB 线", nil, enabled: false)
        }
        for name in names.sorted() {
            let connected = conn != nil && connName == name
            let label = name == "USB" ? "USB 有线连接" : name
            add(label + (connected ? "  ·  \(conn?.isUSB == true ? "USB" : "Wi-Fi")" : ""), #selector(togglePad(_:)), name, on: connected)
        }
        add("状态：\(state)", nil, enabled: false)
        if !statsLine.isEmpty { add(statsLine, nil, enabled: false) }

        menu.addItem(.separator())
        add("平板打开 App 时自动连接", #selector(toggleAuto), on: autoConnect)
        add("插上 USB 线时自动使用有线连接", #selector(toggleUSB), on: usbAuto)
        let rate = NSMenuItem(title: "刷新率", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for hz in [60, 120] {
            let i = NSMenuItem(title: "\(hz) Hz" + (hz == 120 ? "（默认，延时更低）" : "（更省电）"), action: #selector(setRate(_:)), keyEquivalent: "")
            i.target = self
            i.tag = hz
            i.state = fps == hz ? .on : .off
            sub.addItem(i)
        }
        rate.submenu = sub
        menu.addItem(rate)
        add("登录时启动 PadLink", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        add("隐私与安全性设置…", #selector(openPrivacy))
        menu.addItem(.separator())
        add("退出 PadLink", #selector(quit))
    }

    private func setState(_ s: String) {
        if state != s {
            state = s
            Log.info("state: \(s)")
        }
    }

    @objc private func togglePad(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if let c = conn, connName == name {
            manualTarget = nil
            if name != "USB" { suppressed.insert(name) }
            c.close("disconnected from menu")
        } else {
            suppressed.remove(name)
            manualTarget = name == "USB" ? nil : name
            if let c = conn { c.close("switching to \(name)") }
            tryConnect()
        }
    }

    /// padlink://connect[/<name>]  padlink://disconnect   (for Shortcuts, hotkeys and scripts)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "padlink" {
            let name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
            Log.info("url: \(url.absoluteString)")
            switch url.host {
            case "connect":
                guard let target = name.isEmpty ? discovered.keys.sorted().first : name else { continue }
                if let c = conn, connName == target { c.send(.show); continue }
                suppressed.remove(target)
                manualTarget = target
                conn?.close("switching to \(target)")
                tryConnect()
            case "disconnect":
                manualTarget = nil
                if let c = conn {
                    if !c.isUSB { suppressed.insert(connName) }
                    c.close("disconnected by URL")
                }
            default:
                break
            }
        }
    }

    @objc private func toggleAuto() { autoConnect.toggle() }
    @objc private func toggleUSB() { usbAuto.toggle() }

    @objc private func setRate(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: "fps")
        if let c = conn { c.close("refresh rate changed") }   // reconnects with the new rate
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            Log.info("login item: \(error.localizedDescription)")
        }
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func quit() {
        conn?.close("quit")
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()
