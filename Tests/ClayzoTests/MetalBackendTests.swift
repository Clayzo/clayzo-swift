import Foundation
import Metal
import Testing

@testable import Clayzo

private func fixture(_ name: String) throws -> Data {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
  return try Data(contentsOf: url)
}

@Test func translatesEveryBuiltinEffectToMetal() throws {
  let device = try #require(MTLCreateSystemDefaultDevice())
  for (name, source) in builtinEffectSources {
    let translated = try translateSkSL(source)
    #expect(translated.children.first == "inputImage", "\(name) samples its input first")
    // Compiling is the only test that matters: a mistranslation is a compile error here, not a wrong frame later.
    let library = try device.makeLibrary(source: translated.source, options: nil)
    #expect(library.makeFunction(name: "effectFragment") != nil, Comment(rawValue: name))
  }
}

@Test func translatorRejectsWhatItCannotSpell() {
  #expect(throws: SkSLError.self) { try translateSkSL("uniform shader a[2]; half4 main(float2 p) { return half4(1); }") }
  #expect(throws: SkSLError.self) { try translateSkSL("half4 notMain(float2 p) { return half4(1); }") }
}

@Test func translatorCountsUniformFloatsByType() throws {
  let shader = try translateSkSL("uniform float a; uniform float2 b; uniform half4 c; uniform float3x3 m; half4 main(float2 p) { return c; }")
  #expect(shader.declaredFloats == 1 + 2 + 4 + 9)
  #expect(shader.uniforms.map(\.name) == ["a", "b", "c", "m"])
}

@MainActor
@Test func scopeTreeFindsTheEffectPassAndItsBounds() throws {
  let document = try ClayzoDocument(json: fixture("custom-effect"))
  let frame = try #require(document.frame(tick: 200, scale: SIMD2(0.5, 0.5)))
  let tree = ScopeTree(stream: frame.stream, metadata: frame.metadata, scale: SIMD2(0.5, 0.5), canvas: SIMD2(450, 300))
  let effect = try #require(tree.roots.first { $0.kind == .effect })
  #expect(effect.effectName == "custom-sksl")
  // An unbounded runtime effect shades the whole canvas, so its texture covers it.
  #expect(effect.rect == PixelRect(x: 0, y: 0, w: 450, h: 300))
  #expect(effect.end > effect.start)
  #expect(!tree.rootNeedsSplit)
}

@MainActor
@Test func rendersAFrameOffscreenWithNothingUnsupported() throws {
  let device = try #require(MTLCreateSystemDefaultDevice())
  let queue = try #require(device.makeCommandQueue())
  let backend = try MetalBackend(device: device)
  let document = try ClayzoDocument(json: fixture("custom-effect"))
  let frame = try #require(document.frame(tick: 200, scale: SIMD2(0.5, 0.5)))
  let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 450, height: 300, mipmapped: false)
  descriptor.usage = [.renderTarget, .shaderRead]
  descriptor.storageMode = .shared
  let target = try #require(device.makeTexture(descriptor: descriptor))
  let commandBuffer = try #require(queue.makeCommandBuffer())
  let stats = backend.render(frame, into: target, commandBuffer: commandBuffer)
  commandBuffer.commit()
  commandBuffer.waitUntilCompleted()
  #expect(commandBuffer.status == .completed)
  #expect(stats.unsupported.isEmpty, "\(stats.unsupported)")
  #expect(stats.effectsApplied == 1)

  var pixels = [UInt8](repeating: 0, count: 450 * 300 * 4)
  target.getBytes(&pixels, bytesPerRow: 450 * 4, from: MTLRegionMake2D(0, 0, 450, 300), mipmapLevel: 0)
  let background = (UInt8(0.08 * 255), UInt8(0.06 * 255), UInt8(0.05 * 255))  // bgra of the document's canvas colour
  let centre = (225 + 150 * 450) * 4
  #expect(pixels[centre + 3] == 255)
  #expect(pixels[centre] != background.0 || pixels[centre + 1] != background.1 || pixels[centre + 2] != background.2, "the centre is drawn on")
}

@Test func strokerMatchesTheWebGLGeometryShape() {
  // A closed square with mitre joins: four segment quads (two triangles each) and four mitre joins (two triangles each).
  var out: [Float] = []
  strokePolyline([0, 0, 10, 0, 10, 10, 0, 10], closed: true, half: 1, cap: 0, join: 0, miterLimit: 4, into: &out)
  #expect(out.count == (4 * 2 + 4 * 2) * 6)
  // Dashing a 10-unit line with [2, 2] yields three "on" runs.
  #expect(dashPolyline([0, 0, 10, 0], closed: false, pattern: [2, 2]).count == 3)
}

@MainActor
@Test func consecutiveFramesIntoOneTargetDiffer() throws {
  let device = try #require(MTLCreateSystemDefaultDevice())
  let queue = try #require(device.makeCommandQueue())
  let backend = try MetalBackend(device: device)
  let document = try ClayzoDocument(json: fixture("custom-effect"))
  let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 450, height: 300, mipmapped: false)
  descriptor.usage = [.renderTarget, .shaderRead]
  descriptor.storageMode = .shared
  let target = try #require(device.makeTexture(descriptor: descriptor))
  var sums: [Int] = []
  for tick in [0.0, 150.0, 300.0, 450.0] {
    let frame = try #require(document.frame(tick: tick, scale: SIMD2(0.5, 0.5)))
    let commandBuffer = try #require(queue.makeCommandBuffer())
    backend.render(frame, into: target, commandBuffer: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    var pixels = [UInt8](repeating: 0, count: 450 * 300 * 4)
    target.getBytes(&pixels, bytesPerRow: 450 * 4, from: MTLRegionMake2D(0, 0, 450, 300), mipmapLevel: 0)
    sums.append(pixels.reduce(0) { $0 + Int($1) })
  }
  #expect(Set(sums).count == sums.count, "\(sums)")
}

@Test func embeddedShaderSourceMatchesTheMetalFile() throws {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/Clayzo/Metal/Shaders.metal")
  let file = try String(contentsOf: url, encoding: .utf8)
  #expect(shaderSource.trimmingCharacters(in: .newlines) == file.trimmingCharacters(in: .newlines), "run scripts/embed-shaders.sh")
}

@Test func shaderSourceCompilesAtRuntime() throws {
  let device = try #require(MTLCreateSystemDefaultDevice())
  let library = try device.makeLibrary(source: shaderSource, options: nil)
  #expect(library.makeFunction(name: "shapeVertex") != nil)
  #expect(library.makeFunction(name: "layerBlendFragment") != nil)
}
