import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: Settings
    /// Pauses global shortcuts while recording, so the old combination can be pressed again.
    let setRecording: (Bool) -> Void
    let shortcutFailures: Set<String>

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Lyps is on", isOn: $settings.enabled)
                Toggle("Show automatically when a song plays", isOn: $settings.autoShow)
                Toggle("Always on top", isOn: $settings.alwaysOnTop)
            }
            Section("Island") {
                Toggle("Show artwork", isOn: $settings.showArtwork)
                Toggle("Show next line", isOn: $settings.showNextLine)
            }
            Section {
                Toggle("Spotify", isOn: $settings.spotify)
                Toggle("Telegram", isOn: $settings.telegram)
                Toggle("Browsers (YouTube)", isOn: $settings.browsers)
            } header: {
                Text("Sources")
            } footer: {
                Text("Song titles and artists are sent to LRCLIB to find lyrics. With Browsers on, that includes the title of any video that plays. Telegram voice messages are never sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcuts") {
                ShortcutRow(title: "Show or hide lyrics", shortcut: $settings.toggleLyricsShortcut,
                            fallback: .toggleLyrics, failed: shortcutFailures.contains("lyrics"), setRecording: setRecording)
                ShortcutRow(title: "Turn Lyps on or off", shortcut: $settings.togglePowerShortcut,
                            fallback: .togglePower, failed: shortcutFailures.contains("power"), setRecording: setRecording)
                ShortcutRow(title: "Show lyrics earlier", shortcut: $settings.lyricsEarlierShortcut,
                            fallback: .lyricsEarlier, failed: shortcutFailures.contains("earlier"), setRecording: setRecording)
                ShortcutRow(title: "Show lyrics later", shortcut: $settings.lyricsLaterShortcut,
                            fallback: .lyricsLater, failed: shortcutFailures.contains("later"), setRecording: setRecording)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ShortcutRow: View {
    let title: String
    @Binding var shortcut: Shortcut
    let fallback: Shortcut
    let failed: Bool
    let setRecording: (Bool) -> Void

    @LocalState private var recording = false
    @LocalState private var monitor: Any?

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if shortcut != fallback {
                    Button("Reset") { shortcut = fallback }.buttonStyle(.link).font(.caption)
                }
                Button(recording ? "Press keys…" : shortcut.display, action: toggleRecording)
                    .monospacedDigit()
                    .accessibilityLabel("\(title): \(shortcut.display). Change shortcut.")
            }
        } label: {
            Text(title)
            if failed {
                Text("Another app is using this shortcut.").font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        setRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stopRecording()
            } else if let new = Shortcut(event: event) {
                shortcut = new
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        setRecording(false)
    }
}
