import Foundation
import Testing
@testable import Overlap

/// Loudness against the reference cases in EBU Tech 3341, and the export limiter's ceiling.
struct LoudnessTests {
    /// Interleaved stereo: the same sine in both channels, each section at its own peak level in dBFS.
    func stereoSine(_ sections: [(decibels: Double, seconds: Double)], frequency: Double = 1000, sampleRate: Double = 48_000) -> [Float] {
        var samples: [Float] = []
        var frame = 0
        for section in sections {
            let amplitude = pow(10, section.decibels / 20)
            for _ in 0..<Int(section.seconds * sampleRate) {
                let sample = Float(amplitude * sin(2 * .pi * frequency * Double(frame) / sampleRate))
                samples.append(sample)
                samples.append(sample)
                frame += 1
            }
        }
        return samples
    }

    func measure(_ samples: [Float], sampleRate: Double = 48_000, chunk: Int = 4096) -> Double? {
        var meter = LoudnessMeter(sampleRate: sampleRate, channels: 2)
        samples.withUnsafeBufferPointer { all in
            var start = 0
            while start < all.count {
                let end = min(all.count, start + chunk * 2)
                meter.add(UnsafeBufferPointer(rebasing: all[start..<end]))
                start = end
            }
        }
        return meter.integratedLoudness
    }

    @Test func kWeightingMatchesTheStandardAt48kHz() {
        let published = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585,
                         1, -2, 1, -1.99004745483398, 0.99007225036621]
        for (ours, theirs) in zip(LoudnessMeter.kWeighting(sampleRate: 48_000), published) {
            #expect(abs(ours - theirs) < 1e-6)
        }
    }

    @Test func sineAtMinus23ReadsMinus23() throws {
        // EBU Tech 3341 cases 1 and 2: a stereo 1 kHz sine reads its own peak level.
        #expect(abs(try #require(measure(stereoSine([(-23, 20)]))) + 23) < 0.1)
        #expect(abs(try #require(measure(stereoSine([(-33, 20)]))) + 33) < 0.1)
    }

    @Test func quietPassagesAreGatedOut() throws {
        // EBU Tech 3341 case 3: 10 s at −36, 60 s at −23, 10 s at −36 still reads −23.
        let samples = stereoSine([(-36, 10), (-23, 60), (-36, 10)])
        #expect(abs(try #require(measure(samples)) + 23) < 0.1)
    }

    @Test func otherSampleRatesReadTheSame() throws {
        #expect(abs(try #require(measure(stereoSine([(-23, 20)], sampleRate: 44_100), sampleRate: 44_100)) + 23) < 0.1)
    }

    @Test func silenceHasNoLoudness() {
        #expect(measure([Float](repeating: 0, count: 48_000 * 2 * 5)) == nil)
    }

    @Test func truePeakFindsPeaksBetweenSamples() {
        // A quarter-rate sine sampled 45° off its peaks: every sample sits 3 dB under the wave's true top.
        let samples = (0..<48_000).flatMap { frame -> [Float] in
            let sample = Float(sin(.pi / 2 * Double(frame) + .pi / 4))
            return [sample, sample]
        }
        #expect(abs(samples.map(abs).max()! - 0.7071) < 0.001)
        let peak = TruePeakDetector.truePeak(of: samples, channels: 2)
        #expect(abs(20 * log10(Double(peak))) < 0.2)
    }

    func limit(_ samples: [Float], chunk: Int = 1000) -> [Float] {
        var limiter = TruePeakLimiter(sampleRate: 48_000, channels: 2)
        var output: [Float] = []
        samples.withUnsafeBufferPointer { all in
            var start = 0
            while start < all.count {
                let end = min(all.count, start + chunk * 2)
                output += limiter.process(UnsafeBufferPointer(rebasing: all[start..<end]))
                start = end
            }
        }
        return output + limiter.finish()
    }

    @Test func limiterKeepsTruePeaksUnderTheCeiling() {
        // Boosted 6 dB over full scale, with bursts so it has to turn down and come back up.
        let samples = stereoSine([(6, 0.5), (-20, 0.5), (6, 0.5), (-20, 0.5)], frequency: 997)
        let limited = limit(samples)
        #expect(limited.count == samples.count)
        let peak = 20 * log10(Double(TruePeakDetector.truePeak(of: limited, channels: 2)))
        #expect(peak <= -0.9)
        #expect(peak > -1.5)
    }

    @Test func limiterLeavesQuietSoundUntouched() {
        let samples = stereoSine([(-6, 1)], frequency: 440)
        let limited = limit(samples, chunk: 777)
        #expect(limited == samples)
    }

    @Test func limiterComesBackUpAfterAPeak() {
        let samples = stereoSine([(6, 0.2), (-20, 1)], frequency: 997)
        let limited = limit(samples)
        // Half a second after the loud part, the quiet part plays at its own level again.
        let late = limited[(48_000 * 2 * 7 / 10)..<(48_000 * 2 * 12 / 10)]
        let original = samples[(48_000 * 2 * 7 / 10)..<(48_000 * 2 * 12 / 10)]
        #expect(abs(late.map(abs).max()! / original.map(abs).max()! - 1) < 0.01)
    }
}
