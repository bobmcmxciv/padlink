import AppKit
import CoreGraphics

private typealias CGSConnectionID = Int32
@_silgen_name("_CGSDefaultConnection") private func _CGSDefaultConnection() -> CGSConnectionID
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: CGSConnectionID, _ target: CGSConnectionID, _ key: CFString, _ value: CFTypeRef) -> Int32

/// Mouse sharing without the extended display: push the pointer past the chosen screen edge and the Mac's
/// mouse and keyboard drive the tablet (through HidLink); come back past the tablet's edge to return.
final class MouseBridge {
    enum Side: String { case left, right }

    var side: Side = .left
    /// False while the tablet is in use as an extended display.
    var allowed = true
    var onRemoteChanged: ((Bool) -> Void)?

    private let hid: HidLink
    private var tap: CFMachPort?
    private(set) var remote = false
    private var vx = 0.0, vy = 0.0           // pointer estimate on the tablet, in tablet pixels
    private var buttons: UInt8 = 0
    private var pressed: [UInt8] = []
    private var wheelAcc = 0.0, panAcc = 0.0
    private var returnPoint = CGPoint.zero
    private var previousApp: NSRunningApplication?
    private let gain = 1.6                    // tablet pixels per Mac point of mouse movement

    init(hid: HidLink) {
        self.hid = hid
    }

    func start() {
        guard tap == nil else { return }
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        // 29 = gesture, 30 = dock control: trackpad three-finger swipes (Spaces, Mission Control).
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) } | (1 << 29) | (1 << 30)
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, info in
            let bridge = Unmanaged<MouseBridge>.fromOpaque(info!).takeUnretainedValue()
            return bridge.handle(type, event)
        }, userInfo: me)
        guard let tap else { Log.info("mouse bridge: event tap unavailable (Accessibility / Input Monitoring)"); return }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("mouse bridge: on, tablet on the \(side.rawValue)")
    }

    /// Give the pointer back to the Mac now (the extended display is taking over).
    func forceLeave() {
        if remote { leave() }
    }

    func stop() {
        if remote { leave() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
    }

    // MARK: Event tap

    private func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(e)
        }
        // Events PadLink itself injects (extended display input) pass untouched.
        if e.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return Unmanaged.passUnretained(e) }
        if !remote {
            if (type == .mouseMoved) && allowed && hid.isReady { checkEdge(e) }
            return Unmanaged.passUnretained(e)
        }
        // Trackpad system gestures (Spaces, Mission Control) are swallowed while the tablet has the pointer,
        // so they do not act on the Mac behind it.
        if type.rawValue == 29 || type.rawValue == 30 { return nil }
        forward(type, e)
        return nil
    }

    private func desktop() -> CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    private func checkEdge(_ e: CGEvent) {
        let p = e.location, d = desktop()
        let dx = e.getDoubleValueField(.mouseEventDeltaX)
        let atEdge = side == .left ? (p.x <= d.minX + 0.5 && dx < 0) : (p.x >= d.maxX - 1.5 && dx > 0)
        guard atEdge else { return }
        enter(at: p, desktop: d)
    }

    private func enter(at p: CGPoint, desktop d: CGRect) {
        remote = true
        returnPoint = CGPoint(x: side == .left ? d.minX + 4 : d.maxX - 5, y: p.y)
        let size = hid.tabletSize
        let frac = d.height > 0 ? (p.y - d.minY) / d.height : 0.5
        vx = side == .left ? size.width - 1 : 0
        vy = frac * size.height
        // Park the Mac pointer and hide it; the tablet now has the only visible pointer.
        _ = CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(), "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        // A background app cannot hide or freeze the pointer; while the tablet has the mouse PadLink is frontmost
        // (keyboard input goes to the tablet anyway) and the previous app comes back on return.
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
        CGWarpMouseCursorPosition(returnPoint)
        CGDisplayHideCursor(CGMainDisplayID())
        // Pin the tablet pointer to the edge it enters from, then bring it to the matching height.
        let towardEdge = side == .left ? 30000 : -30000
        hid.mouse(buttons: 0, dx: towardEdge, dy: -30000)
        hid.mouse(buttons: 0, dx: 0, dy: Int(vy))
        Log.info("mouse bridge: pointer moved to the tablet")
        onRemoteChanged?(true)
    }

    private func leave() {
        remote = false
        if pressed.count > 0 || buttons != 0 {
            hid.keyboard(modifiers: 0, usages: [])
            hid.mouse(buttons: 0, dx: 0, dy: 0)
        }
        pressed.removeAll(); buttons = 0
        CGWarpMouseCursorPosition(returnPoint)
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
        NSCursor.unhide()
        previousApp?.activate()
        previousApp = nil
        Log.info("mouse bridge: pointer back on the Mac")
        onRemoteChanged?(false)
    }

    private func forward(_ type: CGEventType, _ e: CGEvent) {
        guard hid.isReady else { leave(); return }
        // Keep the hidden Mac pointer parked at the edge it left from.
        if hypot(e.location.x - returnPoint.x, e.location.y - returnPoint.y) > 2 { CGWarpMouseCursorPosition(returnPoint) }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = e.getDoubleValueField(.mouseEventDeltaX) * gain
            let dy = e.getDoubleValueField(.mouseEventDeltaY) * gain
            let size = hid.tabletSize
            vx += dx; vy = min(max(vy + dy, 0), size.height - 1)
            // Leaving across the edge that faces the Mac.
            if side == .left && vx > size.width + 40 { leave(); return }
            if side == .right && vx < -40 { leave(); return }
            vx = min(max(vx, 0), size.width - 1)
            hid.mouse(buttons: buttons, dx: Int(dx.rounded()), dy: Int(dy.rounded()))
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let bit: UInt8 = (type == .leftMouseDown || type == .leftMouseUp) ? 1 : (type == .rightMouseDown || type == .rightMouseUp) ? 2 : 4
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            buttons = down ? buttons | bit : buttons & ~bit
            hid.mouse(buttons: buttons, dx: 0, dy: 0)
        case .scrollWheel:
            // Trackpads report pixels; a wheel notch on Android scrolls roughly 60 px.
            let continuous = e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let y = continuous ? e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) / 30 : e.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            let x = continuous ? e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) / 30 : e.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            wheelAcc += y; panAcc -= x
            let w = wheelAcc.rounded(.towardZero), pn = panAcc.rounded(.towardZero)
            wheelAcc -= w; panAcc -= pn
            if w != 0 || pn != 0 { hid.mouse(buttons: buttons, dx: 0, dy: 0, wheel: Int(w), pan: Int(pn)) }
        case .keyDown, .keyUp:
            let code = CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode))
            guard let usage = HIDKeys.usage[code] else { return }
            if type == .keyDown { if !pressed.contains(usage) { pressed.append(usage) } } else { pressed.removeAll { $0 == usage } }
            hid.keyboard(modifiers: HIDKeys.modifiers(e.flags), usages: pressed)
        case .flagsChanged:
            hid.keyboard(modifiers: HIDKeys.modifiers(e.flags), usages: pressed)
        default:
            break
        }
    }
}
