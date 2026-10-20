@preconcurrency import AVFoundation
import Accelerate
import Foundation
import os

/// Command-line checks the app runs in place of its window, for testing each
/// layer without the UI. Launch through `open` so macOS asks for permissions
/// on behalf of Call Assistant, not the shell:
///
///     open mac/dist/CallAssistant.app --stdout /tmp/ca.log --stderr /tmp/ca.log --args --probe-audio 15
public enum Probes {
    /// The probe named in the launch arguments, if any.
    public static func requested(in arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix("--probe-") }
    }

    /// Runs the probe named in `arguments` and returns its exit code.
    public static func run(_ arguments: [String]) async -> Int32 {
        setlinebuf(stdout)
        guard let flag = requested(in: arguments) else { return 64 }
        let value = arguments.drop { $0 != flag }.dropFirst().first
        switch flag {
        case "--probe-audio":
            return await audio(seconds: value.flatMap(Int.init) ?? 15)
        default:
            print("Unknown probe \(flag)")
            return 64
        }
    }

    /// Captures the mic and the system audio for `seconds`, printing frames and
    /// peak level once a second. Returns 0 only if both channels delivered frames
    /// with sound in them.
    static func audio(seconds: Int) async -> Int32 {
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        print("microphone permission: \(micAllowed ? "granted" : "denied")")

        let mic = MicCapture()
        let system = SystemAudioCapture()
        let micStats = ChannelStats()
        let systemStats = ChannelStats()

        let micStream = mic.bufferStream()
        let systemStream: AsyncStream<AVAudioPCMBuffer>
        do {
            systemStream = try await system.bufferStream().systemAudio
        } catch {
            print("system audio failed to start: \(error.localizedDescription)")
            mic.stop()
            return 2
        }

        let micTask = Task.detached { for await buffer in micStream { micStats.add(buffer) } }
        let systemTask = Task.detached { for await buffer in systemStream { systemStats.add(buffer) } }

        for second in 1...max(1, seconds) {
            try? await Task.sleep(for: .seconds(1))
            let m = micStats.takeInterval()
            let s = systemStats.takeInterval()
            print(String(format: "%3ds  mic frames=%6d peak=%.4f | system frames=%6d peak=%.4f",
                         second, m.frames, m.peak, s.frames, s.peak))
        }

        mic.stop()
        await system.stop()
        micTask.cancel()
        systemTask.cancel()

        let m = micStats.totals()
        let s = systemStats.totals()
        let pass = m.frames > 0 && m.peak > 0 && s.frames > 0 && s.peak > 0
        print(String(format: "RESULT mic frames=%d peak=%.4f | system frames=%d peak=%.4f => %@",
                     m.frames, m.peak, s.frames, s.peak, pass ? "PASS" : "FAIL"))
        if let error = mic.captureError { print("mic error: \(error)") }
        return pass ? 0 : 1
    }
}

/// Frame count and peak level of one audio channel, safe to update from the
/// capture thread and read from the probe.
private final class ChannelStats: Sendable {
    private struct Counts { var frames = 0; var peak: Float = 0 }
    private let interval = OSAllocatedUnfairLock(initialState: Counts())
    private let total = OSAllocatedUnfairLock(initialState: Counts())

    func add(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let peak = Self.peak(of: buffer)
        for lock in [interval, total] {
            lock.withLock { $0.frames += frames; $0.peak = max($0.peak, peak) }
        }
    }

    func takeInterval() -> (frames: Int, peak: Float) {
        interval.withLock { counts in
            defer { counts = Counts() }
            return (counts.frames, counts.peak)
        }
    }

    func totals() -> (frames: Int, peak: Float) {
        total.withLock { ($0.frames, $0.peak) }
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let format = buffer.format
        // Interleaved audio keeps every channel's samples in the first pointer.
        let pointers = format.isInterleaved ? 1 : Int(format.channelCount)
        let count = Int(buffer.frameLength) * (format.isInterleaved ? Int(format.channelCount) : 1)
        var peak: Float = 0
        for i in 0..<pointers {
            var channelPeak: Float = 0
            vDSP_maxmgv(channels[i], 1, &channelPeak, vDSP_Length(count))
            peak = max(peak, channelPeak)
        }
        return peak
    }
}
