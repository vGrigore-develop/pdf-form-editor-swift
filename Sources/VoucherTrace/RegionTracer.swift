import Foundation

/// Flood fill, connected components and outer-boundary tracing on a raster mask.
enum RegionTracer {
    struct Fill { var mask: [Bool]; var touchesBorder: Bool }

    /// 4-connected flood fill of pixels whose RGB distance to the seed's 3x3 mean colour
    /// is at most `threshold`.
    static func floodFill(_ r: PageRaster, seed: Int, threshold: Double) -> Fill {
        let w = r.width, h = r.height
        let sx = seed % w, sy = seed / w
        var sum = (0.0, 0.0, 0.0), cnt = 0.0
        for y in max(0, sy - 1)...min(h - 1, sy + 1) {
            for x in max(0, sx - 1)...min(w - 1, sx + 1) {
                let i = 4 * (y * w + x)
                sum.0 += Double(r.rgba[i]); sum.1 += Double(r.rgba[i + 1]); sum.2 += Double(r.rgba[i + 2])
                cnt += 1
            }
        }
        let c = (Float(sum.0 / cnt), Float(sum.1 / cnt), Float(sum.2 / cnt))
        let t2 = Float(threshold * threshold)
        var mask = [Bool](repeating: false, count: w * h)
        var touches = false
        var stack: [Int32] = [Int32(seed)]
        mask[seed] = true
        r.rgba.withUnsafeBufferPointer { px in
            mask.withUnsafeMutableBufferPointer { M in
                func similar(_ i: Int) -> Bool {
                    let dr = Float(px[4 * i]) - c.0, dg = Float(px[4 * i + 1]) - c.1, db = Float(px[4 * i + 2]) - c.2
                    return dr * dr + dg * dg + db * db <= t2
                }
                while let top = stack.popLast() {
                    let u = Int(top)
                    let x = u % w, y = u / w
                    if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touches = true }
                    if x > 0, !M[u - 1], similar(u - 1) { M[u - 1] = true; stack.append(Int32(u - 1)) }
                    if x < w - 1, !M[u + 1], similar(u + 1) { M[u + 1] = true; stack.append(Int32(u + 1)) }
                    if y > 0, !M[u - w], similar(u - w) { M[u - w] = true; stack.append(Int32(u - w)) }
                    if y < h - 1, !M[u + w], similar(u + w) { M[u + w] = true; stack.append(Int32(u + w)) }
                }
            }
        }
        return Fill(mask: mask, touchesBorder: touches)
    }

    /// The largest 4-connected component of `mask`, as its own mask.
    static func largestComponent(_ mask: [Bool], _ w: Int, _ h: Int) -> [Bool]? {
        var label = [Int32](repeating: 0, count: w * h)
        var best: (label: Int32, size: Int)?
        var next: Int32 = 1
        var stack: [Int32] = []
        for s in 0..<(w * h) where mask[s] && label[s] == 0 {
            var size = 0
            label[s] = next
            stack.append(Int32(s))
            while let top = stack.popLast() {
                let u = Int(top)
                size += 1
                let x = u % w, y = u / w
                for v in [x > 0 ? u - 1 : -1, x < w - 1 ? u + 1 : -1, y > 0 ? u - w : -1, y < h - 1 ? u + w : -1] where v >= 0 {
                    if mask[v] && label[v] == 0 { label[v] = next; stack.append(Int32(v)) }
                }
            }
            if best == nil || size > best!.size { best = (next, size) }
            next += 1
        }
        guard let b = best else { return nil }
        return label.map { $0 == b.label }
    }

    /// Outer boundary of the component containing the topmost-leftmost set pixel, traced
    /// along pixel edges (4-connectivity, holes ignored). Returns the midpoints of the
    /// boundary's unit edges in continuous pixel coordinates (pixel centres at integers),
    /// which halves the staircase of diagonal and curved edges.
    static func outerBoundary(_ mask: [Bool], _ w: Int, _ h: Int) -> [(x: Double, y: Double)] {
        guard let first = mask.firstIndex(of: true) else { return [] }
        func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && mask[y * w + x] }
        let dxs = [1, 0, -1, 0], dys = [0, 1, 0, -1] // right, down, left, up (y down)
        let sx = first % w, sy = first / w
        var vx = sx, vy = sy, d = 0
        var corners: [(Int, Int)] = []
        let limit = 4 * (w + 1) * (h + 1)
        repeat {
            corners.append((vx, vy))
            vx += dxs[d]; vy += dys[d]
            // Pixels ahead of the vertex, to the right and left of the direction of travel.
            let fx = dxs[d], fy = dys[d], rx = -fy, ry = fx
            let arX = vx + (fx + rx - 1) / 2, arY = vy + (fy + ry - 1) / 2
            let alX = vx + (fx - rx - 1) / 2, alY = vy + (fy - ry - 1) / 2
            if !inside(arX, arY) {
                d = (d + 1) % 4
            } else if inside(alX, alY) {
                d = (d + 3) % 4
            }
            if corners.count > limit { break }
        } while !(vx == sx && vy == sy && d == 0)
        var out: [(x: Double, y: Double)] = []
        out.reserveCapacity(corners.count)
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            out.append((Double(a.0 + b.0) / 2 - 0.5, Double(a.1 + b.1) / 2 - 0.5))
        }
        return out
    }
}
