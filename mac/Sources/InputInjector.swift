import AppKit
import CoreGraphics

/// Turns tablet input messages into macOS mouse / scroll / keyboard events on the virtual display.
/// Gesture interpretation (tap, drag, two-finger scroll, long press) happens on the tablet;
/// this side only maps coordinates and keeps button / click-count state.
final class InputInjector {
    enum Kind: UInt8 {
        case move = 1, down = 2, up = 3, drag = 4, scroll = 5, key = 6, magnify = 7
    }

    var displayID: CGDirectDisplayID
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown = Set<Int>()
    private var lastPoint = CGPoint.zero
    private var clickCount = 1
    private var lastClick: (button: Int, time: TimeInterval, point: CGPoint)?
    private var scrollRemainder = (x: 0.0, y: 0.0)
    /// Modifier keys held on the tablet keyboard. Tracked from their own key events (the tablet's meta state on a
    /// modifier's own event can be inverted) and applied to every keyboard, pointer and scroll event.
    private var heldModifiers: [CGKeyCode: CGEventFlags] = [:]
    private static let modifierKeys: [CGKeyCode: CGEventFlags] = [
        0x37: .maskCommand, 0x36: .maskCommand, 0x38: .maskShift, 0x3C: .maskShift,
        0x3B: .maskControl, 0x3E: .maskControl, 0x3A: .maskAlternate, 0x3D: .maskAlternate,
    ]
    private var modifiers: CGEventFlags {
        heldModifiers.values.reduce(into: CGEventFlags()) { $0.insert($1) }
    }

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        // Do not lock out the Mac's own trackpad/mouse after each injected event.
        source?.localEventsSuppressionInterval = 0
    }

    /// Payload layout (24 bytes, big-endian): u8 kind, u8 button, u8 phase, u8 momentumPhase,
    /// f32 x, f32 y, f32 a, f32 b, u32 extra. x/y are 0...1 across the display; a/b carry
    /// pressure or scroll deltas (fractions of display width/height); extra carries key data.
    func handle(_ payload: Data) {
        guard payload.count >= 24 else { return }
        var r = ByteReader(payload)
        guard let kind = Kind(rawValue: r.u8()) else { return }
        let button = Int(r.u8())
        let phase = Int64(r.u8())
        let momentum = Int64(r.u8())
        let x = Double(r.f32()), y = Double(r.f32())
        let a = Double(r.f32()), b = Double(r.f32())
        let extra = r.u32()

        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0 else { return }
        let point = CGPoint(x: bounds.minX + min(max(x, 0), 0.9999) * bounds.width,
                            y: bounds.minY + min(max(y, 0), 0.9999) * bounds.height)

        switch kind {
        case .move:
            lastPoint = point
            post(mouseType(dragging: buttonsDown.first ?? -1, fallback: .mouseMoved), at: point, button: buttonsDown.first ?? 0)
        case .down:
            let now = ProcessInfo.processInfo.systemUptime
            let slop = max(bounds.width, bounds.height) * 0.02
            if let last = lastClick, last.button == button, now - last.time < NSEvent.doubleClickInterval,
               hypot(last.point.x - point.x, last.point.y - point.y) < slop {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastClick = (button, now, point)
            buttonsDown.insert(button)
            lastPoint = point
            post(downType(button), at: point, button: button, pressure: a > 0 ? a : 1, clicks: clickCount)
        case .up:
            buttonsDown.remove(button)
            lastPoint = point
            post(upType(button), at: point, button: button, pressure: 0, clicks: clickCount)
        case .drag:
            lastPoint = point
            post(mouseType(dragging: button, fallback: .mouseMoved), at: point, button: button, pressure: a > 0 ? a : 1, clicks: clickCount)
        case .scroll:
            scrollRemainder.x += a * bounds.width
            scrollRemainder.y += b * bounds.height
            let dx = scrollRemainder.x.rounded(.towardZero), dy = scrollRemainder.y.rounded(.towardZero)
            scrollRemainder.x -= dx
            scrollRemainder.y -= dy
            if phase == 1 || momentum == 1 { scrollRemainder = (0, 0) }
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            e.location = lastPoint
            e.flags = modifiers
            e.post(tap: .cghidEventTap)
        case .magnify:
            postMagnify(delta: a, phase: phase)
        case .key:
            let keyCode = CGKeyCode(extra & 0xffff)
            let down = button == 1
            let tabletFlags = CGEventFlags(rawValue: UInt64(extra >> 16) << 16)
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
            if let flag = Self.modifierKeys[keyCode] {
                if down { heldModifiers[keyCode] = flag } else { heldModifiers.removeValue(forKey: keyCode) }
                e.type = .flagsChanged
                e.flags = modifiers
            } else {
                e.flags = modifiers.union(tabletFlags)
            }
            e.post(tap: .cghidEventTap)
        }
    }

    /// Pinch zoom. macOS has no public API for synthetic gestures; this is the gesture event layout
    /// the trackpad driver produces (type 29 = gesture, HID type 8 = zoom, field 113 = magnification).
    func postMagnify(delta: Double, phase: Int64) {
        guard let e = CGEvent(source: nil) else { return }
        e.setIntegerValueField(CGEventField(rawValue: 55)!, value: 29)
        e.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
        e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        e.setDoubleValueField(CGEventField(rawValue: 113)!, value: delta)
        e.location = lastPoint
        e.post(tap: .cghidEventTap)
    }

    /// Release anything still held when the tablet disconnects mid-gesture.
    func releaseAll() {
        for b in buttonsDown { post(upType(b), at: lastPoint, button: b, pressure: 0, clicks: 1) }
        buttonsDown.removeAll()
        for key in heldModifiers.keys {
            heldModifiers.removeValue(forKey: key)
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { continue }
            e.type = .flagsChanged
            e.flags = modifiers
            e.post(tap: .cghidEventTap)
        }
    }

    private func downType(_ b: Int) -> CGEventType { b == 0 ? .leftMouseDown : b == 1 ? .rightMouseDown : .otherMouseDown }
    private func upType(_ b: Int) -> CGEventType { b == 0 ? .leftMouseUp : b == 1 ? .rightMouseUp : .otherMouseUp }
    private func mouseType(dragging b: Int, fallback: CGEventType) -> CGEventType {
        switch b {
        case 0: return .leftMouseDragged
        case 1: return .rightMouseDragged
        case 2: return .otherMouseDragged
        default: return fallback
        }
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: Int, pressure: Double = 0, clicks: Int = 1) {
        let cgButton = CGMouseButton(rawValue: UInt32(button)) ?? .left
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        if button == 2 { e.setIntegerValueField(.mouseEventButtonNumber, value: 2) }
        if type != .mouseMoved { e.setDoubleValueField(.mouseEventPressure, value: pressure) }
        e.flags = modifiers      // Cmd-click / Shift-click with the tablet keyboard
        e.post(tap: .cghidEventTap)
    }
}

extension InputInjector {
    static func payload(_ kind: Kind, button: UInt8 = 0, phase: UInt8 = 0, momentum: UInt8 = 0,
                        x: Float, y: Float, a: Float = 0, b: Float = 0, extra: UInt32 = 0) -> Data {
        var w = ByteWriter()
        w.u8(kind.rawValue); w.u8(button); w.u8(phase); w.u8(momentum)
        w.u32(x.bitPattern); w.u32(y.bitPattern); w.u32(a.bitPattern); w.u32(b.bitPattern); w.u32(extra)
        return w.data
    }

    /// Diagnostics: replays a short gesture sequence at the centre of the main display.
    static func selfTest(done: @escaping () -> Void) {
        let inj = InputInjector(displayID: CGMainDisplayID())
        var steps: [Data] = [payload(.move, x: 0.5, y: 0.5)]
        steps.append(payload(.scroll, phase: 1, x: 0.5, y: 0.5, b: 0.01))
        for _ in 0..<8 { steps.append(payload(.scroll, phase: 2, x: 0.5, y: 0.5, b: 0.01)) }
        steps.append(payload(.scroll, phase: 4, x: 0.5, y: 0.5))
        for i in 0..<5 { steps.append(payload(.scroll, momentum: i == 0 ? 1 : 2, x: 0.5, y: 0.5, b: 0.005)) }
        steps.append(payload(.scroll, momentum: 3, x: 0.5, y: 0.5))
        steps.append(payload(.magnify, phase: 1, x: 0.5, y: 0.5))
        for _ in 0..<6 { steps.append(payload(.magnify, phase: 2, x: 0.5, y: 0.5, a: 0.05)) }
        steps.append(payload(.magnify, phase: 4, x: 0.5, y: 0.5))
        for _ in 0..<2 {
            steps.append(payload(.down, button: 0, x: 0.5, y: 0.5, a: 1))
            steps.append(payload(.up, button: 0, x: 0.5, y: 0.5))
        }
        steps.append(payload(.down, button: 1, x: 0.5, y: 0.5, a: 1))
        steps.append(payload(.up, button: 1, x: 0.5, y: 0.5))
        for (i, s) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(i) * 0.03) { inj.handle(s) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(steps.count) * 0.03, execute: done)
    }
}
