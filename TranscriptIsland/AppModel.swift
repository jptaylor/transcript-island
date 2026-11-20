import AppKit
import Carbon.HIToolbox
import Observation
import TranscriptCore
import os

/// The app's state and the dictation flow: shortcut → listen → finish (a pause, or Esc) →
/// deliver the text.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case listening
        case finishing
        case done(DeliveryOutcome)
        case failed(String)
    }

    /// What ended a dictation.
    enum FinishTrigger: String {
        case escape, pause, menu
    }

    private(set) var phase: Phase = .idle
    /// The end of the live transcript, for the menu.
    private(set) var liveText = ""
    private(set) var lastTranscript: String?
    private(set) var shortcut: Shortcut
    private(set) var shortcutRegistered = false
    /// False only if another app holds Esc; the menu then offers a Finish button instead.
    private(set) var escapeRegistered = true
    private(set) var microphone = Permissions.microphone
    private(set) var accessibilityTrusted = Permissions.accessibilityTrusted

    var insertIntoFocusedField: Bool {
        didSet { UserDefaults.standard.set(insertIntoFocusedField, forKey: Keys.insert) }
    }
    /// Finish on its own after a pause (see `PauseDetector`), so Esc is optional.
    var autoFinish: Bool {
        didSet { UserDefaults.standard.set(autoFinish, forKey: Keys.autoFinish) }
    }

    /// True from the moment dictation starts until the text is delivered.
    var isBusy: Bool { session != nil }

    /// Starts dictation. Always registered.
    private let shortcutKey = HotKey(id: 1)
    /// Esc finishes. Registered only while dictating, so the rest of the time Esc goes to
    /// whatever app you're in.
    private let escapeKey = HotKey(id: 2)
    private let island = IslandPanel()
    private var session: DictationSession? {
        didSet { updateEscapeKey() }
    }
    /// The text field to type into, captured when dictation starts.
    private var target: InsertionTarget?
    /// Finish was asked for while still starting up; done as soon as it's listening.
    private var pendingFinish: FinishTrigger?
    private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var pauseDetector = PauseDetector()
    @ObservationIgnored private var pauseWatch: Task<Void, Never>?
    /// The island's text as two caption lines, wrapped by measured width: words are added to
    /// the bottom line, and when it's full the lines roll up.
    @ObservationIgnored private var captions = CaptionLines(maxLines: 2, fits: IslandLayout.captionFits)

    private static let log = Logger.app("Dictation")

    private enum Keys {
        static let shortcut = "shortcut"
        static let insert = "insertIntoFocusedField"
        static let autoFinish = "autoFinishOnPause"
    }

    init() {
        let defaults = UserDefaults.standard
        shortcut = defaults.data(forKey: Keys.shortcut)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .defaultShortcut
        insertIntoFocusedField = defaults.object(forKey: Keys.insert) as? Bool ?? true
        autoFinish = defaults.object(forKey: Keys.autoFinish) as? Bool ?? true

        #if DEBUG
        if runHarnessIfRequested() { return }
        #endif

        shortcutKey.onPress = { [weak self] in self?.start() }
        escapeKey.onPress = { [weak self] in self?.finish(by: .escape) }
        shortcutRegistered = shortcutKey.register(shortcut)

        // Typing into other apps needs Accessibility access. Ask at launch rather than
        // mid-dictation, where a prompt would take focus from the text field. If macOS shows
        // no prompt, the menu's Grant button opens the right page in System Settings.
        if insertIntoFocusedField {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if !Permissions.accessibilityTrusted {
                    Permissions.promptForAccessibility()
                }
            }
        }
    }

    // MARK: - Dictation

    /// The shortcut or the menu's Start button. Does nothing while already dictating.
    func start() {
        start(source: nil)
    }

    /// `source` replaces the microphone (debug harness only). It's given the level callback.
    private func start(source makeSource: (@Sendable (@escaping @Sendable (Float) -> Void) -> any AudioSource)?) {
        guard session == nil else { return }
        resetTask?.cancel()
        refreshPermissions()
        target = insertIntoFocusedField ? TextDelivery.captureTarget() : nil

        let session = DictationSession()
        self.session = session
        pendingFinish = nil
        liveText = ""
        captions.reset()
        phase = .preparing("Starting…")
        session.onTextChange = { [weak self] condenser in self?.textChanged(condenser) }
        session.onModelDownload = { [weak self] _ in self?.phase = .preparing("Downloading the speech model…") }
        island.show()  // right away, with the chime, while the speech model loads

        let reportLevel: @Sendable (Float) -> Void = { [weak self] level in
            Task { @MainActor in self?.levelChanged(Double(level)) }
        }
        Task {
            do {
                let source: any AudioSource
                if let makeSource {
                    source = makeSource(reportLevel)
                } else {
                    guard await Permissions.requestMicrophone() else { throw DictationError.microphoneDenied }
                    source = MicrophoneSource(onLevel: reportLevel)
                }
                try await session.start(source: source)
                phase = .listening
                pauseDetector.start(at: .now)
                watchForPause()
                if let pendingFinish { finish(by: pendingFinish) }
            } catch {
                await session.cancel()
                self.session = nil
                fail(error)
            }
        }
    }

    /// Stops listening and delivers the text.
    func finish(by trigger: FinishTrigger) {
        guard let session else { return }
        guard phase == .listening else {
            pendingFinish = trigger
            return
        }
        Self.log.notice("finishing (\(trigger.rawValue, privacy: .public))")
        pauseWatch?.cancel()
        pauseWatch = nil
        phase = .finishing
        Task {
            do {
                let text = try await session.finish()
                self.session = nil
                await deliver(text, finishedBy: trigger)
            } catch {
                self.session = nil
                fail(error)
            }
        }
    }

    private func levelChanged(_ level: Double) {
        island.setLevel(level)
        pauseDetector.level(level, at: .now)
    }

    private func textChanged(_ condenser: TranscriptCondenser) {
        liveText = condenser.tail
        pauseDetector.words(condenser.wordCount, at: .now)
        guard phase == .listening else { return }
        island.update(captions: captions.captions(for: condenser.fullText))
    }

    /// Finishes on its own once `pauseDetector` says the speaker has stopped (unless turned
    /// off in the menu). Esc still finishes right away.
    private func watchForPause() {
        pauseWatch?.cancel()
        guard autoFinish else { return }
        pauseWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.phase == .listening else { return }
                if self.pauseDetector.shouldFinish(at: .now) {
                    self.finish(by: .pause)
                    return
                }
            }
        }
    }

    private func updateEscapeKey() {
        if session != nil {
            if !escapeKey.isRegistered {
                escapeRegistered = escapeKey.register(keyCode: UInt32(kVK_Escape), modifiers: 0)
            }
        } else {
            escapeKey.unregister()
            escapeRegistered = true
        }
    }

    private func deliver(_ text: String, finishedBy trigger: FinishTrigger) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        if writeHarnessReport(trimmed, finishedBy: trigger) { return }
        #endif

        let outcome: DeliveryOutcome
        if trimmed.isEmpty {
            outcome = .nothingHeard
        } else {
            lastTranscript = trimmed
            outcome = await TextDelivery.deliver(trimmed, to: target)
        }
        target = nil
        phase = .done(outcome)
        island.update(captions: captions.captions(for: trimmed))
        island.finish(IslandResult(outcome))
        returnToIdle(after: .seconds(3))
    }

    private func fail(_ error: Error) {
        Self.log.error("dictation failed: \(String(describing: error), privacy: .public)")
        pauseWatch?.cancel()
        pauseWatch = nil
        target = nil
        phase = .failed(error.localizedDescription)
        island.finish(IslandResult(kind: .warning, message: Self.shortMessage(for: error)), lingering: .seconds(2.5))
        returnToIdle(after: .seconds(8))
    }

    /// A few words for the island; the menu shows the full description.
    private static func shortMessage(for error: Error) -> String {
        switch error {
        case DictationError.microphoneDenied: "Microphone access is off"
        case DictationError.languageNotSupported: "Language not supported"
        case AudioSourceError.noInputDevice: "No microphone found"
        default: "Dictation failed"
        }
    }

    private func returnToIdle(after delay: Duration) {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.session == nil else { return }
            self.phase = .idle
        }
    }

    // MARK: - Settings

    func copyLastTranscript() {
        guard let lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    func beginRecordingShortcut() {
        shortcutKey.unregister()  // so the current shortcut can be pressed in the recorder
    }

    func endRecordingShortcut(_ newShortcut: Shortcut?) {
        if let newShortcut {
            shortcut = newShortcut
            if let data = try? JSONEncoder().encode(newShortcut) {
                UserDefaults.standard.set(data, forKey: Keys.shortcut)
            }
        }
        shortcutRegistered = shortcutKey.register(shortcut)
    }

    func refreshPermissions() {
        microphone = Permissions.microphone
        accessibilityTrusted = Permissions.accessibilityTrusted
    }

    func requestMicrophone() {
        if microphone == .notDetermined {
            Task {
                _ = await Permissions.requestMicrophone()
                refreshPermissions()
            }
        } else {
            Permissions.openMicrophoneSettings()
        }
    }

    func requestAccessibility() {
        Permissions.promptForAccessibility()
        Permissions.openAccessibilitySettings()
    }
}

// MARK: - Debug harness

#if DEBUG
/// Command-line flags for trying the app without a microphone (Debug builds only):
///
/// - `--island-demo`: plays a fake dictation in the island, then quits.
/// - `--dictate-file <audio> <report.txt>`: a full dictation with the file in place of the
///   microphone, played at real speed and followed by silence, so the pause detector ends it.
///   Writes a report instead of pasting, then quits.
/// - `--transcribe-file <audio> <output.txt>`: just the speech pipeline; writes the model name
///   and the transcript, then quits.
extension AppModel {
    private static var reportURL: URL?

    /// Returns true if a harness flag was given (the app then skips its normal setup).
    private func runHarnessIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        func values(after flag: String) -> (URL, URL)? {
            guard let index = arguments.firstIndex(of: flag), arguments.count > index + 2 else { return nil }
            return (URL(fileURLWithPath: arguments[index + 1]), URL(fileURLWithPath: arguments[index + 2]))
        }

        if arguments.contains("--island-demo") {
            runIslandDemo()
        } else if let (audio, report) = values(after: "--dictate-file") {
            Self.reportURL = report
            Task { start(source: { onLevel in AudioFileSource(url: audio, realtime: true, onLevel: onLevel) }) }
        } else if let (audio, output) = values(after: "--transcribe-file") {
            transcribe(audio, to: output)
        } else {
            return false
        }
        return true
    }

    /// For `--dictate-file`: writes the report and quits, instead of touching the clipboard.
    private func writeHarnessReport(_ text: String, finishedBy trigger: FinishTrigger) -> Bool {
        guard let url = Self.reportURL else { return false }
        let report = "finished by: \(trigger.rawValue)\nwords: \(text.split(separator: " ").count)\n\(text)"
        try? report.write(to: url, atomically: true, encoding: .utf8)
        exit(0)
    }

    private func transcribe(_ audio: URL, to output: URL) {
        Task {
            let session = DictationSession()
            var report: String
            do {
                try await session.start(source: AudioFileSource(url: audio))
                let text = try await session.finish()
                report = "\(session.transcriberName)\n\(text)"
            } catch {
                report = "ERROR\n\(error)"
            }
            try? report.write(to: output, atomically: true, encoding: .utf8)
            exit(report.hasPrefix("ERROR") ? 1 : 0)
        }
    }

    private func runIslandDemo() {
        let words = """
            Hey team, quick update. The island is live on the Mac now, and it stays open while I talk, \
            so I can read the last few lines as they come in. When I'm done I press Escape and the text \
            lands right where my cursor was.
            """.split(separator: " ")
        Task {
            island.show()
            captions.reset()
            let levels = Task { @MainActor [island] in
                var t = 0.0
                while !Task.isCancelled {
                    let speech = 0.5 + 0.4 * sin(t * 2.3) * sin(t * 0.9)
                    island.setLevel(max(0, min(1, speech + Double.random(in: -0.15...0.15))))
                    t += 0.033
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
            try? await Task.sleep(for: .milliseconds(700))
            for count in 1...words.count {
                try? await Task.sleep(for: .milliseconds(300))
                island.update(captions: captions.captions(for: words.prefix(count).joined(separator: " ")))
            }
            try? await Task.sleep(for: .seconds(1.5))
            levels.cancel()
            island.finish(IslandResult(.inserted(appName: "Notes")))
            try? await Task.sleep(for: .seconds(2.5))
            exit(0)
        }
    }
}
#endif
