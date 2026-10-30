@preconcurrency import AVFoundation

/// Everything the player or exporter needs to render the timeline.
struct BuiltComposition {
    let composition: AVComposition
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?
    let duration: Time
    /// What the compositor draws, shared with it so visual changes can show without a rebuild. Nil without pictures.
    var plan: RenderPlanBox?
    /// What the video composition was made from, to make a fresh one that redraws the picture after the plan changes.
    var videoConfiguration: AVVideoComposition.Configuration?
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
        /// Held for the whole build: a track only weakly refers to its asset, and can't be inserted once it's gone.
        var asset: AVURLAsset
        var video: AVAssetTrack?
        var audio: AVAssetTrack?
        var naturalSize: CGSize = .zero
        var preferredTransform: CGAffineTransform = .identity
    }

    static func build(project: Project, assets: (UUID) -> AVURLAsset?, options: Options = Options()) async throws -> BuiltComposition {
        // Media files are opened for their tracks; images and wallpapers only need their file.
        var loaded: [UUID: LoadedAsset] = [:]
        var urls: [UUID: URL] = [:]
        var used = Set(project.tracks.flatMap(\.clips).map(\.assetID))
        for fill in [project.background] + project.tracks.flatMap(\.clips).map(\.fill) {
            if case let .wallpaper(id)? = fill { used.insert(id) }
        }
        for assetID in used {
            guard let asset = assets(assetID), let kind = project.asset(assetID)?.kind else { continue }
            urls[assetID] = asset.url
            if kind != .image {
                loaded[assetID] = try await load(asset)
            }
        }

        let composition = AVMutableComposition()
        let canvas = project.canvas ?? Project.defaultCanvas
        let renderSize = CGSize(width: canvas.width, height: canvas.height)
        var layers: [RenderLayer] = []
        // Where pictures start and end, for the instructions.
        var edges: Set<Time> = [.zero]
        var audioParameters: [AVMutableAudioMixInputParameters] = []

        // Tracks run bottom to top, and so do the layers.
        for (trackIndex, track) in project.tracks.enumerated() {
            // Muted tracks, and tracks left out by a solo, stay in the composition (so its length holds) but go
            // invisible and silent.
            let isActive = project.isActive(track)
            // Clips alternate between two slots, so a clip and the next one it crossfades with can play at once.
            var videoTracks: [Int: AVMutableCompositionTrack] = [:]
            // Sound with and without pitch correction needs separate composition tracks, since the setting is per track.
            var audioTracks: [AudioSlot: AVMutableCompositionTrack] = [:]
            var segments: [AudioSlot: [GainSegment]] = [:]

            let clips = track.clips.sorted { $0.start < $1.start }
            let crossfades = project.crossfades(onTrack: trackIndex)
            for (index, clip) in clips.enumerated() {
                let slot = index % 2
                var picture: RenderLayer.Source?
                if let title = clip.title {
                    picture = .title(title)
                } else if let fill = clip.fill {
                    picture = resolve(fill, urls: urls).map { .fill($0) }
                } else if project.asset(clip.assetID)?.kind == .image, let url = urls[clip.assetID] {
                    picture = .image(url)
                }

                if let source = loaded[clip.assetID] {
                    let sourceRange = CMTimeRange(start: clip.sourceStart.cmTime, duration: clip.sourceDuration.cmTime)
                    if clip.usesVideo, let sourceVideo = source.video {
                        let target = videoTracks[slot] ?? composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                        videoTracks[slot] = target
                        if let target {
                            try insert(sourceRange, of: sourceVideo, into: target, at: clip)
                            picture = .video(trackID: target.trackID, orientation: orientation(of: source.preferredTransform))
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

                if let picture, isActive {
                    let transition = { (crossfade: Crossfade) in
                        PictureTransition(start: crossfade.range.start.seconds, end: crossfade.range.end.seconds,
                                          curve: crossfade.curve, style: crossfade.videoStyle)
                    }
                    layers.append(RenderLayer(
                        clipID: clip.id, source: picture, track: trackIndex,
                        start: clip.start.seconds, end: clip.end.seconds, visual: clip.visual,
                        transitionIn: crossfades.first { $0.incoming.id == clip.id }.map(transition),
                        transitionOut: crossfades.first { $0.outgoing.id == clip.id }.map(transition)
                    ))
                    edges.insert(clip.start)
                    edges.insert(clip.end)
                }
            }

            for (audioSlot, audioTrack) in audioTracks {
                let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
                parameters.audioTimePitchAlgorithm = audioSlot.keepsPitch ? .spectral : .varispeed
                parameters.audioTapProcessor = AudioTap.make(program: GainProgram(segments: segments[audioSlot] ?? []), master: options.master)
                audioParameters.append(parameters)
            }
        }

        var videoComposition: AVVideoComposition?
        var videoConfiguration: AVVideoComposition.Configuration?
        var plan: RenderPlanBox?
        if project.hasVisualClips, project.duration > .zero {
            // A blank track under the whole timeline gives the compositor a frame to draw everywhere, gaps included.
            let blank = AVURLAsset(url: try await BlankVideo.url())
            let second = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
            guard let blankVideo = try await blank.loadTracks(withMediaType: .video).first,
                  let base = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try base.insertTimeRange(second, of: blankVideo, at: .zero)
            base.scaleTimeRange(second, toDuration: project.duration.cmTime)

            let box = RenderPlanBox(RenderPlan(
                canvas: renderSize,
                background: project.background.flatMap { resolve($0, urls: urls) },
                frame: project.frame,
                layers: layers,
                hiddenClip: nil
            ))
            edges.insert(Time(composition.duration))
            let configuration = AVVideoComposition.Configuration(
                colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
                colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
                colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
                customVideoCompositorClass: Compositor.self,
                frameDuration: frameDuration(for: canvas.frameRate),
                instructions: instructions(edges: edges, until: Time(composition.duration), layers: layers, baseTrack: base.trackID, plan: box),
                renderSize: renderSize
            )
            videoComposition = AVVideoComposition(configuration: configuration)
            videoConfiguration = configuration
            plan = box
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
            duration: Time(composition.duration),
            plan: plan,
            videoConfiguration: videoConfiguration
        )
    }

    /// One instruction between each pair of neighboring edges, asking only for the video tracks playing there.
    private static func instructions(edges: Set<Time>, until end: Time, layers: [RenderLayer],
                                     baseTrack: CMPersistentTrackID, plan: RenderPlanBox) -> [CompositionInstruction] {
        let times = edges.filter { $0 <= end }.sorted()
        return zip(times, times.dropFirst()).map { start, stop in
            let middle = (start.seconds + stop.seconds) / 2
            let playing = layers.filter { $0.isActive(at: middle) }.compactMap { layer -> CMPersistentTrackID? in
                if case let .video(trackID, _) = layer.source { trackID } else { nil }
            }
            return CompositionInstruction(timeRange: CMTimeRange(start: start.cmTime, end: stop.cmTime),
                                          trackIDs: [baseTrack] + Set(playing).sorted(), plan: plan)
        }
    }

    private static func resolve(_ fill: BackgroundFill, urls: [UUID: URL]) -> ResolvedFill? {
        switch fill {
        case let .color(color): .color(color)
        case let .gradient(gradient): .gradient(gradient)
        case let .wallpaper(id): urls[id].map { .image($0) }
        }
    }

    /// The turn a video's stored frames need to stand upright.
    private static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded()) {
        case (0, 1, -1, 0): .right
        case (-1, 0, 0, -1): .down
        case (0, -1, 1, 0): .left
        default: .up
        }
    }

    private static func load(_ asset: AVURLAsset) async throws -> LoadedAsset {
        var result = LoadedAsset(asset: asset)
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

    static func frameDuration(for rate: Double) -> CMTime {
        for ntsc in [23.976, 29.97, 59.94] where abs(rate - ntsc) < 0.01 {
            return CMTime(value: 1001, timescale: CMTimeScale((ntsc * 1001 / 1000).rounded() * 1000))
        }
        return CMTime(value: 1, timescale: CMTimeScale(max(1, rate.rounded())))
    }
}
