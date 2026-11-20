@preconcurrency import AVFoundation
import Speech

/// Pushes audio into the analyzer, converted to the format the model wants.
protocol AudioSource: AnyObject, Sendable {
    func start(outputFormat: AVAudioFormat, into input: AsyncStream<AnalyzerInput>.Continuation) throws
    func stop()
}

enum AudioSourceError: LocalizedError {
    case noInputDevice
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone is available."
        case .unsupportedFormat: "The microphone's audio format can't be converted for the speech model."
        }
    }
}

/// The default microphone, via AVAudioEngine.
///
/// Deliberately not main-actor isolated: the tap block runs on an audio thread.
final class MicrophoneSource: AudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    /// Called on the audio thread with each buffer's loudness, 0…1.
    private let onLevel: (@Sendable (Float) -> Void)?

    init(onLevel: (@Sendable (Float) -> Void)? = nil) {
        self.onLevel = onLevel
    }

    func start(outputFormat: AVAudioFormat, into input: AsyncStream<AnalyzerInput>.Continuation) throws {
        let node = engine.inputNode
        let inputFormat = node.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioSourceError.noInputDevice
        }
        let converter = try BufferConverter(from: inputFormat, to: outputFormat)
        let onLevel = self.onLevel
        // A small buffer, so the level (and the waveform) updates ~40 times a second.
        try node.installAudioTap(onBus: 0, bufferSize: 1024, format: inputFormat) { readOnly, _ in
            let buffer = AVAudioPCMBuffer(copying: readOnly)
            if let onLevel {
                onLevel(Self.level(of: buffer))
            }
            if let converted = converter.convert(buffer) {
                input.yield(AnalyzerInput(buffer: converted))
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            node.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// RMS loudness of the first channel, mapped from −50…−10 dBFS to 0…1.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            sum += samples[index] * samples[index]
        }
        let decibels = 20 * log10(max((sum / Float(count)).squareRoot(), 0.000_01))
        return min(max((decibels + 50) / 40, 0), 1)
    }
}

/// Reads a whole audio file into the analyzer. Used to test the pipeline without speaking.
final class AudioFileSource: AudioSource, @unchecked Sendable {
    private let url: URL
    /// Play the file at its real speed (like a microphone) instead of all at once.
    private let realtime: Bool
    private let onLevel: (@Sendable (Float) -> Void)?
    private var stopped = false

    init(url: URL, realtime: Bool = false, onLevel: (@Sendable (Float) -> Void)? = nil) {
        self.url = url
        self.realtime = realtime
        self.onLevel = onLevel
    }

    func start(outputFormat: AVAudioFormat, into input: AsyncStream<AnalyzerInput>.Continuation) throws {
        let file = try AVAudioFile(forReading: url)
        let converter = try BufferConverter(from: file.processingFormat, to: outputFormat)
        guard realtime else {
            try feed(file, converter: converter, into: input)
            return
        }
        Thread.detachNewThread { [self] in
            try? feed(file, converter: converter, into: input)
        }
    }

    private func feed(_ file: AVAudioFile, converter: BufferConverter, into input: AsyncStream<AnalyzerInput>.Continuation) throws {
        let chunk: AVAudioFrameCount = 1024
        while file.framePosition < file.length, !stopped {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0 else { break }
            onLevel?(MicrophoneSource.level(of: buffer))
            if let converted = converter.convert(buffer) {
                input.yield(AnalyzerInput(buffer: converted))
            }
            if realtime {
                Thread.sleep(forTimeInterval: Double(buffer.frameLength) / file.processingFormat.sampleRate)
            }
        }
        // Then silence, as a microphone would hear after you stop talking.
        while realtime, !stopped {
            onLevel?(0)
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func stop() {
        stopped = true
    }
}

/// Streaming sample-rate/format conversion. Keeps resampler state between buffers.
final class BufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat

    init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws {
        self.outputFormat = outputFormat
        if inputFormat == outputFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw AudioSourceError.unsupportedFormat
            }
            converter.primeMethod = .none
            self.converter = converter
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        let supplied = SuppliedFlag()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied.value {
                inputStatus.pointee = .noDataNow  // wait for the next buffer; keep converter state
                return nil
            }
            supplied.value = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private final class SuppliedFlag: @unchecked Sendable {
        var value = false
    }
}
