import Foundation

/// Decides when a dictation is over without anyone pressing a key: after the speaker has
/// said something, `silenceTimeout` of silence ends it; if they never start, `noSpeechTimeout`.
///
/// "Voice" is either new words from the recognizer or a microphone level clearly above the
/// room's noise floor (tracked as it goes, so a noisy room doesn't count as talking).
public struct PauseDetector: Sendable {
    public var silenceTimeout: TimeInterval
    public var noSpeechTimeout: TimeInterval
    /// How far above the noise floor (on the 0…1 level scale) counts as voice.
    public var voiceMargin: Double
    /// Levels below this never count as voice, however quiet the room.
    public var minimumVoiceLevel: Double

    public private(set) var heardSpeech = false
    private var startedAt: Date?
    private var lastVoiceAt: Date?
    private var wordCount = 0
    private var noiseFloor: Double?

    public init(
        silenceTimeout: TimeInterval = 2.0,
        noSpeechTimeout: TimeInterval = 8.0,
        voiceMargin: Double = 0.2,
        minimumVoiceLevel: Double = 0.3
    ) {
        self.silenceTimeout = silenceTimeout
        self.noSpeechTimeout = noSpeechTimeout
        self.voiceMargin = voiceMargin
        self.minimumVoiceLevel = minimumVoiceLevel
    }

    public mutating func start(at now: Date) {
        heardSpeech = false
        startedAt = now
        lastVoiceAt = nil
        wordCount = 0
        noiseFloor = nil
    }

    /// A microphone level, 0…1.
    public mutating func level(_ level: Double, at now: Date) {
        let floor = noiseFloor ?? level
        // Follow quieter levels quickly and louder ones very slowly, so speech doesn't raise it.
        noiseFloor = level < floor ? level : floor + (level - floor) * 0.01
        if level >= max(minimumVoiceLevel, floor + voiceMargin) {
            lastVoiceAt = now
        }
    }

    /// The recognizer's current word count. Only growth counts as voice: a result being
    /// finalized after you stop talking doesn't add words, so it doesn't delay the finish.
    public mutating func words(_ count: Int, at now: Date) {
        if count > wordCount {
            heardSpeech = true
            lastVoiceAt = now
        }
        wordCount = count
    }

    public func shouldFinish(at now: Date) -> Bool {
        guard let startedAt else { return false }
        if heardSpeech, let lastVoiceAt {
            return now.timeIntervalSince(lastVoiceAt) >= silenceTimeout
        }
        return now.timeIntervalSince(startedAt) >= noSpeechTimeout
    }
}
