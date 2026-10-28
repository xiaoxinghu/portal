// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

// The status panel through the core's status.h, as the Emacs bindings call
// it, on the real screens and panel, with no Portal view or launcher.
// test/portal-status-tests.c covers the placement rules; this covers what
// AppKit makes of them. Whether it shows on other Spaces and over fullscreen
// apps, and keeps another app's keyboard, is a manual check.
@main
struct StatusChecks {
    @MainActor static func main() {
        runChecks {
            _ = NSApplication.shared
            /// Show TEXT with TONE as the bindings would, with LAYOUT's integers.
            func show(_ text: String, _ tone: String = "neutral", at position: String = "bottom",
                      dx: Int64 = 0, dy: Int64 = 24, width: Int64 = 0, height: Int64 = 0,
                      maxWidth: Int64 = 0, lines: Int64 = 1, file: StaticString = #filePath, line: UInt = #line) {
                var error = portal_text()
                defer { free(error.data) }
                let shown = text.withCString { t in tone.withCString { n in position.withCString { p in
                    var layout = portal_status_layout(
                        position: portal_string(data: p, length: position.utf8.count), screen: -1, dx: dx, dy: dy,
                        width: width, height: height, min_width: 0, max_width: maxWidth, lines: lines)
                    return portal_status_present(portal_string(data: t, length: text.utf8.count),
                                                 portal_string(data: n, length: tone.utf8.count), &layout, &error)
                } } }
                if !shown { fail("Cannot show \(text): \(String(cString: error.data))", file: file, line: line) }
            }
            func hide() {
                var error = portal_text()
                defer { free(error.data) }
                check(portal_status_dismiss(&error))
            }
            /// Let fades run.
            func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
            func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }

            // Hiding before anything was shown does nothing.
            hide()
            check(StatusPanel.panel == nil)

            let active = NSApp.isActive
            let frontmost = NSWorkspace.shared.frontmostApplication
            let keyWindow = NSApp.keyWindow
            show("Recording")
            settle()
            let panel = require(StatusPanel.panel)
            check(panel.isVisible && panel.alphaValue == 1 && panel.label.stringValue == "Recording")
            check(!panel.canBecomeKey && !panel.canBecomeMain && !panel.isKeyWindow)
            check(NSApp.isActive == active && NSApp.keyWindow === keyWindow)
            check(NSWorkspace.shared.frontmostApplication == frontmost)
            check(panel.ignoresMouseEvents && panel.level == .statusBar)
            check(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
            check(panel.styleMask.contains(.nonactivatingPanel))

            // Bottom center of the pointer's screen, 24 points up, the text
            // inside: one line, unmarked.
            let area = require(panel.screen?.visibleFrame)
            let first = panel.frame
            check(near(first.midX, area.midX) && near(first.minY, area.minY + 24), "Misplaced: \(first) in \(area)")
            check(panel.mark.isHidden && !panel.label.isHidden)
            check(panel.contentView!.bounds.contains(panel.label.frame), "Text outside: \(panel.label.frame)")
            check(panel.label.frame.width >= panel.label.fittingSize.width - 1, "Text cut: \(panel.label.frame)")

            // A corner, moved inward.
            show("Recording", at: "top-right", dx: 10, dy: 20)
            check(near(panel.frame.maxX, area.maxX - 10) && near(panel.frame.maxY, area.maxY - 20),
                  "Misplaced: \(panel.frame) in \(area)")
            show("Recording", at: "center", dx: 0, dy: 0)
            check(near(panel.frame.midX, area.midX) && near(panel.frame.midY, area.midY))

            // Tones: a spinner for progress, a sign for the others; both widen the panel.
            show("Recording", "progress")
            check(panel.tone == PORTAL_STATUS_PROGRESS && panel.mark.isHidden && !panel.spinner.isHidden)
            check(panel.frame.width > first.width && near(panel.frame.midX, area.midX))
            check(panel.label.frame.minX >= panel.spinner.frame.maxX)
            show("Recording", "error")
            check(panel.tone == PORTAL_STATUS_ERROR && !panel.mark.isHidden && panel.mark.image != nil)

            // Wrapping at a maximum width, up to the lines allowed.
            let long = String(repeating: "Transcribing a long dictation ", count: 6)
            show(long, maxWidth: 240)
            let single = panel.frame
            check(single.width <= 240 && single.width > 200, "Not at its maximum: \(single)")
            show(long, maxWidth: 240, lines: 3)
            check(panel.frame.width <= 240 && panel.frame.height > single.height + 20, "Not wrapped: \(panel.frame)")
            check(panel.contentView!.bounds.contains(panel.label.frame))
            // A fixed size; text wider than the screen is cut, not the panel.
            show("Done", width: 300, height: 60)
            check(panel.frame.width == 300 && panel.frame.height == 60)
            show(String(repeating: "Very long status ", count: 500))
            check(area.contains(panel.frame), "Off screen: \(panel.frame) in \(area)")

            // With PORTAL_STATUS_SCREENSHOTS naming a directory, save each tone's
            // panel there, for a person to look at. Its layers render on a gray
            // backdrop; the material's blur of what is behind it does not.
            if let directory = ProcessInfo.processInfo.environment["PORTAL_STATUS_SCREENSHOTS"] {
                for (tone, text) in [("neutral", "Ready"), ("progress", "Transcribing…"),
                                     ("success", "Pasted"), ("warning", "On the clipboard"),
                                     ("error", "Failed: the recorder exited abnormally with code 2")] {
                    show(text, tone)
                    settle()
                    let view = require(panel.contentView)
                    let scale = panel.backingScaleFactor
                    let size = NSSize(width: view.bounds.width + 40, height: view.bounds.height + 40)
                    let context = require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                                    bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.scaleBy(x: scale, y: scale)
                    context.setFillColor(NSColor.gray.cgColor)
                    context.fill(CGRect(origin: .zero, size: size))
                    context.translateBy(x: 20, y: 20)
                    view.displayIfNeeded()
                    require(view.layer).render(in: context)
                    let png = NSBitmapImageRep(cgImage: require(context.makeImage())).representation(using: .png, properties: [:])
                    check(FileManager.default.createFile(atPath: "\(directory)/status-\(tone).png", contents: png))
                }
            }

            // Hiding fades out; a show during the fade keeps the panel up.
            hide()
            settle()
            check(!panel.isVisible)
            hide()
            show("Done", "success")
            hide()
            show("Done again", "success")
            settle()
            check(StatusPanel.panel === panel && panel.isVisible && panel.alphaValue == 1)
            check(panel.label.stringValue == "Done again")
            check(NSApp.isActive == active && NSWorkspace.shared.frontmostApplication == frontmost)
            hide()
            settle()
            check(!panel.isVisible)
        }
        print("Status checks passed")
    }
}
