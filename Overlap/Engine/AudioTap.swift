import AVFoundation
import MediaToolbox
import Synchronization

/// One clip's gain over its time on a track, in composition seconds: its volume, its own fades, and the
/// crossfades with the clips it overlaps.
struct GainSegment: Hashable, Sendable {
    var start: Double
    var duration: Double
    var volume: Double
    var fadeIn: Double
    var fadeInCurve: Curve
    var fadeOut: Double
    var fadeOutCurve: Curve
    var crossfadeIn: Double = 0
    var crossfadeInCurve: Curve = .equalPower
    var crossfadeOut: Double = 0
    var crossfadeOutCurve: Curve = .equalPower

    init(clip: Clip, fadeIn: Fade, fadeOut: Fade) {
        start = clip.start.seconds
        duration = clip.duration.seconds
        volume = clip.volume
        // Fades never overlap each other inside one clip.
        self.fadeIn = min(fadeIn.duration.seconds, duration / 2)
        fadeInCurve = fadeIn.curve
        self.fadeOut = min(fadeOut.duration.seconds, duration / 2)
        fadeOutCurve = fadeOut.curve
    }

    /// Adds the crossfades the clip takes part in, from its track's crossfades.
    mutating func addCrossfades(_ crossfades: [Crossfade], of clipID: UUID) {
        if let into = crossfades.first(where: { $0.incoming.id == clipID }) {
            crossfadeIn = into.range.duration.seconds
            crossfadeInCurve = into.curve
        }
        if let outOf = crossfades.first(where: { $0.outgoing.id == clipID }) {
            crossfadeOut = outOf.range.duration.seconds
            crossfadeOutCurve = outOf.curve
        }
    }

    func gain(atLocal t: Double) -> Double {
        var gain = volume
        if fadeIn > 0, t < fadeIn {
            gain *= fadeInCurve.gain(at: t / fadeIn)
        }
        let remaining = duration - t
        if fadeOut > 0, remaining < fadeOut {
            gain *= fadeOutCurve.gain(at: remaining / fadeOut)
        }
        // Both sides of a crossfade use the same curve: the incoming clip rises along it, the outgoing one falls mirrored.
        if crossfadeIn > 0, t < crossfadeIn {
            gain *= crossfadeInCurve.gain(at: t / crossfadeIn)
        }
        if crossfadeOut > 0, remaining < crossfadeOut {
            gain *= crossfadeOutCurve.gain(at: remaining / crossfadeOut)
        }
        return gain
    }
}

/// The gain for every moment of one composition audio track. Segments are sorted and never overlap.
struct GainProgram: Sendable {
    var segments: [GainSegment]

    init(segments: [GainSegment]) {
        self.segments = segments.sorted { $0.start < $1.start }
    }

    /// Whether any segment plays between two times.
    func plays(from start: Double, to end: Double) -> Bool {
        segments.contains { $0.start < end && $0.start + $0.duration > start }
    }

    func gain(at seconds: Double) -> Double {
        // Binary search for the last segment starting at or before `seconds`.
        var low = 0
        var high = segments.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].start <= seconds {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard found >= 0 else { return 0 }
        let segment = segments[found]
        let local = seconds - segment.start
        return local < segment.duration ? segment.gain(atLocal: local) : 0
    }
}

/// The master volume during playback, read by every tap for each block of audio, so a change is heard at once
/// without rebuilding. It can boost past 1. Lock-free.
final class MasterGain: Sendable {
    private let bits = Atomic<UInt64>(1.0.bitPattern)

    var value: Double {
        get { Double(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

/// State shared with the tap's real-time callbacks. Written in `prepare` and `unprepare`, and otherwise only
/// used from the tap's own thread.
private final class TapContext: @unchecked Sendable {
    let program: GainProgram
    let master: MasterGain?
    let isolatesVoice: Bool
    var sampleRate: Double = 48_000
    var isFloat32 = false
    /// The tap's format and largest block, kept from `prepare` for making the isolation unit later.
    var format = AudioStreamBasicDescription()
    var maximumFrames = 0
    /// Made the first time playback comes near the clip, not when the item is set up: an item can hold many
    /// isolated clips, and making all their units at once holds up its first frame.
    var isolation: VoiceIsolation?
    var isolationUnavailable = false

    init(program: GainProgram, master: MasterGain?, isolatesVoice: Bool) {
        self.program = program
        self.master = master
        self.isolatesVoice = isolatesVoice
    }

    static func from(_ tap: MTAudioProcessingTap) -> TapContext {
        Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }
}

/// Builds processing taps that isolate voices, if asked, then apply a `GainProgram` sample by sample to a
/// composition audio track. The same tap runs during playback and when reading audio for export, so both sound
/// identical. Isolation comes first, so fades and volume shape the isolated voice.
enum AudioTap {
    /// `master`, when given, scales everything the tap plays, live.
    static func make(program: GainProgram, master: MasterGain? = nil, isolatesVoice: Bool = false) -> MTAudioProcessingTap? {
        let context = Unmanaged.passRetained(TapContext(program: program, master: master, isolatesVoice: isolatesVoice))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: context.toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, maximumFrames, format in
                let context = TapContext.from(tap)
                let description = format.pointee
                context.sampleRate = description.mSampleRate
                context.isFloat32 = description.mFormatID == kAudioFormatLinearPCM
                    && description.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    && description.mBitsPerChannel == 32
                context.format = description
                context.maximumFrames = Int(maximumFrames)
            },
            unprepare: { tap in
                let context = TapContext.from(tap)
                context.isolation = nil
                context.isolationUnavailable = false
            },
            process: { tap, frameCount, _, bufferList, frameCountOut, flagsOut in
                var timeRange = CMTimeRange.zero
                let status = MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, &timeRange, frameCountOut)
                guard status == noErr else { return }
                let context = TapContext.from(tap)
                guard context.isFloat32, timeRange.start.isNumeric else { return }

                let frames = Int(frameCountOut.pointee)
                let start = timeRange.start.seconds
                let sampleRate = context.sampleRate
                // Isolation only runs near the clip, where it's heard: it starts early enough to warm up and make
                // up for its delay. Everywhere else the volume is zero anyway, and the work would be wasted.
                if context.isolatesVoice, !context.isolationUnavailable,
                   context.program.plays(from: start, to: start + Double(frames) / sampleRate + VoiceIsolation.warmUp) {
                    if context.isolation == nil {
                        context.isolation = VoiceIsolation(format: context.format, maximumFrames: context.maximumFrames)
                        context.isolationUnavailable = context.isolation == nil
                    }
                    context.isolation?.process(bufferList, frames: frames, start: start * sampleRate)
                }
                let master = context.master?.value ?? 1
                withUnsafeTemporaryAllocation(of: Float.self, capacity: frames) { gains in
                    for frame in 0..<frames {
                        gains[frame] = Float(context.program.gain(at: start + Double(frame) / sampleRate) * master)
                    }
                    // Interleaved in one buffer or one buffer per channel, every sample in a frame gets that frame's gain.
                    for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                        guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        let channels = Int(buffer.mNumberChannels)
                        for frame in 0..<frames {
                            for channel in 0..<channels {
                                samples[frame * channels + channel] *= gains[frame]
                            }
                        }
                    }
                }
            }
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            context.release()
            return nil
        }
        return tap
    }
}
