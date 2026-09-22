# @clayzo/ios — native playback on Apple platforms

The engine's Rust core as a static XCFramework, a Metal backend for its
draw-command stream, and a player view. No Skia, no WebView, no JavaScript.

| | |
|---|---|
| Adds to a stripped Release app | **~660 KB**: Rust core ≈ 425 KB, Swift backend + player ≈ 165 KB, metallib 67 KB. The same document set on the web costs 2.5 MB (CanvasKit) or 207 KB brotli (WebGL). |
| Release artifact | `ClayzoEngineCore.xcframework.zip`, 1.3 MB (iOS, simulator, macOS slices); Swift sources 180 KB |
| Frame cost, iPhone-Pro resolution, M4 Pro | core 0.07–1.4 ms · encode 0.05–0.7 ms · GPU 0.05–0.6 ms per frame; interactive documents add 0.1–3 ms of core (hit-testing compiles the render graph) |
| Fidelity vs CanvasKit | 0.05–1.1 mean channel Δ on every demo document (WebGL: 0.04–0.98); `font-coverage` 5.3 (glyph hinting) |
| Platforms | iOS 16+, macOS 13+ (Apple GPUs) |

## Use

```swift
import Clayzo

ClayzoDocument.registerFont(id: "*", data: manropeBytes)          // once, process-wide
let document = try ClayzoDocument(json: documentJSON)   // or ClayzoDocument(bundle:)

// SwiftUI — sized to the document's aspect ratio
ClayzoPlayer(document: document, images: ["hero": heroJPEG])

// UIKit / AppKit
let view = try ClayzoPlayerView.make(frame: bounds)
view.setImage("hero", data: heroJPEG)
view.document = document
```

`ClayzoPlayerView` is an `MTKView`; `document`, `isPlaying`, `loops` and `tick`
are the whole surface. `lastStats` reports draw calls, passes and anything the
frame asked for that could not be drawn (empty on every demo document).

### Interaction

A document's declared interactivity — pointer bindings, hit areas, springs,
inputs — runs in the core (`interactive.rs`, a port of the web runtime that
the differential gate holds bit-for-bit to it). The player feeds it touches:
a finger is the pointer, down while it rests on the view; the frame it lifts
on still counts as inside, so a tap on a hit area yields `enter, down, up,
click`, and it leaves on the frame after so `restOnLeave` bindings relax back.
While a finger is on an interactive document the view claims the touch, so a
drag drives the document rather than a navigation back-swipe or a scroll
view (`isInteractionEnabled = false` lets touches fall through).

```swift
view.onInteractionEvent = { event in print(event.kind, event.hitAreaId) }
view.setInput("reach", .number(0.8))     // declared inputs, clamped to their range
view.fire("pulse")                       // momentary trigger

ClayzoPlayer(document: document).onInteractionEvent { event in ... }
```

`MetalBackend` hosts with their own loop call `document.setPointer(...)` and
`document.interactiveFrame(tick:scale:deltaSeconds:)`; the packet's metadata
carries `events`, `settled` (nothing changed — safe to stop drawing) and
`cursor`.

The backend can also be driven directly — `MetalBackend.render(_:into:commandBuffer:)`
draws a `PackedFrame` into any colour texture — for hosts with their own
render loop.

## Shipping

**Install (consumers).** In Xcode, File → Add Package Dependencies →
`https://github.com/Clayzo/clayzo-swift`, or in a `Package.swift`:

```swift
.package(url: "https://github.com/Clayzo/clayzo-swift.git", from: "0.3.5")
// target dependency: .product(name: "Clayzo", package: "clayzo-swift")
```

Xcode fetches the Swift sources at the tag and the Rust core as a
checksum-verified XCFramework zip committed at that same tag. Nothing to run,
no Rust toolchain, no CocoaPods.

**Publish (us).** Automatic, the same way the npm packages ship. The release
gate (`security.yml`) builds the XCFramework, runs this package's tests on
macOS and compiles it for iOS on every PR and every push to `main`. When the
gate passes on `main`, `publish-swift.yml` reads the synchronized release
version, and if the package repository has no tag for it yet:

1. builds the stripped XCFramework zip and its checksum (`scripts/package-release.sh`);
2. mirrors `packages/ios` (minus build products and the example app) plus the
   zip into `Clayzo/clayzo-swift`, with `Package.swift`'s binary target
   pointed at the zip's raw URL at the tag and its checksum;
3. commits and tags `v<version>` over the repository's write deploy key;
4. resolves the published package from a scratch consumer to prove the install works.

So merging `staging → main` publishes the Swift package alongside the npm
ones, at the same version. The pieces outside this repository: the public
`Clayzo/clayzo-swift` repository with a write deploy key, whose private half
is the `CLAYZO_SWIFT_DEPLOY_KEY` secret in this repository's `swift-release`
environment (the same shape as the agent-skills publish). The package
repository's name is the `SWIFT_REPOSITORY` variable at the top of the
workflow.

To reproduce a release by hand: `scripts/package-release.sh <zip-url>` writes
`dist/` with the zip, its checksum and the release `Package.swift`.

**The content.** Ship documents as `.clayzo` bundles — the file the engine's
`packageClayzoBundle` / CLI produce, one zip with the document, its images and
its fonts, the same file the web players load. Bundle them as app resources
or fetch them from a CDN; `ClayzoBundle` opens one, `ClayzoPlayerView.load(_:)`
or `ClayzoPlayer(bundle:)` plays it. A bare document `.json` works too when it
has no assets. Fonts are registered process-wide once; documents that only
name a family fall back to the `"*"` face.

```swift
let bundle = try ClayzoBundle(contentsOf: url)          // fonts + images + document
ClayzoPlayer(bundle: bundle)                            // SwiftUI
try playerView.load(bundle)                             // UIKit / AppKit
```

## Build

```bash
scripts/build-xcframework.sh   # Rust core → ClayzoEngineCore.xcframework (iOS, simulator, macOS)
swift test                     # macOS: core round trip, translator, offscreen Metal render
```

The XCFramework is gitignored; the script is the source of truth. It needs the
rustup toolchain (`~/.cargo/bin` ahead of Homebrew) and Xcode's Metal
toolchain (`xcodebuild -downloadComponent MetalToolchain`). Under `~/Documents`
codesign trips on provenance xattrs: `xattr -cr .` before `swift test`.

`Example/` holds a demo app (`xcodegen generate` there, then build the
`ClayzoExample` scheme) that plays the demo documents with a live cost readout.

## Fidelity

```bash
cd ../animation-engine && npx tsx ../ios/tools/reference-frames.mts --ticks 2   # CanvasKit references
cd ../ios && swift run -c release clayzo-fidelity                                # Metal vs reference
swift run -c release clayzo-fidelity --bench                                     # per-frame cost
```

The harness renders every demo document offscreen and reports the same metrics
the repo's WebGL parity gate does, writing `candidate.png` and `diff.png`
beside each reference under `.reference/`.

## How it draws

The Rust core evaluates the document into a flat draw-command stream
(`render_frame`); the backend only interprets that. It is the WebGL2 backend's
design — analytic coverage for rects and ellipses, stencil-then-cover on a 4×
multisampled target for paths and glyphs, three-box blurs, SkSL effects
translated at runtime — with the parts a tile-based GPU rewards done
differently:

- Layers, effects and mattes are found in a pre-pass and rendered
  depth-first, so every render target is opened exactly once and the root
  pass keeps its samples and stencil in tile memory (`memoryless`). Only a
  glass or refraction effect, which reads what is behind it, splits a pass.
- Advanced blend modes read the destination through the tile (`[[color(0)]]`)
  instead of snapshotting it.
- Gradients are evaluated from their stops in the shader; analytic clips
  antialias through the sample mask.
- SkSL → MSL is a small translator (`SkSLTranslator.swift`): uniforms and
  child shaders become members of a struct the shader's functions are methods
  of, `X.eval(p)` samples with bounds clamping, `toLinearSrgb`/`fromLinearSrgb`
  are the sRGB curves (every surface here is 8-bit sRGB). Hand-written
  `custom-sksl` documents run unchanged.

## Known differences from CanvasKit

- **Text**: Skia hints and pixel-snaps glyphs; the core emits outlines, so
  stems land up to a pixel apart on long lines. Same on WebGL.
- **Minified images**: both sample linear/no-mip, so a 10× downscale is
  sub-texel sensitive, and ImageIO's JPEG decode differs from libjpeg-turbo by
  a level or two.
- **Not yet**: Lottie nodes, layer folding and the packed frame cache the
  WebGL player uses on loops, multi-touch (the first finger is the pointer),
  a cheaper hit-test path than compiling the whole render graph, and per-family
  font selection (the core keeps one fallback face; a bundle with several
  font families gets the first as `"*"`).

## Documents and render scale

A `custom-sksl` shader receives `p` and its point parameters in device pixels
and its number parameters as authored. A shader that mixes the two only looks
right at one render scale — `electric-water` did, and its arcs shrank into the
body on a 3× phone. The fix is in the document, not the renderer: declare a
`{1, 1}` point parameter (it arrives as the device scale) and divide the
device-space inputs by it, as `sploosh` and now `electric-water` do. Both
renderers agree with each other at every scale; a document that changes with
scale changes in CanvasKit too.
