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

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    /// Counts composition swaps. While the latest swap's seek is pending, the new item reports 0:00,
    /// which would flash the playhead to the start; those reports are ignored.
    @ObservationIgnored private var swapGeneration = 0
    @ObservationIgnored private var isSwapping = false
    /// Told when a rebuilt composition starts replacing the current one (true) and when it's in place (false),
    /// so the preview can hold the last frame across the swap instead of flashing.
    @ObservationIgnored var onSwap: ((Bool) -> Void)?

    /// Shared with every audio tap, so master volume changes are heard at once, boost included.
    @ObservationIgnored let masterGain = MasterGain()

    func setMasterVolume(_ volume: Double) {
        masterGain.value = max(0, volume)
    }

    #if DEBUG
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
            let playing = (change.newValue ?? 0) != 0
            Task { @MainActor in
                self?.isPlaying = playing
            }
        }
    }

    /// What the current composition's compositor draws, for showing look changes without a rebuild.
    @ObservationIgnored private(set) var plan: RenderPlanBox?

    /// Draws the frame at the playhead again after the plan changes. While playing, the next frame shows it anyway.
    func redrawPicture() {
        guard !isPlaying, player.currentItem != nil else { return }
        player.seek(to: currentTime.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Swaps in a rebuilt composition, keeping the playhead and play state.
    func install(_ built: BuiltComposition) {
        plan = built.plan
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
