@preconcurrency import AVFoundation
@testable import CallCore
import Foundation
import Testing

struct WebRTCEchoCancellerTests {
    static let rate = 16_000

    /// Repeatable white noise, standing in for speech from the speakers.
    static func noise(count: Int, amplitude: Float, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)) * amplitude
        }
    }

    static func buffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: WebRTCEchoCanceller.format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
    }

    static func decibels(_ ratio: Float) -> Float { 20 * log10(ratio) }

    /// Feeds far end and near end in 100 ms chunks, far end first (the
    /// speakers play before the mic hears it), and returns the cleaned mic.
    static func run(_ canceller: WebRTCEchoCanceller, far: [Float], near: [Float]) -> [Float] {
        var output: [Float] = []
        let chunk = rate / 10
        for start in stride(from: 0, to: near.count, by: chunk) {
            let end = min(start + chunk, near.count)
            canceller.addFarEnd(buffer(far[start..<end]))
            if let cleaned = canceller.process(buffer(near[start..<end])) {
                output += UnsafeBufferPointer(start: cleaned.floatChannelData![0], count: Int(cleaned.frameLength))
            }
        }
        return output
    }

    @Test func removesAnEchoOfWhatTheSpeakersPlayed() throws {
        let canceller = try #require(WebRTCEchoCanceller())
        let far = Self.noise(count: 8 * Self.rate, amplitude: 0.25, seed: 1)
        // The mic hears the speakers 40 ms later at half the level.
        let delay = Self.rate * 40 / 1000
        let near = Array(repeating: Float(0), count: delay) + far.dropLast(delay).map { $0 * 0.5 }
        let output = Self.run(canceller, far: far, near: near)
        let lastTwoSeconds = 6 * Self.rate..<8 * Self.rate
        let reduction = Self.decibels(Self.rms(near[lastTwoSeconds]) / Self.rms(output[lastTwoSeconds]))
        print("MEASURE echo reduction over the last 2 s: \(reduction) dB")
        #expect(reduction >= 15)
    }

    @Test func leavesMyVoiceAloneWhenNothingIsPlaying() throws {
        let canceller = try #require(WebRTCEchoCanceller())
        let far = Array(repeating: Float(0), count: 4 * Self.rate)
        let near = Self.noise(count: 4 * Self.rate, amplitude: 0.1, seed: 2)
        let output = Self.run(canceller, far: far, near: near)
        let lastTwoSeconds = 2 * Self.rate..<4 * Self.rate
        let change = Self.decibels(Self.rms(output[lastTwoSeconds]) / Self.rms(near[lastTwoSeconds]))
        print("MEASURE level change with nothing playing: \(change) dB")
        #expect(abs(change) <= 3)
    }

    @Test func outputsWholeTenMillisecondFrames() throws {
        let canceller = try #require(WebRTCEchoCanceller())
        #expect(canceller.frameSize == 160)
        // 250 samples in: one 160-sample frame out, 90 held for next time.
        let first = canceller.process(Self.buffer(Self.noise(count: 250, amplitude: 0.1, seed: 3)[...]))
        #expect(first?.frameLength == 160)
        let second = canceller.process(Self.buffer(Self.noise(count: 70, amplitude: 0.1, seed: 4)[...]))
        #expect(second?.frameLength == 160)
    }
}
