import simd

// Swift mirrors of the uniform structs in Shaders.metal. Field order and
// alignment follow Metal's constant address space rules; `Layout` asserts
// the sizes once at startup so a drifted field fails loudly rather than as
// a subtly wrong frame.

struct VertexUniforms {
  var linear: simd_float2x2
  var translate: SIMD2<Float>
  var scale: SIMD2<Float>
  var target: SIMD4<Float>
}

let maxGradientStops = 16

struct Paint {
  var color = SIMD4<Float>(0, 0, 0, 1)
  var box = SIMD4<Float>(repeating: 0)
  var gradient = SIMD4<Float>(repeating: 0)
  var radius: Float = 0
  var stroke: Float = 0
  var shape: Int32 = 0
  var paint: Int32 = 0
  var opacity: Float = 1
  var stopCount: Int32 = 0
  var pad = SIMD2<Float>(repeating: 0)
  var stopColor: (
    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
  ) = (
    .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero,
    .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero
  )
  var stopOffset: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)

  mutating func setStops(_ stops: [(offset: Float, color: SIMD4<Float>)]) {
    // More stops than the struct holds are resampled evenly, which keeps the
    // gradient's shape at the cost of exactness on a document no one writes.
    var resampled = stops
    if resampled.count > maxGradientStops {
      resampled = (0..<maxGradientStops).map { index in
        let t = Float(index) / Float(maxGradientStops - 1)
        let source = min(stops.count - 1, Int(t * Float(stops.count - 1) + 0.5))
        return stops[source]
      }
    }
    stopCount = Int32(resampled.count)
    withUnsafeMutableBytes(of: &stopColor) { raw in
      let colors = raw.bindMemory(to: SIMD4<Float>.self)
      for (index, stop) in resampled.enumerated() { colors[index] = stop.color }
    }
    withUnsafeMutableBytes(of: &stopOffset) { raw in
      let offsets = raw.bindMemory(to: Float.self)
      for (index, stop) in resampled.enumerated() { offsets[index] = stop.offset }
    }
  }
}

struct ImageUniforms {
  var source: SIMD4<Float>
  var box: SIMD4<Float>
  var alpha: Float
}

/// Where a sampled render target sits, in the device space of the pass
/// reading it (a downsampled blur level divides everything by its factor).
struct Source {
  var rect: SIMD4<Float>
  var texSize: SIMD2<Float>
  var scale: SIMD2<Float>
}

struct LayerUniforms {
  var layer: Source
  var alpha: Float
  var blend: Int32
}

struct BoxUniforms {
  var src: Source
  var direction: SIMD2<Float>
  var window: Int32
  var offset: Int32
}

struct ColorMatrixUniforms {
  var src: Source
  var m: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
}

struct TintUniforms {
  var src: Source
  var tint: SIMD4<Float>
  var offset: SIMD2<Float>
}

struct CopyUniforms {
  var src: Source
}

enum Layout {
  static func check() {
    assert(MemoryLayout<VertexUniforms>.stride == 48)
    assert(MemoryLayout<Paint>.stride == 80 + 16 * 16 + 4 * 16)
    assert(MemoryLayout<Source>.stride == 32)
    assert(MemoryLayout<LayerUniforms>.stride == 48)
    assert(MemoryLayout<BoxUniforms>.stride == 48)
    assert(MemoryLayout<ColorMatrixUniforms>.stride == 112)
    assert(MemoryLayout<TintUniforms>.stride == 64)
  }
}
