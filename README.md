# MacDown (Swift)

A modern, native **Swift / SwiftUI rewrite** of [MacDown](https://github.com/MacDownApp/macdown), the open-source Markdown editor for macOS.

> **Credit where it's due.** MacDown was created by **[Tzu-ping Chung](https://github.com/uranusjr)** and contributors, who in turn took inspiration from [Chen Luo](https://twitter.com/chenluois)'s [Mou](http://mouapp.com). This project is an independent, affectionate rewrite — the original hasn't been updated in years, and Apple is winding down support for Intel-only apps. All original copyrights and the MIT License are preserved. This is *their* idea, rebuilt for the next decade of the Mac.

## Why a rewrite?

The original MacDown is Objective-C built on Hoedown, CocoaPods, and an AppKit codebase that predates Apple Silicon. This version is:

- **Pure Swift + SwiftUI**, cross-platform core (macOS and iOS share `MacDownCore`)
- **Apple Silicon native**, no Intel-era dependencies
- **Built with Swift Package Manager** — no CocoaPods, no submodules
- **GitHub-Flavored Markdown** via Apple's [`swift-cmark`](https://github.com/apple/swift-cmark) (tables, task lists, strikethrough, autolinks, footnotes)
- Live preview with editor↔preview scroll sync, Prism syntax highlighting, MathJax, and Mermaid

It is a deliberately *modern* take rather than a 1:1 port — some legacy features (plug-ins, Homebrew subprocess integration, the older preference surface) are intentionally dropped.

## Install

Download the latest `MacDown.app.zip` from the [Releases page](https://github.com/mfbergmann/macdown-swift/releases), unzip, and drag **MacDown.app** to your Applications folder.

Released builds are signed with an Apple Developer ID and notarized by Apple, so they open without Gatekeeper warnings.

## Build from source

Requirements: macOS 15+ and a recent Xcode / Swift 6 toolchain.

```sh
git clone https://github.com/mfbergmann/macdown-swift.git
cd macdown-swift

swift build          # build the package
swift test           # run the test suite
swift run MacDownSwift   # launch the macOS app

./scripts/build-app.sh   # produce dist/MacDown.app
```

See [RELEASING.md](RELEASING.md) for signing, notarization, and cutting a release.

## Project layout

```
Shared/        MacDownCore — cross-platform model, rendering, editor, preview
macOS/         macOS app target (DocumentGroup, menus, Settings)
iOS/           iOS app target
Tests/         Swift Testing test suite
scripts/       build-app.sh — assembles the .app bundle
```

## License

Released under the **MIT License**, the same as the original MacDown. The original
copyright — `Copyright (c) 2014 Tzu-ping Chung` — is preserved in
`LICENSE/macdown.txt`, alongside full license texts for all third-party
components in the `LICENSE/` directory.

The following editor themes and CSS files are extracted from [Mou](http://mouapp.com), courtesy of Chen Luo:

* Mou Fresh Air / Fresh Air+
* Mou Night / Night+
* Mou Paper / Paper+
* Tomorrow / Tomorrow Blue / Tomorrow+
* Writer / Writer+
* Clearness / Clearness Dark
* GitHub / GitHub2

## Acknowledgements

- **Tzu-ping Chung** and the MacDown contributors — for the original app this is built on.
- **Chen Luo** — for Mou, and the themes used here.
- [swift-cmark](https://github.com/apple/swift-cmark), [Highlightr](https://github.com/raspu/Highlightr), [Prism](https://prismjs.com), [MathJax](https://www.mathjax.org), and [Mermaid](https://mermaid.js.org).
