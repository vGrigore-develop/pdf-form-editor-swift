import Foundation

/// Edge strength of a page raster, used as the "magnetic" field for tracing.
///
/// Pipeline (all plain Swift over Float buffers, no dependencies):
/// 1. luminance (Rec. 601) in 0...1;
/// 2. a [1 2 1]/4 separable blur (sigma about 0.7 px) against JPEG noise;
/// 3. gradient magnitude from central differences (a sharp step of contrast c gives about 0.75 c);
/// 4. a thin-line ("ridge") response |mean5x5 - L| * 2, so a 1-2 px stroke is one strong band
///    with its maximum on the stroke's centre line rather than two edges either side of it;
/// 5. F = max(gradient, ridge), blurred once more so its maximum is centred on an edge.
///
/// `norm` is a robust scale for F (the 90th percentile over non-flat pixels), so the
/// sensitivity setting means the same on a faint pencil line and on black-on-white art.
public final class EdgeMap: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// Blurred luminance, 0...1.
    public let luminance: [Float]
    /// Edge strength F (about 0...1).
    public let strength: [Float]
    /// Robust scale of F.
    public let norm: Float
    /// Noise floor of F (photos, JPEG noise, paper texture); below it nothing is an edge.
    public let floor: Float

    public init(raster: PageRaster) {
        let w = raster.width, h = raster.height, n = w * h
        width = w; height = h
        var lum = [Float](repeating: 0, count: n)
        raster.rgba.withUnsafeBufferPointer { px in
            lum.withUnsafeMutableBufferPointer { out in
                for i in 0..<n {
                    let r = Float(px[4 * i]), g = Float(px[4 * i + 1]), b = Float(px[4 * i + 2])
                    out[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255
                }
            }
        }
        let blurred = Self.blur121(lum, w, h)
        let mean = Self.boxMean(blurred, w, h, radius: 2)
        var f = [Float](repeating: 0, count: n)
        blurred.withUnsafeBufferPointer { L in
            mean.withUnsafeBufferPointer { M in
                f.withUnsafeMutableBufferPointer { F in
                    for y in 0..<h {
                        let ym = max(y - 1, 0), yp = min(y + 1, h - 1)
                        for x in 0..<w {
                            let xm = max(x - 1, 0), xp = min(x + 1, w - 1)
                            let gx = L[y * w + xp] - L[y * w + xm]
                            let gy = L[yp * w + x] - L[ym * w + x]
                            let g = (gx * gx + gy * gy).squareRoot()
                            let ridge = abs(M[y * w + x] - L[y * w + x]) * 2
                            F[y * w + x] = max(g, ridge)
                        }
                    }
                }
            }
        }
        let fb = Self.blur121(f, w, h)
        luminance = blurred
        strength = fb
        (floor, norm) = Self.robustNorm(fb)
    }

    // MARK: Cost

    /// F at which a pixel counts as fully "magnetic". At the default sensitivity (0.5) it
    /// is a little above the 99.5th percentile, so the centre of an edge band stays cheaper
    /// than its flanks and the path does not wander across the band.
    func knee(_ sensitivity: Double) -> Float {
        max(floor + 1e-4, norm * Float(2.0 - 1.7 * min(max(sensitivity, 0), 1)))
    }

    /// Per-pixel cost of passing through a pixel (4...124): low on strong edges.
    /// `sensitivity` 0...1: higher means weaker edges count as fully "magnetic".
    public func costMap(sensitivity: Double) -> [UInt8] {
        let knee = knee(sensitivity)
        let lo = floor, span = knee - floor
        var out = [UInt8](repeating: 0, count: strength.count)
        strength.withUnsafeBufferPointer { F in
            out.withUnsafeMutableBufferPointer { C in
                for i in 0..<F.count {
                    let fn = min(1, max(0, F[i] - lo) / span)
                    let d = 1 - fn
                    C[i] = UInt8(4 + Int((120 * d * d).rounded()))
                }
            }
        }
        return out
    }

    /// Threshold on F above which a pixel counts as "on an edge" for anchor snapping.
    public func edgeThreshold(sensitivity: Double) -> Float {
        floor + (knee(sensitivity) - floor) * 0.25
    }

    // MARK: Anchor snapping

    /// The pixel an anchor clicked at (x, y) snaps to: the strongest corner within
    /// `radius` px if there is one on a strong edge, else the strongest edge pixel,
    /// else the click itself. Returns a pixel index.
    public func snap(x: Int, y: Int, radius: Int, sensitivity: Double) -> Int {
        let x = min(max(x, 0), width - 1), y = min(max(y, 0), height - 1)
        guard radius > 0 else { return y * width + x }
        let r2 = radius * radius
        let edgeMin = edgeThreshold(sensitivity: sensitivity)
        // Corners: Shi-Tomasi minimum eigenvalue of the 5x5 structure tensor.
        let x0 = max(x - radius, 0), x1 = min(x + radius, width - 1)
        let y0 = max(y - radius, 0), y1 = min(y + radius, height - 1)
        // The strongest corner response in the window (ties: the nearer), then onto the crest.
        var corners: [(score: Float, idx: Int, d2: Int)] = []
        let cornerMin = (0.3 * norm) * (0.3 * norm)
        for yy in y0...y1 {
            for xx in x0...x1 {
                let d2 = (xx - x) * (xx - x) + (yy - y) * (yy - y)
                guard d2 <= r2, strength[yy * width + xx] >= max(edgeMin, 0.5 * norm) else { continue }
                // A corner has strong gradients in two directions: both eigenvalues large and
                // comparable (an anti-aliased, gently curving line has one dominant direction).
                let (lmin, lmax) = eigen(xx, yy)
                if lmin >= cornerMin, lmin >= 0.25 * lmax { corners.append((lmin, yy * width + xx, d2)) }
            }
        }
        if let c = corners.max(by: { $0.score < $1.score * 0.95 || ($0.score <= $1.score * 1.05 && $0.d2 > $1.d2) }) {
            return climb(c.idx, steps: 4)
        }
        // Edges: the nearest pixel that is nearly as strong as the strongest edge in the
        // window, then one step onto the ridge's crest.
        var windowMax: Float = 0
        for yy in y0...y1 {
            for xx in x0...x1 where (xx - x) * (xx - x) + (yy - y) * (yy - y) <= r2 {
                windowMax = max(windowMax, strength[yy * width + xx])
            }
        }
        guard windowMax >= edgeMin else { return y * width + x }
        let accept = max(edgeMin, 0.7 * windowMax)
        var best: (idx: Int, d2: Int)?
        for yy in y0...y1 {
            for xx in x0...x1 {
                let d2 = (xx - x) * (xx - x) + (yy - y) * (yy - y)
                guard d2 <= r2, strength[yy * width + xx] >= accept else { continue }
                if best == nil || d2 < best!.d2 { best = (yy * width + xx, d2) }
            }
        }
        return best.map { climb($0.idx, steps: 2) } ?? (y * width + x)
    }

    /// Hill-climb on F from `idx` to a local maximum (at most a few pixels): a corner found
    /// on the luminance lands on the centre line of a stroke, or right on a filled edge.
    func climb(_ idx: Int, steps: Int) -> Int {
        var cur = idx
        for _ in 0..<steps {
            let x = cur % width, y = cur / width
            var best = cur
            for yy in max(0, y - 1)...min(height - 1, y + 1) {
                for xx in max(0, x - 1)...min(width - 1, x + 1) where strength[yy * width + xx] > strength[best] * 1.0001 {
                    best = yy * width + xx
                }
            }
            if best == cur { break }
            cur = best
        }
        return cur
    }

    /// (min, max) eigenvalues of the structure tensor averaged over the 5x5 window at (x, y).
    func eigen(_ x: Int, _ y: Int) -> (Float, Float) {
        guard width > 2, height > 2 else { return (0, 0) }
        var sxx: Float = 0, syy: Float = 0, sxy: Float = 0
        for yy in (y - 2)...(y + 2) {
            for xx in (x - 2)...(x + 2) {
                let cx = min(max(xx, 1), width - 2), cy = min(max(yy, 1), height - 2)
                let gx = luminance[cy * width + cx + 1] - luminance[cy * width + cx - 1]
                let gy = luminance[(cy + 1) * width + cx] - luminance[(cy - 1) * width + cx]
                sxx += gx * gx; syy += gy * gy; sxy += gx * gy
            }
        }
        sxx /= 25; syy /= 25; sxy /= 25
        let tr = sxx + syy, det = sxx * syy - sxy * sxy
        let disc = max(0, tr * tr / 4 - det).squareRoot()
        return (tr / 2 - disc, tr / 2 + disc)
    }

    // MARK: Sub-pixel refinement

    /// Bilinear sample of F at continuous pixel coordinates (pixel centres at integers).
    public func sample(_ x: Double, _ y: Double) -> Float {
        let cx = min(max(x, 0), Double(width - 1)), cy = min(max(y, 0), Double(height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = Float(cx - Double(x0)), fy = Float(cy - Double(y0))
        let a = strength[y0 * width + x0], b = strength[y0 * width + x1]
        let c = strength[y1 * width + x0], d = strength[y1 * width + x1]
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    /// Move each point (continuous pixel coordinates) across the path, along the local
    /// normal, onto the ridge of F (a parabola through the best of 5 samples, at most
    /// 1.5 px). Points with `movable[i] == false`, and points with no edge stronger than
    /// `minStrength` near them (a gap the path bridges), stay where they are. The path is closed.
    public func refine(_ pts: [(x: Double, y: Double)], movable: [Bool], minStrength: Float = 0) -> [(x: Double, y: Double)] {
        let n = pts.count
        guard n >= 5 else { return pts }
        var out = pts
        for i in 0..<n where movable[i] {
            let a = pts[(i - 2 + n) % n], b = pts[(i + 2) % n]
            var tx = b.x - a.x, ty = b.y - a.y
            let len = (tx * tx + ty * ty).squareRoot()
            guard len > 1e-9 else { continue }
            tx /= len; ty /= len
            let nx = -ty, ny = tx
            let p = pts[i]
            var s = [Float](repeating: 0, count: 5)
            for k in 0..<5 { s[k] = sample(p.x + Double(k - 2) * nx, p.y + Double(k - 2) * ny) }
            // Only move onto a clear ridge (a peak across the path), never along a cap or a
            // corner where F is flat across the path.
            guard let k = (1...3).max(by: { s[$0] < s[$1] }), s[k] > max(0, minStrength),
                  s[k] > s[k - 1] * 1.02 || s[k] > s[k + 1] * 1.02 else { continue }
            let den = s[k - 1] - 2 * s[k] + s[k + 1]
            var off = Double(k - 2)
            if den < -1e-9 { off += Double(max(-0.5, min(0.5, 0.5 * (s[k - 1] - s[k + 1]) / den))) }
            out[i] = (p.x + off * nx, p.y + off * ny)
        }
        // Two [1 2 1]/4 passes over the movable points: pixel quantisation and the odd
        // one-pixel kink become sub-tolerance; corners are rebuilt by the fitter anyway.
        for _ in 0..<2 {
            let src = out
            for i in 0..<n where movable[i] {
                let a = src[(i - 1 + n) % n], b = src[i], c = src[(i + 1) % n]
                out[i] = ((a.x + 2 * b.x + c.x) / 4, (a.y + 2 * b.y + c.y) / 4)
            }
        }
        return out
    }

    // MARK: Filters

    static func blur121(_ src: [Float], _ w: Int, _ h: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: src.count)
        var out = [Float](repeating: 0, count: src.count)
        src.withUnsafeBufferPointer { S in
            tmp.withUnsafeMutableBufferPointer { T in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        let a = S[row + max(x - 1, 0)], b = S[row + x], c = S[row + min(x + 1, w - 1)]
                        T[row + x] = (a + 2 * b + c) * 0.25
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { T in
            out.withUnsafeMutableBufferPointer { O in
                for y in 0..<h {
                    let up = max(y - 1, 0) * w, row = y * w, dn = min(y + 1, h - 1) * w
                    for x in 0..<w { O[row + x] = (T[up + x] + 2 * T[row + x] + T[dn + x]) * 0.25 }
                }
            }
        }
        return out
    }

    /// Mean over a (2r+1)^2 box, edges clamped, via running sums.
    static func boxMean(_ src: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: src.count)
        var out = [Float](repeating: 0, count: src.count)
        let k = Float(2 * r + 1)
        src.withUnsafeBufferPointer { S in
            tmp.withUnsafeMutableBufferPointer { T in
                for y in 0..<h {
                    let row = y * w
                    var acc: Float = 0
                    for d in -r...r { acc += S[row + min(max(d, 0), w - 1)] }
                    for x in 0..<w {
                        T[row + x] = acc / k
                        acc += S[row + min(x + r + 1, w - 1)] - S[row + max(x - r, 0)]
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { T in
            out.withUnsafeMutableBufferPointer { O in
                for x in 0..<w {
                    var acc: Float = 0
                    for d in -r...r { acc += T[min(max(d, 0), h - 1) * w + x] }
                    for y in 0..<h {
                        O[y * w + x] = acc / k
                        acc += T[min(y + r + 1, h - 1) * w + x] - T[max(y - r, 0) * w + x]
                    }
                }
            }
        }
        return out
    }

    /// (noise floor, scale) of F: the floor is twice the median (most pixels are flat, so
    /// the median is the noise level); the scale is the 99.5th percentile, at least 4x the
    /// floor and at least 0.1.
    static func robustNorm(_ f: [Float]) -> (floor: Float, norm: Float) {
        var hist = [Int](repeating: 0, count: 1024)
        for v in f { hist[min(1023, max(0, Int(v * 800)))] += 1 }
        func percentile(_ q: Double) -> Float {
            let target = Int(Double(f.count) * q)
            var acc = 0
            for (i, c) in hist.enumerated() {
                acc += c
                if acc > target { return Float(i) / 800 }
            }
            return 1023 / 800
        }
        let floor = 2 * percentile(0.5)
        return (floor, max(0.1, 4 * floor, percentile(0.995)))
    }
}
