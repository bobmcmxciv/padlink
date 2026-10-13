import AppKit
import QuartzCore

// Draws this Mac's wall clock (ms, 32-bit) as a barcode near the top-left of one display, every frame.
// Usage: LatencyProbe <displayID> [seconds]
// Bit i of row 0 is centred at (40 + 32*i + 16, 60 + 16) points from the display's top-left;
// row 1 holds the inverted bits 32 pt lower.
let args = CommandLine.arguments
let targetID = args.count > 1 ? UInt32(args[1]) ?? CGMainDisplayID() : CGMainDisplayID()
let seconds = args.count > 2 ? Double(args[2]) ?? 60 : 60

final class BarView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        let v = UInt32(truncatingIfNeeded: Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000)
        for i in 0..<32 {
            let bit = (v >> (31 - UInt32(i))) & 1 == 1
            (bit ? NSColor.white : NSColor.black).setFill()
            NSRect(x: i * 32, y: 0, width: 32, height: 32).fill()
            (bit ? NSColor.black : NSColor.white).setFill()
            NSRect(x: i * 32, y: 32, width: 32, height: 32).fill()
        }
    }

    private var ticks = 0
    private var since = CACurrentMediaTime()

    @objc func tick(_ link: CADisplayLink?) {
        needsDisplay = true
        ticks += 1
        let now = CACurrentMediaTime()
        if now - since >= 2 {
            print(String(format: "probe redraw %.1f fps", Double(ticks) / (now - since)))
            fflush(stdout)
            ticks = 0
            since = now
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let key = NSDeviceDescriptionKey("NSScreenNumber")
guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == targetID }) else {
    print("display \(targetID) not found")
    exit(1)
}
let frame = NSRect(x: screen.frame.minX + 40, y: screen.frame.maxY - 60 - 64, width: 1024, height: 64)
let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
win.level = .screenSaver
win.ignoresMouseEvents = true
win.collectionBehavior = [.canJoinAllSpaces, .stationary]
let view = BarView(frame: NSRect(origin: .zero, size: frame.size))
win.contentView = view
win.orderFrontRegardless()
if CommandLine.arguments.contains("--timer") {
    // Diagnostics: redraw from a 240 Hz timer instead of the display link.
    Timer.scheduledTimer(withTimeInterval: 1.0 / 240, repeats: true) { _ in view.tick(nil) }
} else {
    let link = view.displayLink(target: view, selector: #selector(BarView.tick(_:)))
    link.add(to: .main, forMode: .common)
}
print("screen maximumFramesPerSecond \(screen.maximumFramesPerSecond), mode refresh \(CGDisplayCopyDisplayMode(targetID)?.refreshRate ?? 0)")
print("probe on display \(targetID) frame \(screen.frame)")
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
app.run()
