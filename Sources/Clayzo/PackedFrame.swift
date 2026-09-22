import Foundation

/// A discrete thing the pointer did to a hit area during a frame.
public struct InteractionEvent: Decodable, Sendable {
  public enum Kind: String, Decodable, Sendable { case enter, leave, down, up, click }
  public struct Point: Decodable, Sendable {
    public let x: Double
    public let y: Double
  }
  public let kind: Kind
  public let hitAreaId: String
  public let nodeId: String
  /// Composition-space pointer position when it happened.
  public let position: Point
}

/// One evaluated frame: the draw-command stream plus what a backend needs to
/// resolve it. Mirrors `PackedFrame` in the WebGL player's packed-frame.ts.
public struct PackedFrame: Sendable {
  public struct Metadata: Decodable, Sendable {
    public let assets: [String]
    public let effects: [String]
    public let effectParameterNames: [[String]]
    public let effectParameterTypes: [[String]]
    public let effectImplementations: [String]
    // Present on interactive frames only.
    public var events: [InteractionEvent]? = nil
    public var settled: Bool? = nil
    public var cursor: String? = nil
  }

  public let width: Double
  public let height: Double
  /// Premultiplication is the backend's business; this is the document's RGBA.
  public let background: SIMD4<Double>
  public let stream: [Double]
  public let metadata: Metadata

  /// Header layout is fixed by `frame::encode` in the core: ten f64 words,
  /// UTF-8 metadata padded to f64 alignment, then the commands.
  init?(packet: UnsafePointer<Double>) {
    let words = packet[0], metadataBytes = packet[1], count = packet[2]
    guard let words = Int(exactly: words), let metadataBytes = Int(exactly: metadataBytes),
      let count = Int(exactly: count), metadataBytes >= 0, count >= 0
    else { return nil }
    let metadataWords = (metadataBytes + 7) / 8
    guard words == 10 + metadataWords + count else { return nil }

    let json = Data(bytes: UnsafeRawPointer(packet + 10), count: metadataBytes)
    guard let metadata = try? JSONDecoder().decode(Metadata.self, from: json) else { return nil }

    self.width = packet[3]
    self.height = packet[4]
    self.background = SIMD4(packet[5], packet[6], packet[7], packet[8])
    self.stream = Array(UnsafeBufferPointer(start: packet + 10 + metadataWords, count: count))
    self.metadata = metadata
  }
}
