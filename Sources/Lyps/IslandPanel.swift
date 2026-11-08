import AppKit
import SwiftUI

/// Dragging anywhere on the island moves it.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A panel that floats without ever taking focus from the app you're using.
@MainActor
final class IslandPanel: NSPanel {
    private static let size = NSSize(width: IslandView.width + 32, height: IslandView.height + 32)
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        contentView = DraggableHostingView(rootView: IslandView(model: model, settings: model.settings))

        placeAtTopCenter()
        setFrameAutosaveName("LypsIsland")
        keepOnScreen()

        applySettings()
        model.onVisibilityChange = { [weak self] visible in self?.setShown(visible) }
        // A display unplugged under the island would leave it off-screen.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen() }
        }
    }

    private func keepOnScreen() {
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { placeAtTopCenter() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func applySettings() {
        level = model.settings.alwaysOnTop ? .statusBar : .normal
    }

    private func placeAtTopCenter() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: screen.midX - frame.width / 2, y: screen.maxY - frame.height + 8))
    }

    private func setShown(_ shown: Bool) {
        if shown {
            orderFrontRegardless()
        } else {
            // Waits for the fade-out in IslandView to finish.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.model.isVisible else { return }
                self.orderOut(nil)
            }
        }
    }
}
