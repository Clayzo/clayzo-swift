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
.package(url: "https://github.com/Clayzo/clayzo-swift.git", from: "0.3.16")
// target dependency: .product(name: "Clayzo", package: "clayzo-swift")
```

## Use

```swift
import Clayzo

let bundle = try ClayzoBundle(contentsOf: url)

// SwiftUI
ClayzoPlayer(bundle: bundle)

// UIKit / AppKit
let view = try ClayzoPlayerView.make(frame: bounds)
try view.load(bundle)
```

`isPlaying`, `loops` and `tick` control playback.

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
ClayzoPlayer(bundle: bundle, isMuted: false)
```

`hasAudio` says whether the document has any.

## License

The Clayzo SDK License; see `LICENSE.md`.
