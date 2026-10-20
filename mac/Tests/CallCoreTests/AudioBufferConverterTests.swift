@preconcurrency import AVFoundation
@testable import CallCore
import Foundation
import Testing

struct AudioBufferConverterTests {
    static let mono16k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    /// One second of a 440 Hz tone at half volume.
    static func tone(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let frames = AVAudioFrameCount(sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![channel][i] = Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate) * 0.5)
            }
        }
        return buffer
    }

    static func peak(_ buffer: AVAudioPCMBuffer) -> Int {
        let samples = UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength))
        return samples.map { abs(Int($0)) }.max() ?? 0
    }

    // The resampler holds back about 60 ms (measured: 15,018 frames from the
    // first one-second buffer, 16,016 from each one after), and releases it on
    // the next call. So check the steady state and the running total.

    @Test func convertsStereo48kToMono16k() throws {
        let converter = AudioBufferConverter(to: Self.mono16k)
        var frames: [Int] = []
        for _ in 1...3 {
            let output = try #require(try converter.convert(Self.tone(sampleRate: 48_000, channels: 2)))
            #expect(output.format == Self.mono16k)
            #expect(Self.peak(output) > 10_000)  // half volume is about 16,384
            frames.append(Int(output.frameLength))
        }
        #expect(abs(frames[2] - 16_000) <= 160)
        #expect(abs(frames.reduce(0, +) - 48_000) <= 1_100)
    }

    @Test func keepsWorkingWhenTheInputFormatChanges() throws {
        let converter = AudioBufferConverter(to: Self.mono16k)
        _ = try converter.convert(Self.tone(sampleRate: 48_000, channels: 2))
        _ = try converter.convert(Self.tone(sampleRate: 44_100, channels: 1))
        let steady = try #require(try converter.convert(Self.tone(sampleRate: 44_100, channels: 1)))
        #expect(abs(Int(steady.frameLength) - 16_000) <= 160)
        #expect(Self.peak(steady) > 10_000)
    }

    @Test func passesThroughAudioAlreadyInTheTargetFormat() throws {
        let converter = AudioBufferConverter(to: Self.mono16k)
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.mono16k, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        let output = try #require(try converter.convert(buffer))
        #expect(output === buffer)
    }
}
