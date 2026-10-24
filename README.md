# Clayzo for iOS and macOS

Play Clayzo animations natively in Swift apps.

| | |
|---|---|
| Platforms | iOS 16+, macOS 13+ (Apple silicon) |
| Xcode | 16 or later |
| Adds to an app | about 1.4 MB |

## Install

In Xcode, choose File → Add Package Dependencies and enter
`https://github.com/Clayzo/clayzo-swift`, or in a `Package.swift`:

```swift
.package(url: "https://github.com/Clayzo/clayzo-swift.git", from: "0.3.19")
// target dependency: .product(name: "Clayzo", package: "clayzo-swift")
```

## Use

```swift
import Clayzo

// Load once, outside a SwiftUI `body`: a new document starts the player over.
let bundle = try ClayzoBundle(contentsOf: url)
let document = try ClayzoDocument(bundle: bundle)

// SwiftUI
ClayzoPlayer(document: document, images: bundle.images, audio: bundle.audio)

// UIKit / AppKit
let view = try ClayzoPlayerView.make(frame: bounds)
try view.load(bundle)
```

`isPlaying`, `loops` and `tick` control playback. In SwiftUI, `label:` describes
the animation to VoiceOver (`decorative: true` hides it instead), and
`.placeholder { … }` shows until the first frame is drawn. With Reduce Motion
on, nothing animates: a still frame holds, and a document's states still
follow touches, each shown at its last frame.

### States

A document with a state machine plays one state at a time, such as idle,
hover, pressed, loading and done. Touches, inputs and `setState` move it
between states.

```swift
struct UploadButton: View {
  let document: ClayzoDocument   // loaded once, as above
  let isLoading: Bool

  var body: some View {
    ClayzoPlayer(document: document, inputs: ["loading": .boolean(isLoading)], state: "idle")
      .onStateChange { change in print(change.from.name, "→", change.to.name) }
  }
}

view.setState("done")
view.currentState   // its id and name
```

`state` moves the machine when its value changes. `onComplete` reports a state
that plays once reaching its end.

### Interaction

```swift
view.onInteractionEvent = { event in print(event.kind, event.hitAreaId) }
view.setInput("reach", .number(0.8))
view.fire("pulse")
```

### Audio

The player starts muted. Turn sound on from your own control:

```swift
view.isMuted = false
ClayzoPlayer(document: document, audio: bundle.audio, isMuted: false)
```

`hasAudio` says whether the document has any.

## License

The Clayzo SDK License; see `LICENSE.md`.
