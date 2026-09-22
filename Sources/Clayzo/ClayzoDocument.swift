import ClayzoEngineCore
import Foundation

public enum ClayzoError: Error {
  case core(String)
}

/// A document resident in the engine core.
///
/// Main-actor bound because the core keeps its document table in thread-local
/// storage: a handle opened on one thread does not exist on another.
@MainActor
public final class ClayzoDocument {
  private let handle: UInt32

  public let info: Info

  public init(json: Data) throws {
    info = try JSONDecoder().decode(Info.self, from: json)
    // Spliced as bytes so the document is parsed once, by the core.
    var request = Data(#"{"op":"openDocument","document":"#.utf8)
    request.append(json)
    request.append(UInt8(ascii: "}"))
    let response = try Self.call(request)
    guard let handle = (response["handle"] as? NSNumber)?.uint32Value else {
      throw ClayzoError.core("openDocument returned no handle")
    }
    self.handle = handle
  }

  deinit {
    // `call` is nonisolated and the core's tables are process-wide, so the
    // handle can be released from whichever thread drops the last reference.
    _ = try? Self.call(Data("{\"op\":\"closeDocument\",\"handle\":\(handle)}".utf8))
  }

  /// Evaluates the frame at `tick`. `scale` is device pixels per composition
  /// unit; `bounds` adds render-graph bounds, which only glass and refraction need.
  public func frame(tick: Double, scale: SIMD2<Double> = SIMD2(1, 1), bounds: Bool = false) -> PackedFrame? {
    guard let packet = render_frame(handle, tick, scale.x, scale.y, bounds ? 1 : 0) else { return nil }
    defer { free_frame(packet) }
    return PackedFrame(packet: packet)
  }

  /* -------------------- interaction -------------------- */

  /// Whether the document declares any bindings. A document that does not
  /// never pays for the interactive path.
  public var isInteractive: Bool { is_interactive(handle) != 0 }

  /// A value a declared input can take.
  public enum InputValue {
    case number(Double)
    case boolean(Bool)
    case point(Double, Double)
    case color(Double, Double, Double, Double)
  }

  /// Sets the pointer — or the one touch — for the next interactive frame,
  /// in composition units. `inside` is false once it has left the view.
  public func setPointer(x: Double, y: Double, inside: Bool, down: Bool) {
    set_pointer(handle, x, y, inside ? 1 : 0, down ? 1 : 0)
  }

  public func setScroll(x: Double, y: Double) { set_scroll(handle, x, y) }

  /// Sets a declared input by name; false when the document declares no such input.
  @discardableResult
  public func setInput(_ name: String, _ value: InputValue) -> Bool {
    let (kind, a, b, c, d): (UInt32, Double, Double, Double, Double)
    switch value {
    case .number(let n): (kind, a, b, c, d) = (0, n, 0, 0, 0)
    case .boolean(let flag): (kind, a, b, c, d) = (1, flag ? 1 : 0, 0, 0, 0)
    case .point(let x, let y): (kind, a, b, c, d) = (2, x, y, 0, 0)
    case .color(let r, let g, let bl, let al): (kind, a, b, c, d) = (3, r, g, bl, al)
    }
    return Array(name.utf8).withUnsafeBufferPointer { set_input(handle, $0.baseAddress, $0.count, kind, a, b, c, d) } != 0
  }

  /// Fires a momentary (trigger) input. It reads true for exactly one frame.
  @discardableResult
  public func fire(_ name: String) -> Bool {
    Array(name.utf8).withUnsafeBufferPointer { set_input(handle, $0.baseAddress, $0.count, 4, 0, 0, 0, 0) } != 0
  }

  /// `frame(tick:)` with the pointer and inputs folded in and `deltaSeconds`
  /// of wall clock advanced for springs and damping. The metadata carries
  /// the hit-area events, whether anything changed, and the cursor.
  public func interactiveFrame(tick: Double, scale: SIMD2<Double> = SIMD2(1, 1), bounds: Bool = false, deltaSeconds: Double) -> PackedFrame? {
    guard let packet = render_frame_interactive(handle, tick, scale.x, scale.y, bounds ? 1 : 0, deltaSeconds) else { return nil }
    defer { free_frame(packet) }
    return PackedFrame(packet: packet)
  }

  /// Registers font bytes with the core, which rasterizes glyph outlines
  /// itself. `"*"` is the fallback for runs that name a family but carry no
  /// asset. Returns false when the bytes are not outlines the core can read.
  @discardableResult
  nonisolated public static func registerFont(id: String, data: Data) -> Bool {
    var request = Data("{\"op\":\"loadFont\",\"id\":\"".utf8)
    request.append(Data(id.utf8))
    request.append(Data("\",\"bytesBase64\":\"".utf8))
    request.append(Data(data.base64EncodedString().utf8))
    request.append(Data("\"}".utf8))
    return (try? call(request)) != nil
  }

  /// Timing and canvas facts a player needs, read once from the document.
  public struct Info: Decodable, Sendable {
    public struct Timing: Decodable, Sendable {
      public let ticksPerSecond: Double
      public let durationTicks: Double
    }
    public struct Canvas: Decodable, Sendable {
      public let width: Double
      public let height: Double
    }
    public let timing: Timing
    public let canvas: Canvas
  }

  nonisolated private static func call(_ request: Data) throws -> [String: Any] {
    guard let input = alloc(request.count) else { throw ClayzoError.core("alloc failed") }
    request.copyBytes(to: input, count: request.count)
    // `process` takes ownership of `input`.
    guard let result = process(input, request.count) else { throw ClayzoError.core("no response") }
    defer { free_result(result) }
    let length = Int(UnsafeRawPointer(result).loadUnaligned(as: UInt32.self).littleEndian)
    let body = Data(bytes: result + 4, count: length)
    guard let response = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      throw ClayzoError.core("malformed response")
    }
    guard response["ok"] as? Bool == true else {
      throw ClayzoError.core(response["error"] as? String ?? "unknown error")
    }
    return response
  }
}
