import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd

/// What one frame cost, and what it could not draw.
public struct RenderStats: Sendable {
  public var drawCalls = 0
  public var paths = 0
  public var primitives = 0
  public var effectsApplied = 0
  public var passes = 0
  /// Constructs the frame asked for that this backend could not honour, with
  /// how often. Empty means the frame is complete.
  public var unsupported: [String: Int] = [:]
  public init() {}
}

public enum MetalBackendError: Error {
  case noShaderLibrary
  case pipeline(String)
}

/*
 * Stencil budget, shared with the WebGL backend: four low bits carry a path's
 * winding number and the four high bits are one-per-nesting-level clip
 * flags, so a clip inside a clip intersects rather than replaces. Clip bits
 * sit strictly above the winding bits so that one `less` comparison over
 * the combined mask means "inside every clip AND wound non-zero".
 */
private let windingMask: UInt32 = 0x0f
private let fillBits: UInt32 = 0x07
private let boldBit: UInt32 = 0x08
private let clipBits: [UInt32] = [0x10, 0x20, 0x40, 0x80]

/// Past this sigma a blur runs on a downsampled copy of its input, as Skia's
/// GPU blur does.
private let maxDirectBlurSigma = 4.0
/// Pooled textures are rounded up to this so a layer that drifts by a pixel
/// keeps hitting the same pool bucket.
private let granule = 64
private let sampleCount = 4

/// A Metal backend for the engine's draw-command stream.
///
/// The commands the Rust core emits, drawn without Skia. It is the WebGL2
/// backend's design on Apple's GPU, with the parts a tile-based renderer
/// rewards done differently:
///
/// - Scopes (layers, effects, mattes) are found in a pre-pass and rendered
///   depth-first, so each render target is opened exactly once. The root
///   pass never has to be interrupted, which keeps its multisampled colour
///   and stencil in tile memory (`memoryless`) — they never reach DRAM. The
///   one exception is an effect that reads its backdrop, which splits the
///   pass it sits in.
/// - Advanced blend modes read the destination through the tile
///   (`[[color(0)]]`) instead of snapshotting it.
/// - Gradients are evaluated from their stops in the shader; no ramp texture.
///
/// Antialiasing is the WebGL backend's: analytic coverage for rectangles and
/// ellipses, stencil-then-cover on a 4x multisampled target for paths.
public final class MetalBackend {
  public let device: MTLDevice
  let library: MTLLibrary
  private let vertexFunction: MTLFunction
  private var fragments: [String: MTLFunction] = [:]
  private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]
  private var stencilStates: [StencilKey: MTLDepthStencilState] = [:]
  private var effectPipelines: [String: EffectProgram] = [:]
  private var effectErrors: [String: String] = [:]
  private var images: [String: MTLTexture] = [:]
  private var pool: [TextureKey: [MTLTexture]] = [:]
  /// Whether the GPU can read the framebuffer in a fragment shader.
  let tileReads: Bool

  // Vertex data is bump-allocated from a shared buffer per frame; three of
  // them rotate so the CPU never writes into a frame the GPU is reading.
  private var vertexBuffers: [[MTLBuffer]] = [[], [], []]
  private var frameSlot = 0
  private var vertexBuffer: MTLBuffer?
  private var vertexOffset = 0
  private let inFlight = DispatchSemaphore(value: 3)

  public init(device: MTLDevice) throws {
    self.device = device
    // Xcode compiles Shaders.metal into a metallib in the package's resource
    // bundle; a SwiftPM-native build does not, and then the same source is
    // compiled here once (Metal caches the result on disk for later launches).
    if let bundle = Self.resourceBundle, let precompiled = try? device.makeDefaultLibrary(bundle: bundle) {
      library = precompiled
    } else {
      library = try device.makeLibrary(source: shaderSource, options: nil)
    }
    guard let vertex = library.makeFunction(name: "shapeVertex") else { throw MetalBackendError.noShaderLibrary }
    vertexFunction = vertex
    tileReads = device.supportsFamily(.apple1)
    Layout.check()
  }

  /// The package's resource bundle, where Xcode puts the compiled metallib.
  /// Looked up by name rather than through `Bundle.module`, which SwiftPM only
  /// generates when it recognises a resource — and it does not recognise .metal.
  private static var resourceBundle: Bundle? {
    let name = "Clayzo_Clayzo.bundle"
    let candidates = [
      Bundle.main.resourceURL,
      Bundle(for: MetalBackend.self).resourceURL,
      Bundle.main.bundleURL,
      Bundle(for: MetalBackend.self).bundleURL.deletingLastPathComponent(),
    ]
    for url in candidates.compactMap({ $0?.appendingPathComponent(name) }) {
      if let bundle = Bundle(url: url) { return bundle }
    }
    return nil
  }

  /* ---------------------------------------------------------------------- */
  /* Images                                                                  */
  /* ---------------------------------------------------------------------- */

  /// Decodes an image to premultiplied RGBA in its own colour space — no
  /// profile conversion, which is what Skia does and what the reference
  /// renderer's pixels therefore contain.
  @discardableResult
  public func setImage(_ id: String, data: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return false }
    let width = image.width, height = image.height
    guard width > 0, height > 0 else { return false }
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
      guard let context = CGContext(
        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return false }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = .shaderRead
    #if os(macOS)
    descriptor.storageMode = .managed
    #else
    descriptor.storageMode = .shared
    #endif
    guard let texture = device.makeTexture(descriptor: descriptor) else { return false }
    pixels.withUnsafeBytes { raw in
      texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width * 4)
    }
    images[id] = texture
    return true
  }

  public func setImage(_ id: String, texture: MTLTexture) { images[id] = texture }
  public func removeImage(_ id: String) { images[id] = nil }

  /* ---------------------------------------------------------------------- */
  /* Pipelines and stencil states                                            */
  /* ---------------------------------------------------------------------- */

  enum Blend {
    /// Premultiplied source-over; everything is written premultiplied.
    case over
    /// Skia's Plus: ONE/ONE on premultiplied colour.
    case add
    case dstIn
    case dstOut
    /// The shader produced the final composite (it read the destination).
    case none
  }

  struct PipelineKey: Hashable {
    let fragment: String
    let blend: Blend
    let writeColor: Bool
    let samples: Int
    let format: MTLPixelFormat
  }

  struct StencilKey: Hashable {
    let compare: MTLCompareFunction
    let pass: MTLStencilOperation
    let readMask: UInt32
    let writeMask: UInt32
  }

  private func fragment(_ name: String) -> MTLFunction? {
    if let function = fragments[name] { return function }
    let function = library.makeFunction(name: name)
    fragments[name] = function
    return function
  }

  func pipeline(fragment name: String, function: MTLFunction? = nil, blend: Blend, writeColor: Bool = true, samples: Int, format: MTLPixelFormat) -> MTLRenderPipelineState? {
    let key = PipelineKey(fragment: name, blend: blend, writeColor: writeColor, samples: samples, format: format)
    if let state = pipelines[key] { return state }
    guard let fragmentFunction = function ?? fragment(name) else { return nil }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertexFunction
    descriptor.fragmentFunction = fragmentFunction
    descriptor.rasterSampleCount = samples
    descriptor.stencilAttachmentPixelFormat = .stencil8
    let color = descriptor.colorAttachments[0]!
    color.pixelFormat = format
    color.writeMask = writeColor ? .all : []
    color.isBlendingEnabled = blend != .none
    color.rgbBlendOperation = .add
    color.alphaBlendOperation = .add
    switch blend {
    case .over, .none:
      color.sourceRGBBlendFactor = .one; color.sourceAlphaBlendFactor = .one
      color.destinationRGBBlendFactor = .oneMinusSourceAlpha; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    case .add:
      color.sourceRGBBlendFactor = .one; color.sourceAlphaBlendFactor = .one
      color.destinationRGBBlendFactor = .one; color.destinationAlphaBlendFactor = .one
    case .dstIn:
      color.sourceRGBBlendFactor = .zero; color.sourceAlphaBlendFactor = .zero
      color.destinationRGBBlendFactor = .sourceAlpha; color.destinationAlphaBlendFactor = .sourceAlpha
    case .dstOut:
      color.sourceRGBBlendFactor = .zero; color.sourceAlphaBlendFactor = .zero
      color.destinationRGBBlendFactor = .oneMinusSourceAlpha; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
    guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
    pipelines[key] = state
    return state
  }

  func stencilState(compare: MTLCompareFunction, pass: MTLStencilOperation, readMask: UInt32, writeMask: UInt32) -> MTLDepthStencilState {
    let key = StencilKey(compare: compare, pass: pass, readMask: readMask, writeMask: writeMask)
    if let state = stencilStates[key] { return state }
    let stencil = MTLStencilDescriptor()
    stencil.stencilCompareFunction = compare
    stencil.stencilFailureOperation = .keep
    stencil.depthFailureOperation = .keep
    stencil.depthStencilPassOperation = pass
    stencil.readMask = readMask
    stencil.writeMask = writeMask
    let descriptor = MTLDepthStencilDescriptor()
    descriptor.frontFaceStencil = stencil
    descriptor.backFaceStencil = stencil
    descriptor.isDepthWriteEnabled = false
    descriptor.depthCompareFunction = .always
    let state = device.makeDepthStencilState(descriptor: descriptor)!
    stencilStates[key] = state
    return state
  }

  /// A runtime effect compiled from its (translated) SkSL source.
  struct EffectProgram {
    let function: MTLFunction
    let shader: TranslatedShader
  }

  func effectProgram(_ source: String) -> EffectProgram? {
    if let program = effectPipelines[source] { return program }
    if effectErrors[source] != nil { return nil }
    do {
      let translated = try translateSkSL(source)
      let options = MTLCompileOptions()
      // The reference rasterizes in IEEE float; fast math would let the
      // compiler reassociate its way to a visibly different dither.
      if #available(iOS 18, macOS 15, *) { options.mathMode = .safe } else { options.fastMathEnabled = false }
      let library = try device.makeLibrary(source: translated.source, options: options)
      guard let function = library.makeFunction(name: "effectFragment") else { throw MetalBackendError.pipeline("no effectFragment") }
      let program = EffectProgram(function: function, shader: translated)
      effectPipelines[source] = program
      return program
    } catch {
      effectErrors[source] = "\(error)"
      return nil
    }
  }

  /* ---------------------------------------------------------------------- */
  /* Textures                                                                */
  /* ---------------------------------------------------------------------- */

  struct TextureKey: Hashable {
    let width: Int, height: Int
    let format: MTLPixelFormat
    let samples: Int
    let memoryless: Bool
  }

  private func roundUp(_ value: Int) -> Int { max(granule, ((value + granule - 1) / granule) * granule) }

  func acquireTexture(width: Int, height: Int, format: MTLPixelFormat, samples: Int = 1, memoryless: Bool = false, exact: Bool = false) -> MTLTexture {
    let key = TextureKey(width: exact ? width : roundUp(width), height: exact ? height : roundUp(height), format: format, samples: samples, memoryless: memoryless)
    if var free = pool[key], let texture = free.popLast() {
      pool[key] = free
      return texture
    }
    let descriptor = MTLTextureDescriptor()
    descriptor.textureType = samples > 1 ? .type2DMultisample : .type2D
    descriptor.pixelFormat = format
    descriptor.width = key.width
    descriptor.height = key.height
    descriptor.sampleCount = samples
    descriptor.storageMode = memoryless ? .memoryless : .private
    descriptor.usage = samples > 1 || memoryless ? .renderTarget : [.renderTarget, .shaderRead]
    return device.makeTexture(descriptor: descriptor)!
  }

  func releaseTexture(_ texture: MTLTexture) {
    let key = TextureKey(width: texture.width, height: texture.height, format: texture.pixelFormat, samples: texture.sampleCount, memoryless: texture.storageMode == .memoryless)
    pool[key, default: []].append(texture)
  }

  /* ---------------------------------------------------------------------- */
  /* Vertex data                                                             */
  /* ---------------------------------------------------------------------- */

  private func beginFrameBuffers() {
    inFlight.wait()
    frameSlot = (frameSlot + 1) % vertexBuffers.count
    vertexBuffer = vertexBuffers[frameSlot].first
    vertexOffset = 0
  }

  /// Copies `vertices` into the frame's buffer and returns where.
  func upload(_ vertices: [Float]) -> (MTLBuffer, Int)? {
    let bytes = vertices.count * MemoryLayout<Float>.stride
    if bytes == 0 { return nil }
    if vertexBuffer == nil || vertexOffset + bytes > vertexBuffer!.length {
      // Find a buffer in this slot with room, or make a bigger one.
      var buffers = vertexBuffers[frameSlot]
      if let found = buffers.first(where: { $0 !== vertexBuffer && $0.length >= bytes }) {
        vertexBuffer = found
      } else {
        let length = max(bytes, 256 * 1024)
        guard let made = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        buffers.append(made)
        vertexBuffers[frameSlot] = buffers
        vertexBuffer = made
      }
      vertexOffset = 0
    }
    let buffer = vertexBuffer!
    vertices.withUnsafeBytes { raw in
      buffer.contents().advanced(by: vertexOffset).copyMemory(from: raw.baseAddress!, byteCount: bytes)
    }
    let offset = vertexOffset
    // Keep every allocation 256-byte aligned; it is the strictest requirement any target has.
    vertexOffset += (bytes + 255) & ~255
    return (buffer, offset)
  }

  /* ---------------------------------------------------------------------- */
  /* Frame                                                                   */
  /* ---------------------------------------------------------------------- */

  /// Renders a frame into `target`, a non-multisampled colour texture (a
  /// drawable, or an offscreen texture with `.shaderRead` for readback). The
  /// frame is scaled to fill it; the aspect ratio is the caller's business.
  @discardableResult
  public func render(_ frame: PackedFrame, into target: MTLTexture, commandBuffer: MTLCommandBuffer) -> RenderStats {
    beginFrameBuffers()
    commandBuffer.addCompletedHandler { [inFlight] _ in inFlight.signal() }
    let renderer = FrameRenderer(backend: self, frame: frame, output: target, commandBuffer: commandBuffer, images: images)
    renderer.run()
    return renderer.stats
  }
}

/* -------------------------------------------------------------------------- */
/* One frame                                                                   */
/* -------------------------------------------------------------------------- */

/// A render target: the texture drawn into, the texture sampled afterwards,
/// and the device region they cover.
struct Target {
  let color: MTLTexture
  let resolve: MTLTexture?
  let stencil: MTLTexture
  let rect: PixelRect
  /// Resolution divisor: a downsampled blur level covers `rect` at `1/factor`.
  var factor = 1
  /// The result as later passes read it.
  var result: MTLTexture { resolve ?? color }
  var samples: Int { color.sampleCount }
}

/// A finished texture and the device region it holds, possibly downsampled.
struct Sampled {
  let texture: MTLTexture
  let rect: PixelRect
  let factor: Int
}

final class FrameRenderer {
  let backend: MetalBackend
  let frame: PackedFrame
  let stream: [Double]
  let output: MTLTexture
  let commandBuffer: MTLCommandBuffer
  let images: [String: MTLTexture]
  let scale: SIMD2<Double>
  let canvas: SIMD2<Int>
  let tree: ScopeTree
  var stats = RenderStats()

  // State of the pass being encoded.
  var encoder: MTLRenderCommandEncoder?
  var current: Target!
  var matrix = Affine.identity
  var clipMask: UInt32 = 0
  var clipDepth = 0
  var buildingClip = false
  var buildingClipBit: UInt32 = 0
  var scopeStack: [(Affine, UInt32, Int)] = []

  var fillColor = SIMD4<Float>(0, 0, 0, 1)
  var strokeColor: SIMD4<Float>?
  var strokeWidth = 0.0
  var strokeCap = 0
  var strokeJoin = 0
  var strokeMiterLimit = 4.0
  var strokeDash: [Double] = []
  var paint = Paint()
  var paintMode: Int32 = 0

  /// Per-scope outputs, keyed by object identity.
  var outputs: [ObjectIdentifier: Sampled] = [:]
  var backdrops: [ObjectIdentifier: Sampled] = [:]

  init(backend: MetalBackend, frame: PackedFrame, output: MTLTexture, commandBuffer: MTLCommandBuffer, images: [String: MTLTexture]) {
    self.backend = backend
    self.frame = frame
    self.stream = frame.stream
    self.output = output
    self.commandBuffer = commandBuffer
    self.images = images
    canvas = SIMD2(output.width, output.height)
    scale = SIMD2(Double(output.width) / max(frame.width, 1e-9), Double(output.height) / max(frame.height, 1e-9))
    tree = ScopeTree(stream: frame.stream, metadata: frame.metadata, scale: scale, canvas: canvas)
  }

  func note(_ what: String) { stats.unsupported[what, default: 0] += 1 }

  func run() {
    // The root keeps its samples in tile memory unless a backdrop effect
    // forces the pass to be split, which needs the samples stored between
    // the two halves.
    let rootRect = PixelRect(x: 0, y: 0, w: canvas.x, h: canvas.y)
    let root = makeTarget(rect: rootRect, samples: sampleCount, resolveInto: output, storable: tree.rootNeedsSplit)
    current = root
    if ProcessInfo.processInfo.environment["CLAYZO_DEBUG"] != nil {
      func describe(_ scope: Scope, _ depth: Int) {
        print(String(repeating: "  ", count: depth + 1), scope.kind, scope.effectName, "range", scope.start, scope.end, "rect", scope.rect, "samples", scope.samples, "alpha", scope.alpha, "blend", scope.blend, "matte", scope.matteMode)
        for child in scope.children { describe(child, depth + 1) }
      }
      print("  stream", stream.count, "words; roots", tree.roots.count)
      for scope in tree.roots { describe(scope, 0) }
    }
    for scope in tree.roots where !scope.usesBackdrop { prepare(scope) }
    let background = frame.background
    beginPass(root, clear: MTLClearColor(red: background.x * background.w, green: background.y * background.w, blue: background.z * background.w, alpha: background.w), storable: tree.rootNeedsSplit)
    interpret(from: 0, to: stream.count, children: tree.roots)
    endPass()
    releaseTarget(root, keepResult: true)
    for sampled in outputs.values { backend.releaseTexture(sampled.texture) }
    for sampled in backdrops.values { backend.releaseTexture(sampled.texture) }
  }

  /* -------------------- targets and passes -------------------- */

  func makeTarget(rect: PixelRect, samples: Int, resolveInto: MTLTexture? = nil, storable: Bool = false) -> Target {
    let format = output.pixelFormat
    // Memoryless attachments live only in tile memory; a target that has to
    // survive a pass split is stored to DRAM instead.
    let memoryless = !storable && backend.device.supportsFamily(.apple1)
    if samples > 1 {
      let color = backend.acquireTexture(width: rect.w, height: rect.h, format: format, samples: samples, memoryless: memoryless, exact: resolveInto != nil)
      let stencil = backend.acquireTexture(width: rect.w, height: rect.h, format: .stencil8, samples: samples, memoryless: memoryless, exact: resolveInto != nil)
      let resolve = resolveInto ?? backend.acquireTexture(width: rect.w, height: rect.h, format: format)
      return Target(color: color, resolve: resolve, stencil: stencil, rect: rect)
    }
    let color = resolveInto ?? backend.acquireTexture(width: rect.w, height: rect.h, format: format)
    let stencil = backend.acquireTexture(width: rect.w, height: rect.h, format: .stencil8, samples: 1, memoryless: memoryless, exact: resolveInto != nil)
    return Target(color: color, resolve: nil, stencil: stencil, rect: rect)
  }

  func releaseTarget(_ target: Target, keepResult: Bool) {
    if target.resolve != nil || !keepResult { backend.releaseTexture(target.color) }
    backend.releaseTexture(target.stencil)
    if !keepResult, let resolve = target.resolve, resolve !== output { backend.releaseTexture(resolve) }
  }

  func beginPass(_ target: Target, clear: MTLClearColor? = nil, storable: Bool = false) {
    let descriptor = MTLRenderPassDescriptor()
    let color = descriptor.colorAttachments[0]!
    color.texture = target.color
    color.loadAction = clear == nil ? .load : .clear
    color.clearColor = clear ?? MTLClearColor()
    if let resolve = target.resolve {
      color.resolveTexture = resolve
      color.storeAction = storable ? .storeAndMultisampleResolve : .multisampleResolve
    } else {
      color.storeAction = .store
    }
    descriptor.stencilAttachment.texture = target.stencil
    descriptor.stencilAttachment.loadAction = clear == nil && storable ? .load : .clear
    descriptor.stencilAttachment.clearStencil = 0
    descriptor.stencilAttachment.storeAction = storable ? .store : .dontCare
    encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
    encoder?.setCullMode(.none)
    // The region occupies the texture's top-left corner; the rest of a pooled
    // texture is cleared with it, so a blur tap past the region's edge reads
    // transparent rather than whatever was there last frame.
    encoder?.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(target.rect.w / target.factor), height: Double(target.rect.h / target.factor), znear: 0, zfar: 1))
    current = target
    stats.passes += 1
  }

  func endPass() {
    encoder?.endEncoding()
    encoder = nil
  }

  /* -------------------- draw plumbing -------------------- */

  func setVertexUniforms(_ encoder: MTLRenderCommandEncoder, matrix m: Affine, target: Target) {
    let factor = target.factor
    var uniforms = VertexUniforms(
      linear: simd_float2x2(SIMD2(Float(m.a), Float(m.d)), SIMD2(Float(m.b), Float(m.e))),
      translate: SIMD2(Float(m.c), Float(m.f)),
      scale: SIMD2(Float(scale.x / Double(factor)), Float(scale.y / Double(factor))),
      target: SIMD4(Float(target.rect.x) / Float(factor), Float(target.rect.y) / Float(factor), Float(target.rect.w) / Float(factor), Float(target.rect.h) / Float(factor)))
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<VertexUniforms>.stride, index: 1)
  }

  func drawTriangles(_ encoder: MTLRenderCommandEncoder, _ vertices: [Float]) {
    guard let (buffer, offset) = backend.upload(vertices) else { return }
    encoder.setVertexBuffer(buffer, offset: offset, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 2)
    stats.drawCalls += 1
  }

  func usePipeline(_ encoder: MTLRenderCommandEncoder, fragment: String, function: MTLFunction? = nil, blend: MetalBackend.Blend, writeColor: Bool = true) -> Bool {
    guard let state = backend.pipeline(fragment: fragment, function: function, blend: blend, writeColor: writeColor, samples: current.samples, format: current.color.pixelFormat) else {
      note("pipeline:\(fragment)")
      return false
    }
    encoder.setRenderPipelineState(state)
    return true
  }

  func setStencil(_ encoder: MTLRenderCommandEncoder, compare: MTLCompareFunction, pass: MTLStencilOperation, reference: UInt32, readMask: UInt32, writeMask: UInt32) {
    encoder.setDepthStencilState(backend.stencilState(compare: compare, pass: pass, readMask: readMask, writeMask: writeMask))
    encoder.setStencilReferenceValue(reference)
  }

  /// Stencil state for an ordinary colour draw under the current state.
  func applyDrawStencil(_ encoder: MTLRenderCommandEncoder) {
    if buildingClip && buildingClipBit != 0 {
      // Write this clip's bit, but only where every enclosing clip already
      // passes — that intersection is the whole point of the nesting.
      setStencil(encoder, compare: .equal, pass: .replace, reference: clipMask | buildingClipBit, readMask: clipMask, writeMask: buildingClipBit)
    } else if clipMask != 0 {
      setStencil(encoder, compare: .equal, pass: .keep, reference: clipMask, readMask: clipMask, writeMask: 0)
    } else {
      setStencil(encoder, compare: .always, pass: .keep, reference: 0, readMask: 0, writeMask: 0)
    }
  }

  /// A rect's two triangles in composition units.
  func rectQuad(_ rect: PixelRect) -> [Float] {
    let left = Float(Double(rect.x) / scale.x), top = Float(Double(rect.y) / scale.y)
    let right = left + Float(Double(rect.w) / scale.x), bottom = top + Float(Double(rect.h) / scale.y)
    return [left, top, right, top, left, bottom, right, top, right, bottom, left, bottom]
  }

  func source(_ sampled: Sampled) -> Source {
    let f = Float(sampled.factor)
    return Source(
      rect: SIMD4(Float(sampled.rect.x) / f, Float(sampled.rect.y) / f, Float(sampled.rect.w) / f, Float(sampled.rect.h) / f),
      texSize: SIMD2(Float(sampled.texture.width), Float(sampled.texture.height)),
      scale: SIMD2(Float(scale.x) / f, Float(scale.y) / f))
  }

  func currentPaint(color: SIMD4<Float>, opacity: Float = 1) -> Paint {
    var p = paint
    p.color = color
    p.paint = paintMode
    p.opacity = opacity
    return p
  }

  /* -------------------- primitives -------------------- */

  func drawAnalytic(_ encoder: MTLRenderCommandEncoder, shape: Int32, cx: Double, cy: Double, hx: Double, hy: Double, radius: Double, color: SIMD4<Float>, stroke: Double = 0) {
    applyDrawStencil(encoder)
    // A clip on a multisampled target spends the coverage on the sample mask.
    let fragment = buildingClip && current.samples > 1 ? "shapeMaskFragment" : "shapeFragment"
    guard usePipeline(encoder, fragment: fragment, blend: .over, writeColor: !buildingClip) else { return }
    setVertexUniforms(encoder, matrix: matrix, target: current)
    var p = currentPaint(color: color)
    p.shape = shape
    p.box = SIMD4(Float(cx), Float(cy), Float(hx), Float(hy))
    p.radius = Float(min(radius, min(hx, hy)))
    p.stroke = Float(stroke)
    if buildingClip { p.paint = 0 }
    encoder.setFragmentBytes(&p, length: MemoryLayout<Paint>.stride, index: 0)
    // Room for the coverage ramp plus half the stroke.
    let margin = 2 / matrix.scale + stroke * 0.5 + 1
    let l = Float(cx - hx - margin), t = Float(cy - hy - margin), r = Float(cx + hx + margin), b = Float(cy + hy + margin)
    drawTriangles(encoder, [l, t, r, t, l, b, r, t, r, b, l, b])
    stats.primitives += 1
  }

  /// Winding fans for a set of contours, inverting the low stencil bits.
  func windContours(_ encoder: MTLRenderCommandEncoder, _ contours: [[Float]]) -> Box? {
    var box = Box()
    var fan: [Float] = []
    for contour in contours {
      var index = 0
      while index + 1 < contour.count {
        box.add(Double(contour[index]), Double(contour[index + 1]))
        index += 2
      }
      if contour.count < 6 { continue }
      var i = 2
      while i + 3 < contour.count {
        fan.append(contentsOf: [contour[0], contour[1], contour[i], contour[i + 1], contour[i + 2], contour[i + 3]])
        i += 2
      }
    }
    guard box.minX.isFinite else { return nil }
    guard usePipeline(encoder, fragment: "solidFragment", blend: .over, writeColor: false) else { return nil }
    setVertexUniforms(encoder, matrix: matrix, target: current)
    var p = Paint()
    encoder.setFragmentBytes(&p, length: MemoryLayout<Paint>.stride, index: 0)
    if !fan.isEmpty { drawTriangles(encoder, fan) }
    return box
  }

  func coverQuad(_ box: Box) -> [Float] {
    let l = Float(box.minX), t = Float(box.minY), r = Float(box.maxX), b = Float(box.maxY)
    return [l, t, r, t, l, b, r, t, r, b, l, b]
  }

  /// Winding into the low bits, cover where non-zero — and, when a clip is
  /// active, only where every clip bit is set too.
  func stencilThenCover(_ encoder: MTLRenderCommandEncoder, contours: [[Float]], color: SIMD4<Float>, boldWidth: Double, closed: [Bool]) {
    if clipMask != 0 { setStencil(encoder, compare: .equal, pass: .invert, reference: clipMask, readMask: clipMask, writeMask: fillBits) }
    else { setStencil(encoder, compare: .always, pass: .invert, reference: 0, readMask: fillBits, writeMask: fillBits) }
    var bounds = windContours(encoder, contours)

    if boldWidth > 0 {
      // Skia's synthetic bold strokes the outline and fills the union, so the
      // stroke is marked into the same nibble rather than painted.
      var triangles: [Float] = []
      for (index, contour) in contours.enumerated() {
        strokePolyline(contour, closed: index < closed.count ? closed[index] : true, half: boldWidth / 2, cap: 0, join: 0, miterLimit: 4, into: &triangles)
      }
      if !triangles.isEmpty {
        if clipMask != 0 { setStencil(encoder, compare: .equal, pass: .replace, reference: clipMask | boldBit, readMask: clipMask, writeMask: boldBit) }
        else { setStencil(encoder, compare: .always, pass: .replace, reference: boldBit, readMask: boldBit, writeMask: boldBit) }
        drawTriangles(encoder, triangles)
        var i = 0
        while i + 1 < triangles.count {
          if bounds != nil { bounds!.add(Double(triangles[i]), Double(triangles[i + 1])) }
          i += 2
        }
      }
    }
    guard let box = bounds else { return }

    if clipMask != 0 { setStencil(encoder, compare: .less, pass: .zero, reference: clipMask, readMask: clipMask | windingMask, writeMask: windingMask) }
    else { setStencil(encoder, compare: .notEqual, pass: .zero, reference: 0, readMask: windingMask, writeMask: windingMask) }
    guard usePipeline(encoder, fragment: "solidFragment", blend: .over) else { return }
    var p = currentPaint(color: color)
    encoder.setFragmentBytes(&p, length: MemoryLayout<Paint>.stride, index: 0)
    drawTriangles(encoder, coverQuad(box))
    stats.paths += 1
  }

  /// Strokes a set of contours through the stencil, so a translucent stroke
  /// is painted once however many pieces overlap.
  func strokeContours(_ encoder: MTLRenderCommandEncoder, contours: [[Float]], closed: [Bool], color: SIMD4<Float>) {
    let half = strokeWidth / 2
    var triangles: [Float] = []
    for (index, contour) in contours.enumerated() {
      let isClosed = index < closed.count ? closed[index] : false
      let runs = strokeDash.count >= 2 ? dashPolyline(contour, closed: isClosed, pattern: strokeDash) : [contour]
      let runsAreClosed = strokeDash.count >= 2 ? false : isClosed
      for run in runs {
        strokePolyline(run, closed: runsAreClosed, half: half, cap: strokeCap, join: strokeJoin, miterLimit: strokeMiterLimit, into: &triangles)
      }
    }
    if triangles.isEmpty { return }
    var box = Box()
    var i = 0
    while i + 1 < triangles.count {
      box.add(Double(triangles[i]), Double(triangles[i + 1]))
      i += 2
    }

    // REPLACE, not INVERT: overlapping pieces must union.
    if clipMask != 0 { setStencil(encoder, compare: .equal, pass: .replace, reference: clipMask | 1, readMask: clipMask, writeMask: windingMask) }
    else { setStencil(encoder, compare: .always, pass: .replace, reference: 1, readMask: windingMask, writeMask: windingMask) }
    guard usePipeline(encoder, fragment: "solidFragment", blend: .over, writeColor: false) else { return }
    setVertexUniforms(encoder, matrix: matrix, target: current)
    var blank = Paint()
    encoder.setFragmentBytes(&blank, length: MemoryLayout<Paint>.stride, index: 0)
    drawTriangles(encoder, triangles)

    if clipMask != 0 { setStencil(encoder, compare: .less, pass: .zero, reference: clipMask, readMask: clipMask | windingMask, writeMask: windingMask) }
    else { setStencil(encoder, compare: .notEqual, pass: .zero, reference: 0, readMask: windingMask, writeMask: windingMask) }
    guard usePipeline(encoder, fragment: "solidFragment", blend: .over) else { return }
    var p = currentPaint(color: color)
    p.paint = 0
    encoder.setFragmentBytes(&p, length: MemoryLayout<Paint>.stride, index: 0)
    box.minX -= 1; box.minY -= 1; box.maxX += 1; box.maxY += 1
    drawTriangles(encoder, coverQuad(box))
    stats.paths += 1
  }

  /* -------------------- composites -------------------- */

  /// Composites a finished texture onto the current target.
  func compositePlain(_ encoder: MTLRenderCommandEncoder, _ sampled: Sampled, alpha: Float, blend: Int) {
    applyDrawStencil(encoder)
    let additive = blend == 7
    let needsDst = blend != 0 && !additive
    let fragment: String
    let mode: MetalBackend.Blend
    if needsDst && backend.tileReads {
      fragment = "layerBlendFragment"
      mode = .none
    } else {
      if needsDst { note("blend-mode:\(blend)") }
      fragment = "layerFragment"
      mode = additive ? .add : .over
    }
    guard usePipeline(encoder, fragment: fragment, blend: mode) else { return }
    setVertexUniforms(encoder, matrix: .identity, target: current)
    var uniforms = LayerUniforms(layer: source(sampled), alpha: alpha, blend: Int32(blend))
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
    encoder.setFragmentTexture(sampled.texture, index: 0)
    drawTriangles(encoder, rectQuad(sampled.rect))
  }

  /* -------------------- scopes -------------------- */

  /// Renders a scope into its own texture, children first, and leaves the
  /// result (blurred, for the blur family) in `outputs` for its parent to
  /// composite. Backdrop effects are prepared from inside the parent's pass
  /// instead, once the backdrop exists.
  func prepare(_ scope: Scope) {
    for child in scope.children where !child.usesBackdrop { prepare(child) }
    let target = makeTarget(rect: scope.rect, samples: scope.samples ? sampleCount : 1, storable: scope.children.contains { $0.usesBackdrop })

    // Save the parent's interpreter state; a scope starts from its own.
    let saved = (encoder, current, matrix, clipMask, clipDepth, scopeStack)
    current = target
    matrix = scope.entryMatrix
    clipMask = 0
    clipDepth = 0
    scopeStack = []
    beginPass(target, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0), storable: scope.children.contains { $0.usesBackdrop })
    interpret(from: scope.start, to: scope.end, children: scope.children)
    endPass()
    (encoder, current, matrix, clipMask, clipDepth, scopeStack) = saved

    var result = Sampled(texture: target.result, rect: scope.rect, factor: 1)
    releaseTarget(target, keepResult: true)
    if scope.kind == .effect {
      let scalar = { (key: String, fallback: Double) -> Double in scope.values[key]?.first ?? fallback }
      switch scope.effectName {
      case "blur", "depth-blur":
        var sigmaX = 0.0, sigmaY = 0.0
        if scope.effectName == "blur" {
          let radius = max(0, scalar("radius", 8))
          sigmaX = max(0, scalar("sigmaX", radius))
          sigmaY = max(0, scalar("sigmaY", radius))
        } else {
          sigmaX = max(0, scalar("resolvedSigma", 0))
          sigmaY = sigmaX
        }
        if let blurred = blurToTexture(result, sigmaX: sigmaX, sigmaY: sigmaY) {
          backend.releaseTexture(result.texture)
          result = blurred
        }
      case "drop-shadow":
        let sigma = max(0, scalar("blur", 8))
        // The shadow needs both the blurred silhouette and the untouched source.
        if let blurred = blurToTexture(result, sigmaX: sigma, sigmaY: sigma) {
          backdrops[ObjectIdentifier(scope)] = blurred
        }
      default: break
      }
    }
    outputs[ObjectIdentifier(scope)] = result
  }

  /// Draws a finished child into the current pass.
  func composite(_ scope: Scope, _ encoder: MTLRenderCommandEncoder) {
    guard let result = outputs[ObjectIdentifier(scope)] else { return }
    let scalar = { (key: String, fallback: Double) -> Double in scope.values[key]?.first ?? fallback }
    switch scope.kind {
    case .layer, .matteContent:
      compositePlain(encoder, result, alpha: Float(scope.alpha), blend: scope.blend)
    case .matteMask:
      // The current target is the content layer. ZERO/SRC_ALPHA is DstIn and
      // ZERO/ONE_MINUS_SRC_ALPHA is DstOut; the blend unit computes the
      // whole thing. Luma modes take the renderer's own alpha fallback.
      let inverted = scope.parent?.matteMode == 1 || scope.parent?.matteMode == 3
      applyDrawStencil(encoder)
      guard usePipeline(encoder, fragment: "layerFragment", blend: inverted ? .dstOut : .dstIn) else { return }
      setVertexUniforms(encoder, matrix: .identity, target: current)
      var uniforms = LayerUniforms(layer: source(result), alpha: 1, blend: 0)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
      encoder.setFragmentTexture(result.texture, index: 0)
      // DstIn has to reach every pixel of the content layer, not only the mask's region.
      drawTriangles(encoder, rectQuad(current.rect))
    case .effect:
      switch scope.effectName {
      case "blur", "depth-blur":
        compositePlain(encoder, result, alpha: 1, blend: 0)
        stats.effectsApplied += 1
      case "color-matrix", "brightness-contrast":
        applyDrawStencil(encoder)
        guard usePipeline(encoder, fragment: "colorMatrixFragment", blend: .over) else { return }
        setVertexUniforms(encoder, matrix: .identity, target: current)
        var terms = [Float](repeating: 0, count: 20)
        if scope.effectName == "color-matrix" {
          for index in 0..<20 { terms[index] = Float(scalar("m\(index)", index % 6 == 0 ? 1 : 0)) }
        } else {
          let brightness = max(-1, min(1, scalar("brightness", 0)))
          let contrast = max(0, min(4, scalar("contrast", 1)))
          let offset = brightness + 0.5 * (1 - contrast)
          terms = [
            Float(contrast), 0, 0, 0, Float(offset),
            0, Float(contrast), 0, 0, Float(offset),
            0, 0, Float(contrast), 0, Float(offset),
            0, 0, 0, 1, 0,
          ]
        }
        var uniforms = ColorMatrixUniforms(src: source(result), m: (
          SIMD4(terms[0], terms[1], terms[2], terms[3]), SIMD4(terms[4], terms[5], terms[6], terms[7]),
          SIMD4(terms[8], terms[9], terms[10], terms[11]), SIMD4(terms[12], terms[13], terms[14], terms[15]),
          SIMD4(terms[16], terms[17], terms[18], terms[19])))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ColorMatrixUniforms>.stride, index: 0)
        encoder.setFragmentTexture(result.texture, index: 0)
        drawTriangles(encoder, rectQuad(result.rect))
        stats.effectsApplied += 1
      case "drop-shadow":
        // MakeDropShadow blurs the source, tints it, offsets it, and draws the
        // untouched source on top.
        let tint = scope.values["color"] ?? [0, 0, 0, 0.5]
        let silhouette = backdrops[ObjectIdentifier(scope)] ?? result
        applyDrawStencil(encoder)
        guard usePipeline(encoder, fragment: "tintFragment", blend: .over) else { return }
        setVertexUniforms(encoder, matrix: .identity, target: current)
        var uniforms = TintUniforms(
          src: source(silhouette),
          tint: SIMD4(Float(tint[0]), Float(tint[1]), Float(tint[2]), Float(tint.count > 3 ? tint[3] : 1)),
          offset: SIMD2(Float(scalar("offsetX", 0) / scale.x), Float(scalar("offsetY", 4) / scale.y)))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TintUniforms>.stride, index: 0)
        encoder.setFragmentTexture(silhouette.texture, index: 0)
        drawTriangles(encoder, rectQuad(result.rect))
        compositePlain(encoder, result, alpha: 1, blend: 0)
        stats.effectsApplied += 1
      default:
        runtimeEffect(scope, result, encoder)
      }
    }
  }

  func runtimeEffect(_ scope: Scope, _ result: Sampled, _ encoder: MTLRenderCommandEncoder) {
    guard let source = scope.source, let program = backend.effectProgram(source) else {
      note("effect:\(scope.effectName.isEmpty ? "unknown" : scope.effectName)")
      compositePlain(encoder, result, alpha: 1, blend: 0)
      return
    }
    applyDrawStencil(encoder)
    guard usePipeline(encoder, fragment: "effect:\(source.hashValue)", function: program.function, blend: .over) else {
      compositePlain(encoder, result, alpha: 1, blend: 0)
      return
    }
    setVertexUniforms(encoder, matrix: .identity, target: current)
    let bounds = scope.bounds
    // A shader may opt into the render scale by declaring two floats more
    // than its parameters supply; they arrive last.
    var values = scope.uniformValues.map { Float($0) }
    if program.shader.declaredFloats == values.count + 2 { values += [Float(scale.x), Float(scale.y)] }
    while values.count < program.shader.declaredFloats { values.append(0) }
    var uniforms: [Float] = [
      Float(bounds[0]), Float(bounds[1]), Float(bounds[2]), Float(bounds[3]),
      Float(current.rect.x), Float(current.rect.y), Float(current.rect.w), Float(current.rect.h),
    ]
    var rects: [Float] = [0, 0, 0, 0, 0, 0, 0, 0]
    var sizes: [Float] = [1, 1, 1, 1]
    let backdrop = backdrops[ObjectIdentifier(scope)]
    for (index, child) in program.shader.children.prefix(2).enumerated() {
      let sampled = child == "inputImage" || backdrop == nil ? result : backdrop!
      rects[index * 4] = Float(sampled.rect.x); rects[index * 4 + 1] = Float(sampled.rect.y)
      rects[index * 4 + 2] = Float(sampled.rect.w); rects[index * 4 + 3] = Float(sampled.rect.h)
      sizes[index * 2] = Float(sampled.texture.width); sizes[index * 2 + 1] = Float(sampled.texture.height)
      encoder.setFragmentTexture(sampled.texture, index: index)
    }
    uniforms += rects + sizes + values
    while uniforms.count % 4 != 0 { uniforms.append(0) }
    uniforms.withUnsafeBytes { raw in encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0) }
    let left = Float(bounds[0] / scale.x), top = Float(bounds[1] / scale.y)
    let right = left + Float(bounds[2] / scale.x), bottom = top + Float(bounds[3] / scale.y)
    drawTriangles(encoder, [left, top, right, top, left, bottom, right, top, right, bottom, left, bottom])
    stats.effectsApplied += 1
  }

  /// Snapshots what the current target holds over `region`, for an effect
  /// that reads its backdrop. The pass has to be ended and resumed around
  /// it, which is the one thing that forces a target out of tile memory.
  func snapshotBackdrop(_ scope: Scope) {
    let parent = current.rect
    let b = scope.bounds
    let x0 = max(parent.x, Int(b[0].rounded(.down)))
    let y0 = max(parent.y, Int(b[1].rounded(.down)))
    let x1 = min(parent.x + parent.w, Int((b[0] + b[2]).rounded(.up)))
    let y1 = min(parent.y + parent.h, Int((b[1] + b[3]).rounded(.up)))
    let region = x1 > x0 && y1 > y0 ? PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0) : PixelRect(x: parent.x, y: parent.y, w: 1, h: 1)
    endPass()
    let copy = backend.acquireTexture(width: region.w, height: region.h, format: current.color.pixelFormat)
    if let blit = commandBuffer.makeBlitCommandEncoder() {
      blit.copy(
        from: current.result, sourceSlice: 0, sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: region.x - parent.x, y: region.y - parent.y, z: 0),
        sourceSize: MTLSize(width: region.w, height: region.h, depth: 1),
        to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
      blit.endEncoding()
    }
    backdrops[ObjectIdentifier(scope)] = Sampled(texture: copy, rect: region, factor: 1)
  }

  /* -------------------- the stream -------------------- */

  func next(_ cursor: inout Int) -> Double {
    let value = stream[cursor]
    cursor += 1
    return value
  }

  /// Interprets `[from, to)` of the stream into the current pass. Child
  /// scopes are skipped over and composited from their finished textures.
  func interpret(from: Int, to: Int, children: [Scope]) {
    var cursor = from
    var childIndex = 0
    while cursor < to {
      guard let encoder else { return }
      let opcode = next(&cursor)
      switch opcode {
      case Op.save:
        scopeStack.append((matrix, clipMask, clipDepth))
      case Op.restore:
        let popped = scopeStack.popLast()
        matrix = popped?.0 ?? .identity
        clipMask = popped?.1 ?? 0
        clipDepth = popped?.2 ?? 0
      case Op.transform:
        let a = next(&cursor), b = next(&cursor), c = next(&cursor), d = next(&cursor), e = next(&cursor), f = next(&cursor)
        matrix = matrix * Affine(a: a, b: b, c: c, d: d, e: e, f: f)
      case Op.beginLayer, Op.beginEffect, Op.beginMatte, Op.matteSource:
        guard childIndex < children.count else { cursor = to; break }
        let child = children[childIndex]
        childIndex += 1
        let storable = children.contains { $0.usesBackdrop }
        if child.usesBackdrop {
          snapshotBackdrop(child)
          prepare(child)
          beginPass(current, storable: storable)
        }
        if let encoder = self.encoder { composite(child, encoder) }
        cursor = child.end + 1
      case Op.endLayer, Op.endEffect, Op.endMatte:
        // Reached only when a scope is closed by the op that ends this range.
        break
      case Op.fillStyle:
        fillColor = SIMD4(Float(next(&cursor)), Float(next(&cursor)), Float(next(&cursor)), Float(next(&cursor)))
        paintMode = 0
      case Op.strokeStyle:
        strokeColor = SIMD4(Float(next(&cursor)), Float(next(&cursor)), Float(next(&cursor)), Float(next(&cursor)))
        strokeWidth = next(&cursor)
        strokeCap = Int(next(&cursor))
        strokeJoin = Int(next(&cursor))
        strokeMiterLimit = next(&cursor)
        let dashCount = Int(next(&cursor))
        strokeDash = (0..<dashCount).map { _ in next(&cursor) }
      case Op.gradientStyle:
        let radial = next(&cursor)
        paint.gradient = SIMD4(Float(next(&cursor)), Float(next(&cursor)), Float(next(&cursor)), Float(next(&cursor)))
        let opacity = next(&cursor)
        let stopCount = Int(next(&cursor))
        var stops: [(offset: Float, color: SIMD4<Float>)] = []
        for _ in 0..<stopCount {
          let offset = Float(next(&cursor))
          stops.append((offset, SIMD4(Float(next(&cursor)), Float(next(&cursor)), Float(next(&cursor)), Float(next(&cursor) * opacity))))
        }
        paint.setStops(stops)
        paintMode = radial == 1 ? 2 : 1
      case Op.rect:
        let x = next(&cursor), y = next(&cursor), w = next(&cursor), h = next(&cursor), radius = next(&cursor)
        let flags = Int(next(&cursor))
        if buildingClip { drawAnalytic(encoder, shape: 0, cx: x + w / 2, cy: y + h / 2, hx: w / 2, hy: h / 2, radius: radius, color: SIMD4(1, 1, 1, 1)); break }
        if flags & 1 != 0 { drawAnalytic(encoder, shape: 0, cx: x + w / 2, cy: y + h / 2, hx: w / 2, hy: h / 2, radius: radius, color: fillColor) }
        if flags & 2 != 0, let stroke = strokeColor { drawAnalytic(encoder, shape: 0, cx: x + w / 2, cy: y + h / 2, hx: w / 2, hy: h / 2, radius: radius, color: stroke, stroke: strokeWidth) }
      case Op.ellipse:
        let cx = next(&cursor), cy = next(&cursor), rx = next(&cursor), ry = next(&cursor)
        let flags = Int(next(&cursor))
        if buildingClip { drawAnalytic(encoder, shape: 1, cx: cx, cy: cy, hx: rx, hy: ry, radius: 0, color: SIMD4(1, 1, 1, 1)); break }
        if flags & 1 != 0 { drawAnalytic(encoder, shape: 1, cx: cx, cy: cy, hx: rx, hy: ry, radius: 0, color: fillColor) }
        if flags & 2 != 0, let stroke = strokeColor { drawAnalytic(encoder, shape: 1, cx: cx, cy: cy, hx: rx, hy: ry, radius: 0, color: stroke, stroke: strokeWidth) }
      case Op.path:
        let contourCount = Int(next(&cursor))
        let flags = Int(next(&cursor))
        let boldWidth = next(&cursor)
        let pathScale = matrix.scale * max(scale.x, scale.y)
        var contours: [[Float]] = []
        var closed: [Bool] = []
        for _ in 0..<contourCount {
          let vertexCount = Int(next(&cursor))
          let isClosed = next(&cursor) == 1
          closed.append(isClosed)
          var vertices: [(Double, Double, Double, Double, Double, Double)] = []
          vertices.reserveCapacity(vertexCount)
          for _ in 0..<vertexCount {
            vertices.append((next(&cursor), next(&cursor), next(&cursor), next(&cursor), next(&cursor), next(&cursor)))
          }
          guard let first = vertices.first else { contours.append([]); continue }
          var flat: [Float] = [Float(first.0), Float(first.1)]
          for index in 1..<max(1, vertices.count) {
            let from = vertices[index - 1], to = vertices[index]
            flattenCubic(into: &flat, from.0, from.1, from.0 + from.4, from.1 + from.5, to.0 + to.2, to.1 + to.3, to.0, to.1, scale: pathScale)
          }
          if isClosed, let last = vertices.last {
            flattenCubic(into: &flat, last.0, last.1, last.0 + last.4, last.1 + last.5, first.0 + first.2, first.1 + first.3, first.0, first.1, scale: pathScale)
          }
          contours.append(flat)
        }
        if buildingClip {
          // A path clip: wind the low bits, then a cover pass whose REPLACE
          // sets the clip bit and clears the winding in one write.
          setStencil(encoder, compare: .always, pass: .invert, reference: 0, readMask: fillBits, writeMask: fillBits)
          if let box = windContours(encoder, contours) {
            setStencil(encoder, compare: .notEqual, pass: .replace, reference: clipMask | buildingClipBit, readMask: windingMask, writeMask: windingMask | buildingClipBit)
            drawTriangles(encoder, coverQuad(box))
          }
          break
        }
        if flags & 1 != 0 { stencilThenCover(encoder, contours: contours, color: fillColor, boldWidth: boldWidth, closed: closed) }
        if flags & 2 != 0, let stroke = strokeColor, strokeWidth > 0 { strokeContours(encoder, contours: contours, closed: closed, color: stroke) }
      case Op.image:
        let asset = Int(next(&cursor))
        let boxWidth = next(&cursor), boxHeight = next(&cursor)
        let fit = Int(next(&cursor))
        let hasCrop = next(&cursor) == 1
        let cropX = next(&cursor), cropY = next(&cursor), cropWidth = next(&cursor), cropHeight = next(&cursor)
        let assetId = asset < frame.metadata.assets.count ? frame.metadata.assets[asset] : nil
        guard let assetId, let texture = images[assetId] else { note("image-unresolved"); break }
        let width = Double(texture.width), height = Double(texture.height)
        let sourceX = hasCrop ? cropX : 0
        let sourceY = hasCrop ? cropY : 0
        let sourceWidth = hasCrop && cropWidth > 0 ? cropWidth : width
        let sourceHeight = hasCrop && cropHeight > 0 ? cropHeight : height
        var drawWidth = boxWidth, drawHeight = boxHeight
        if fit == 1 {
          drawWidth = sourceWidth; drawHeight = sourceHeight
        } else if fit == 2 || fit == 3 {
          let s = fit == 2 ? min(boxWidth / sourceWidth, boxHeight / sourceHeight) : max(boxWidth / sourceWidth, boxHeight / sourceHeight)
          drawWidth = sourceWidth * s; drawHeight = sourceHeight * s
        }
        let x = -drawWidth / 2, y = -drawHeight / 2
        applyDrawStencil(encoder)
        guard usePipeline(encoder, fragment: "textureFragment", blend: .over) else { break }
        setVertexUniforms(encoder, matrix: matrix, target: current)
        var uniforms = ImageUniforms(
          source: SIMD4(Float(sourceX / width), Float(sourceY / height), Float(sourceWidth / width), Float(sourceHeight / height)),
          box: SIMD4(Float(x), Float(y), Float(drawWidth), Float(drawHeight)), alpha: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ImageUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        let l = Float(x), t = Float(y), r = Float(x + drawWidth), b = Float(y + drawHeight)
        drawTriangles(encoder, [l, t, r, t, l, b, r, t, r, b, l, b])
        stats.primitives += 1
      case Op.clipBegin:
        if clipDepth >= clipBits.count {
          note("clip-depth-exceeded")
          buildingClip = true
          buildingClipBit = 0
          break
        }
        buildingClip = true
        buildingClipBit = clipBits[clipDepth]
        // Clear only this level's bit. Metal has no mid-pass clear, so a
        // full-target quad zeroes it through the stencil unit.
        setStencil(encoder, compare: .always, pass: .zero, reference: 0, readMask: 0, writeMask: buildingClipBit)
        if usePipeline(encoder, fragment: "solidFragment", blend: .over, writeColor: false) {
          setVertexUniforms(encoder, matrix: .identity, target: current)
          var blank = Paint()
          encoder.setFragmentBytes(&blank, length: MemoryLayout<Paint>.stride, index: 0)
          drawTriangles(encoder, rectQuad(current.rect))
        }
      case Op.clipEnd:
        buildingClip = false
        if buildingClipBit != 0 {
          clipMask |= buildingClipBit
          clipDepth += 1
        }
        buildingClipBit = 0
      case Op.skipped:
        cursor += 1
        note("skipped-node")
      default:
        note("unknown-opcode")
        cursor = to
      }
    }
  }
}
