import Foundation
import Testing

@testable import Clayzo

@MainActor
@Test func rendersPackedFrameThroughTheCore() throws {
  let url = try #require(Bundle.module.url(forResource: "custom-effect", withExtension: "json", subdirectory: "Fixtures"))
  let document = try ClayzoDocument(json: Data(contentsOf: url))

  let frame = try #require(document.frame(tick: 0))
  #expect(frame.width > 0 && frame.height > 0)
  // Every node is bracketed SAVE … RESTORE (draw_list.rs opcodes 1 and 2).
  #expect(frame.stream.first == 1)
  #expect(frame.stream.last == 2)
  #expect(!frame.metadata.effectImplementations.isEmpty)

  // The stream is a function of the tick, and a deterministic one.
  let later = try #require(document.frame(tick: 120))
  #expect(later.stream != frame.stream)
  #expect(document.frame(tick: 120)?.stream == later.stream)
}

@MainActor
@Test func rejectsADocumentTheCoreCannotOpen() {
  #expect(throws: (any Error).self) { try ClayzoDocument(json: Data("not json".utf8)) }
}

@MainActor
@Test func registersTheFallbackFont() throws {
  // The engine's bundled fallback face, the same one the browser players stage.
  let url = try #require(Bundle.module.url(forResource: "Manrope-wght", withExtension: "ttf", subdirectory: "Fixtures"))
  let data = try Data(contentsOf: url)
  #expect(ClayzoDocument.registerFont(id: "*", data: data))
}

@MainActor
@Test func residentHandleAdvancesAcrossWholeTicks() throws {
  let url = try #require(Bundle.module.url(forResource: "electric-water", withExtension: "json", subdirectory: "Fixtures"))
  let document = try ClayzoDocument(json: Data(contentsOf: url))
  let scale = SIMD2(1110.0 / 720, 1110.0 / 720)
  // The core evaluates whole ticks only; the player floors its playhead.
  #expect(document.frame(tick: 1058.3, scale: scale) == nil)
  let a = try #require(document.frame(tick: 1058, scale: scale))
  let b = try #require(document.frame(tick: 1418, scale: scale))
  #expect(a.stream != b.stream)
}

@MainActor
@Test func interactiveFramesFollowThePointerAndReportEvents() throws {
  let url = try #require(Bundle.module.url(forResource: "interactive-character", withExtension: "clayzo", subdirectory: "Fixtures"))
  let document = try ClayzoDocument(bundle: ClayzoBundle(contentsOf: url))
  #expect(document.isInteractive)
  let scale = SIMD2(0.5, 0.5)
  let width = document.info.canvas.width, height = document.info.canvas.height

  // A finger arriving far left, then far right: the springs pull the face the other way.
  document.setPointer(x: width * 0.1, y: height * 0.5, inside: true, down: false)
  let left = try #require(document.interactiveFrame(tick: 10, scale: scale, deltaSeconds: 1 / 60))
  document.setPointer(x: width * 0.9, y: height * 0.5, inside: true, down: false)
  let right = try #require(document.interactiveFrame(tick: 10, scale: scale, deltaSeconds: 1 / 60))
  #expect(left.stream != right.stream)
  #expect(left.metadata.settled == false)

  // A tap on the face's hit area: down, then up while still inside, is a click.
  document.setPointer(x: width * 0.5, y: height * 0.42, inside: true, down: true)
  let pressed = try #require(document.interactiveFrame(tick: 11, scale: scale, deltaSeconds: 1 / 60))
  document.setPointer(x: width * 0.5, y: height * 0.42, inside: true, down: false)
  let released = try #require(document.interactiveFrame(tick: 12, scale: scale, deltaSeconds: 1 / 60))
  let kinds = (pressed.metadata.events ?? []).map(\.kind) + (released.metadata.events ?? []).map(\.kind)
  #expect(kinds == [.enter, .down, .up, .click], "\(kinds)")

  // An undeclared input is refused; a plain frame carries no interaction metadata.
  #expect(document.setInput("nope", .number(1)) == false)
  #expect(document.frame(tick: 12, scale: scale)?.metadata.events == nil)
}
