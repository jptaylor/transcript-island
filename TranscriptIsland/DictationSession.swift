@preconcurrency import AVFoundation
import Speech
import TranscriptCore

enum DictationError: LocalizedError {
    case microphoneDenied
    case languageNotSupported(Locale)
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
        case .languageNotSupported(let locale):
            "On-device transcription doesn't support \(locale.identifier) yet."
        case .noAudioFormat:
            "The speech model didn't report a usable audio format."
        }
    }
}

/// Apple's on-device speech-to-text. Prefers `SpeechTranscriber` (the newer model);
/// falls back to `DictationTranscriber` (the system dictation model) for languages
/// or devices the newer one doesn't cover.
enum Transcriber: Sendable {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    static func make(for locale: Locale) async throws -> Transcriber {
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return .speech(SpeechTranscriber(locale: supported, preset: .progressiveTranscription))
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return .dictation(DictationTranscriber(locale: supported, preset: .progressiveLongDictation))
        }
        throw DictationError.languageNotSupported(locale)
    }

    var module: any SpeechModule {
        switch self {
        case .speech(let transcriber): transcriber
        case .dictation(let transcriber): transcriber
        }
    }

    var name: String {
        switch self {
        case .speech: "SpeechTranscriber"
        case .dictation: "DictationTranscriber"
        }
    }

    /// Live (volatile) and final results as transcript segments.
    func segments() -> AsyncThrowingStream<TranscriptSegment, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptSegment.self)
        let task = Task {
            do {
                switch self {
                case .speech(let transcriber):
                    for try await result in transcriber.results {
                        continuation.yield(TranscriptSegment(String(result.text.characters), isFinal: result.isFinal))
                    }
                case .dictation(let transcriber):
                    for try await result in transcriber.results {
                        continuation.yield(TranscriptSegment(String(result.text.characters), isFinal: result.isFinal))
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

/// One recording: audio source → SpeechAnalyzer → text.
@MainActor
final class DictationSession {
    /// The transcript so far. Its `tail` (the menu's live preview) is the last 200 characters.
    private(set) var condenser = TranscriptCondenser(maxCharacters: 200)
    private(set) var transcriberName = ""
    var onTextChange: ((TranscriptCondenser) -> Void)?
    /// Called if the speech model for this language has to be downloaded first.
    var onModelDownload: ((Progress) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var source: (any AudioSource)?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Error>?

    func start(locale: Locale = .current, source: any AudioSource) async throws {
        let transcriber = try await Transcriber.make(for: locale)
        transcriberName = transcriber.name

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber.module]) {
            onModelDownload?(request.progress)
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber.module]) else {
            throw DictationError.noAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber.module])
        try await analyzer.prepareToAnalyze(in: format)

        let segments = transcriber.segments()
        resultsTask = Task { [weak self] in
            for try await segment in segments {
                self?.ingest(segment)
            }
        }

        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        self.input = input
        self.source = source
        try source.start(outputFormat: format, into: input)
    }

    /// Stops listening and waits for the final transcript.
    func finish() async throws -> String {
        source?.stop()
        input?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        try await resultsTask?.value
        release()
        return condenser.fullText
    }

    func cancel() async {
        source?.stop()
        input?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        release()
    }

    private func ingest(_ segment: TranscriptSegment) {
        condenser.ingest(segment)
        onTextChange?(condenser)
    }

    private func release() {
        analyzer = nil
        source = nil
        input = nil
        resultsTask = nil
    }
}
