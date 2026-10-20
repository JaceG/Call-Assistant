@preconcurrency import AVFoundation
import CEchoCanceller
import Foundation

/// WebRTC's AEC3 echo canceller. Feed it what the speakers play (the system
/// audio) and the mic; it removes the speakers' sound from the mic. Unlike
/// Apple's voice processing, it doesn't turn the call down.
///
/// The far end and the near end each come from their own task. Each side's
/// buffering is only touched by its own task; calls into WebRTC go through
/// `lock`.
final class WebRTCEchoCanceller: @unchecked Sendable {
    /// Speech recognition doesn't need more than 16 kHz, and AEC3 is cheaper there.
    static let sampleRate = 16_000
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false
    )!

    let frameSize: Int
    private let handle: OpaquePointer
    private let lock = NSLock()
    private let farConverter = AudioBufferConverter(to: format)
    private let nearConverter = AudioBufferConverter(to: format)
    private var farPending: [Float] = []
    private var nearPending: [Float] = []

    /// Nil if WebRTC couldn't be set up.
    init?() {
        guard let handle = ca_echo_canceller_create(Int32(Self.sampleRate)) else { return nil }
        self.handle = handle
        self.frameSize = Int(ca_echo_canceller_frame_size(handle))
    }

    deinit {
        ca_echo_canceller_destroy(handle)
    }

    /// What the speakers are playing.
    func addFarEnd(_ buffer: AVAudioPCMBuffer) {
        guard let samples = Self.samples(from: buffer, using: farConverter) else { return }
        farPending += samples
        var offset = 0
        while farPending.count - offset >= frameSize {
            farPending.withUnsafeBufferPointer { pending in
                let frame = pending.baseAddress! + offset
                lock.withLock { _ = ca_echo_canceller_add_far_end(handle, frame) }
            }
            offset += frameSize
        }
        farPending.removeFirst(offset)
    }

    /// The mic with the speakers' sound removed, at 16 kHz mono, in whole
    /// 10 ms frames. Nil until a full frame has arrived.
    func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let samples = Self.samples(from: buffer, using: nearConverter) else { return nil }
        nearPending += samples
        let frames = nearPending.count / frameSize
        guard frames > 0,
              let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(frames * frameSize))
        else { return nil }
        output.frameLength = AVAudioFrameCount(frames * frameSize)
        let destination = output.floatChannelData![0]
        nearPending.withUnsafeBufferPointer { pending in
            destination.update(from: pending.baseAddress!, count: frames * frameSize)
        }
        nearPending.removeFirst(frames * frameSize)
        for frame in 0..<frames {
            lock.withLock { _ = ca_echo_canceller_process(handle, destination + frame * frameSize) }
        }
        return output
    }

    private static func samples(from buffer: AVAudioPCMBuffer, using converter: AudioBufferConverter) -> [Float]? {
        guard let converted = try? converter.convert(buffer),
              let data = converted.floatChannelData
        else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength)))
    }
}
