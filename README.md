# Fen

A native **Swift / SwiftUI** Markdown editor for macOS and iOS — fast, minimal, and built for Apple Silicon. Fen grew out of a full rewrite of [MacDown](https://github.com/MacDownApp/macdown), the beloved open-source Markdown editor for macOS.

> **Credit where it's due.** **[Tzu-ping Chung](https://github.com/uranusjr)** and contributors created MacDown, drawing inspiration from [Chen Luo](https://twitter.com/chenluois)'s [Mou](http://mouapp.com). Fen is an independent, affectionate rewrite — the original hasn't shipped an update in years, and Apple is winding down support for Intel-only apps. We keep every original copyright and the MIT License intact. This is *their* idea, rebuilt for the next decade of the Mac, growing into something new.

## Why Fen?

A fen is a wetland that feeds itself — nutrient-rich, self-sustaining, always growing. That's the idea: a place where your notes aren't just stored, they grow into something more connected and useful over time.

The original MacDown is Objective-C, built on Hoedown, CocoaPods, and an AppKit codebase that predates Apple Silicon. Fen gives you:

- **Pure Swift + SwiftUI**, with a cross-platform core (macOS and iOS share `FenCore`)
- **Apple Silicon native** — no Intel-era dependencies
- **Swift Package Manager** — no CocoaPods, no submodules
- **GitHub-Flavored Markdown** via Apple's [`swift-cmark`](https://github.com/apple/swift-cmark) — tables, task lists, strikethrough, autolinks, footnotes
- Live preview with editor↔preview scroll sync, syntax highlighting, MathJax, and Mermaid

It's a deliberately *modern* take, not a 1:1 port. We drop some legacy features on purpose — plug-ins, Homebrew subprocess integration, the older preference surface. And we're just getting started: check [ROADMAP.md](ROADMAP.md) for what's next, including turning your notes into a connected, searchable knowledge base.

## Install

Download the latest `Fen.app.zip` from the [Releases page](https://github.com/zoharbabin/fen/releases), unzip, and drag **Fen.app** to your Applications folder.

We sign every release with an Apple Developer ID and notarize it, so it opens without Gatekeeper warnings.

## Build from source

Requirements: macOS 15+ and a recent Xcode / Swift 6 toolchain.

```sh
git clone https://github.com/zoharbabin/fen.git
cd fen

swift build          # build the package
swift test           # run the test suite
swift run Fen        # launch the macOS app

./scripts/build-app.sh   # produce dist/Fen.app
```

See [RELEASING.md](RELEASING.md) for signing, notarization, and cutting a release.

## Project layout

```
Shared/        FenCore — cross-platform model, rendering, editor, preview
macOS/         macOS app target (DocumentGroup, menus, Settings)
iOS/           iOS app target
Tests/         Swift Testing test suite
UITests/       UI tests (xcodegen-generated project, see CONTRIBUTING.md)
scripts/       build-app.sh — assembles the .app bundle
```

## Contributing

Fen is open to contributions — see [CONTRIBUTING.md](CONTRIBUTING.md) for coding style and pull request guidelines.

## License

Fen ships under the **MIT License** ([LICENSE.md](LICENSE.md)), the same as the original MacDown. We keep the original copyright — `Copyright (c) 2014 Tzu-ping Chung` — alongside full license texts for every third-party component, in the `LICENSE/` directory.

These editor themes and CSS files come from [Mou](http://mouapp.com), courtesy of Chen Luo:

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
