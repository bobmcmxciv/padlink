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
                            done?()
                        }
                    }
                }
            }
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
                guard let d = displays.first(where: { CGDisplayBounds($0).contains(center) }) else { continue }
                let b = CGDisplayBounds(d)
                out.append(Tracked(element: w, display: d, offset: CGPoint(x: frame.minX - b.minX, y: frame.minY - b.minY)))
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
