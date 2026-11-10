import AVFoundation
import Observation

/// Owns the player that drives the preview and the speakers.
@MainActor
@Observable
final class PlaybackController {
    @ObservationIgnored let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var currentTime: Time = .zero
    private(set) var duration: Time = .zero

    /// Whether playing past the end starts again from the beginning. New windows take the last choice.
    var loopsPlayback = UserDefaults.standard.bool(forKey: "loopsPlayback") {
        didSet { UserDefaults.standard.set(loopsPlayback, forKey: "loopsPlayback") }
    }

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    /// The speed of the last forward play, which a loop carries on at.
    @ObservationIgnored private var forwardRate: Float = 1
    /// Counts composition swaps. While the latest swap's seek is pending, the new item reports 0:00,
    /// which would flash the playhead to the start; those reports are ignored.
    @ObservationIgnored private var swapGeneration = 0
    @ObservationIgnored private var isSwapping = false
    /// Told when a rebuilt composition starts replacing the current one (true) and when it's in place (false),
    /// so the preview can hold the last frame across the swap instead of flashing.
    @ObservationIgnored var onSwap: ((Bool) -> Void)?
    /// Hears when playing starts or stops.
    @ObservationIgnored var onPlayingChange: ((Bool) -> Void)?

    /// Shared with every audio tap, so master volume changes are heard at once, boost included.
    @ObservationIgnored let masterGain = MasterGain()

    func setMasterVolume(_ volume: Double) {
        masterGain.value = max(0, volume)
    }

    #if DEBUG
    /// Whether a rebuilt composition's seek is still pending.
    var debugIsSwapping: Bool { isSwapping }

    /// Every time the player reports, while a debug check is recording.
    @ObservationIgnored var reportedTimes: [Double]?
    #endif

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isSwapping else { return }
                self.currentTime = Time(time)
                #if DEBUG
                self.reportedTimes?.append(time.seconds)
                #endif
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            let rate = change.newValue ?? 0
            Task { @MainActor in
                guard let self else { return }
                let playing = rate != 0
                if playing != self.isPlaying {
                    self.isPlaying = playing
                    self.onPlayingChange?(playing)
                }
                if rate > 0 { self.forwardRate = rate }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
            let ended = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, self.loopsPlayback, let current = self.player.currentItem, ended == ObjectIdentifier(current) else { return }
                self.loopToStart()
            }
        }
    }

    /// Played to the end with Loop on: back to the start, playing on at the same speed. The rate is set first, so
    /// the player starts the moment the seek lands instead of waiting to be told after.
    private func loopToStart() {
        currentTime = .zero
        player.rate = forwardRate
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// What the current composition's compositor draws, for showing look changes without a rebuild.
    @ObservationIgnored private(set) var plan: RenderPlanBox?
    @ObservationIgnored private var videoConfiguration: AVVideoComposition.Configuration?

    /// Draws the frame at the playhead again after the plan changes. Seeking to the same time doesn't redraw, but a
    /// fresh video composition does. While playing, the next frame shows the change anyway.
    func redrawPicture() {
        guard !isPlaying, let item = player.currentItem, let videoConfiguration else { return }
        item.videoComposition = AVVideoComposition(configuration: videoConfiguration)
    }

    /// Takes a rebuilt composition's picture and sound into the item that's playing, for a change that leaves the
    /// timeline's layout as it was: the item keeps its decoders, so the change shows on the very next frame instead
    /// of waiting for a new item to seek and decode. Only for builds with the same `CompositionBuilder.Layout`.
    /// The picture is replaced only when it looks different, and the sound only when `mixChanged`: a new mix makes
    /// the item refill its audio, and a new picture makes it draw again.
    func refresh(with built: BuiltComposition, mixChanged: Bool) {
        guard let item = player.currentItem else {
            install(built)
            return
        }
        let pictureChanged = built.plan?.current != plan?.current
            || built.videoConfiguration?.renderSize != videoConfiguration?.renderSize
            || built.videoConfiguration?.frameDuration != videoConfiguration?.frameDuration
        if pictureChanged {
            plan = built.plan
            videoConfiguration = built.videoConfiguration
            item.videoComposition = built.videoComposition
        }
        if mixChanged {
            item.audioMix = built.audioMix
        }
    }

    /// Swaps in a rebuilt composition, keeping the playhead and play state.
    func install(_ built: BuiltComposition) {
        plan = built.plan
        videoConfiguration = built.videoConfiguration
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix

        let rate = player.rate
        let time = min(currentTime, built.duration)
        duration = built.duration
        currentTime = time
        swapGeneration += 1
        let generation = swapGeneration
        isSwapping = true
        onSwap?(true)
        player.replaceCurrentItem(with: item)
        player.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                // A newer swap may have started; only the latest one ends the quiet period.
                guard let self, generation == self.swapGeneration else { return }
                self.endSwap()
                if rate != 0 { self.player.rate = rate }
            }
        }
    }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
            return
        }
        guard duration > .zero else { return }
        if currentTime >= duration - Time(seconds: 0.05) {
            seek(to: .zero)
        }
        player.play()
    }

    func pause() {
        player.pause()
    }

    /// J and L: each press plays faster in that direction, 1× up to 8×. Reverse play needs media that supports it.
    func shuttle(forward: Bool) {
        guard duration > .zero else { return }
        let rate = player.rate
        if forward {
            if currentTime >= duration - Time(seconds: 0.05) { seek(to: .zero) }
            player.rate = rate <= 0 ? 1 : min(rate * 2, 8)
        } else if player.currentItem?.canPlayReverse == true {
            player.rate = rate >= 0 ? -1 : max(rate * 2, -8)
        }
    }

    func seek(to time: Time) {
        // Before the first composition is built, the length isn't known yet, so only zero bounds the seek.
        let clamped = duration > .zero ? min(max(time, .zero), duration) : max(time, .zero)
        currentTime = clamped
        // A seek during a swap cancels the swap's own seek, so this one ends the quiet period instead.
        let generation = swapGeneration
        player.seek(to: clamped.cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                if let self, self.isSwapping, generation == self.swapGeneration { self.endSwap() }
            }
        }
    }

    private func endSwap() {
        isSwapping = false
        onSwap?(false)
    }
}
