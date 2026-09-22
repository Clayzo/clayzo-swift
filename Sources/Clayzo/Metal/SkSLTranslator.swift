import Foundation

/// A runtime-effect shader translated to Metal.
struct TranslatedShader {
  let source: String
  /// Child shader names, in declaration order.
  let children: [String]
  /// Scalar, vector and matrix uniforms, by name and SkSL type.
  let uniforms: [(name: String, type: String)]
  /// Floats the packed uniform array must supply for the declared uniforms.
  var declaredFloats: Int { uniforms.reduce(0) { $0 + (uniformFloats[$1.type] ?? 1) } }
}

/// Floats each uniform type consumes from the packed array.
let uniformFloats: [String: Int] = [
  "float": 1, "int": 1, "float2": 2, "float3": 3, "float4": 4,
  "float2x2": 4, "float3x3": 9, "float4x4": 16,
]

enum SkSLError: Error, CustomStringConvertible {
  case unsupported(String)
  case noEntryPoint

  var description: String {
    switch self {
    case .unsupported(let what): return "SkSL uses \(what), which this translator does not handle"
    case .noEntryPoint: return "SkSL has no `half4 main(float2)` entry point"
    }
  }
}

private let unsupported: [(NSRegularExpression, String)] = [
  (try! NSRegularExpression(pattern: #"\buniform\s+shader\s+\w+\s*\["#), "arrays of child shaders"),
]

/// `half` is a real 16-bit type in Metal. The CanvasKit reference rasterizes
/// in 32-bit float, so `half` is widened here exactly as the GLSL translator
/// widens it — matching the reference, not Skia's GPU precision hints.
private let typeMap: [(NSRegularExpression, String)] = [
  (try! NSRegularExpression(pattern: #"\bhalf4x4\b"#), "float4x4"),
  (try! NSRegularExpression(pattern: #"\bhalf3x3\b"#), "float3x3"),
  (try! NSRegularExpression(pattern: #"\bhalf2x2\b"#), "float2x2"),
  (try! NSRegularExpression(pattern: #"\bhalf4\b"#), "float4"),
  (try! NSRegularExpression(pattern: #"\bhalf3\b"#), "float3"),
  (try! NSRegularExpression(pattern: #"\bhalf2\b"#), "float2"),
  (try! NSRegularExpression(pattern: #"\bhalf\b"#), "float"),
]

/// Metal keeps a reservation list SkSL does not share: a shader with an
/// ordinary local named `sample`, `texture` or `kernel` compiles under Skia
/// and not here. Whole-word renames inside one self-contained shader are
/// safe; uniform and child names are captured after the rename, in step.
private let reserved = [
  "sample", "filter", "input", "output", "buffer", "kernel", "vertex", "fragment",
  "device", "constant", "thread", "threadgroup", "texture", "sampler", "access",
  "address", "coord", "class", "template", "this", "namespace", "using", "static",
  "inline", "operator", "new", "delete", "virtual", "public", "private", "protected",
  "union", "enum", "typedef", "auto", "register", "volatile", "extern", "goto",
  "short", "long", "unsigned", "signed", "char", "packed", "patch", "shared",
  "restrict", "readonly", "writeonly", "flat", "precise", "asm", "sizeof", "cast",
]
private let reservedPatterns = reserved.map { try! NSRegularExpression(pattern: "\\b\($0)\\b") }

private extension String {
  func replacing(_ pattern: NSRegularExpression, with template: String) -> String {
    pattern.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
  }
  func matches(_ pattern: NSRegularExpression) -> [NSTextCheckingResult] {
    pattern.matches(in: self, range: NSRange(startIndex..., in: self))
  }
  func contains(_ pattern: NSRegularExpression) -> Bool {
    pattern.firstMatch(in: self, range: NSRange(startIndex..., in: self)) != nil
  }
  subscript(_ range: NSRange) -> String { String(self[Range(range, in: self)!]) }
}

/// Translates an engine SkSL effect shader into a Metal fragment function.
///
/// The translation is viable because SkSL is close to Metal's shading
/// language — closer than to GLSL, since `float2`, `half4` and `float3x3`
/// are Metal's own spellings. What differs: `uniform shader X` is a sampled
/// child, `X.eval(p)` samples it at a pixel coordinate, Metal has no file
/// scope variables (so uniforms and children become members of a struct the
/// shader's functions are methods of), `mod` and two-argument `atan` are
/// spelled differently, and `main` returns its colour through a wrapper.
///
/// Like the GLSL translator, this is not a compiler. Anything outside the
/// shapes the engine's own shaders and the `custom-sksl` contract use is
/// rejected rather than mistranslated.
func translateSkSL(_ original: String) throws -> TranslatedShader {
  for (pattern, what) in unsupported where original.contains(pattern) {
    throw SkSLError.unsupported(what)
  }
  var source = original
  for pattern in reservedPatterns {
    source = source.replacing(pattern, with: "csk_$0")
  }

  var children: [String] = []
  let childPattern = try! NSRegularExpression(pattern: #"uniform\s+shader\s+(\w+)\s*;"#)
  for match in source.matches(childPattern) { children.append(source[match.range(at: 1)]) }
  var body = source.replacing(childPattern, with: "")

  for (pattern, replacement) in typeMap { body = body.replacing(pattern, with: replacement) }

  var uniforms: [(name: String, type: String)] = []
  let uniformPattern = try! NSRegularExpression(
    pattern: #"uniform\s+(float|float2|float3|float4|int|float2x2|float3x3|float4x4)\s+(\w+)\s*;"#)
  for match in body.matches(uniformPattern) { uniforms.append((body[match.range(at: 2)], body[match.range(at: 1)])) }
  body = body.replacing(uniformPattern, with: "")

  for child in children {
    body = body.replacing(try! NSRegularExpression(pattern: "\\b\(child)\\s*\\.\\s*eval\\s*\\("), with: "csk_eval_\(child)(")
  }

  let mainPattern = try! NSRegularExpression(pattern: #"float4\s+main\s*\(\s*float2\s+(\w+)\s*\)"#)
  guard body.contains(mainPattern) else { throw SkSLError.noEntryPoint }
  body = body.replacing(mainPattern, with: "float4 csk_main(float2 $1)")

  // Children first — argument buffers aside, Metal is happy with textures as
  // members of a local struct, and this is what lets the shader's own helper
  // functions call `eval` without threading the texture through by hand.
  var members = children.map { "  texture2d<float> \($0);" }
  members.append("  float4 csk_bounds;")
  for (index, child) in children.enumerated() {
    members.append("  float4 csk_rect_\(child);")
    members.append("  float2 csk_texSize_\(child);")
    _ = index
  }
  for uniform in uniforms { members.append("  \(uniform.type) \(uniform.name);") }

  let evals = children.map { child in
    """
      float4 csk_eval_\(child)(float2 csk_p) {
        // csk_p is relative to the pass bounds. Clamping to them first is what
        // makes a bounded pass behave like Skia's, where the child image *is*
        // the bounds and TileMode.Clamp holds its edge.
        float2 csk_clamped = clamp(csk_p, float2(0.0), csk_bounds.zw);
        float2 csk_pixel = csk_clamped + csk_bounds.xy;
        return \(child).sample(csk_sampler, (csk_pixel - csk_rect_\(child).xy) / csk_texSize_\(child));
      }
    """
  }

  // The struct is aggregate-initialised in member order: children, bounds,
  // per-child regions, then the uniforms unpacked from the float array.
  var inits = children.enumerated().map { "csk_t\($0.offset)" }
  inits.append("u.bounds")
  for index in children.indices {
    inits.append("u.rect[\(index)]")
    inits.append("u.texSize[\(index)]")
  }
  var offset = 0
  for uniform in uniforms {
    let count = uniformFloats[uniform.type] ?? 1
    let values = (0..<count).map { "u.values[\(offset + $0)]" }
    offset += count
    switch uniform.type {
    case "float": inits.append(values[0])
    case "int": inits.append("int(\(values[0]))")
    case "float2", "float3", "float4": inits.append("\(uniform.type)(\(values.joined(separator: ", ")))")
    case "float2x2": inits.append("float2x2(float2(\(values[0]), \(values[1])), float2(\(values[2]), \(values[3])))")
    case "float3x3":
      inits.append("float3x3(float3(\(values[0..<3].joined(separator: ", "))), float3(\(values[3..<6].joined(separator: ", "))), float3(\(values[6..<9].joined(separator: ", "))))")
    case "float4x4":
      let columns = (0..<4).map { "float4(\(values[$0 * 4..<$0 * 4 + 4].joined(separator: ", ")))" }
      inits.append("float4x4(\(columns.joined(separator: ", ")))")
    default: inits.append(values[0])
    }
  }
  let textureArguments = children.enumerated().map { ", texture2d<float> csk_t\($0.offset) [[texture(\($0.offset))]]" }.joined()

  let translated = """
  #include <metal_stdlib>
  using namespace metal;
  struct Varyings { float4 position [[position]]; float2 local; };
  struct EffectUniforms {
    float4 bounds;       // pass bounds in device pixels: origin, size
    float4 targetRect;   // device region of the framebuffer being drawn into
    float4 rect[2];      // per child: the device region its texture covers
    float2 texSize[2];   // per child: the texture's size in texels
    float values[\(max(offset, 1))];
  };
  constexpr sampler csk_sampler(filter::linear, address::clamp_to_edge, mip_filter::none);
  // SkSL intrinsics Metal spells differently or lacks. Declared unconditionally:
  // an unused function costs nothing and a custom shader may reach for any.
  static float mod(float x, float y) { return x - y * floor(x / y); }
  static float2 mod(float2 x, float2 y) { return x - y * floor(x / y); }
  static float3 mod(float3 x, float3 y) { return x - y * floor(x / y); }
  static float4 mod(float4 x, float4 y) { return x - y * floor(x / y); }
  static float2 mod(float2 x, float y) { return x - y * floor(x / y); }
  static float3 mod(float3 x, float y) { return x - y * floor(x / y); }
  static float4 mod(float4 x, float y) { return x - y * floor(x / y); }
  static float atan(float y, float x) { return atan2(y, x); }
  static float2 atan(float2 y, float2 x) { return atan2(y, x); }
  static float inversesqrt(float x) { return rsqrt(x); }
  static float2 inversesqrt(float2 x) { return rsqrt(x); }
  static float3 inversesqrt(float3 x) { return rsqrt(x); }
  static float4 inversesqrt(float4 x) { return rsqrt(x); }
  // Skia's own definition, epsilon included: dividing by a zero alpha is the
  // difference between an invisible pixel and a NaN that propagates.
  static float4 unpremul(float4 c) { return float4(c.rgb / max(c.a, 0.0001), c.a); }
  // The working colour space intrinsics. Every surface this engine draws to
  // is 8-bit sRGB — the drawable included — so these are the sRGB transfer
  // curves exactly, which is what Skia evaluates them to on such a surface.
  static float3 toLinearSrgb(float3 c) {
    float3 low = c / 12.92;
    float3 high = pow((c + 0.055) / 1.055, float3(2.4));
    return select(high, low, c <= 0.04045);
  }
  static float3 fromLinearSrgb(float3 c) {
    float3 low = c * 12.92;
    float3 high = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
    return select(high, low, c <= 0.0031308);
  }
  static float4 toLinearSrgb(float4 c) { return float4(toLinearSrgb(c.rgb), c.a); }
  static float4 fromLinearSrgb(float4 c) { return float4(fromLinearSrgb(c.rgb), c.a); }
  struct Shader {
  \(members.joined(separator: "\n"))
  \(evals.joined(separator: "\n"))
  \(body)
  };
  fragment float4 effectFragment(Varyings in [[stage_in]],
                                 constant EffectUniforms &u [[buffer(0)]]\(textureArguments)) {
    Shader csk_shader = { \(inits.joined(separator: ", ")) };
    // The fragment position is relative to the framebuffer being drawn into;
    // the shader's coordinate must stay relative to the canvas, then to the
    // pass bounds. Targets are y-down, so no flip is needed anywhere.
    float2 csk_p = in.position.xy + u.targetRect.xy - u.bounds.xy;
    return csk_shader.csk_main(csk_p);
  }
  """
  return TranslatedShader(source: translated, children: children, uniforms: uniforms)
}
