import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The playing song's lyrics: read them with their timings, edit lines, time them by tapping, and
/// publish the user's own version to LRCLIB.
struct LyricsWindowView: View {
    let model: AppModel

    private enum Mode { case view, edit, time }

    @LocalState private var mode = Mode.view
    @LocalState private var draft = ""
    /// The song an edit or timing belongs to, in case the player moves on mid-way.
    @LocalState private var song: Track?
    @LocalState private var session: TimingSession?
    @LocalState private var monitor: Any?
    @LocalState private var notice: String?
    @LocalState private var problem: String?
    @LocalState private var confirmingPublish = false
    @LocalState private var confirmingRevert = false
    @LocalState private var publishing: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).font(.headline).lineLimit(1)
                Text(origin).font(.caption).foregroundStyle(.secondary)
            }
            switch mode {
            case .view: viewing
            case .edit: editing
            case .time: if let session { timing(session) }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(20)
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity, alignment: .topLeading)
        // Closing the window ends timing; the key monitor must not outlive it.
        .onDisappear { stopTiming(); mode = .view }
        .confirmationDialog("Publish these lyrics to LRCLIB?", isPresented: $confirmingPublish) {
            Button("Publish") { publish() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LRCLIB is a public database: anyone can see and download what you publish, and you can't remove it yourself. Lyrics usually belong to their songwriters, so only publish lyrics you're comfortable sharing.")
        }
        .confirmationDialog("Go back to LRCLIB's lyrics for this song?", isPresented: $confirmingRevert) {
            Button("Delete My Version", role: .destructive) { revert() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your timing and edits for this song will be deleted from this Mac.")
        }
    }

    private var heading: String {
        guard let track = model.track else { return "Nothing playing" }
        return [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var origin: String {
        let lyrics = model.effectiveLyrics
        switch (model.isMine, lyrics.synced.isEmpty, lyrics.plain.isEmpty) {
        case (_, true, true): return model.status == .loading ? "Looking for lyrics…" : "No lyrics yet"
        case (true, false, _): return "Your version, synced"
        case (true, true, _): return "Your version, not synced yet"
        case (false, false, _): return "From LRCLIB, synced"
        case (false, true, _): return "From LRCLIB, not synced"
        }
    }

    // MARK: Viewing, with saved timings

    @ViewBuilder
    private var viewing: some View {
        let lyrics = model.effectiveLyrics
        if model.track == nil {
            Text("Play a song in Spotify or Telegram to see its lyrics.").foregroundStyle(.secondary)
            Spacer()
        } else if lyrics.synced.isEmpty, lyrics.plain.isEmpty {
            Text("There are no lyrics for this song yet. You can add them yourself: paste or type the words, then time them by tapping along.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack { Spacer(); Button("Add Lyrics…", action: startEditing).keyboardShortcut(.defaultAction) }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if lyrics.synced.isEmpty {
                        ForEach(lyrics.plain.indices, id: \.self) { i in row(time: nil, text: lyrics.plain[i]) }
                    } else {
                        ForEach(lyrics.synced.indices, id: \.self) { i in
                            row(time: lyrics.synced[i].time, text: lyrics.synced[i].text, current: i == model.lineIndex)
                        }
                    }
                }
                .textSelection(.enabled)
            }
            HStack {
                Button("Edit…", action: startEditing)
                Button(lyrics.synced.isEmpty ? "Time These Lyrics…" : "Retime…", action: startTiming)
                if model.isMine {
                    Button("Use LRCLIB's Version…") { confirmingRevert = true }
                }
                Spacer()
                if publishing != nil {
                    ProgressView().controlSize(.small)
                    Button("Stop", action: cancelPublishing)
                } else if model.isMine {
                    Button("Publish to LRCLIB…") { confirmingPublish = true }
                        .help("Share your version on LRCLIB, so every app that uses it has these lyrics.")
                }
            }
        }
    }

    private func row(time: TimeInterval?, text: String, current: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let time {
                Text(Self.clock(time))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            Text(text.isEmpty ? "♪" : text).fontWeight(current ? .semibold : .regular)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(current ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    // MARK: Editing: add, break and change lines

    private var editing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One line per lyric. Press Return to break a line in two, or add new lines anywhere. Times like [01:23.45] are optional: a line without one gets an estimate between its neighbors. With no times at all, you can time the lyrics by tapping after saving.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
            HStack {
                Button("Cancel") { mode = .view; problem = nil }
                Spacer()
                Button("Save", action: saveEdit)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func startEditing() {
        guard let track = model.track else { return }
        song = track
        draft = LyricsText.editable(model.effectiveLyrics)
        problem = nil
        notice = nil
        mode = .edit
    }

    private func saveEdit() {
        guard let song else { return }
        let (lyrics, estimated) = LyricsText.parse(draft)
        do {
            try model.saveLyrics(lyrics, for: song)
            mode = .view
            problem = nil
            notice = estimated > 0
                ? "\(estimated) \(estimated == 1 ? "line got an estimated time" : "lines got estimated times"). Check them while the song plays, or retime."
                : nil
        } catch {
            problem = "Couldn't save the lyrics: \(error.localizedDescription)"
        }
    }

    // MARK: Timing by tapping

    private func timing(_ session: TimingSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Play the song from the start, and press Space as each line begins. Delete undoes the last tap.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(session.lines.indices, id: \.self) { index in
                            row(time: index < session.times.count ? session.times[index] : nil,
                                text: session.lines[index], current: index == session.next)
                                .foregroundStyle(index < session.next ? .secondary : .primary)
                                .id(index)
                        }
                    }
                }
                .onChange(of: session.next) { _, next in
                    withAnimation { proxy.scrollTo(min(next, session.lines.count - 1), anchor: .center) }
                }
            }
            HStack {
                Button("Cancel", action: stopTiming)
                Button("Undo", action: undo).disabled(session.times.isEmpty)
                Spacer()
                Text("\(session.times.count) of \(session.lines.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Tap", action: tap).disabled(session.isComplete)
                Button("Save", action: saveTiming)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.isComplete)
            }
        }
    }

    private func startTiming() {
        let lyrics = model.effectiveLyrics
        let lines = lyrics.synced.isEmpty ? lyrics.plain : lyrics.synced.map(\.text).filter { !$0.isEmpty }
        guard let track = model.track, !lines.isEmpty else { return }
        session = TimingSession(track: track, lines: lines)
        problem = nil
        notice = nil
        mode = .time
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Space: tap()
            case kVK_Delete: undo()
            // Esc only leaves before anything is tapped, so a stray key can't throw work away.
            case kVK_Escape where session?.times.isEmpty == true: stopTiming()
            default: return event
            }
            return nil
        }
    }

    private func tap() {
        guard var current = session else { return }
        guard model.track?.title == current.track.title, model.track?.artist == current.track.artist else {
            problem = "The song changed. Play \"\(current.track.title)\" again to keep timing it."
            return NSSound.beep()
        }
        guard model.isPlaying else {
            problem = "Play the song to time its lyrics."
            return NSSound.beep()
        }
        if current.tap(at: model.playbackPosition) {
            problem = nil
        } else {
            NSSound.beep()
        }
        session = current
    }

    private func undo() {
        session?.undo()
        problem = nil
    }

    private func saveTiming() {
        guard let current = session, current.isComplete else { return }
        do {
            try model.saveTiming(current)
            stopTiming()
        } catch {
            problem = "Couldn't save the timing: \(error.localizedDescription)"
        }
    }

    private func stopTiming() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        session = nil
        if mode == .time { mode = .view }
    }

    // MARK: Your version, LRCLIB's version

    private func revert() {
        do {
            try model.useLRCLIBVersion()
            notice = nil
        } catch {
            problem = "Couldn't delete your version: \(error.localizedDescription)"
        }
    }

    private func publish() {
        guard let track = model.track, model.isMine else { return }
        let lyrics = model.effectiveLyrics
        problem = nil
        notice = "Publishing… LRCLIB first has this Mac solve a short anti-spam check, which can take a minute."
        publishing = Task {
            do {
                try await LRCLIBPublisher.publish(lyrics, for: track)
                notice = "Published to LRCLIB. Other apps that use LRCLIB can find these lyrics now."
            } catch is CancellationError {
                notice = nil
            } catch {
                notice = nil
                problem = "Couldn't publish: \(error.localizedDescription)"
            }
            publishing = nil
        }
    }

    private func cancelPublishing() {
        publishing?.cancel()
        publishing = nil
        notice = nil
    }
}
