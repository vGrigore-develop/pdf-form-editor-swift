import Foundation

/// Minimum-cost paths from one seed pixel through a cost image ("live wire",
/// Mortensen and Barrett 1995), with Dial's bucket queue over integer costs.
///
/// The shortest-path tree grows lazily: `path(to:)` expands only until the target is
/// settled, and later queries continue from where the last one stopped. While the
/// cursor moves away from an anchor, each update therefore settles only the pixels
/// that became cheaper than the new target, and one anchor's whole tree is built at
/// most once (a full 150 dpi A4 page is about 2.2 M pixels).
///
/// 8-connected; entering a pixel costs its cost value, times sqrt(2) on diagonals.
public final class LiveWire {
    public let width: Int
    public let height: Int
    public let seed: Int
    private let cost: [UInt8]
    private var dist: [UInt32]
    /// Direction index (0..7) of the step that reached each pixel; -1 = none.
    private var parent: [Int8]
    private var settled: [Bool]
    private var buckets: [[Int32]]
    private var currentBucket: Int = 0
    private var queued = 0
    public private(set) var settledCount = 0

    private static let dx: [Int] = [1, 1, 0, -1, -1, -1, 0, 1]
    private static let dy: [Int] = [0, 1, 1, 1, 0, -1, -1, -1]
    private static let ring = 256 // > the largest step cost (124 * 181 / 128 = 175)

    public init(cost: [UInt8], width: Int, height: Int, seed: Int) {
        precondition(cost.count == width * height && seed >= 0 && seed < cost.count)
        self.cost = cost
        self.width = width
        self.height = height
        self.seed = seed
        dist = [UInt32](repeating: .max, count: cost.count)
        parent = [Int8](repeating: -1, count: cost.count)
        settled = [Bool](repeating: false, count: cost.count)
        buckets = Array(repeating: [], count: Self.ring)
        dist[seed] = 0
        buckets[0].append(Int32(seed))
        queued = 1
    }

    public func isSettled(_ index: Int) -> Bool { settled[index] }

    /// Pixel indices from the seed to `target` (both included), or nil if the target
    /// cannot be reached within `maxSettle` newly settled pixels.
    public func path(to target: Int, maxSettle: Int = .max) -> [Int]? {
        guard target >= 0, target < cost.count else { return nil }
        if !settled[target] && !expand(until: target, maxSettle: maxSettle) { return nil }
        var out: [Int] = [target]
        var cur = target
        while cur != seed {
            let d = Int(parent[cur])
            guard d >= 0 else { return nil }
            cur -= Self.dy[d] * width + Self.dx[d]
            out.append(cur)
        }
        return out.reversed()
    }

    private func expand(until target: Int, maxSettle: Int) -> Bool {
        let w = width, h = height
        var budget = maxSettle
        return cost.withUnsafeBufferPointer { C in
            dist.withUnsafeMutableBufferPointer { D in
                parent.withUnsafeMutableBufferPointer { P in
                    settled.withUnsafeMutableBufferPointer { S in
                        while queued > 0 {
                            // Find the next non-empty bucket.
                            var guardCount = 0
                            while buckets[currentBucket % Self.ring].isEmpty {
                                currentBucket += 1
                                guardCount += 1
                                if guardCount > Self.ring { return false }
                            }
                            let b = currentBucket % Self.ring
                            let u = Int(buckets[b].removeLast())
                            queued -= 1
                            if S[u] || Int(D[u]) != currentBucket { continue }
                            S[u] = true
                            settledCount += 1
                            budget -= 1
                            let ux = u % w, uy = u / w
                            let du = D[u]
                            for k in 0..<8 {
                                let vx = ux + Self.dx[k], vy = uy + Self.dy[k]
                                if vx < 0 || vy < 0 || vx >= w || vy >= h { continue }
                                let v = vy * w + vx
                                if S[v] { continue }
                                let c = UInt32(C[v])
                                let step = (k & 1) == 1 ? (c * 181 + 64) >> 7 : c
                                let nd = du + step
                                if nd < D[v] {
                                    D[v] = nd
                                    P[v] = Int8(k)
                                    buckets[Int(nd) % Self.ring].append(Int32(v))
                                    queued += 1
                                }
                            }
                            if u == target { return true }
                            if budget <= 0 { return S[target] }
                        }
                        return S[target]
                    }
                }
            }
        }
    }
}
