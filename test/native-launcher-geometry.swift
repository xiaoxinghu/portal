// SPDX-License-Identifier: GPL-3.0-or-later
// The launcher panel's placement arithmetic, with no application, window or
// focus: the rectangle for each size and offset on captured display areas,
// clamped to them, and fitted heights. test/native-launcher.swift and the
// graphical suite place real panels.
import AppKit

@main
struct LauncherGeometryChecks {
    @MainActor static func main() {
        runChecks {
            func placement(_ width: Int64 = 713, _ height: Int64 = 407,
                           _ dx: Int64 = 0, _ dy: Int64 = 0) -> NativeLauncher.Placement {
                .init(width: width, height: height, dx: dx, dy: dy, screen: -1, shadow: true, radius: 14)
            }
            // Captured experiment displays; same physical point placement at
            // either Retina scale. Synthetic negative-X origins cover left displays.
            let areas = [NSRect(x: 0, y: 0, width: 2560, height: 1410),
                         NSRect(x: 2560, y: -483, width: 1440, height: 2530),
                         NSRect(x: -1920, y: -300, width: 1920, height: 1057)]
            for area in areas {
                for (width, height): (Int64, Int64) in [(640, 320), (720, 420), (860, 520), (713, 407)] {
                    let rect = NativeLauncher.rectangle(placement(width, height, -137, 81), in: area)
                    check(rect.width == CGFloat(width) && rect.height == CGFloat(height))
                    check(rect.minX == floor(area.midX - CGFloat(width) / 2 - 137))
                    check(rect.minY == floor(area.midY - CGFloat(height) / 2 - 81))
                    check(area.contains(rect))
                }
                check(NativeLauncher.rectangle(placement(100000, 100000, -100000, 100000), in: area) == area)
                check(NativeLauncher.rectangle(placement(713, 407, -100000, 100000), in: area).origin == area.origin)
                // Fitting keeps the left, width and top edges of the first
                // placement, moving only the bottom edge, within the area.
                let placed = NativeLauncher.rectangle(placement(713, 100, -137, 81), in: area)
                for height: Int64 in [100, 164, 407, 120] {
                    let fitted = NativeLauncher.fitted(placed, height: height, in: area)
                    check(fitted.minX == placed.minX && fitted.width == placed.width && fitted.maxY == placed.maxY)
                    check(fitted.height == CGFloat(height) && area.contains(fitted))
                }
                let tall = NativeLauncher.fitted(placed, height: 100000, in: area)
                check(tall.maxY == placed.maxY && tall.minY == area.minY && tall.minX == placed.minX)
                let low = NativeLauncher.rectangle(placement(713, 100, 0, 100000), in: area)
                check(NativeLauncher.fitted(low, height: 407, in: area) == low)
            }
            print("Launcher geometry checks passed: placement and fitting on \(areas.count) display areas")
        }
    }
}
