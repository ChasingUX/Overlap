import Accelerate

/// Measures integrated loudness the way ITU-R BS.1770 defines it: each channel K-weighted, mean square over
/// 400 ms blocks overlapping by 75%, then gated at −70 LUFS and at 10 LU below the level of what's left.
/// Every channel counts equally, as left, right and center do.
struct LoudnessMeter {
    private var filters: [vDSP.Biquad<Float>]
    private let subBlockLength: Int
    /// Each 100 ms step's sum of squares across all channels. A block is four steps in a row.
    private var subBlocks: [Double] = []
    private var partialSum = 0.0
    private var partialCount = 0

    init(sampleRate: Double, channels: Int) {
        let coefficients = Self.kWeighting(sampleRate: sampleRate)
        filters = (0..<channels).map { _ in
            vDSP.Biquad(coefficients: coefficients, channelCount: 1, sectionCount: 2, ofType: Float.self)!
        }
        subBlockLength = Int((sampleRate / 10).rounded())
    }

    /// Adds interleaved samples, one frame after another.
    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        let channels = filters.count
        let frames = samples.count / channels
        guard frames > 0 else { return }
        var energy = [Float](repeating: 0, count: frames)
        var channel = [Float](repeating: 0, count: frames)
        for index in 0..<channels {
            for frame in 0..<frames {
                channel[frame] = samples[frame * channels + index]
            }
            let weighted = filters[index].apply(input: channel)
            vDSP.add(energy, vDSP.square(weighted), result: &energy)
        }
        var start = 0
        while start < frames {
            let end = min(frames, start + subBlockLength - partialCount)
            partialSum += Double(vDSP.sum(energy[start..<end]))
            partialCount += end - start
            if partialCount == subBlockLength {
                subBlocks.append(partialSum)
                partialSum = 0
                partialCount = 0
            }
            start = end
        }
    }

    /// In LUFS, or nil when there's nothing louder than the −70 LUFS gate, as with silence.
    var integratedLoudness: Double? {
        guard subBlocks.count >= 4 else { return nil }
        let blockLength = Double(subBlockLength * 4)
        let blocks = (0...(subBlocks.count - 4)).map { start in
            subBlocks[start..<start + 4].reduce(0, +) / blockLength
        }
        let audible = blocks.filter { Self.loudness(ofMeanSquare: $0) > -70 }
        guard !audible.isEmpty else { return nil }
        let relativeGate = Self.loudness(ofMeanSquare: audible.reduce(0, +) / Double(audible.count)) - 10
        let gated = audible.filter { Self.loudness(ofMeanSquare: $0) > relativeGate }
        return Self.loudness(ofMeanSquare: gated.reduce(0, +) / Double(gated.count))
    }

    static func loudness(ofMeanSquare meanSquare: Double) -> Double {
        -0.691 + 10 * log10(meanSquare)
    }

    /// The K-weighting filter's two stages, a high shelf for the head's effect and a high-pass, as vDSP biquad
    /// coefficients (b0, b1, b2, a1, a2 for each). Worked out from the analog filters BS.1770 is based on, so they
    /// hold at any sample rate and match the standard's published values at 48 kHz.
    static func kWeighting(sampleRate: Double) -> [Double] {
        let shelfK = tan(.pi * 1681.974450955533 / sampleRate)
        let shelfQ = 0.7071752369554196
        let shelfGain = pow(10, 3.999843853973347 / 20)
        let shelfBand = pow(shelfGain, 0.4996667741545416)
        let shelfA0 = 1 + shelfK / shelfQ + shelfK * shelfK
        let shelf = [
            (shelfGain + shelfBand * shelfK / shelfQ + shelfK * shelfK) / shelfA0,
            2 * (shelfK * shelfK - shelfGain) / shelfA0,
            (shelfGain - shelfBand * shelfK / shelfQ + shelfK * shelfK) / shelfA0,
            2 * (shelfK * shelfK - 1) / shelfA0,
            (1 - shelfK / shelfQ + shelfK * shelfK) / shelfA0,
        ]
        let passK = tan(.pi * 38.13547087602444 / sampleRate)
        let passQ = 0.5003270373238773
        let passA0 = 1 + passK / passQ + passK * passK
        let highPass = [1, -2, 1, 2 * (passK * passK - 1) / passA0, (1 - passK / passQ + passK * passK) / passA0]
        return shelf + highPass
    }
}

/// Finds the peaks between samples, where a waveform can swing higher than any sample once it's turned back into
/// sound, by drawing it four times finer. Each call returns, for every frame it was given, the highest point in
/// the gap that ends six frames earlier.
struct TruePeakDetector {
    static let taps = 12
    /// The gap a result describes ends this many frames before the frame it's returned with.
    static let lag = 6
    private let channels: Int
    /// The last frames of the previous call, one array per channel, that the next gaps still need.
    private var history: [[Float]]

    /// The four in-between points per gap come from four short filters, cut from one windowed-sinc low-pass. Each
    /// is reversed, ready for correlation.
    private static let phases: [[Float]] = {
        let length = taps * 4
        let middle = Double(length - 1) / 2
        let prototype = (0..<length).map { index -> Double in
            let t = (Double(index) - middle) / 4
            let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
            let window = 0.42 - 0.5 * cos(2 * .pi * Double(index) / Double(length - 1)) + 0.08 * cos(4 * .pi * Double(index) / Double(length - 1))
            return sinc * window
        }
        return (0..<4).map { phase in
            let filter = (0..<taps).map { prototype[$0 * 4 + phase] }
            let total = filter.reduce(0, +)
            return filter.reversed().map { Float($0 / total) }
        }
    }()

    init(channels: Int) {
        self.channels = channels
        history = Array(repeating: Array(repeating: 0, count: Self.taps - 1), count: channels)
    }

    mutating func gapPeaks(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        let frames = samples.count / channels
        var peaks = [Float](repeating: 0, count: frames)
        guard frames > 0 else { return peaks }
        for index in 0..<channels {
            var signal = history[index]
            signal.reserveCapacity(signal.count + frames)
            for frame in 0..<frames {
                signal.append(samples[frame * channels + index])
            }
            for filter in Self.phases {
                let points = vDSP.correlate(signal, withKernel: filter)
                vDSP.maximum(peaks, vDSP.absolute(points), result: &peaks)
            }
            history[index] = Array(signal.suffix(Self.taps - 1))
        }
        return peaks
    }

    /// The highest true peak in a whole recording, as a linear level.
    static func truePeak(of samples: [Float], channels: Int) -> Float {
        var detector = TruePeakDetector(channels: channels)
        let tail = [Float](repeating: 0, count: lag * channels)
        let peaks = samples.withUnsafeBufferPointer { detector.gapPeaks($0) } + tail.withUnsafeBufferPointer { detector.gapPeaks($0) }
        return max(vDSP.maximumMagnitude(samples), vDSP.maximum(peaks))
    }
}

/// Keeps true peaks under a ceiling, for an export's final mix. It looks a little ahead so it can turn the level
/// down smoothly before a peak arrives, then lets it back up over about a tenth of a second. Below the ceiling the
/// sound passes through untouched. Output comes out later than input; `finish` returns the rest, so the whole
/// output is exactly as long as the input.
struct TruePeakLimiter {
    private let channels: Int
    private let ceiling: Float
    private let lookahead: Int
    private let release: Float
    private var detector: TruePeakDetector

    /// Frames taken in but not yet given out, interleaved, and each one's highest level so far.
    private var pending: [Float] = []
    private var pendingPeaks: [Float] = []
    /// How many frames have been taken in and given out.
    private var received = 0
    private var sent = 0
    /// How many frames' peaks are fully known.
    private var measured = 0

    /// The gains each upcoming frame needs, lowest first, for the minimum over the lookahead.
    private var window: [(frame: Int, gain: Float)] = []
    private var windowStart = 0
    private var held: Float = 1
    /// The last gains, averaged so each turn-down ramps in across the lookahead.
    private var ramp: [Float]
    private var rampIndex = 0
    private var rampSum: Float

    /// `ceiling` in dBTP.
    init(sampleRate: Double, channels: Int, ceiling: Double = -1) {
        self.channels = channels
        self.ceiling = Float(pow(10, ceiling / 20))
        lookahead = max(1, Int(sampleRate * 0.0015))
        release = Float(1 - exp(-1 / (sampleRate * 0.1)))
        detector = TruePeakDetector(channels: channels)
        ramp = Array(repeating: 1, count: lookahead + 1)
        rampSum = Float(lookahead + 1)
    }

    /// Takes in interleaved frames and returns the frames that are ready.
    mutating func process(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        let frames = samples.count / channels
        let first = received
        for frame in 0..<frames {
            var peak: Float = 0
            for channel in 0..<channels {
                let sample = samples[frame * channels + channel]
                pending.append(sample)
                peak = max(peak, abs(sample))
            }
            pendingPeaks.append(peak)
        }
        received += frames

        // A gap's peak counts for the frames on both sides of it.
        let gaps = detector.gapPeaks(samples)
        for (index, peak) in gaps.enumerated() {
            let left = first + index - TruePeakDetector.lag
            if left >= sent {
                pendingPeaks[left - sent] = max(pendingPeaks[left - sent], peak)
            }
            if left + 1 >= sent {
                pendingPeaks[left + 1 - sent] = max(pendingPeaks[left + 1 - sent], peak)
            }
        }
        // The newest frames still wait for the gaps after them.
        return emit(through: max(measured, received - TruePeakDetector.lag))
    }

    /// Returns the frames still held back.
    mutating func finish() -> [Float] {
        let total = received
        let silence = [Float](repeating: 0, count: (lookahead + TruePeakDetector.lag + 2) * channels)
        var output = silence.withUnsafeBufferPointer { process($0) }
        output += emit(through: received)
        let extra = (sent - total) * channels
        if extra > 0 { output.removeLast(min(extra, output.count)) }
        return output
    }

    /// Works out the gain for every frame whose lookahead is now known, and gives those frames out.
    private mutating func emit(through known: Int) -> [Float] {
        var output: [Float] = []
        while measured < known {
            let frame = measured
            let peak = pendingPeaks[frame - sent]
            let needed = peak > ceiling ? ceiling / peak : 1
            while window.count > windowStart, let last = window.last, last.gain >= needed { window.removeLast() }
            window.append((frame, needed))
            measured += 1

            // Before the first frame goes out, the ramp still runs, so a peak right at the start is turned down
            // as smoothly as any other.
            let outFrame = frame - lookahead
            while window[windowStart].frame < outFrame { windowStart += 1 }
            let lowest = window[windowStart].gain
            held = min(lowest, held + (1 - held) * release)
            rampSum += held - ramp[rampIndex]
            ramp[rampIndex] = held
            rampIndex = (rampIndex + 1) % ramp.count
            // Summed afresh once per lap, so rounding never builds up over a long export.
            if rampIndex == 0 { rampSum = ramp.reduce(0, +) }
            guard outFrame >= sent else { continue }
            let gain = min(1, rampSum / Float(ramp.count))
            let offset = (outFrame - sent) * channels
            for channel in 0..<channels {
                output.append(pending[offset + channel] * gain)
            }
        }
        let done = output.count / channels
        if done > 0 {
            pending.removeFirst(done * channels)
            pendingPeaks.removeFirst(done)
            sent += done
        }
        if windowStart > 1024 {
            window.removeFirst(windowStart)
            windowStart = 0
        }
        return output
    }
}
