import Foundation

/// Opcodes of the draw-command stream, from `draw_list.rs`.
enum Op {
  static let save = 1.0, restore = 2.0, transform = 3.0, beginLayer = 4.0, endLayer = 5.0
  static let fillStyle = 6.0, strokeStyle = 7.0, rect = 8.0, ellipse = 9.0, path = 10.0
  static let image = 11.0, beginEffect = 12.0, endEffect = 13.0, beginMatte = 14.0
  static let matteSource = 15.0, endMatte = 16.0, clipBegin = 17.0, clipEnd = 18.0
  static let skipped = 19.0, gradientStyle = 20.0
}

enum ScopeKind {
  case layer, effect, matteContent, matteMask
}

/// One offscreen scope of the stream: a layer, an effect pass, or half of a
/// matte. Built before drawing so every scope is rendered into a texture no
/// larger than what it holds, and so scopes can be drawn depth-first — each
/// render target opened exactly once, which is what a tile-based GPU wants.
final class Scope {
  let kind: ScopeKind
  /// Stream index of the first command inside the scope.
  let start: Int
  /// Stream index of the op that closes the scope.
  var end = 0
  let parent: Scope?
  var children: [Scope] = []
  /// Transform in force when the scope opened; content continues from it.
  let entryMatrix: Affine
  let alpha: Double
  let blend: Int
  /// Device-pixel region the scope's texture covers.
  var rect = PixelRect(x: 0, y: 0, w: 1, h: 1)
  /// Whether anything inside needs the multisampled stencil path.
  var samples = false

  // Effects.
  var effectName = ""
  var values: [String: [Double]] = [:]
  var uniformValues: [Double] = []
  /// Pass bounds in device pixels: origin, size.
  var bounds: [Double] = [0, 0, 0, 0]
  var source: String?
  var matteMode = 0

  var usesBackdrop: Bool { kind == .effect && (effectName == "glass" || effectName == "refraction") }
  /// A backdrop read somewhere inside means this scope's content depends on
  /// what its parent had drawn before it opened.
  var readsBackdrop = false

  init(kind: ScopeKind, start: Int, parent: Scope?, matrix: Affine, alpha: Double, blend: Int) {
    self.kind = kind
    self.start = start
    self.parent = parent
    self.entryMatrix = matrix
    self.alpha = alpha
    self.blend = blend
  }
}

/// Skia's box-window for a Gaussian sigma: `floor(sigma * 3 * sqrt(2π) / 4 + 0.5)`.
func blurWindow(_ sigma: Double) -> Int {
  guard sigma > 0 else { return 0 }
  return Int((sigma * 3 * (2 * Double.pi).squareRoot() / 4 + 0.5).rounded(.down))
}

/// The three box passes Skia runs for one axis, as (window, offset) pairs.
func blurPasses(_ sigma: Double) -> [(Int, Int)] {
  let window = blurWindow(sigma)
  if window <= 1 { return [] }
  if window % 2 == 1 {
    let offset = (window - 1) / 2
    return [(window, offset), (window, offset), (window, offset)]
  }
  let half = window / 2
  return [(window, half), (window, half - 1), (window + 1, half)]
}

private func blurReach(_ sigma: Double) -> Double {
  let window = blurWindow(sigma)
  return window <= 1 ? 0 : (1.5 * Double(window) + 2).rounded(.up)
}

struct ScopeTree {
  /// Top-level scopes in stream order; nested ones hang off `children`.
  let roots: [Scope]
  let rootSamples: Bool
  /// A direct child reads the backdrop, so the root pass has to be split
  /// around it — which means the root's multisampled colour must be stored
  /// rather than kept in tile memory.
  let rootNeedsSplit: Bool

  init(stream: [Double], metadata: PackedFrame.Metadata, scale: SIMD2<Double>, canvas: SIMD2<Int>) {
    var roots: [Scope] = []
    var current: Scope?
    var box = Box()
    var boxStack: [Box] = []
    var samples = false
    var samplesStack: [Bool] = []
    var matrix = Affine.identity
    var saved: [Affine] = []
    var strokeWidth = 0.0
    var strokeMiter = 4.0
    var buildingClip = false
    var effectOrdinal = 0
    var cursor = 0

    func next() -> Double {
      let value = stream[cursor]
      cursor += 1
      return value
    }

    func add(_ x: Double, _ y: Double, pad: Double) {
      let (X, Y) = matrix.apply(x, y)
      box.add(X * scale.x, Y * scale.y, pad: pad)
    }
    func addBox(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, padUnits: Double) {
      if buildingClip { return }
      let pad = padUnits * matrix.scale * max(scale.x, scale.y)
      add(x0, y0, pad: pad); add(x1, y0, pad: pad); add(x0, y1, pad: pad); add(x1, y1, pad: pad)
    }

    func open(_ scope: Scope) {
      if let parent = current { parent.children.append(scope) } else { roots.append(scope) }
      current = scope
      boxStack.append(box)
      samplesStack.append(samples)
      box = Box()
      samples = false
    }

    func close() {
      guard let scope = current else { return }
      scope.end = cursor - 1
      let content = box
      scope.samples = samples
      box = boxStack.removeLast()
      samples = samplesStack.removeLast()

      var minX = content.minX, minY = content.minY, maxX = content.maxX, maxY = content.maxY
      let scalar = { (key: String, fallback: Double) -> Double in scope.values[key]?.first ?? fallback }
      if scope.kind == .effect {
        switch scope.effectName {
        case "blur":
          let radius = max(0, scalar("radius", 8))
          let reachX = blurReach(max(0, scalar("sigmaX", radius)))
          let reachY = blurReach(max(0, scalar("sigmaY", radius)))
          minX -= reachX; maxX += reachX; minY -= reachY; maxY += reachY
        case "depth-blur":
          let reach = blurReach(max(0, scalar("resolvedSigma", 0)))
          minX -= reach; maxX += reach; minY -= reach; maxY += reach
        case "drop-shadow":
          let reach = blurReach(max(0, scalar("blur", 8)))
          let offsetX = scalar("offsetX", 0) * scale.x, offsetY = scalar("offsetY", 4) * scale.y
          minX = min(minX, minX + offsetX) - reach; maxX = max(maxX, maxX + offsetX) + reach
          minY = min(minY, minY + offsetY) - reach; maxY = max(maxY, maxY + offsetY) + reach
        case "color-matrix", "brightness-contrast":
          break
        default:
          // A runtime effect shades its whole pass bounds, so the texture
          // must cover them: the shader clamps reads to the bounds, and a
          // read outside the fitted region would smear the edge texel.
          let b = scope.bounds
          minX = min(minX, b[0]); minY = min(minY, b[1])
          maxX = max(maxX, b[0] + b[2]); maxY = max(maxY, b[1] + b[3])
        }
      }
      if minX < maxX && minY < maxY {
        let x0 = max(0, Int((minX - 2).rounded(.down)))
        let y0 = max(0, Int((minY - 2).rounded(.down)))
        let x1 = min(canvas.x, Int((maxX + 2).rounded(.up)))
        let y1 = min(canvas.y, Int((maxY + 2).rounded(.up)))
        scope.rect = x1 > x0 && y1 > y0 ? PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0) : PixelRect(x: 0, y: 0, w: 1, h: 1)
      }

      if scope.usesBackdrop || scope.readsBackdrop { scope.parent?.readsBackdrop = true }
      current = scope.parent
      if scope.rect.w > 1 || scope.rect.h > 1 {
        box.add(Double(scope.rect.x), Double(scope.rect.y))
        box.add(Double(scope.rect.x + scope.rect.w), Double(scope.rect.y + scope.rect.h))
      }
    }

    while cursor < stream.count {
      let opcode = next()
      switch opcode {
      case Op.save: saved.append(matrix)
      case Op.restore: matrix = saved.popLast() ?? .identity
      case Op.transform:
        let a = next(), b = next(), c = next(), d = next(), e = next(), f = next()
        matrix = matrix * Affine(a: a, b: b, c: c, d: d, e: e, f: f)
      case Op.beginLayer:
        let alpha = next(), blend = Int(next())
        open(Scope(kind: .layer, start: cursor, parent: current, matrix: matrix, alpha: alpha, blend: blend))
      case Op.endLayer, Op.endEffect: close()
      case Op.fillStyle: cursor += 4
      case Op.strokeStyle:
        cursor += 4
        strokeWidth = next()
        cursor += 2
        strokeMiter = next()
        cursor += Int(next())
      case Op.gradientStyle:
        cursor += 6
        cursor += Int(next()) * 5
      case Op.rect:
        let x = next(), y = next(), w = next(), h = next()
        cursor += 1
        let flags = Int(next())
        let stroke = flags & 2 != 0 ? strokeWidth : 0
        addBox(x, y, x + w, y + h, padUnits: 2 / matrix.scale + stroke * 0.5 + 1)
      case Op.ellipse:
        let cx = next(), cy = next(), rx = next(), ry = next()
        let flags = Int(next())
        let stroke = flags & 2 != 0 ? strokeWidth : 0
        addBox(cx - rx, cy - ry, cx + rx, cy + ry, padUnits: 2 / matrix.scale + stroke * 0.5 + 1)
      case Op.path:
        let contourCount = Int(next())
        let flags = Int(next())
        let boldWidth = next()
        if !buildingClip { samples = true }
        let padUnits = (flags & 2 != 0 ? strokeWidth * max(1, strokeMiter) / 2 : 0) + boldWidth / 2 + 1
        let pad = padUnits * matrix.scale * max(scale.x, scale.y)
        for _ in 0..<contourCount {
          let vertexCount = Int(next())
          cursor += 1
          for _ in 0..<vertexCount {
            let x = next(), y = next(), inX = next(), inY = next(), outX = next(), outY = next()
            if buildingClip { continue }
            add(x, y, pad: pad); add(x + inX, y + inY, pad: pad); add(x + outX, y + outY, pad: pad)
          }
        }
      case Op.image:
        // The drawn size needs the decoded image, which the pre-pass does not
        // have; the node's box is the bound for `fill`, `contain` and any
        // crop, and `none`/`cover` may overflow it — those are rare and the
        // overflow is clipped to the fitted texture, never misplaced.
        cursor += 1
        let boxWidth = next(), boxHeight = next()
        cursor += 6
        addBox(-boxWidth / 2, -boxHeight / 2, boxWidth / 2, boxHeight / 2, padUnits: 0)
      case Op.beginEffect:
        let effectIndex = Int(next())
        let count = Int(next())
        let uniformCount = Int(next())
        let left = next(), top = next(), right = next(), bottom = next()
        let names = effectOrdinal < metadata.effectParameterNames.count ? metadata.effectParameterNames[effectOrdinal] : []
        let types = effectOrdinal < metadata.effectParameterTypes.count ? metadata.effectParameterTypes[effectOrdinal] : []
        let implementation = effectOrdinal < metadata.effectImplementations.count ? metadata.effectImplementations[effectOrdinal] : ""
        effectOrdinal += 1
        var values: [String: [Double]] = [:]
        for index in 0..<count {
          let quad = [next(), next(), next(), next()]
          let type = index < types.count ? types[index] : "number"
          let name = index < names.count ? names[index] : "#\(index)"
          values[name] = type == "number" || type == "boolean" ? [quad[0]] : quad
        }
        let uniformValues = (0..<uniformCount).map { _ in next() }
        let scope = Scope(kind: .effect, start: cursor, parent: current, matrix: matrix, alpha: 1, blend: 0)
        scope.values = values
        scope.uniformValues = uniformValues
        scope.effectName = effectIndex < metadata.effects.count ? metadata.effects[effectIndex] : ""
        scope.bounds = [left, top, right - left, bottom - top]
        scope.source = scope.effectName == "custom-sksl" ? implementation : builtinEffectSources[scope.effectName]
        open(scope)
      case Op.beginMatte:
        let mode = Int(next())
        let scope = Scope(kind: .matteContent, start: cursor, parent: current, matrix: matrix, alpha: 1, blend: 0)
        scope.matteMode = mode
        open(scope)
      case Op.matteSource:
        open(Scope(kind: .matteMask, start: cursor, parent: current, matrix: matrix, alpha: 1, blend: 0))
      case Op.endMatte:
        close()
        close()
      case Op.clipBegin: buildingClip = true; samples = true
      case Op.clipEnd: buildingClip = false
      case Op.skipped: cursor += 1
      default:
        // An unknown opcode leaves the cursor unrecoverable; stop reading.
        cursor = stream.count
      }
    }
    while current != nil { close() }
    self.roots = roots
    self.rootSamples = samples
    self.rootNeedsSplit = roots.contains { $0.usesBackdrop }
  }
}
