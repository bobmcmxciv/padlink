import AppKit
import ApplicationServices

/// Makes another display the main display while keeping every window on the physical screen it was on.
///
/// macOS keeps window coordinates relative to the main display, so changing the main display swaps windows
/// between screens. A secondary virtual display is also composited at the main display's cadence (60 Hz on a
/// 60 Hz MacBook panel); as the main display it runs at its own 120 Hz. This switches the main display and then
/// puts windows back with the Accessibility API. (The Dock and the menu bar go with the main display.)
final class WindowKeeper {
    private struct Tracked {
        let element: AXUIElement
        let display: CGDirectDisplayID
        let offset: CGPoint
    }

    private(set) var originalMain: CGDirectDisplayID?
    private let queue = DispatchQueue(label: "padlink.windows")

    var isSwitched: Bool { originalMain != nil && CGMainDisplayID() != originalMain }

    /// Make `display` the main display. Calls `done` on the main queue.
    func makeMain(_ display: CGDirectDisplayID, done: (() -> Void)? = nil) {
        guard CGMainDisplayID() != display else { done?(); return }
        if originalMain == nil { originalMain = CGMainDisplayID() }
        switchMain(to: display, done: done)
    }

    /// Give the main display back to the screen that had it before `makeMain`.
    func restore(done: (() -> Void)? = nil) {
        guard let original = originalMain else { done?(); return }
        originalMain = nil
        guard activeDisplays().contains(original), CGMainDisplayID() != original else { done?(); return }
        switchMain(to: original, done: done)
    }

    private func switchMain(to target: CGDirectDisplayID, done: (() -> Void)?) {
        busy = true
        queue.async {
            let tracked = self.snapshot()
            DispatchQueue.main.async {
                // Shift every display by the same amount: the arrangement stays, only the origin moves.
                let shift = CGDisplayBounds(target).origin
                var cfg: CGDisplayConfigRef?
                CGBeginDisplayConfiguration(&cfg)
                for id in self.activeDisplays() {
                    let o = CGDisplayBounds(id).origin
                    CGConfigureDisplayOrigin(cfg, id, Int32(o.x - shift.x), Int32(o.y - shift.y))
                }
                let err = CGCompleteDisplayConfiguration(cfg, .forSession)
                Log.info("main display -> \(target) (\(err.rawValue)), keeping \(tracked.count) windows in place")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.queue.async {
                        var moved = self.place(tracked)
                        Thread.sleep(forTimeInterval: 0.8)
                        moved += self.place(tracked)      // a second pass for windows that were still animating
                        Log.info("windows put back: \(moved) position updates")
                        DispatchQueue.main.async {
                            self.busy = false
                            done?()
                        }
                    }
                }
            }
        }
    }

    // MARK: Layout memory
    // Which screen (Mac or tablet) each window belongs to, refreshed while the layout is stable, so windows can be
    // put back after the tablet display vanished unexpectedly (sleep, lock, cable) and macOS shuffled them.

    private struct Remembered {
        let element: AXUIElement
        let onTablet: Bool
        let fx: CGFloat, fy: CGFloat     // origin as a fraction of the screen size
    }
    private var memory: [Remembered] = []
    private(set) var busy = false
    var hasMemory: Bool { !memory.isEmpty }

    /// Record the current layout. Only call while both screens are present and nothing is reconfiguring.
    func remember(tablet: CGDirectDisplayID, builtin: CGDirectDisplayID) {
        guard !busy else { return }
        queue.async {
            let now = self.snapshot().compactMap { t -> Remembered? in
                guard t.display == tablet || t.display == builtin else { return nil }
                let b = CGDisplayBounds(t.display)
                return Remembered(element: t.element, onTablet: t.display == tablet,
                                  fx: t.offset.x / max(b.width, 1), fy: t.offset.y / max(b.height, 1))
            }
            guard !now.isEmpty else { return }
            // People move windows one or two at a time; many windows changing screen at once means the system
            // shuffled them, and the old layout is the one to keep.
            let changed = now.filter { n in self.memory.contains { CFEqual($0.element, n.element) && $0.onTablet != n.onTablet } }.count
            if !self.memory.isEmpty && changed > max(2, now.count / 2) {
                Log.info("window layout: \(changed) windows changed screen at once, keeping the remembered layout")
                return
            }
            self.memory = now
        }
    }

    /// Put every remembered window back on its screen.
    func restoreLayout(tablet: CGDirectDisplayID, builtin: CGDirectDisplayID, done: ((Int) -> Void)? = nil) {
        queue.async {
            let tb = CGDisplayBounds(tablet), mb = CGDisplayBounds(builtin)
            let tracked = self.memory.map { m -> Tracked in
                let b = m.onTablet ? tb : mb
                return Tracked(element: m.element, display: m.onTablet ? tablet : builtin, offset: CGPoint(x: m.fx * b.width, y: m.fy * b.height))
            }
            var moved = self.place(tracked)
            Thread.sleep(forTimeInterval: 0.6)
            moved += self.place(tracked)
            Log.info("window layout restored: \(tracked.count) windows, \(moved) position updates")
            DispatchQueue.main.async { done?(moved) }
        }
    }

    /// Move every window on screen `a` to screen `b` and the other way round, at the same relative position.
    func swapWindows(_ a: CGDirectDisplayID, _ b: CGDirectDisplayID, done: ((Int) -> Void)? = nil) {
        queue.async {
            let tracked = self.snapshot().compactMap { t -> Tracked? in
                guard t.display == a || t.display == b else { return nil }
                let to = t.display == a ? b : a
                let from = CGDisplayBounds(t.display), dest = CGDisplayBounds(to)
                // Keep the position proportional, so windows fit screens of different sizes.
                let x = t.offset.x / max(from.width, 1) * dest.width, y = t.offset.y / max(from.height, 1) * dest.height
                return Tracked(element: t.element, display: to, offset: CGPoint(x: x, y: y))
            }
            var moved = self.place(tracked)
            Thread.sleep(forTimeInterval: 0.6)
            moved += self.place(tracked)
            Log.info("swapped \(tracked.count) windows between displays \(a) and \(b)")
            DispatchQueue.main.async { done?(moved) }
        }
    }

    // MARK: Windows

    private func snapshot() -> [Tracked] {
        var out: [Tracked] = []
        let displays = activeDisplays()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for w in windows {
                if boolAttr(w, kAXMinimizedAttribute) || boolAttr(w, "AXFullScreen") { continue }
                guard let frame = frame(of: w) else { continue }
                let center = CGPoint(x: frame.midX, y: frame.midY)
                // A window left outside every screen (e.g. after a display vanished) belongs to the nearest one
                // and is pulled back into view.
                guard let d = displays.first(where: { CGDisplayBounds($0).contains(center) })
                        ?? displays.min(by: { distance(center, CGDisplayBounds($0)) < distance(center, CGDisplayBounds($1)) }) else { continue }
                let b = CGDisplayBounds(d)
                let ox = min(max(frame.minX - b.minX, 0), max(0, b.width - min(frame.width, b.width)))
                let oy = min(max(frame.minY - b.minY, 0), max(0, b.height - min(frame.height, b.height)))
                out.append(Tracked(element: w, display: d, offset: CGPoint(x: ox, y: oy)))
            }
        }
        return out
    }

    /// Returns how many windows needed moving.
    private func place(_ tracked: [Tracked]) -> Int {
        var moved = 0
        for t in tracked {
            let b = CGDisplayBounds(t.display)
            var target = CGPoint(x: b.minX + t.offset.x, y: b.minY + t.offset.y)
            if let f = frame(of: t.element), abs(f.minX - target.x) < 1, abs(f.minY - target.y) < 1 { continue }
            guard let v = AXValueCreate(.cgPoint, &target) else { continue }
            if AXUIElementSetAttributeValue(t.element, kAXPositionAttribute as CFString, v) == .success { moved += 1 }
        }
        return moved
    }

    private func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    private func frame(of w: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success,
              let pv = pos, let sv = size else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private func boolAttr(_ w: AXUIElement, _ name: String) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(w, name as CFString, &v) == .success && (v as? Bool) == true
    }

    private func activeDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return Array(ids.prefix(Int(n)))
    }
}
