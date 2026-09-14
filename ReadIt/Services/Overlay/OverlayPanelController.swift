import AppKit
import SwiftUI

/// Panel that can become key so SwiftUI controls inside receive clicks.
final class ClickThroughHostingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayPanelController: ObservableObject {
    private var panel: ClickThroughHostingPanel?
    private var hideWorkItem: DispatchWorkItem?
    private weak var engine: TTSEngine?
    private weak var preferences: AppPreferences?

    func configure(engine: TTSEngine, preferences: AppPreferences) {
        self.engine = engine
        self.preferences = preferences
    }

    func show() {
        guard let engine, let preferences else { return }
        hideWorkItem?.cancel()

        if panel == nil {
            let panel = ClickThroughHostingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 86),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false // system shadow on clear panels draws a jagged black halo
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.animationBehavior = .utilityWindow
            panel.isMovableByWindowBackground = false
            panel.acceptsMouseMovedEvents = true

            let root = PlaybackPillView(onDismiss: { [weak self] in
                self?.engine?.dismiss()
                self?.hide()
            })
            .environmentObject(engine)
            .environmentObject(preferences)

            let hosting = NSHostingView(rootView: root)
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            hosting.frame = panel.contentView?.bounds ?? .zero
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            self.panel = panel
            OverlayHoverBridge.shared.cancelHide = { [weak self] in
                self?.cancelHide()
            }
            OverlayHoverBridge.shared.dismiss = { [weak self] in
                self?.engine?.dismiss()
                self?.hide()
            }
        }

        positionPanel()
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        // Allow button hits without stealing focus from the source app long-term.
        panel?.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel?.animator().alphaValue = 1
        }
    }

    func scheduleHide(after delay: TimeInterval = 2.4) {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    func updateVisibility(for status: PlaybackStatus) {
        switch status {
        case .loading, .playing, .paused:
            show()
            cancelHide()
        case .idle:
            // Keep visible briefly when showing an error/status message.
            if let message = engine?.snapshot.statusMessage, !message.isEmpty {
                show()
                scheduleHide(after: 2.0)
            } else if engine?.snapshot.text.isEmpty == false {
                scheduleHide(after: 1.2)
            } else {
                scheduleHide(after: 0.35)
            }
        }
    }

    private func positionPanel() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }

        let width: CGFloat = 540
        let height: CGFloat = 86
        let x = screen.visibleFrame.midX - width / 2
        let y = screen.visibleFrame.maxY - height - 14
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

/// Lightweight bridge so SwiftUI hover / dismiss can talk to the panel controller.
enum OverlayHoverBridge {
    static let shared = Bridge()

    final class Bridge {
        var cancelHide: (() -> Void)?
        var dismiss: (() -> Void)?
    }
}
