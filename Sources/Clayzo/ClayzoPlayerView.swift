import Foundation
import Metal
import MetalKit

/// Plays a document: core, backend, clock and pointer in one view.
///
/// The view's drawable is the frame — the document is scaled to fill it, so
/// give the view the document's aspect ratio (the SwiftUI `ClayzoPlayer`
/// does). Each frame is one `render_frame` call into the core and one
/// command buffer; nothing is allocated per frame after the first.
///
/// Touches drive the document's declared interactivity directly: a finger is
/// the pointer, down while it rests on the view, and the frame it lifts on
/// still counts as inside so a tap on a hit area produces its `click`. It
/// leaves on the frame after, so bindings that rest on leave relax back.
@MainActor
public final class ClayzoPlayerView: MTKView, MTKViewDelegate {
  public let backend: MetalBackend
  private let queue: MTLCommandQueue

  /// The document being played. Setting it restarts the clock at tick zero.
  public var document: ClayzoDocument? {
    didSet {
      tick = 0
      lastFrameAt = nil
      needsBounds = false
      interactive = document?.isInteractive ?? false
      #if os(iOS)
      claim.isEnabled = isInteractionEnabled && interactive
      #endif
      isPaused = false
      draw()
    }
  }
  public var isPlaying = true {
    didSet { if isPlaying { isPaused = false } }
  }
  public var loops = true
  /// The playhead, in the document's ticks. Fractional while playing.
  public var tick: Double = 0
  /// What the last frame cost, for a host that wants to show it.
  public private(set) var lastStats = RenderStats()
  /// Hit-area events — enter, leave, down, up, click — as the frames that
  /// produced them are drawn.
  public var onInteractionEvent: ((InteractionEvent) -> Void)?
  /// Whether touches are forwarded to the document. Off, the view is inert
  /// and its touches fall through to scroll views and navigation gestures.
  public var isInteractionEnabled = true {
    didSet {
      #if os(iOS)
      claim.isEnabled = isInteractionEnabled && interactive
      #endif
    }
  }
  #if os(iOS)
  /// Recognises on touch-down and cancels every other recogniser watching
  /// the touch — a navigation stack's back-swipe, a scroll view's pan — so a
  /// drag across an interactive document drives the document rather than
  /// the screen. Touches still reach `touchesBegan` and friends.
  private let claim = UILongPressGestureRecognizer()
  #endif

  private var lastFrameAt: CFTimeInterval?
  /// Set once a frame reports a glass or refraction effect: those take their
  /// bounds from the render graph, which costs a compile per frame, so it is
  /// only asked for when a document needs it.
  private var needsBounds = false
  private var interactive = false
  private struct Sample { var x: Double, y: Double, inside: Bool, down: Bool }
  /// Pointer samples not yet handed to the core, oldest first. Moves with the
  /// same button state coalesce; a press or release never does, so a tap
  /// that begins and ends between two frames still reads as down then up —
  /// which is what makes it a click.
  private var pending: [Sample] = []
  /// The last sample the core saw.
  private var pointer = Sample(x: 0, y: 0, inside: false, down: false)

  /// Fails only when the system has no Metal device or the shader library
  /// did not ship with the package.
  public init(frame: CGRect, backend: MetalBackend) throws {
    guard let queue = backend.device.makeCommandQueue() else { throw MetalBackendError.noShaderLibrary }
    self.backend = backend
    self.queue = queue
    super.init(frame: frame, device: backend.device)
    colorPixelFormat = .bgra8Unorm
    // An effect that reads its backdrop copies out of the drawable.
    framebufferOnly = false
    #if os(iOS)
    layer.isOpaque = false
    isMultipleTouchEnabled = false
    claim.minimumPressDuration = 0
    claim.cancelsTouchesInView = false
    claim.delaysTouchesBegan = false
    claim.delaysTouchesEnded = false
    claim.isEnabled = false
    addGestureRecognizer(claim)
    #endif
    preferredFramesPerSecond = 120
    delegate = self
  }

  /// A player on the system's default Metal device.
  public static func make(frame: CGRect = .zero) throws -> ClayzoPlayerView {
    guard let device = MTLCreateSystemDefaultDevice() else { throw MetalBackendError.noShaderLibrary }
    return try ClayzoPlayerView(frame: frame, backend: MetalBackend(device: device))
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError("ClayzoPlayerView is created in code") }

  /// Registers an image asset the document references by id.
  @discardableResult
  public func setImage(_ id: String, data: Data) -> Bool {
    let ok = backend.setImage(id, data: data)
    isPaused = false
    return ok
  }

  /// Registers a font with the core; `"*"` is the fallback family.
  @discardableResult
  public func registerFont(id: String, data: Data) -> Bool {
    let ok = ClayzoDocument.registerFont(id: id, data: data)
    isPaused = false
    return ok
  }

  /// Sets a declared input — a slider, a value from the network, anything
  /// that is not the pointer — and redraws.
  @discardableResult
  public func setInput(_ name: String, _ value: ClayzoDocument.InputValue) -> Bool {
    let ok = document?.setInput(name, value) ?? false
    isPaused = false
    return ok
  }

  /// Fires a momentary input and redraws.
  @discardableResult
  public func fire(_ name: String) -> Bool {
    let ok = document?.fire(name) ?? false
    isPaused = false
    return ok
  }

  /* -------------------- pointer -------------------- */

  /// Feeds a pointer sample in view coordinates. Touches and the mouse call
  /// this; a host with its own gesture recognisers can too.
  public func setPointer(at point: CGPoint, inside: Bool, down: Bool) {
    guard let document, interactive, isInteractionEnabled else { return }
    let size = bounds.size
    guard size.width > 0, size.height > 0 else { return }
    let x = Double(point.x / size.width) * document.info.canvas.width
    let y = Double(point.y / size.height) * document.info.canvas.height
    let sample = Sample(x: x, y: y, inside: inside, down: down)
    if let last = pending.last, last.inside == inside, last.down == down {
      pending[pending.count - 1] = sample
    } else {
      pending.append(sample)
    }
    isPaused = false
  }

  /// The pointer lifted: still inside for one frame (the click), gone the next.
  private func lift(at point: CGPoint) {
    setPointer(at: point, inside: true, down: false)
    setPointer(at: point, inside: false, down: false)
  }

  #if os(iOS)
  public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    setPointer(at: touch.location(in: self), inside: true, down: true)
  }
  public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    setPointer(at: touch.location(in: self), inside: true, down: true)
  }
  public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    lift(at: touch.location(in: self))
  }
  public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    // Cancelled by the system, not lifted by the user: no click, just gone.
    setPointer(at: touch.location(in: self), inside: false, down: false)
  }
  #elseif os(macOS)
  private var tracking: NSTrackingArea?
  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }
  private func location(_ event: NSEvent) -> CGPoint {
    var point = convert(event.locationInWindow, from: nil)
    if !isFlipped { point.y = bounds.height - point.y }
    return point
  }
  public override func mouseMoved(with event: NSEvent) { setPointer(at: location(event), inside: true, down: false) }
  public override func mouseDragged(with event: NSEvent) { setPointer(at: location(event), inside: true, down: true) }
  public override func mouseEntered(with event: NSEvent) { setPointer(at: location(event), inside: true, down: false) }
  public override func mouseExited(with event: NSEvent) { setPointer(at: location(event), inside: false, down: false) }
  public override func mouseDown(with event: NSEvent) { setPointer(at: location(event), inside: true, down: true) }
  public override func mouseUp(with event: NSEvent) { setPointer(at: location(event), inside: true, down: false) }
  public override var acceptsFirstResponder: Bool { true }
  #endif

  /* -------------------- frames -------------------- */

  public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  public func draw(in view: MTKView) {
    guard let document, let drawable = currentDrawable else { return }
    let now = CACurrentMediaTime()
    // Clamped: a view that was off screen for a minute resumes where it
    // paused rather than teleporting the playhead.
    let elapsed = min(now - (lastFrameAt ?? now), 0.25)
    if isPlaying {
      let next = tick + elapsed * document.info.timing.ticksPerSecond
      let duration = max(1, document.info.timing.durationTicks)
      tick = loops ? next.truncatingRemainder(dividingBy: duration) : min(next, duration - 1)
    }
    lastFrameAt = now

    let texture = drawable.texture
    let scale = SIMD2(Double(texture.width) / document.info.canvas.width, Double(texture.height) / document.info.canvas.height)
    if interactive, !pending.isEmpty {
      pointer = pending.removeFirst()
      document.setPointer(x: pointer.x, y: pointer.y, inside: pointer.inside, down: pointer.down)
    }
    // The core evaluates whole ticks only (a plan at 1058.3 is refused, not
    // rounded), so the playhead is a real number and the frame is its floor.
    let whole = tick.rounded(.down)
    let evaluate = { (bounds: Bool) -> PackedFrame? in
      self.interactive
        ? document.interactiveFrame(tick: whole, scale: scale, bounds: bounds, deltaSeconds: elapsed)
        : document.frame(tick: whole, scale: scale, bounds: bounds)
    }
    guard var frame = evaluate(needsBounds) else { return }
    if !needsBounds && frame.metadata.effects.contains(where: { $0 == "glass" || $0 == "refraction" }) {
      needsBounds = true
      // Re-evaluating an interactive frame would step its dynamics twice;
      // the first bounded frame simply arrives one frame late.
      if !interactive, let bounded = evaluate(true) { frame = bounded }
    }
    guard let commandBuffer = queue.makeCommandBuffer() else { return }
    lastStats = backend.render(frame, into: texture, commandBuffer: commandBuffer)
    commandBuffer.present(drawable)
    commandBuffer.commit()

    if let events = frame.metadata.events, let onInteractionEvent {
      for event in events { onInteractionEvent(event) }
    }
    // A paused document keeps drawing while samples wait or springs move.
    if !isPlaying && pending.isEmpty && (frame.metadata.settled ?? true) { isPaused = true }
  }
}

#if canImport(SwiftUI)
import SwiftUI

/// A document playing in SwiftUI, sized to the document's aspect ratio.
///
///     ClayzoPlayer(document: document, images: ["hero": heroJPEG])
///       .onInteractionEvent { event in ... }
///
/// Fonts are process-wide: register them once with
/// `ClayzoDocument.registerFont` before the first frame.
public struct ClayzoPlayer: View {
  let document: ClayzoDocument
  let images: [String: Data]
  let isPlaying: Bool
  var onEvent: ((InteractionEvent) -> Void)?

  public init(document: ClayzoDocument, images: [String: Data] = [:], isPlaying: Bool = true) {
    self.document = document
    self.images = images
    self.isPlaying = isPlaying
  }

  /// A bundle's document with its images; fonts are registered on the way in.
  public init(bundle: ClayzoBundle, isPlaying: Bool = true) throws {
    self.init(document: try ClayzoDocument(bundle: bundle), images: bundle.images, isPlaying: isPlaying)
  }

  /// Receives hit-area events (enter, leave, down, up, click).
  public func onInteractionEvent(_ handler: @escaping (InteractionEvent) -> Void) -> ClayzoPlayer {
    var copy = self
    copy.onEvent = handler
    return copy
  }

  public var body: some View {
    PlayerRepresentable(document: document, images: images, isPlaying: isPlaying, onEvent: onEvent)
      .aspectRatio(document.info.canvas.width / max(document.info.canvas.height, 1), contentMode: .fit)
  }
}

#if os(iOS)
private struct PlayerRepresentable: UIViewRepresentable {
  let document: ClayzoDocument
  let images: [String: Data]
  let isPlaying: Bool
  let onEvent: ((InteractionEvent) -> Void)?

  func makeUIView(context: Context) -> ClayzoPlayerView {
    let view = try! ClayzoPlayerView.make()
    for (id, data) in images { view.setImage(id, data: data) }
    view.document = document
    return view
  }

  func updateUIView(_ view: ClayzoPlayerView, context: Context) {
    if view.document !== document { view.document = document }
    view.isPlaying = isPlaying
    view.onInteractionEvent = onEvent
  }
}
#elseif os(macOS)
private struct PlayerRepresentable: NSViewRepresentable {
  let document: ClayzoDocument
  let images: [String: Data]
  let isPlaying: Bool
  let onEvent: ((InteractionEvent) -> Void)?

  func makeNSView(context: Context) -> ClayzoPlayerView {
    let view = try! ClayzoPlayerView.make()
    for (id, data) in images { view.setImage(id, data: data) }
    view.document = document
    return view
  }

  func updateNSView(_ view: ClayzoPlayerView, context: Context) {
    if view.document !== document { view.document = document }
    view.isPlaying = isPlaying
    view.onInteractionEvent = onEvent
  }
}
#endif
#endif
