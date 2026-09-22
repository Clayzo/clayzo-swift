// Renders every case under packages/ios/.reference through the Metal backend
// and differences it against the CanvasKit reference — the same comparison
// `renderers.md` reports for the WebGL backend, with the same metrics.
//
//   swift run -c release clayzo-fidelity [substring] [--out dir]
//
// Writes candidate.png and diff.png beside each reference for eyes.
import Clayzo
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

struct Meta: Decodable {
  let name: String
  let tick: Double
  let width: Int
  let height: Int
  let scale: Double
  let fonts: [String: String]
  let images: [String: String]
}

func writePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) {
  let data = CFDataCreate(nil, pixels, pixels.count)!
  let provider = CGDataProvider(data: data)!
  let image = CGImage(
    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil)
  CGImageDestinationFinalize(destination)
}

@MainActor
func main() throws {
  let arguments = Array(CommandLine.arguments.dropFirst())
  let filter = arguments.first { !$0.hasPrefix("--") }
  if arguments.contains("--bench") { try bench(filter: filter); return }
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".reference")
  let cases = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    .filter { $0.hasDirectoryPath && (filter == nil || $0.lastPathComponent.contains(filter!)) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

  let device = MTLCreateSystemDefaultDevice()!
  let queue = device.makeCommandQueue()!
  let backend = try MetalBackend(device: device)

  print("")
  print("  Metal backend vs CanvasKit reference — \(device.name)")
  print("  " + String(repeating: "-", count: 96))
  print("  case                                            mean Δ    max   differing   content   ms   notes")
  var totals: [Double] = []
  for folder in cases {
    let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: folder.appendingPathComponent("meta.json")))
    let reference = [UInt8](try Data(contentsOf: folder.appendingPathComponent("reference.rgba")))
    for (id, file) in meta.fonts {
      ClayzoDocument.registerFont(id: id, data: try Data(contentsOf: folder.appendingPathComponent("fonts/\(file)")))
    }
    for (id, file) in meta.images {
      backend.setImage(id, data: try Data(contentsOf: folder.appendingPathComponent("images/\(file)")))
    }
    let document = try ClayzoDocument(json: Data(contentsOf: folder.appendingPathComponent("document.json")))
    let scale = SIMD2(Double(meta.width) / document.info.canvas.width, Double(meta.height) / document.info.canvas.height)
    guard let frame = document.frame(tick: meta.tick, scale: scale, bounds: true) else {
      print("  \(folder.lastPathComponent.padEnd(48)) core returned no frame")
      continue
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: meta.width, height: meta.height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let target = device.makeTexture(descriptor: descriptor)!

    // Warm once so shader compilation is not in the timing.
    var stats = RenderStats()
    var elapsed = 0.0
    for pass in 0..<2 {
      let commandBuffer = queue.makeCommandBuffer()!
      let started = Date()
      stats = backend.render(frame, into: target, commandBuffer: commandBuffer)
      commandBuffer.commit()
      commandBuffer.waitUntilCompleted()
      if pass == 1 { elapsed = Date().timeIntervalSince(started) * 1000 }
    }

    var pixels = [UInt8](repeating: 0, count: meta.width * meta.height * 4)
    target.getBytes(&pixels, bytesPerRow: meta.width * 4, from: MTLRegionMake2D(0, 0, meta.width, meta.height), mipmapLevel: 0)
    // BGRA premultiplied -> RGBA unpremultiplied, like the reference readback.
    var candidate = [UInt8](repeating: 0, count: pixels.count)
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let a = Int(pixels[index + 3])
      let unpremul = { (value: UInt8) -> UInt8 in a == 0 ? 0 : UInt8(min(255, (Int(value) * 255 + a / 2) / a)) }
      candidate[index] = unpremul(pixels[index + 2])
      candidate[index + 1] = unpremul(pixels[index + 1])
      candidate[index + 2] = unpremul(pixels[index])
      candidate[index + 3] = UInt8(a)
    }

    // The metrics the repo's parity gates report.
    var maxDelta = 0, total = 0, differing = 0, content = 0
    var diff = [UInt8](repeating: 255, count: pixels.count)
    let corner = Array(reference[0..<4])
    for index in stride(from: 0, to: pixels.count, by: 4) {
      var pixelMax = 0, cornerMax = 0
      for channel in 0..<4 {
        let delta = abs(Int(candidate[index + channel]) - Int(reference[index + channel]))
        total += delta
        pixelMax = max(pixelMax, delta)
        cornerMax = max(cornerMax, abs(Int(reference[index + channel]) - Int(corner[channel])))
      }
      maxDelta = max(maxDelta, pixelMax)
      if pixelMax > 2 { differing += 1 }
      if cornerMax > 8 { content += 1 }
      let heat = UInt8(min(255, pixelMax * 4))
      diff[index] = 255; diff[index + 1] = 255 - heat; diff[index + 2] = 255 - heat
    }
    let count = pixels.count / 4
    let mean = Double(total) / Double(pixels.count)
    totals.append(mean)
    writePNG(candidate, width: meta.width, height: meta.height, to: folder.appendingPathComponent("candidate.png"))
    writePNG(diff, width: meta.width, height: meta.height, to: folder.appendingPathComponent("diff.png"))
    let notes = stats.unsupported.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: " ")
    print("  \(folder.lastPathComponent.padEnd(48)) \(String(format: "%6.2f", mean))  \(String(format: "%5d", maxDelta))   \(String(format: "%6.1f%%", Double(differing) / Double(count) * 100))   \(String(format: "%5.1f%%", Double(content) / Double(count) * 100))  \(String(format: "%5.2f", elapsed))  \(notes)")
  }
  print("  " + String(repeating: "-", count: 96))
  if !totals.isEmpty {
    print("  mean of means \(String(format: "%.2f", totals.reduce(0, +) / Double(totals.count)))   worst \(String(format: "%.2f", totals.max()!))")
  }
}

/// Frame cost at phone resolution: the core's `render_frame`, the backend's
/// encode, and the GPU, each per frame over a run of animated ticks.
@MainActor
func bench(filter: String?) throws {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".reference")
  // One case per document; the tick only seeds the animation.
  var seen: Set<String> = []
  let cases = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    .filter { $0.hasDirectoryPath && (filter == nil || $0.lastPathComponent.contains(filter!)) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .filter { seen.insert(String($0.lastPathComponent.split(separator: "@")[0])).inserted }
  let device = MTLCreateSystemDefaultDevice()!
  let queue = device.makeCommandQueue()!
  let backend = try MetalBackend(device: device)
  let side = 1170  // iPhone Pro logical 390pt at 3x
  print("")
  print("  frame cost at \(side)px wide — \(device.name), 120 frames each")
  print("  " + String(repeating: "-", count: 90))
  print("  document                             core ms   encode ms   gpu ms   draws  passes   (core includes the interaction runtime where the document has one)")
  for folder in cases {
    let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: folder.appendingPathComponent("meta.json")))
    for (id, file) in meta.fonts { ClayzoDocument.registerFont(id: id, data: try Data(contentsOf: folder.appendingPathComponent("fonts/\(file)"))) }
    for (id, file) in meta.images { backend.setImage(id, data: try Data(contentsOf: folder.appendingPathComponent("images/\(file)"))) }
    let document = try ClayzoDocument(json: Data(contentsOf: folder.appendingPathComponent("document.json")))
    let width = side, height = Int(Double(side) * document.info.canvas.height / document.info.canvas.width)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    let target = device.makeTexture(descriptor: descriptor)!
    let scale = SIMD2(Double(width) / document.info.canvas.width, Double(height) / document.info.canvas.height)
    let needsBounds = document.frame(tick: 0, scale: scale)?.metadata.effects.contains { $0 == "glass" || $0 == "refraction" } ?? false
    var core = 0.0, encode = 0.0, gpu = 0.0
    var stats = RenderStats()
    let frames = 120
    let duration = document.info.timing.durationTicks
    for index in 0..<(frames + 10) {
      let tick = (duration * Double(index % frames) / Double(frames)).rounded(.down)
      if document.isInteractive {
        // A finger circling the canvas, so springs and hit areas stay busy.
        let angle = Double(index) / 30
        document.setPointer(x: document.info.canvas.width * (0.5 + 0.3 * cos(angle)), y: document.info.canvas.height * (0.5 + 0.3 * sin(angle)), inside: true, down: index % 40 < 10)
      }
      let t0 = Date()
      guard let frame = document.isInteractive
        ? document.interactiveFrame(tick: tick, scale: scale, bounds: needsBounds, deltaSeconds: 1 / 120)
        : document.frame(tick: tick, scale: scale, bounds: needsBounds)
      else { continue }
      let t1 = Date()
      let commandBuffer = queue.makeCommandBuffer()!
      stats = backend.render(frame, into: target, commandBuffer: commandBuffer)
      let t2 = Date()
      commandBuffer.commit()
      commandBuffer.waitUntilCompleted()
      if index >= 10 {
        core += t1.timeIntervalSince(t0) * 1000
        encode += t2.timeIntervalSince(t1) * 1000
        gpu += (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
      }
    }
    let n = Double(frames)
    print("  \(meta.name.padEnd(36)) \(String(format: "%7.2f", core / n))   \(String(format: "%9.2f", encode / n))   \(String(format: "%6.2f", gpu / n))   \(String(format: "%5d", stats.drawCalls))  \(String(format: "%6d", stats.passes))")
  }
}

extension String {
  func padEnd(_ width: Int) -> String { count >= width ? self : self + String(repeating: " ", count: width - count) }
}

try main()
