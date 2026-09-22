import Foundation
import Testing

@testable import Clayzo

private let demos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("../../apps/studio/public/demo")

/// Every demo bundle in the monorepo, or the fixture alone when the package
/// is checked out on its own.
@MainActor
@Test func opensEveryDemoBundle() throws {
  var files = (try? FileManager.default.contentsOfDirectory(at: demos, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "clayzo" } ?? []
  if files.isEmpty { files = [try #require(Bundle.module.url(forResource: "interactive-character", withExtension: "clayzo", subdirectory: "Fixtures"))] }
  for file in files {
    let bundle = try ClayzoBundle(contentsOf: file)
    #expect(bundle.manifest.format == "clayzo")
    #expect(bundle.manifest.assets.filter { $0.type == "image" }.count == bundle.images.count, Comment(rawValue: file.lastPathComponent))
    let document = try ClayzoDocument(bundle: bundle)
    #expect(document.isInteractive == bundle.manifest.interactive)
    #expect(document.frame(tick: 0) != nil)
  }
}

@Test func rejectsWhatIsNotABundle() {
  #expect(throws: ClayzoBundle.Error.self) { try ClayzoBundle(data: Data("{}".utf8)) }
}
