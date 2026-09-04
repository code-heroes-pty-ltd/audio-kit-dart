// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Every source file under `Sources/audio_flutter_darwin` imports
// `Flutter`/`FlutterMacOS`, so that target only compiles inside a Flutter
// build — and `swift test` builds every target a package declares, not just
// the ones its tests depend on. Setting AUDIO_FLUTTER_DARWIN_CORE_TESTS=1
// narrows the package to the Flutter-free core plus its XCTest target, which
// is the only way to run `swift test` here; `tool/verify.sh` is what sets it.
//
// No Flutter build and no CocoaPods build ever sets it (there is no podspec),
// so what an application resolves is the `audio-flutter-darwin` library
// product exactly as before, with the core linked into it.
let coreTestsOnly =
  ProcessInfo.processInfo.environment["AUDIO_FLUTTER_DARWIN_CORE_TESTS"] == "1"

/// Flutter-free decision logic the capture chains delegate to: the supervision
/// window math, the sample-rate re-rate math, and tap target selection. It
/// imports nothing beyond Foundation, AVFoundation, and CoreAudio, which is
/// what makes it testable on its own.
let core = Target.target(
  name: "AudioFlutterDarwinCore",
  dependencies: [],
  resources: []
)

let plugin = Target.target(
  name: "audio_flutter_darwin",
  dependencies: ["AudioFlutterDarwinCore"],
  resources: []
)

let coreTests = Target.testTarget(
  name: "AudioFlutterDarwinCoreTests",
  dependencies: ["AudioFlutterDarwinCore"]
)

let package = Package(
  name: "audio_flutter_darwin",
  platforms: [
    // The plugin shell, microphone capture, and playback support macOS 12.
    // Process-tap system audio remains runtime-gated to macOS 14.4 in the
    // implementation, so applications can launch on macOS 12/13.
    .macOS("12.0"),
  ],
  products: coreTestsOnly
    ? [
      .library(
        name: "audio-flutter-darwin-core",
        targets: ["AudioFlutterDarwinCore"]
      )
    ]
    : [
      .library(name: "audio-flutter-darwin", targets: ["audio_flutter_darwin"])
    ],
  dependencies: [],
  targets: coreTestsOnly ? [core, coreTests] : [core, plugin]
)
