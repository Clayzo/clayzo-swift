import Compression
import Foundation

/// A `.clayzo` bundle: the shipping form of a document. One file carrying
/// the document, its images and its fonts, produced by the engine's
/// `packageClayzoBundle` and identical to what the web players load.
///
/// The container is a zip whose entries are stored, not deflated (images and
/// fonts are already compressed), so reading it is a walk of the central
/// directory and no decompression. Deflated entries are accepted too.
public struct ClayzoBundle: Sendable {
  public struct Manifest: Decodable, Sendable {
    public struct AssetEntry: Decodable, Sendable {
      public let id: String
      public let type: String
      public let path: String
      public let mimeType: String?
      public let byteLength: Int
    }
    public struct FontFamilyEntry: Decodable, Sendable {
      public let families: [String]
      public let weight: Double?
      public let path: String
      public let byteLength: Int
    }
    public struct Input: Decodable, Sendable {
      public let name: String
      public let kind: String
      public let label: String?
      public let minimum: Double?
      public let maximum: Double?
    }
    public let format: String
    public let version: Int
    public let document: String
    public let documentId: String
    public let revision: String
    public let name: String
    public let durationTicks: Double
    public let ticksPerSecond: Double
    public let interactive: Bool
    public let inputs: [Input]
    public let assets: [AssetEntry]
    public let fontFamilies: [FontFamilyEntry]
  }

  public enum Error: Swift.Error {
    case notAZip
    case corrupt(String)
    case unsupportedCompression(UInt16)
    case missingEntry(String)
  }

  public let manifest: Manifest
  /// The document JSON, as the core parses it.
  public let documentJSON: Data
  /// Encoded image bytes by asset id.
  public let images: [String: Data]
  /// Font bytes by asset id — the ids runs name in `fontAssetId`.
  public let fontAssets: [String: Data]
  /// Fonts supplied by family rather than asset, in manifest order.
  public let fontFamilies: [(families: [String], weight: Double?, bytes: Data)]

  public static func isBundle(_ data: Data) -> Bool {
    data.count >= 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4b
      && (data[data.startIndex + 2] == 3 || data[data.startIndex + 2] == 5) && (data[data.startIndex + 3] == 4 || data[data.startIndex + 3] == 6)
  }

  public init(data: Data) throws {
    guard Self.isBundle(data) else { throw Error.notAZip }
    let entries = try Self.readZip(data)
    guard let manifestBytes = entries["manifest.json"] else { throw Error.missingEntry("manifest.json") }
    let manifest = try JSONDecoder().decode(Manifest.self, from: manifestBytes)
    guard let document = entries[manifest.document] else { throw Error.missingEntry(manifest.document) }
    var images: [String: Data] = [:]
    var fonts: [String: Data] = [:]
    for asset in manifest.assets {
      guard let bytes = entries[asset.path] else { continue }
      if asset.type == "image" { images[asset.id] = bytes } else if asset.type == "font" { fonts[asset.id] = bytes }
    }
    self.manifest = manifest
    documentJSON = document
    self.images = images
    fontAssets = fonts
    fontFamilies = manifest.fontFamilies.compactMap { entry in
      entries[entry.path].map { (families: entry.families, weight: entry.weight, bytes: $0) }
    }
  }

  public init(contentsOf url: URL) throws {
    try self.init(data: Data(contentsOf: url))
  }

  /// Registers the bundle's fonts with the core: every font asset by id, and
  /// the first family font as the `"*"` fallback for runs that name a family
  /// without an asset. The core keeps one fallback face, so a bundle that
  /// ships several families gets the first; a run naming another family
  /// falls back to it rather than to nothing.
  @discardableResult
  public func registerFonts() -> Bool {
    var ok = true
    for (id, bytes) in fontAssets { ok = ClayzoDocument.registerFont(id: id, data: bytes) && ok }
    if let first = fontFamilies.first { ok = ClayzoDocument.registerFont(id: "*", data: first.bytes) && ok }
    return ok
  }

  /* -------------------- zip -------------------- */

  private static func readZip(_ data: Data) throws -> [String: Data] {
    let bytes = [UInt8](data)
    func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

    // End of central directory: signature 0x06054b50, searched back past a comment.
    var eocd = bytes.count - 22
    while eocd >= 0, !(bytes[eocd] == 0x50 && bytes[eocd + 1] == 0x4b && bytes[eocd + 2] == 5 && bytes[eocd + 3] == 6) { eocd -= 1 }
    guard eocd >= 0 else { throw Error.corrupt("no end of central directory") }
    let count = u16(eocd + 10)
    var offset = u32(eocd + 16)
    var entries: [String: Data] = [:]
    for _ in 0..<count {
      guard offset + 46 <= bytes.count, u32(offset) == 0x0201_4b50 else { throw Error.corrupt("bad central directory entry") }
      let method = UInt16(u16(offset + 10))
      let compressed = u32(offset + 20)
      let uncompressed = u32(offset + 24)
      let nameLength = u16(offset + 28), extraLength = u16(offset + 30), commentLength = u16(offset + 32)
      let localHeader = u32(offset + 42)
      let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
      offset += 46 + nameLength + extraLength + commentLength

      guard localHeader + 30 <= bytes.count, u32(localHeader) == 0x0403_4b50 else { throw Error.corrupt("bad local header for \(name)") }
      let dataStart = localHeader + 30 + u16(localHeader + 26) + u16(localHeader + 28)
      guard dataStart + compressed <= bytes.count else { throw Error.corrupt("truncated entry \(name)") }
      let payload = Data(bytes[dataStart..<(dataStart + compressed)])
      switch method {
      case 0: entries[name] = payload
      case 8: entries[name] = try inflate(payload, size: uncompressed)
      default: throw Error.unsupportedCompression(method)
      }
    }
    return entries
  }

  private static func inflate(_ payload: Data, size: Int) throws -> Data {
    var out = Data(count: size)
    let written = out.withUnsafeMutableBytes { destination in
      payload.withUnsafeBytes { source in
        compression_decode_buffer(
          destination.bindMemory(to: UInt8.self).baseAddress!, size,
          source.bindMemory(to: UInt8.self).baseAddress!, payload.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard written == size else { throw Error.corrupt("inflate produced \(written) of \(size) bytes") }
    return out
  }
}

extension ClayzoDocument {
  /// Opens a bundle's document, registering its fonts first so the first
  /// frame has them. Images are the player's: `ClayzoPlayerView.load(_:)`.
  public convenience init(bundle: ClayzoBundle) throws {
    bundle.registerFonts()
    try self.init(json: bundle.documentJSON)
  }
}

extension ClayzoPlayerView {
  /// Loads a bundle: fonts to the core, images to the backend, document to
  /// the view. Everything a `.clayzo` file carries, in one call.
  @discardableResult
  public func load(_ bundle: ClayzoBundle) throws -> ClayzoDocument {
    for (id, bytes) in bundle.images { setImage(id, data: bytes) }
    let document = try ClayzoDocument(bundle: bundle)
    self.document = document
    return document
  }
}
