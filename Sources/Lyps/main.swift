import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private lazy var model = AppModel(settings: settings)
    private lazy var panel = IslandPanel(model: model)
    private let hotkeys = Hotkeys()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var lyricsWindow: NSWindow?
    private var availableUpdate: Updates.Release?
    private var updateTimer: Timer?
    private var shortcutFailures: Set<String> = []
    private var recordingShortcut = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        SystemMute.unmute() // in case Lyps quit mid-ad last time
        settings.onChange = { [weak self] in
            guard let self else { return }
            self.panel.applySettings()
            self.model.settingsChanged()
            self.registerShortcuts()
            self.scheduleUpdateChecks()
        }
        _ = panel
        model.onOpenLyrics = { [weak self] in self?.openLyrics() }
        registerShortcuts()
        scheduleUpdateChecks()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "music.quarternote.3", accessibilityDescription: "Lyps")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.releaseAdMute()
        model.bridge.stop()
    }

    private func registerShortcuts() {
        guard !recordingShortcut else { return }
        var failures: Set<String> = []
        if !hotkeys.register(id: 1, settings.toggleLyricsShortcut, action: { [weak self] in self?.model.toggleShown() }) {
            failures.insert("lyrics")
        }
        if !hotkeys.register(id: 2, settings.togglePowerShortcut, action: { [weak self] in self?.model.togglePower() }) {
            failures.insert("power")
        }
        if !hotkeys.register(id: 3, settings.lyricsEarlierShortcut, action: { [weak self] in self?.model.nudge(by: -TimingNudge.step) }) {
            failures.insert("earlier")
        }
        if !hotkeys.register(id: 4, settings.lyricsLaterShortcut, action: { [weak self] in self?.model.nudge(by: TimingNudge.step) }) {
            failures.insert("later")
        }
        if failures != shortcutFailures {
            shortcutFailures = failures
            refreshSettingsWindow()
        }
    }

    private func setRecording(_ recording: Bool) {
        recordingShortcut = recording
        if recording {
            for id in UInt32(1)...4 { hotkeys.unregister(id: id) }
        } else {
            registerShortcuts()
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if !model.bridge.isAvailable {
            status = "Now Playing bridge is missing"
        } else if NowPlayingBridge.needsMovingToApplications {
            status = "Move Lyps to Applications, then reopen it"
        } else if !model.bridgeHealthy {
            status = "Can't read Now Playing. A macOS update may have blocked it."
        } else if let track = model.track {
            status = [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " · ")
        } else {
            status = settings.enabled ? "Nothing playing" : "Lyps is off"
        }
        if let update = availableUpdate {
            menu.addItem(withTitle: "Update Available: Lyps \(update.version)…", action: #selector(openUpdate), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        addItem(to: menu, model.isVisible ? "Hide Lyrics" : "Show Lyrics", settings.toggleLyricsShortcut, #selector(toggleLyrics))
            .isEnabled = settings.enabled
        addItem(to: menu, settings.enabled ? "Turn Lyps Off" : "Turn Lyps On", settings.togglePowerShortcut, #selector(togglePower))
        menu.addItem(.separator())

        addItem(to: menu, "Show Lyrics Earlier", settings.lyricsEarlierShortcut, #selector(lyricsEarlier)).isEnabled = model.canNudge
        addItem(to: menu, "Show Lyrics Later", settings.lyricsLaterShortcut, #selector(lyricsLater)).isEnabled = model.canNudge
        if model.timingOffset != 0, model.canNudge {
            let title = "Reset Timing (\(String(format: "%+.2fs", model.timingOffset)))"
            menu.addItem(withTitle: title, action: #selector(resetTiming), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Lyrics for This Song…", action: #selector(openLyrics), keyEquivalent: "").target = self
        menu.items.last?.isEnabled = model.track != nil
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesNow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Lyps", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ shortcut: Shortcut, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: shortcut.menuKey)
        item.keyEquivalentModifierMask = shortcut.menuModifiers
        item.target = self
        return item
    }

    @objc private func toggleLyrics() { model.toggleShown() }
    @objc private func togglePower() { model.togglePower() }
    @objc private func lyricsEarlier() { model.nudge(by: -TimingNudge.step) }
    @objc private func lyricsLater() { model.nudge(by: TimingNudge.step) }
    @objc private func resetTiming() { model.resetTiming() }

    @objc private func openLyrics() {
        if lyricsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 580),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Lyrics"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LyricsWindowView(model: model))
            window.center()
            lyricsWindow = window
        }
        NSApp.activate()
        lyricsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Updates

    /// Checks once a day while automatic checks are on; the timer only decides whether a day has passed.
    private func scheduleUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = nil
        guard settings.checkForUpdates else { return }
        checkForUpdatesIfDue()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForUpdatesIfDue() }
        }
    }

    private func checkForUpdatesIfDue() {
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Updates.interval else { return }
        Task {
            guard let release = try? await Updates.latest() else { return }
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
            if Updates.isNewer(release.version, than: Updates.currentVersion) { availableUpdate = release }
        }
    }

    @objc private func checkForUpdatesNow() {
        Task {
            let alert = NSAlert()
            do {
                let release = try await Updates.latest()
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                if Updates.isNewer(release.version, than: Updates.currentVersion) {
                    availableUpdate = release
                    alert.messageText = "Lyps \(release.version) is available"
                    alert.informativeText = "You have \(Updates.currentVersion). The download page has the new version and what changed."
                    alert.addButton(withTitle: "Open Download Page")
                    alert.addButton(withTitle: "Later")
                } else {
                    availableUpdate = nil
                    alert.messageText = "Lyps is up to date"
                    alert.informativeText = "You have the latest version, \(Updates.currentVersion)."
                }
            } catch {
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "Check your internet connection and try again."
            }
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn, alert.buttons.count == 2 { openUpdate() }
        }
    }

    @objc private func openUpdate() {
        NSWorkspace.shared.open(availableUpdate?.htmlURL ?? URL(string: "https://github.com/ausdavoud/lyps/releases/latest")!)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Lyps Settings"
            window.isReleasedWhenClosed = false
            settingsWindow = window
            refreshSettingsWindow()
            window.center()
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func refreshSettingsWindow() {
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(
            settings: settings,
            setRecording: { [weak self] in self?.setRecording($0) },
            shortcutFailures: shortcutFailures
        ))
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    withExtendedLifetime(delegate) {}
}
