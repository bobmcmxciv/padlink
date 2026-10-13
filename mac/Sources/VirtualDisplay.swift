import Foundation
import CoreGraphics

/// A macOS display that exists only while this object is alive.
/// The default mode is HiDPI at half the tablet's pixel size, so the backing store matches the panel 1:1.
final class PadVirtualDisplay {
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    private let display: CGVirtualDisplay

    var displayID: CGDirectDisplayID { display.displayID }

    init?(name: String, pixelWidth: Int, pixelHeight: Int, refreshRate: Double, xdpi: Double, ydpi: Double, serial: UInt32) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate

        // Scaled "more space" modes render above panel resolution and are downsampled on capture.
        let largest = (w: Int(Double(pixelWidth) * 4 / 3), h: Int(Double(pixelHeight) * 4 / 3))

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(largest.w)
        descriptor.maxPixelsHigh = UInt32(largest.h)
        let mmW = xdpi > 0 ? Double(pixelWidth) / xdpi * 25.4 : 240
        let mmH = ydpi > 0 ? Double(pixelHeight) / ydpi * 25.4 : 160
        descriptor.sizeInMillimeters = CGSize(width: mmW, height: mmH)
        descriptor.vendorID = 0x2717   // Xiaomi
        descriptor.productID = 0x5044
        descriptor.serialNum = serial
        display = CGVirtualDisplay(descriptor: descriptor)
        guard display.displayID != 0 else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        // Mode sizes are in points; with hiDPI the backing store is 2x.
        let base = (w: pixelWidth / 2, h: pixelHeight / 2)
        var modes = [CGVirtualDisplayMode(width: UInt32(base.w), height: UInt32(base.h), refreshRate: refreshRate)]
        for scale in [1.2, 4.0 / 3.0, 0.8] {
            let w = Int((Double(base.w) * scale).rounded()), h = Int((Double(base.h) * scale).rounded())
            modes.append(CGVirtualDisplayMode(width: UInt32(w), height: UInt32(h), refreshRate: refreshRate))
        }
        settings.modes = modes
        guard display.apply(settings) else { return nil }
        Log.info("virtual display \(displayID) created: \(name) \(pixelWidth)x\(pixelHeight)@\(refreshRate)")
    }

    deinit {
        Log.info("virtual display \(display.displayID) removed")
    }

    static func serial(for name: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return h & 0x7fff_ffff
    }
}
