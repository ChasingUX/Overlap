import Accelerate
import AVFoundation

/// A stretch of a video that can play over and over without the join showing: the jump back is no bigger than
/// the change from one frame to the next.
struct Loop: Hashable, Sendable {
    /// Source times, in seconds: the loop plays from `start` up to `end`, then from `start` again.
    let start: Double
    let end: Double

    var length: Double { end - start }
}

/// How often a whole video repeats: the same picture comes back `frames` later wherever you look, so a loop that
/// long, or a few times that long, can start anywhere.
struct Repetition: Hashable, Sendable {
    let frames: Int
    /// In seconds.
    let length: Double
}

/// A tiny grayscale copy of each frame of a video, made to find where it loops. Frames are 32 × 18, scaled by the
/// decoder itself: that small, grain and compression noise mostly average away, while anything that moves still shows.
struct FramePrints: Sendable {
    static let width = 32
    static let height = 18
    static let size = width * height
    /// The most frames kept, whatever the video's length: every frame up to 30 a second, fewer for long videos.
    static let maximumFrames = 9000

    /// The source time of each frame, in seconds.
    let times: [Double]
    /// Each frame's brightness, 0 to 1, `size` values per frame, one frame after another.
    let values: [Float]
    /// How different each frame is from the next.
    let steps: [Float]
    /// How much a typical frame differs from the next: the yardstick a join is measured against.
    let motion: Float

    init(times: [Double], values: [Float]) {
        self.times = times
        self.values = values
        let count = times.count
        let steps = count > 1 ? (0..<(count - 1)).map { Self.difference($0, $0 + 1, in: values) } : []
        self.steps = steps
        motion = steps.isEmpty ? 0 : steps.sorted()[steps.count / 2]
    }

    var count: Int { times.count }

    /// Frames kept per second.
    var rate: Double {
        guard count > 1, let first = times.first, let last = times.last, last > first else { return 30 }
        return Double(count - 1) / (last - first)
    }

    /// A shot that barely moves loops from any point.
    var isStill: Bool { motion < Self.stillMotion }

    private static let stillMotion: Float = 0.003

    /// How different two frames look: their mean brightness difference, 0 to 1.
    func difference(_ a: Int, _ b: Int) -> Float {
        Self.difference(a, b, in: values)
    }

    private static func difference(_ a: Int, _ b: Int, in values: [Float]) -> Float {
        values.withUnsafeBufferPointer { all in
            withUnsafeTemporaryAllocation(of: Float.self, capacity: size) { scratch in
                let base = all.baseAddress!
                vDSP_vsub(base + b * size, 1, base + a * size, 1, scratch.baseAddress!, 1, vDSP_Length(size))
                var mean: Float = 0
                vDSP_meamgv(scratch.baseAddress!, 1, &mean, vDSP_Length(size))
                return mean
            }
        }
    }

    /// The frame showing at a source time.
    func index(at time: Double) -> Int {
        var low = 0
        var high = count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if times[middle] <= time + 0.0005 { low = middle } else { high = middle - 1 }
        }
        return low
    }

    // MARK: Joins

    /// How visible a join from just before frame `end` back to frame `start` would be. The frames around each are
    /// compared too, `reach` either side, and the worst pair counts, so the movement has to carry on the same way,
    /// not only the picture match: a pendulum passes the middle going both ways.
    func joinCost(start: Int, end: Int, reach: Int) -> Float {
        let lower = max(-reach, -start)
        let upper = min(reach, count - 1 - end)
        guard lower <= upper else { return .infinity }
        var worst: Float = 0
        for offset in lower...upper {
            worst = max(worst, difference(start + offset, end + offset))
        }
        return worst
    }

    /// Whether a join doesn't show: its jump is no bigger than about one step from frame to frame where the cut is.
    /// A jump hides in fast movement, but only if both sides of the cut move fast, as the slower side shows it
    /// plainly. It's never measured against less than the video's typical change, and never passes a jump of more
    /// than `largestJump`, however fast things move.
    func isSeamless(start: Int, end: Int, cost: Float) -> Bool {
        guard cost <= Self.largestJump else { return false }
        return cost / max(min(change(around: start), change(around: end)), motion, Self.stillMotion) <= 1.5
    }

    /// A join that changes this much of the picture's brightness, on average, shows.
    private static let largestJump: Float = 0.06

    /// The mean change from frame to frame, a few frames either side of one.
    private func change(around frame: Int) -> Float {
        let nearby = max(0, frame - 3)..<min(steps.count, frame + 3)
        return nearby.isEmpty ? 0 : steps[nearby].reduce(0, +) / Float(nearby.count)
    }

    /// Whether anything moves between frames `start` and `end`. A stretch of black, or a held frame, matches itself
    /// perfectly but isn't worth looping.
    func moves(from start: Int, to end: Int) -> Bool {
        guard end > start else { return false }
        let moving = steps[start..<min(end, steps.count)].reduce(0, +) / Float(end - start)
        return moving >= max(motion * 0.3, Self.stillMotion)
    }

    /// A tenth of a second either side of a join.
    private var reach: Int { max(1, Int((rate / 10).rounded())) }

    /// The best places to loop back to the frame at `start`, a source time, best first.
    func loops(from start: Double, minimumLength: Double = 1, limit: Int = 5) -> [Loop] {
        let first = index(at: start)
        let shortest = Int((minimumLength * rate).rounded(.up))
        guard first + shortest < count else { return [] }
        let ends = Array((first + shortest)..<count)
        let costs = ends.map { joinCost(start: first, end: $0, reach: reach) }
        // Only low points: a join a frame either side of a good one is the same join, only worse.
        let spread = max(1, Int((rate * 0.15).rounded()))
        var picks: [(end: Int, cost: Float)] = []
        for (offset, cost) in costs.enumerated() {
            let around = costs[max(0, offset - spread)...min(costs.count - 1, offset + spread)]
            guard cost <= around.min() ?? cost, picks.last.map({ ends[offset] - $0.end > spread }) ?? true,
                  moves(from: first, to: ends[offset]) else { continue }
            picks.append((ends[offset], cost))
        }
        return picks.sorted { $0.cost < $1.cost }
            .compactMap { pick in
                isSeamless(start: first, end: pick.end, cost: pick.cost) ? Loop(start: times[first], end: times[pick.end]) : nil
            }
            .prefix(limit).map { $0 }
    }

    /// How often the whole video repeats, if it does. Each length is judged by the typical difference between frames
    /// that far apart, across the video, so a single lucky match doesn't count. The shortest length that repeats
    /// about as well as any wins: a video that repeats every second also repeats every two.
    func repetition(minimumLength: Double = 1, maximumLength: Double = 60) -> Repetition? {
        let shortest = Int((minimumLength * rate).rounded(.up))
        // Enough of the video left to compare at that distance: a quarter of it, and at least a second.
        let longest = min(Int(maximumLength * rate), count - max(Int(rate.rounded()), count / 4))
        guard shortest <= longest else { return nil }
        let every = max(1, (count - shortest) / 240)
        func typical(_ lag: Int, every: Int, share: Double = 0.5) -> Float {
            let differences = stride(from: 0, to: count - lag, by: every).map { difference($0, $0 + lag) }.sorted()
            return differences[min(differences.count - 1, Int(Double(differences.count) * share))]
        }
        let typicals = (shortest...longest).map { typical($0, every: every) }
        guard let best = typicals.min(), let first = typicals.indices.first(where: { typicals[$0] <= best * 1.25 + 0.0005 }) else {
            return nil
        }
        // The low point around the first length that's nearly as good as the best.
        let spread = max(1, Int((rate * 0.15).rounded()))
        let around = first...min(typicals.count - 1, first + spread)
        let lag = shortest + (around.min { typicals[$0] < typicals[$1] } ?? first)
        // Most of the video has to repeat, not one stretch of it.
        let yardstick = max(motion, Self.stillMotion)
        guard typical(lag, every: 1, share: 0.75) <= yardstick * 3 else { return nil }
        let ratio = typical(lag, every: 1) / yardstick
        guard ratio <= 3 else { return nil }
        guard ratio <= 1.5 else { return nil }
        return Repetition(frames: lag, length: Double(lag) / rate)
    }

    /// Loops of one, two, three and four repeats, starting at the frame at `start`, a source time, as far as the
    /// video goes.
    func loops(repeating repetition: Repetition, from start: Double) -> [Loop] {
        let first = index(at: start)
        return (1...4).compactMap { repeats in
            let end = first + repetition.frames * repeats
            return end < count ? Loop(start: times[first], end: times[end]) : nil
        }
    }

    /// The best loops anywhere in the video, each a different length, best first. A first pass compares frames
    /// about a sixth of a second apart; the best of those are then fine-tuned frame by frame.
    func suggestedLoops(minimumLength: Double = 1, maximumLength: Double = 30, limit: Int = 5) -> [Loop] {
        let step = max(1, Int((rate / 6).rounded()))
        let coarse = Array(stride(from: 0, to: count, by: step))
        let shortest = max(1, Int((minimumLength * rate / Double(step)).rounded(.up)))
        let longest = min(coarse.count - 1, Int(maximumLength * rate / Double(step)))
        guard shortest <= longest else { return [] }

        // Differences between coarse frames, by how far apart they are; a join's cost is the worst of three in a row.
        var differences = [[Float]](repeating: [], count: coarse.count)
        for a in coarse.indices {
            let reachable = min(longest, coarse.count - 1 - a)
            differences[a] = reachable >= shortest ? (shortest...reachable).map { difference(coarse[a], coarse[a + $0]) } : []
        }
        var joins: [(a: Int, apart: Int, cost: Float)] = []
        for a in coarse.indices {
            for apart in shortest...longest where a + apart < coarse.count {
                var worst: Float = 0
                for neighbor in max(0, a - 1)...min(coarse.count - 1, a + 1) where neighbor + apart < coarse.count {
                    worst = max(worst, differences[neighbor][apart - shortest])
                }
                joins.append((a, apart, worst))
            }
        }

        // One loop of each length: a video that repeats every second loops just as well from any start.
        let sameLength = max(1, Int((0.3 * rate / Double(step)).rounded()))
        var picked: [(a: Int, apart: Int)] = []
        for join in joins.sorted(by: { $0.cost < $1.cost }) where picked.count < limit * 2 {
            guard !picked.contains(where: { abs($0.apart - join.apart) <= sameLength }),
                  moves(from: coarse[join.a], to: coarse[join.a + join.apart]) else { continue }
            picked.append((join.a, join.apart))
        }

        // Fine-tuned to the frame, around each coarse pick.
        var loops: [(loop: Loop, cost: Float)] = []
        for pick in picked {
            var best = (start: coarse[pick.a], end: coarse[pick.a + pick.apart], cost: Float.infinity)
            for start in max(0, coarse[pick.a] - step)...min(count - 1, coarse[pick.a] + step) {
                for end in max(start + 1, coarse[pick.a + pick.apart] - step)...min(count - 1, coarse[pick.a + pick.apart] + step) {
                    let cost = joinCost(start: start, end: end, reach: reach)
                    if cost < best.cost { best = (start, end, cost) }
                }
            }
            if times[best.end] - times[best.start] >= minimumLength - 0.001, isSeamless(start: best.start, end: best.end, cost: best.cost) {
                loops.append((Loop(start: times[best.start], end: times[best.end]), best.cost))
            }
        }
        return loops.sorted { $0.cost < $1.cost }.prefix(limit).map(\.loop)
    }

    // MARK: Reading

    /// Reads every frame of a video's first video track, telling `progress` how far it has got, 0 to 1.
    @concurrent
    static func make(for url: URL, progress: @escaping @Sendable @MainActor (Double) -> Void) async -> FramePrints? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration).seconds, duration > 0,
              let nominalRate = try? await track.load(.nominalFrameRate) else { return nil }
        let perSecond = min(nominalRate > 0 ? Double(nominalRate) : 30, 30, Double(maximumFrames) / duration)
        let spacing = 1 / perSecond
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        output.alwaysCopiesSampleData = false

        var times: [Double] = []
        var values: [Float] = []
        values.reserveCapacity(min(maximumFrames, Int(duration * perSecond) + 1) * size)
        var nextKept = -Double.infinity
        var lastReported = 0
        do {
            let reader = try AVAssetReader(asset: asset)
            let provider = reader.outputProvider(for: output)
            try reader.start()
            while let ready = try await provider.next() {
                ready.withUnsafeSampleBuffer { buffer in
                    let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                    // Long or fast videos keep every second or third frame, and so on, evenly spaced.
                    guard time + spacing / 4 >= nextKept, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
                    nextKept = time + spacing
                    if append(pixels, to: &values) { times.append(time) }
                }
                if times.count - lastReported >= 60 {
                    lastReported = times.count
                    await progress(min(1, (times.last ?? 0) / duration))
                }
            }
        } catch {
            return nil
        }
        guard times.count > 1 else { return nil }
        return FramePrints(times: times, values: values)
    }

    /// Adds a frame's brightness, read from its luma plane. The decoder scales to 32 × 18 itself; if it hands back
    /// another size, the nearest pixels stand in.
    private static func append(_ pixels: CVPixelBuffer, to values: inout [Float]) -> Bool {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixels) >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return false }
        let planeWidth = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let planeHeight = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        guard planeWidth > 0, planeHeight > 0 else { return false }
        for y in 0..<height {
            let line = base.advanced(by: (y * planeHeight / height) * row).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                values.append(Float(line[x * planeWidth / width]) / 255)
            }
        }
        return true
    }
}
