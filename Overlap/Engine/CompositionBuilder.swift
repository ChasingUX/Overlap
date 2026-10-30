@preconcurrency import AVFoundation

/// Everything the player or exporter needs to render the timeline.
struct BuiltComposition {
    let composition: AVComposition
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?
    let duration: Time
}

/// Turns the project model into an AVFoundation composition. Rebuilt after every edit.
@MainActor
enum CompositionBuilder {
    struct Options {
        /// Debug aid for the audio-tap prototype: gives every clip 2-second S-curve fades.
        var prototypeFades = false
        /// Playback's live master volume. Without one, the project's master volume is built into the mix,
        /// as an export needs.
        var master: MasterGain?
    }

    private struct AudioSlot: Hashable {
        var slot: Int
        var keepsPitch: Bool
    }

    private struct LoadedAsset {
        var video: AVAssetTrack?
        var audio: AVAssetTrack?
        var naturalSize: CGSize = .zero
        var preferredTransform: CGAffineTransform = .identity
    }

    static func build(project: Project, assets: (UUID) -> AVURLAsset?, options: Options = Options()) async throws -> BuiltComposition {
        var loaded: [UUID: LoadedAsset] = [:]
        for assetID in Set(project.tracks.flatMap(\.clips).map(\.assetID)) {
            guard let asset = assets(assetID) else { continue }
            loaded[assetID] = try await load(asset)
        }

        let composition = AVMutableComposition()
        let renderSize = CGSize(width: project.canvas?.width ?? 1920, height: project.canvas?.height ?? 1080)
        var layerInstructions: [AVVideoCompositionLayerInstruction] = []
        var audioParameters: [AVMutableAudioMixInputParameters] = []


        // Tracks run bottom to top; layer instructions list the topmost layer first.
        for (trackIndex, track) in project.tracks.enumerated() {
            // Muted tracks, and tracks left out by a solo, stay in the composition (so its length holds) but go
            // invisible and silent.
            let isActive = project.isActive(track)
            // Clips alternate between two slots, so a clip and the next one it crossfades with can play at once.
            var videoTracks: [Int: AVMutableCompositionTrack] = [:]
            // Sound with and without pitch correction needs separate composition tracks, since the setting is per track.
            var audioTracks: [AudioSlot: AVMutableCompositionTrack] = [:]
            var transforms: [Int: [(Time, CGAffineTransform)]] = [:]
            var opacities: [Int: [(Time, Float)]] = [:]
            var segments: [AudioSlot: [GainSegment]] = [:]

            let clips = track.clips.sorted { $0.start < $1.start }
            let crossfades = project.crossfades(onTrack: trackIndex)
            for (index, clip) in clips.enumerated() {
                guard let source = loaded[clip.assetID] else { continue }
                let slot = index % 2
                let sourceRange = CMTimeRange(start: clip.sourceStart.cmTime, duration: clip.sourceDuration.cmTime)
                let outOf = crossfades.first { $0.outgoing.id == clip.id }

                if clip.usesVideo, let sourceVideo = source.video {
                    let target = videoTracks[slot] ?? composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                    videoTracks[slot] = target
                    if let target {
                        try insert(sourceRange, of: sourceVideo, into: target, at: clip)
                        transforms[slot, default: []].append((clip.start, fitTransform(source, into: renderSize)))
                        // Until milestone 4's dissolves, a video crossfade cuts to the incoming clip where the overlap starts.
                        opacities[slot, default: []].append((clip.start, 1))
                        if let outOf { opacities[slot, default: []].append((outOf.incoming.start, 0)) }
                    }
                }
                if clip.usesAudio, let sourceAudio = source.audio {
                    let audioSlot = AudioSlot(slot: slot, keepsPitch: clip.preservesPitch || clip.speed == 1)
                    let target = audioTracks[audioSlot] ?? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    audioTracks[audioSlot] = target
                    if let target {
                        try insert(sourceRange, of: sourceAudio, into: target, at: clip)
                        let prototype = Fade(duration: Time(seconds: 2), curve: .sCurve)
                        var segment = GainSegment(
                            clip: clip,
                            fadeIn: options.prototypeFades ? prototype : clip.playedFade(.start, crossfades: crossfades),
                            fadeOut: options.prototypeFades ? prototype : clip.playedFade(.end, crossfades: crossfades)
                        )
                        segment.volume = isActive ? clip.volume * track.volume * (options.master == nil ? project.masterVolume : 1) : 0
                        segment.addCrossfades(crossfades, of: clip.id)
                        segments[audioSlot, default: []].append(segment)
                    }
                }
            }

            for (slot, videoTrack) in videoTracks.sorted(by: { $0.key < $1.key }) {
                var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
                for (time, transform) in transforms[slot] ?? [] {
                    layer.setTransform(transform, at: time.cmTime)
                }
                if isActive {
                    for (time, opacity) in opacities[slot] ?? [] {
                        layer.setOpacity(opacity, at: time.cmTime)
                    }
                } else {
                    layer.setOpacity(0, at: .zero)
                }
                layerInstructions.insert(AVVideoCompositionLayerInstruction(configuration: layer), at: 0)
            }
            for (audioSlot, audioTrack) in audioTracks {
                let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
                parameters.audioTimePitchAlgorithm = audioSlot.keepsPitch ? .spectral : .varispeed
                parameters.audioTapProcessor = AudioTap.make(program: GainProgram(segments: segments[audioSlot] ?? []), master: options.master)
                audioParameters.append(parameters)
            }
        }

        var videoComposition: AVVideoComposition?
        if !layerInstructions.isEmpty {
            let instruction = AVVideoCompositionInstruction(configuration: .init(
                backgroundColor: CGColor(gray: 0, alpha: 1),
                layerInstructions: layerInstructions,
                timeRange: CMTimeRange(start: .zero, duration: composition.duration)
            ))
            videoComposition = AVVideoComposition(configuration: .init(
                frameDuration: frameDuration(for: project.canvas?.frameRate ?? 30),
                instructions: [instruction],
                renderSize: renderSize
            ))
        }

        var audioMix: AVMutableAudioMix?
        if !audioParameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioParameters
            audioMix = mix
        }

        return BuiltComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            duration: Time(composition.duration)
        )
    }

    private static func load(_ asset: AVURLAsset) async throws -> LoadedAsset {
        var result = LoadedAsset()
        result.video = try await asset.loadTracks(withMediaType: .video).first
        result.audio = try await asset.loadTracks(withMediaType: .audio).first
        if let video = result.video {
            (result.naturalSize, result.preferredTransform) = try await video.load(.naturalSize, .preferredTransform)
        }
        return result
    }

    /// Inserts a clip's source range at its start, padding the track with an empty edit after a gap,
    /// then stretches or squeezes it to the clip's length for a speed change.
    private static func insert(_ range: CMTimeRange, of source: AVAssetTrack, into track: AVMutableCompositionTrack, at clip: Clip) throws {
        let trackEnd = track.segments.isEmpty ? CMTime.zero : track.timeRange.end
        if clip.start.cmTime > trackEnd {
            track.insertEmptyTimeRange(CMTimeRange(start: trackEnd, end: clip.start.cmTime))
        }
        try track.insertTimeRange(range, of: source, at: clip.start.cmTime)
        if clip.speed != 1 {
            track.scaleTimeRange(CMTimeRange(start: clip.start.cmTime, duration: range.duration), toDuration: clip.duration.cmTime)
        }
    }

    /// Scales a clip to fit the canvas, centered, after applying its own rotation.
    private static func fitTransform(_ asset: LoadedAsset, into canvas: CGSize) -> CGAffineTransform {
        let rotated = CGRect(origin: .zero, size: asset.naturalSize).applying(asset.preferredTransform)
        guard rotated.width > 0, rotated.height > 0 else { return asset.preferredTransform }
        let upright = asset.preferredTransform.concatenating(CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY))
        let scale = min(canvas.width / rotated.width, canvas.height / rotated.height)
        let offsetX = (canvas.width - rotated.width * scale) / 2
        let offsetY = (canvas.height - rotated.height * scale) / 2
        return upright
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
    }

    static func frameDuration(for rate: Double) -> CMTime {
        for ntsc in [23.976, 29.97, 59.94] where abs(rate - ntsc) < 0.01 {
            return CMTime(value: 1001, timescale: CMTimeScale((ntsc * 1001 / 1000).rounded() * 1000))
        }
        return CMTime(value: 1, timescale: CMTimeScale(max(1, rate.rounded())))
    }
}
