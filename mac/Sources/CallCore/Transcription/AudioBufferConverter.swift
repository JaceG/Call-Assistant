@preconcurrency import AVFoundation

/// Converts capture buffers, in whatever format the device delivers, into the
/// format the speech analyzer asks for. Keeps one AVAudioConverter between
/// calls so resampling stays continuous across buffers, and builds a new one
/// when the input format changes (a different output device, for example).
final class AudioBufferConverter {
    enum ConversionError: Error {
        case cannotConvert(from: AVAudioFormat, to: AVAudioFormat)
        case failed(Error?)
    }

    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    /// The converted audio, or nil when the converter is still buffering
    /// (resampling can hold back a few frames until the next call).
    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        if inputFormat == outputFormat { return buffer }

        if converter?.inputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw ConversionError.cannotConvert(from: inputFormat, to: outputFormat)
            }
            // No priming: start each stream at its first sample rather than
            // padding it, so result times line up with the audio.
            newConverter.primeMethod = .none
            converter = newConverter
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw ConversionError.failed(error) }
        return output.frameLength > 0 ? output : nil
    }
}
