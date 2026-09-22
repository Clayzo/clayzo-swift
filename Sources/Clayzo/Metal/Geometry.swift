import Foundation

/// Row-major 2x3 affine, the order the stream carries it in.
struct Affine: Equatable {
  var a: Double = 1, b: Double = 0, c: Double = 0
  var d: Double = 0, e: Double = 1, f: Double = 0

  static let identity = Affine()

  static func * (left: Affine, right: Affine) -> Affine {
    Affine(
      a: left.a * right.a + left.b * right.d,
      b: left.a * right.b + left.b * right.e,
      c: left.a * right.c + left.b * right.f + left.c,
      d: left.d * right.a + left.e * right.d,
      e: left.d * right.b + left.e * right.e,
      f: left.d * right.c + left.e * right.f + left.f)
  }

  func apply(_ x: Double, _ y: Double) -> (Double, Double) {
    (a * x + b * y + c, d * x + e * y + f)
  }

  /// Largest axis stretch, used to keep flattening tolerances in pixels.
  var scale: Double {
    let value = max((a * a + d * d).squareRoot(), (b * b + e * e).squareRoot())
    return value == 0 ? 1 : value
  }
}

struct Box {
  var minX = Double.infinity, minY = Double.infinity
  var maxX = -Double.infinity, maxY = -Double.infinity

  var isEmpty: Bool { !(minX < maxX && minY < maxY) }

  mutating func add(_ x: Double, _ y: Double, pad: Double = 0) {
    if x - pad < minX { minX = x - pad }
    if x + pad > maxX { maxX = x + pad }
    if y - pad < minY { minY = y - pad }
    if y + pad > maxY { maxY = y + pad }
  }

  mutating func add(_ other: Box) {
    if other.minX < minX { minX = other.minX }
    if other.minY < minY { minY = other.minY }
    if other.maxX > maxX { maxX = other.maxX }
    if other.maxY > maxY { maxY = other.maxY }
  }

  func intersects(_ other: Box) -> Bool {
    minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
  }
}

/// Integer device-pixel rectangle.
struct PixelRect: Equatable {
  var x: Int, y: Int, w: Int, h: Int
}

/// Flattens a cubic to line segments. The count follows the control polygon's
/// screen-space length, so tolerance stays in pixels under any transform.
func flattenCubic(
  into out: inout [Float],
  _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
  _ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double, scale: Double
) {
  let polygon = hypot(x1 - x0, y1 - y0) + hypot(x2 - x1, y2 - y1) + hypot(x3 - x2, y3 - y2)
  let steps = max(2, min(64, Int((polygon * scale * 0.6).squareRoot().rounded(.up))))
  for step in 1...steps {
    let t = Double(step) / Double(steps)
    let inverse = 1 - t
    let a = inverse * inverse * inverse
    let b = 3 * inverse * inverse * t
    let c = 3 * inverse * t * t
    let d = t * t * t
    out.append(Float(a * x0 + b * x1 + c * x2 + d * x3))
    out.append(Float(a * y0 + b * y1 + c * y2 + d * y3))
  }
}

/* -------------------------------------------------------------------------- */
/* Stroker — a port of webgl/stroker.ts, triangle for triangle.                */
/* -------------------------------------------------------------------------- */

private func quad(
  _ out: inout [Float],
  _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double,
  _ cx: Double, _ cy: Double, _ dx: Double, _ dy: Double
) {
  out.append(contentsOf: [
    Float(ax), Float(ay), Float(bx), Float(by), Float(cx), Float(cy),
    Float(ax), Float(ay), Float(cx), Float(cy), Float(dx), Float(dy),
  ])
}

/// Triangle fan around a centre, from `from` to `to` radians.
private func fan(_ out: inout [Float], _ cx: Double, _ cy: Double, _ radius: Double, _ from: Double, _ to: Double) {
  let sweep = to - from
  // Enough segments that the flat side of each wedge stays inside a third of
  // a pixel of the true arc at any radius the document uses.
  let steps = max(2, min(64, Int((abs(sweep) / (Double.pi / 16)).rounded(.up)) + 1))
  let step = sweep / Double(steps)
  for i in 0..<steps {
    let a0 = from + step * Double(i)
    let a1 = from + step * Double(i + 1)
    out.append(contentsOf: [
      Float(cx), Float(cy),
      Float(cx + cos(a0) * radius), Float(cy + sin(a0) * radius),
      Float(cx + cos(a1) * radius), Float(cy + sin(a1) * radius),
    ])
  }
}

private func addJoin(
  _ out: inout [Float],
  _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ cx: Double, _ cy: Double,
  half: Double, join: Int, miterLimit: Double
) {
  let inX = bx - ax, inY = by - ay
  let outX = cx - bx, outY = cy - by
  let inLength = hypot(inX, inY), outLength = hypot(outX, outY)
  if inLength < 1e-12 || outLength < 1e-12 { return }
  let ux = inX / inLength, uy = inY / inLength
  let vx = outX / outLength, vy = outY / outLength
  let cross = ux * vy - uy * vx
  if abs(cross) < 1e-9 { return }

  // Outer side is opposite the turn.
  let sign: Double = cross > 0 ? -1 : 1
  let n0x = -uy * half * sign, n0y = ux * half * sign
  let n1x = -vy * half * sign, n1y = vx * half * sign

  if join == 1 {
    let a0 = atan2(n0y, n0x)
    let a1 = atan2(n1y, n1x)
    var delta = a1 - a0
    while delta > .pi { delta -= .pi * 2 }
    while delta < -.pi { delta += .pi * 2 }
    fan(&out, bx, by, half, a0, a0 + delta)
    return
  }

  if join == 0 {
    // Mitre length over half-width is 1/sin(θ/2); Skia falls back to a bevel
    // when that exceeds the limit, so the corner never shoots off to infinity.
    let dot = ux * vx + uy * vy
    let halfAngleSin = max(0, (1 - dot) / 2).squareRoot()
    if halfAngleSin > 1e-6 && 1 / halfAngleSin <= miterLimit {
      var mx = n0x + n1x, my = n0y + n1y
      let mLength = hypot(mx, my)
      if mLength > 1e-9 {
        let scale = (half / halfAngleSin) / mLength
        mx *= scale
        my *= scale
        out.append(contentsOf: [Float(bx), Float(by), Float(bx + n0x), Float(by + n0y), Float(bx + mx), Float(by + my)])
        out.append(contentsOf: [Float(bx), Float(by), Float(bx + mx), Float(by + my), Float(bx + n1x), Float(by + n1y)])
        return
      }
    }
  }
  out.append(contentsOf: [Float(bx), Float(by), Float(bx + n0x), Float(by + n0y), Float(bx + n1x), Float(by + n1y)])
}

/// Cap at `b`, pointing away from `a`.
private func addCap(_ out: inout [Float], _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, half: Double, cap: Int) {
  let dx = bx - ax, dy = by - ay
  let length = hypot(dx, dy)
  if length < 1e-12 { return }
  let ux = dx / length, uy = dy / length
  let nx = -uy * half, ny = ux * half
  if cap == 1 {
    let a0 = atan2(ny, nx)
    fan(&out, bx, by, half, a0, a0 - .pi)
    return
  }
  let ex = ux * half, ey = uy * half
  quad(&out, bx + nx, by + ny, bx + nx + ex, by + ny + ey, bx - nx + ex, by - ny + ey, bx - nx, by - ny)
}

/// Turns a polyline into stroke geometry with real caps and joins. Pieces
/// overlap by construction; the backend draws them through the stencil so
/// each pixel is painted once.
func strokePolyline(
  _ points: [Float], closed: Bool, half: Double, cap: Int, join: Int, miterLimit: Double,
  into out: inout [Float]
) {
  // Drop repeated points: a zero-length segment has no normal, and carrying
  // one through the join maths produces NaN geometry that swallows the draw.
  var p: [Double] = []
  p.reserveCapacity(points.count)
  var i = 0
  while i + 1 < points.count {
    let x = Double(points[i]), y = Double(points[i + 1])
    let n = p.count
    if !(n >= 2 && abs(p[n - 2] - x) < 1e-9 && abs(p[n - 1] - y) < 1e-9) {
      p.append(x)
      p.append(y)
    }
    i += 2
  }
  if closed && p.count >= 4 {
    let n = p.count
    if abs(p[0] - p[n - 2]) < 1e-9 && abs(p[1] - p[n - 1]) < 1e-9 { p.removeLast(2) }
  }
  let count = p.count / 2
  if count < 2 {
    // A degenerate contour still paints a dot under a round or square cap,
    // which is how Skia renders a zero-length subpath.
    if count == 1 && cap != 0 {
      let x = p[0], y = p[1]
      if cap == 1 { fan(&out, x, y, half, 0, .pi * 2) } else { quad(&out, x - half, y - half, x + half, y - half, x + half, y + half, x - half, y + half) }
    }
    return
  }

  let segments = closed ? count : count - 1
  for i in 0..<segments {
    let ax = p[i * 2], ay = p[i * 2 + 1]
    let j = (i + 1) % count
    let bx = p[j * 2], by = p[j * 2 + 1]
    let length = hypot(bx - ax, by - ay)
    if length < 1e-12 { continue }
    let nx = (-(by - ay) / length) * half
    let ny = ((bx - ax) / length) * half
    quad(&out, ax + nx, ay + ny, bx + nx, by + ny, bx - nx, by - ny, ax - nx, ay - ny)
  }

  let joints = closed ? count : count - 2
  if joints > 0 {
    for k in 0..<joints {
      let i = closed ? k : k + 1
      let prev = (i - 1 + count) % count
      let next = (i + 1) % count
      addJoin(&out, p[prev * 2], p[prev * 2 + 1], p[i * 2], p[i * 2 + 1], p[next * 2], p[next * 2 + 1],
              half: half, join: join, miterLimit: miterLimit)
    }
  }

  if !closed && cap != 0 {
    addCap(&out, p[2], p[3], p[0], p[1], half: half, cap: cap)
    let n = count - 1
    addCap(&out, p[(n - 1) * 2], p[(n - 1) * 2 + 1], p[n * 2], p[n * 2 + 1], half: half, cap: cap)
  }
}

/// Splits a polyline into the "on" runs of a dash pattern. Skia doubles an
/// odd-length interval list so the pattern always alternates, and starts at
/// phase zero, which is what the renderer asks for.
func dashPolyline(_ points: [Float], closed: Bool, pattern: [Double]) -> [[Float]] {
  var intervals = pattern.map { max(0, $0) }
  if intervals.count % 2 == 1 { intervals += intervals }
  let total = intervals.reduce(0, +)
  if intervals.count < 2 || total <= 0 { return [points] }

  var path = points
  if closed && path.count >= 4 { path.append(path[0]); path.append(path[1]) }

  var runs: [[Float]] = []
  var index = 0
  var remaining = intervals[0]
  var on = true
  var current: [Float] = [path[0], path[1]]

  var i = 0
  while i + 3 < path.count {
    var ax = Double(path[i]), ay = Double(path[i + 1])
    let bx = Double(path[i + 2]), by = Double(path[i + 3])
    var segment = hypot(bx - ax, by - ay)
    while segment > remaining {
      let t = remaining / segment
      let mx = ax + (bx - ax) * t, my = ay + (by - ay) * t
      if on { current.append(Float(mx)); current.append(Float(my)); runs.append(current); current = [] }
      else { current = [Float(mx), Float(my)] }
      on.toggle()
      ax = mx
      ay = my
      segment -= remaining
      index = (index + 1) % intervals.count
      remaining = intervals[index]
      // A zero-length interval would spin here forever.
      if remaining <= 0 { index = (index + 1) % intervals.count; remaining = intervals[index]; on.toggle() }
    }
    remaining -= segment
    if on { current.append(Float(bx)); current.append(Float(by)) }
    i += 2
  }
  if on && current.count >= 4 { runs.append(current) }
  return runs
}
