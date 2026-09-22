import Metal
import simd

extension FrameRenderer {
  /// A filter pass: one full-region draw of `fragment` into a fresh
  /// texture covering `rect` at `1/factor` resolution, sampling `read`.
  private func filterPass(fragment: String, rect: PixelRect, factor: Int, read: Sampled, uniforms: (Source) -> [Float], into texture: MTLTexture) {
    let stencil = backend.acquireTexture(width: texture.width, height: texture.height, format: .stencil8, samples: 1, memoryless: backend.device.supportsFamily(.apple1))
    let target = Target(color: texture, resolve: nil, stencil: stencil, rect: rect, factor: factor)
    let saved = current
    beginPass(target, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
    if let encoder, usePipeline(encoder, fragment: fragment, blend: .none) {
      setStencil(encoder, compare: .always, pass: .keep, reference: 0, readMask: 0, writeMask: 0)
      setVertexUniforms(encoder, matrix: .identity, target: target)
      let values = uniforms(source(read))
      values.withUnsafeBytes { raw in encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0) }
      encoder.setFragmentTexture(read.texture, index: 0)
      drawTriangles(encoder, rectQuad(rect))
    }
    endPass()
    backend.releaseTexture(stencil)
    current = saved
  }

  private func floats(_ source: Source) -> [Float] {
    [source.rect.x, source.rect.y, source.rect.z, source.rect.w, source.texSize.x, source.texSize.y, source.scale.x, source.scale.y]
  }

  /// Blurs a texture, three box passes per axis the way Skia does. Past
  /// `maxDirectBlurSigma` the input is halved first, as many times as it
  /// takes — Skia's GPU blur does the same, so this tracks the CanvasKit
  /// reference more closely than a full-resolution pass would, at a fraction
  /// of the fill. Returns nil when both sigmas round to no blur at all.
  func blurToTexture(_ input: Sampled, sigmaX: Double, sigmaY: Double) -> Sampled? {
    var factor = 1
    while max(sigmaX, sigmaY) / Double(factor) > 4 && factor < 8 { factor *= 2 }
    let passes = blurPasses(sigmaX / Double(factor)).map { ($0.0, $0.1, 0) } + blurPasses(sigmaY / Double(factor)).map { ($0.0, $0.1, 1) }
    if passes.isEmpty { return nil }

    // Every mapping onto the small texture must be integral, or the region
    // origin moving by a pixel a frame lands on a different texel and the
    // blurred layer visibly jitters. The region only grows outward.
    var work = input.rect
    if factor > 1 {
      let x0 = (work.x / factor) * factor
      let y0 = (work.y / factor) * factor
      let x1 = ((work.x + work.w + factor - 1) / factor) * factor
      let y1 = ((work.y + work.h + factor - 1) / factor) * factor
      work = PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    var read = input
    var readIsSpare = false
    var width = work.w, height = work.h
    var level = 1
    // Each halving is one linear fetch per output pixel: an exact 2x2 box.
    var step = factor
    while step > 1 {
      width /= 2
      height /= 2
      level *= 2
      let texture = backend.acquireTexture(width: width, height: height, format: output.pixelFormat)
      filterPass(fragment: "copyFragment", rect: work, factor: level, read: read, uniforms: { self.floats($0) }, into: texture)
      if readIsSpare { backend.releaseTexture(read.texture) }
      read = Sampled(texture: texture, rect: work, factor: level)
      readIsSpare = true
      step /= 2
    }

    var front = backend.acquireTexture(width: width, height: height, format: output.pixelFormat)
    var back: MTLTexture?
    for (window, offset, axis) in passes {
      filterPass(fragment: "boxFragment", rect: work, factor: factor, read: read, uniforms: { source in
        self.floats(source) + [axis == 0 ? 1 : 0, axis == 0 ? 0 : 1, Float(bitPattern: UInt32(window)), Float(bitPattern: UInt32(offset))]
      }, into: front)
      // Ping-pong: the target just written becomes the next pass's source.
      let spare = back ?? (readIsSpare ? read.texture : backend.acquireTexture(width: width, height: height, format: output.pixelFormat))
      back = front
      front = spare
      read = Sampled(texture: back!, rect: work, factor: factor)
      readIsSpare = true
    }
    if front !== back { backend.releaseTexture(front) }
    return Sampled(texture: back!, rect: work, factor: factor)
  }
}
