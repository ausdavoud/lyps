import AppKit
import CoreAudio
import os

private let log = Logger(subsystem: "app.lyps.Lyps", category: "ads")

enum AdMuteMode: String, CaseIterable {
    case off, system, app

    /// Prompts belong to the moment the user picks a mode: never at launch, never when another
    /// setting changes, and the audio one only for muting just Spotify.
    static func prompts(from old: AdMuteMode, to new: AdMuteMode) -> (automation: Bool, audioCapture: Bool) {
        guard new != .off, new != old else { return (false, false) }
        return (true, new == .app)
    }

    /// Mutes for an ad. Muting only Spotify gets `everything` as its fallback, for when macOS refuses.
    func mute(spotifyOnly: (@escaping () -> Void) -> Void, everything: @escaping () -> Void) {
        switch self {
        case .off: return
        case .system: everything()
        case .app: spotifyOnly(everything)
        }
    }
}

/// Whether Spotify is in an ad, judged only from Spotify's own reports. macOS reports one app at a
/// time, so when another app starts playing mid-ad, Spotify goes quiet in the data while its ad
/// plays on. Its reported length then says when the ad should end.
struct SpotifyAdClock {
    private(set) var endsAt: Date?

    mutating func observe(_ state: PlaybackState, at now: Date = Date()) {
        guard state.bundleID == "com.spotify.client" else { return }
        if AdDetector.isSpotifyAd(state) {
            // A paused ad makes no sound, so nothing needs muting until it plays again.
            guard state.isPlaying else { endsAt = nil; return }
            // A new ad can arrive with no length yet, or with the last ad's finished position, so an
            // ad that looks nearly over is taken as just starting. A typical ad is 30 seconds.
            let length = state.duration > 0 ? state.duration : 30
            let left = length - state.position(at: now)
            endsAt = now.addingTimeInterval(left >= 2 ? left : length)
        } else if !state.title.isEmpty {
            endsAt = nil
        }
    }

    func adPlaying(at now: Date = Date()) -> Bool { endsAt.map { now < $0 } ?? false }

    /// Spotify quit, so whatever it was playing is over.
    mutating func reset() { endsAt = nil }
}

/// Asks Spotify what it's playing. macOS reports only one app as now playing, and it can stay on
/// another app (a paused Telegram song, say) while Spotify plays on, songs and ads unseen. Spotify
/// answers directly. Needs the Automation permission.
///
/// Every call here can block for a long time (the permission check waits on macOS and Spotify, and
/// the first use waits on the user's answer), so all of it runs on one background queue, one call
/// at a time, and nothing here may ever run on the main thread.
enum SpotifyScript {
    private static let bundleID = "com.spotify.client"
    private static let separator = "\u{1F}"
    private static let queue = DispatchQueue(label: "app.lyps.spotify")
    /// Set once Spotify has answered, so polling never triggers macOS's prompt by surprise.
    /// (macOS's own permission-check call hung on this Mac, so a real answer is the test.)
    private static let allowedKey = "spotifyAutomationAllowed"
    // Touched only on `queue`.
    nonisolated(unsafe) private static var script: NSAppleScript?
    nonisolated(unsafe) private static var busy = false
    /// Checks Spotify is running first, because addressing a closed app opens it, and gives up after
    /// 3 seconds rather than the default 2 minutes if Spotify hangs.
    static let source = """
        if application id "com.spotify.client" is not running then return "stopped"
        with timeout of 3 seconds
            tell application id "com.spotify.client"
                set s to player state as string
                if s is "stopped" then return "stopped"
                set t to current track
                set d to character id 31
                return s & d & (id of t) & d & (name of t) & d & (album of t) & d & (track number of t) & d & (duration of t) & d & (player position)
            end tell
        end timeout
        """

    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    /// Asks Spotify once, which makes macOS show its Automation prompt if it hasn't been answered.
    static func requestPermission() {
        guard isRunning else { return }
        queue.async { _ = run(allowedOrNot: true) }
    }

    /// What Spotify is playing, in the same form as a Now Playing report, delivered on the main thread.
    /// Skipped while the previous question is still waiting, and until Spotify has answered once.
    static func ask(_ answer: @escaping @MainActor (PlaybackState) -> Void) {
        guard isRunning, UserDefaults.standard.bool(forKey: allowedKey) else { return }
        queue.async {
            guard let state = run(allowedOrNot: false) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { answer(state) } }
        }
    }

    /// Runs on `queue`. A refusal (-1743) is remembered, so Lyps stops asking.
    private static func run(allowedOrNot: Bool) -> PlaybackState? {
        guard !busy, isRunning else { return nil }
        busy = true
        defer { busy = false }
        if script == nil { script = NSAppleScript(source: source) }
        var error: NSDictionary?
        let output = script?.executeAndReturnError(&error).stringValue
        let code = error?[NSAppleScript.errorNumber] as? Int
        let wasAllowed = UserDefaults.standard.bool(forKey: allowedKey)
        let nowAllowed = allowed(answered: output != nil, errorCode: code, before: wasAllowed)
        UserDefaults.standard.set(nowAllowed, forKey: allowedKey)
        if output == nil {
            log.error("spotify: no answer (\(String(describing: code), privacy: .public))")
        }
        return output.flatMap { state(from: $0) }
    }

    /// Whether to keep asking Spotify. An answer proves the permission; macOS's refusal (-1743) is
    /// remembered so Lyps stops asking; any other failure, like Spotify being busy, changes nothing.
    static func allowed(answered: Bool, errorCode: Int?, before: Bool) -> Bool {
        if answered { return true }
        return errorCode == -1743 ? false : before
    }

    /// Parses the script's answer: state, ID, name, album, track number, duration (ms), position (s).
    static func state(from output: String, now: Date = Date()) -> PlaybackState? {
        let parts = output.components(separatedBy: separator)
        guard parts.count == 7 else { return nil }
        let playing = parts[0] == "playing"
        var state = PlaybackState()
        state.apply(["type": "data", "diff": false, "payload": [
            "bundleIdentifier": bundleID, "title": parts[2], "album": parts[3],
            "trackNumber": Int(parts[4]) ?? 0, "durationMicros": (Double(parts[5]) ?? 0) * 1000,
            "elapsedTimeMicros": (Double(parts[6].replacingOccurrences(of: ",", with: ".")) ?? 0) * 1_000_000,
            "timestampEpochMicros": now.timeIntervalSince1970 * 1_000_000, "playing": playing,
            "playbackRate": playing ? 1.0 : 0.0, "isAdvertisement": parts[1].hasPrefix("spotify:ad:"),
        ] as [String: Any]])
        return state
    }
}

enum AdDetector {
    /// Spotify never sets the advertisement flag. Recorded ads, video and audio-only alike, either
    /// carry Spotify's own "Advertisement" title or have no album and no track number, unlike any
    /// song. That also catches the placeholder in other languages, which has no track number at
    /// all. The length limit keeps an untagged local file, which can also lack an album, playing.
    static func isSpotifyAd(_ state: PlaybackState) -> Bool {
        guard state.bundleID == "com.spotify.client" else { return false }
        if state.isAdvertisement || state.title.localizedCaseInsensitiveContains("Advertisement") { return true }
        return state.album.isEmpty && (state.trackNumber ?? 0) == 0 && state.duration > 0 && state.duration <= 65
    }
}

/// Mutes as soon as an ad starts, and unmutes once something else has played for a moment:
/// mid-ad, Spotify briefly reported the next song for about a second before the ad went on.
@MainActor
final class AdMuter {
    private let mute: () -> Void
    private let unmute: () -> Void
    private let settle: TimeInterval
    private var muted = false
    private var pendingUnmute: DispatchWorkItem?

    var isMuted: Bool { muted }

    init(settle: TimeInterval = 1.5, mute: @escaping () -> Void, unmute: @escaping () -> Void) {
        (self.settle, self.mute, self.unmute) = (settle, mute, unmute)
    }

    func update(adPlaying: Bool) {
        if adPlaying {
            pendingUnmute?.cancel()
            pendingUnmute = nil
            guard !muted else { return }
            muted = true
            mute()
        } else if muted, pendingUnmute == nil {
            let work = DispatchWorkItem { [weak self] in self?.release() }
            pendingUnmute = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
        }
    }

    /// Unmutes now, for quitting or turning the feature off.
    func release() {
        pendingUnmute?.cancel()
        pendingUnmute = nil
        guard muted else { return }
        muted = false
        unmute()
    }
}

// MARK: - Muting everything

/// Mutes the current output device. Remembers what it did, so sound comes back even if Lyps
/// quits unexpectedly mid-ad: the next launch restores it. Called again while an ad plays, so
/// switching outputs mid-ad (plugging in headphones, say) mutes the new one too.
enum SystemMute {
    private static let rememberedKey = "adMutedDeviceUID"
    nonisolated(unsafe) private static var unavailable: String?

    /// The devices Lyps muted. Older versions stored a single one.
    static func uids(from stored: Any?) -> [String] {
        stored as? [String] ?? (stored as? String).map { [$0] } ?? []
    }

    private static var remembered: [String] {
        get { uids(from: UserDefaults.standard.object(forKey: rememberedKey)) }
        set { newValue.isEmpty ? UserDefaults.standard.removeObject(forKey: rememberedKey) : UserDefaults.standard.set(newValue, forKey: rememberedKey) }
    }

    static var isActive: Bool { !remembered.isEmpty }

    static func mute() {
        guard let device = defaultOutput(), let uid = uid(of: device), !remembered.contains(uid) else { return }
        switch isMuted(device) {
        case true?: return // muted already, by the user; leave it to them
        case nil:
            if unavailable != uid { log.error("system mute unavailable for the current output") }
            unavailable = uid
            return
        case false?:
            guard setMuted(device, true) else { return }
            remembered.append(uid)
            log.info("ad: muted system output")
        }
    }

    static func unmute() {
        let uids = remembered
        guard !uids.isEmpty else { return }
        remembered = []
        for uid in uids {
            if let device = device(uid: uid) { _ = setMuted(device, false) }
        }
        log.info("ad: unmuted system output")
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutput() -> AudioDeviceID? {
        var query = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &query, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var query = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &query),
              AudioObjectGetPropertyData(device, &query, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var query = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(device, &query, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    static func uid(of device: AudioDeviceID) -> String? {
        var query = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &query, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func device(uid: String) -> AudioDeviceID? {
        var query = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &query,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }
}

// MARK: - Muting only Spotify

/// Silences Spotify's processes with a Core Audio tap whose sound goes to Lyps instead of the
/// speakers. macOS only applies the mute, and only asks for the System Audio Recording permission,
/// once the tap's audio stream is running, so Lyps runs one and discards everything it receives.
/// Matching by bundle ID covers helper processes that play ad audio, even if they start later.
/// The tap and its stream end with Lyps, so sound always comes back if Lyps quits.
///
/// Starting the stream can wait on macOS's permission prompt for as long as it's on screen, so all
/// of this runs on its own queue, in order: a permission check and a mute can never overlap.
final class SpotifyMute: @unchecked Sendable {
    private static let knownBundleIDs = ["com.spotify.client", "com.spotify.client.helper"]

    /// How much sound the tap diverted: proof the mute took hold. Levels only.
    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var peak: Float = 0
        func record(_ list: UnsafePointer<AudioBufferList>) {
            var loudest: Float = 0
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)) {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size { loudest = max(loudest, abs(samples[i])) }
            }
            lock.lock(); count += 1; peak = max(peak, loudest); lock.unlock()
        }
        var buffers: Int { lock.lock(); defer { lock.unlock() }; return count }
        var summary: String { lock.lock(); defer { lock.unlock() }; return "\(count) buffers, peak \(peak)" }
    }

    private let queue = DispatchQueue(label: "app.lyps.ad-mute")
    // Touched only on `queue`.
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var meter = Meter()
    private var outputUID: String?
    private var muting = false

    /// Mutes Spotify. Calls `failed` on the main thread if macOS refuses, so the caller can mute
    /// everything instead. A stream that never runs means the permission wasn't given.
    func mute(failed: @escaping @MainActor () -> Void) {
        queue.async { [self] in
            guard !muting else { return }
            stop() // a permission check might still be running
            guard start(muting: true) else { return report(failed) }
            muting = true
            log.info("ad: muted Spotify")
            queue.asyncAfter(deadline: .now() + 1.5) { [self] in
                guard muting, meter.buffers == 0 else { return }
                log.error("ad: Spotify mute isn't receiving audio; muting everything instead")
                stop()
                muting = false
                report(failed)
            }
        }
    }

    func unmute() {
        queue.async { [self] in
            guard muting else { return }
            log.info("ad: unmuted Spotify; the tap diverted \(self.meter.summary, privacy: .public)")
            stop()
            muting = false
        }
    }

    /// Rebuilds the mute on the new output if the output changed mid-ad, such as headphones.
    func followDefaultOutput() {
        queue.async { [self] in
            guard muting, let output = SystemMute.defaultOutput(), let uid = SystemMute.uid(of: output),
                  uid != outputUID else { return }
            log.info("ad: output changed; moving the Spotify mute to it")
            stop()
            if !start(muting: true) { muting = false }
        }
    }

    /// Runs an unmuted tap for a moment, so macOS asks for the permission now rather than mid-ad.
    func requestPermission() {
        queue.async { [self] in
            guard !muting, start(muting: false) else { return }
            Thread.sleep(forTimeInterval: 0.5)
            log.info("ad: permission check, the tap received \(self.meter.summary, privacy: .public)")
            stop()
        }
    }

    private func report(_ failed: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { failed() } }
    }

    private func start(muting: Bool) -> Bool {
        meter = Meter()
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.bundleIDs = Array(Set(Self.knownBundleIDs + TelegramAudio.bundleIDs(withPrefix: "com.spotify.client")))
        description.muteBehavior = muting ? .muted : .unmuted
        description.isPrivate = true
        description.name = "Lyps ad mute"
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown,
              let tapUID = Self.string(tap, kAudioTapPropertyUID),
              let output = SystemMute.defaultOutput(), let outputUID = SystemMute.uid(of: output) else {
            return fail("creating the tap", status)
        }
        self.outputUID = outputUID

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lyps ad mute",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { return fail("creating the audio device", status) }

        let meter = self.meter
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, DispatchQueue(label: "app.lyps.ad-mute.io")) { _, input, _, _, _ in
            meter.record(input)
        }
        guard status == noErr else { return fail("creating the audio stream", status) }
        status = AudioDeviceStart(device, ioProc)
        guard status == noErr else { return fail("starting the audio stream", status) }
        return true
    }

    private func fail(_ step: String, _ status: OSStatus) -> Bool {
        log.error("ad: couldn't mute Spotify, \(step, privacy: .public) failed (status \(status, privacy: .public))")
        stop()
        return false
    }

    private func stop() {
        if device != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(device, ioProc)
                AudioDeviceDestroyIOProcID(device, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        (tap, device, ioProc, outputUID) = (AudioObjectID(kAudioObjectUnknown), AudioObjectID(kAudioObjectUnknown), nil, nil)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var query = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &query, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
