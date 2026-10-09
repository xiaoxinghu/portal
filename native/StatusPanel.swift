// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import PortalCore

/// The screens and the status panel of portal.h: portal_screens,
/// portal_status_measure, portal_status_show and portal_status_hide. The core
/// decides the panel's rectangle; this draws it: text on the system's HUD
/// material, after a mark for the tone, with a hairline edge: a spinner, a
/// symbol, or a red dot that breathes unless the user asked to reduce motion.
/// The panel floats
/// above every application's windows, on every Space and over fullscreen
/// apps. It never becomes key or main and ignores the mouse, and showing it
/// never activates Emacs, so the frontmost application keeps the keyboard.
@MainActor
enum StatusPanel {
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let padding = NSSize(width: 14, height: 8)
    static let markSize: CGFloat = 16
    static let spacing: CGFloat = 7
    static let fadeIn = 0.12, fadeOut = 0.2

    private(set) static var panel: Panel?
    /// Counts shows and hides, so a fade-out that a show interrupted leaves the panel up.
    private static var generation = 0

    final class Panel: NSPanel {
        let background = NSVisualEffectView()
        let edge = NSView()
        let label = StatusPanel.field()
        let mark = NSImageView()
        let spinner = NSProgressIndicator()
        let dot = NSView()
        fileprivate(set) var tone = PORTAL_STATUS_NEUTRAL
        fileprivate(set) var hiding = false

        init() {
            super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: true)
            isReleasedWhenClosed = false
            hidesOnDeactivate = false
            isFloatingPanel = true
            level = .statusBar
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            ignoresMouseEvents = true
            tabbingMode = .disallowed
            animationBehavior = .none
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            background.material = .hudWindow
            background.blendingMode = .behindWindow
            background.state = .active
            edge.wantsLayer = true
            mark.imageScaling = .scaleProportionallyDown
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            dot.wantsLayer = true
            for view in [mark, spinner, dot, label, edge] { background.addSubview(view) }
            contentView = background
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// A label as the panel draws text: wrapped to its lines, the last cut short.
    private static func field(_ text: String = "", lines: Int = 1) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = .labelColor
        field.isSelectable = false
        field.maximumNumberOfLines = lines
        field.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    /// The width of TONE's mark and the space after it.
    private static func markWidth(_ tone: portal_status_tone) -> CGFloat {
        tone == PORTAL_STATUS_NEUTRAL ? 0 : markSize + spacing
    }

    /// The size of TEXT on at most LINES lines at most WIDTH wide.
    private static func textSize(_ text: String, width: CGFloat, lines: Int) -> NSSize {
        let size = field(text, lines: lines).cell!.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: max(width, 1), height: .greatestFiniteMagnitude))
        let line = ceil(NSLayoutManager().defaultLineHeight(for: font))
        return NSSize(width: min(ceil(size.width), max(width, 1)),
                      height: min(ceil(size.height), line * CGFloat(lines)))
    }

    // MARK: Screens

    /// The top of the primary screen, from which the core's plane measures y downward.
    private static var top: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func screens() -> [portal_screen] {
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let under = screens.firstIndex { NSMouseInRect(pointer, $0.frame, false) } ?? 0
        return screens.enumerated().map { index, screen in
            let area = screen.visibleFrame
            return portal_screen(area: portal_rect(x: Int64(ceil(area.minX)), y: Int64(ceil(top - area.maxY)),
                                                   width: Int64(floor(area.width)),
                                                   height: Int64(floor(area.height))),
                                 pointer: index == under)
        }
    }

    // MARK: Panel

    static func measure(_ text: String, tone: portal_status_tone, width: Int64, lines: Int64) -> (Int64, Int64) {
        let chrome = 2 * padding.width + markWidth(tone)
        let size = textSize(text, width: CGFloat(width) - chrome, lines: Int(lines))
        let height = max(size.height, tone == PORTAL_STATUS_NEUTRAL ? 0 : markSize) + 2 * padding.height
        return (min(Int64(size.width + chrome), width), Int64(height))
    }

    static func show(_ text: String, tone: portal_status_tone, rect: portal_rect, lines: Int64) {
        let panel = panel ?? Panel()
        self.panel = panel
        generation += 1
        let frame = NSRect(x: CGFloat(rect.x), y: top - CGFloat(rect.y + rect.height),
                           width: CGFloat(rect.width), height: CGFloat(rect.height))
        let changed = panel.label.stringValue != text
        layOut(panel, text: text, tone: tone, size: frame.size, lines: Int(lines))
        panel.setFrame(frame, display: true)
        if !panel.isVisible || panel.hiding {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.hiding = false
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = fadeIn; panel.animator().alphaValue = 1 }
        }
        if changed {
            // VoiceOver reads what the user cannot reach: the panel takes no focus.
            NSAccessibility.post(element: panel, notification: .announcementRequested,
                                 userInfo: [.announcement: text,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    static func hide() {
        guard let panel, panel.isVisible, !panel.hiding else { return }
        generation += 1
        let hiding = generation
        panel.hiding = true
        NSAnimationContext.runAnimationGroup({ $0.duration = fadeOut; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { finishHiding(hiding) }
        }
    }

    /// Order the panel out once its fade-out ends, unless a show or hide came since HIDING.
    private static func finishHiding(_ hiding: Int) {
        guard generation == hiding, let panel else { return }
        panel.orderOut(nil)
        panel.hiding = false
        panel.spinner.stopAnimation(nil)
        panel.dot.layer?.removeAnimation(forKey: breathing)
    }

    /// Fill PANEL, SIZE big: TONE's mark, then TEXT centered vertically.
    private static func layOut(_ panel: Panel, text: String, tone: portal_status_tone, size: NSSize, lines: Int) {
        let bounds = NSRect(origin: .zero, size: size)
        let radius = min(size.height / 2, 18)
        panel.background.frame = bounds
        panel.background.maskImage = rounded(radius)
        panel.edge.frame = bounds
        panel.edge.layer?.cornerRadius = radius
        panel.edge.layer?.borderWidth = 1
        panel.background.effectiveAppearance.performAsCurrentDrawingAppearance {
            panel.edge.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }

        let markFrame = NSRect(x: padding.width, y: floor((size.height - markSize) / 2),
                               width: markSize, height: markSize)
        panel.tone = tone
        panel.mark.isHidden = marks[tone.rawValue] == nil
        panel.mark.frame = markFrame
        if case let (symbol, color)? = marks[tone.rawValue] {
            panel.mark.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
            panel.mark.contentTintColor = color
        }
        panel.spinner.frame = markFrame
        if tone == PORTAL_STATUS_PROGRESS { panel.spinner.startAnimation(nil) } else { panel.spinner.stopAnimation(nil) }
        layOutDot(panel, in: markFrame)

        let x = padding.width + markWidth(tone)
        let width = max(size.width - x - padding.width, 1)
        let height = min(textSize(text, width: width, lines: lines).height, size.height)
        panel.label.stringValue = text
        panel.label.maximumNumberOfLines = lines
        panel.label.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        panel.label.frame = NSRect(x: x, y: floor((size.height - height) / 2), width: width, height: height)
    }

    static let dotSize: CGFloat = 10
    /// The key of the dot's breathing animation.
    static let breathing = "breathing"

    /// Show the recording tone's red dot centered in FRAME, breathing, or hide it for another tone.
    private static func layOutDot(_ panel: Panel, in frame: NSRect) {
        let recording = panel.tone == PORTAL_STATUS_RECORDING
        panel.dot.isHidden = !recording
        guard recording, let layer = panel.dot.layer else {
            panel.dot.layer?.removeAnimation(forKey: breathing)
            return
        }
        panel.dot.frame = NSRect(x: frame.midX - dotSize / 2, y: frame.midY - dotSize / 2,
                                 width: dotSize, height: dotSize)
        layer.cornerRadius = dotSize / 2
        panel.background.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.systemRed.cgColor
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            layer.removeAnimation(forKey: breathing)
        } else if layer.animation(forKey: breathing) == nil {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 0.3
            animation.duration = 0.9
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: breathing)
        }
    }

    /// Symbol and color of each tone with a still mark, by raw value.
    private static let marks: [UInt32: (String, NSColor)] = [
        PORTAL_STATUS_SUCCESS.rawValue: ("checkmark.circle.fill", .systemGreen),
        PORTAL_STATUS_WARNING.rawValue: ("exclamationmark.triangle.fill", .systemYellow),
        PORTAL_STATUS_ERROR.rawValue: ("xmark.circle.fill", .systemRed),
    ]

    /// A mask that rounds any rectangle's corners by RADIUS.
    private static func rounded(_ radius: CGFloat) -> NSImage {
        let side = 2 * radius + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
