import AppKit
import SwiftUI

/// A transient clipboard picker. The full library remains in the workspace.
@MainActor final class ClipboardPanelController: NSObject, NSWindowDelegate {
    static let shared = ClipboardPanelController()
    private enum PositionKey {
        static let x = "clipboardPanel.origin.x"
        static let y = "clipboardPanel.origin.y"
    }

    private var panel: IslandPanel?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        ClipboardStore.shared.rememberPasteDestination()
        if panel == nil {
            let window = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Clipboard"
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.delegate = self
            window.dismissHandler = { [weak self] in self?.hide() }
            panel = window
        }
        guard let panel else { return }
        // A fresh hosting root makes each opening begin with an empty search and
        // a focused query field, even after a previous hidden-window session.
        let host = NSHostingView(rootView: ClipboardStripView(onClose: { [weak self] in self?.hide() }, onOpenLibrary: { [weak self] in
            self?.hide(); AppState.shared.page = .clipboard; AppDelegate.shared?.openWorkspace()
        }).preferredColorScheme(.dark))
        host.sizingOptions = []
        panel.contentView = host
        position()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.alphaValue = 1 }
        else { NSAnimationContext.runAnimationGroup { context in context.duration = 0.16; panel.animator().alphaValue = 1 } }
        installDismissal()
    }

    func toggle() { isVisible ? hide() : show() }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible, notification.object as? NSWindow === panel else { return }
        hide()
    }

    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, let panel else { return }
        UserDefaults.standard.set(Double(panel.frame.origin.x), forKey: PositionKey.x)
        UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: PositionKey.y)
    }

    private func position() {
        guard let panel, let fallbackScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let defaults = UserDefaults.standard
        let savedX = defaults.object(forKey: PositionKey.x) as? Double
        let savedY = defaults.object(forKey: PositionKey.y) as? Double
        let savedOrigin = savedX.flatMap { x in savedY.map { y in NSPoint(x: x, y: y) } }

        let screen: NSScreen
        if let savedOrigin {
            let probe = NSRect(origin: savedOrigin, size: panel.frame.size)
            screen = NSScreen.screens.max { lhs, rhs in
                lhs.visibleFrame.intersection(probe).area < rhs.visibleFrame.intersection(probe).area
            } ?? fallbackScreen
        } else {
            screen = fallbackScreen
        }
        let visible = screen.visibleFrame
        let width = min(1040, max(320, visible.width - 48))
        let height = min(290, max(220, visible.height - 48))
        let defaultOrigin = NSPoint(x: visible.midX - width / 2, y: visible.minY + 18)
        let origin = ClipboardPanelPlacement.clampedOrigin(
            savedOrigin ?? defaultOrigin,
            windowSize: NSSize(width: width, height: height),
            visibleFrame: visible
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    private func installDismissal() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53, NSApp.modalWindow == nil {
                self.hide(); return nil
            }
            if event.type != .keyDown, let window = event.window, window !== self.panel {
                self.hide()
            }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.position() }
        }
    }
}

enum ClipboardPanelPlacement {
    static func clampedOrigin(
        _ origin: NSPoint,
        windowSize: NSSize,
        visibleFrame: NSRect,
        margin: CGFloat = 8
    ) -> NSPoint {
        let safe = visibleFrame.insetBy(dx: min(margin, visibleFrame.width / 2), dy: min(margin, visibleFrame.height / 2))
        let maximumX = max(safe.minX, safe.maxX - windowSize.width)
        let maximumY = max(safe.minY, safe.maxY - windowSize.height)
        return NSPoint(
            x: min(max(origin.x, safe.minX), maximumX),
            y: min(max(origin.y, safe.minY), maximumY)
        )
    }
}

private extension NSRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
