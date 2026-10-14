import Foundation
import WebKit
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Pictures of rendered blocks for Live Preview (issue #135, phase 3). A block renders once in an offscreen web
/// view, one at a time, and the picture is cached until the block, the width or the appearance changes. Inline
/// formulas that wait together render in one batch. A block that fails to render is remembered for a minute, so
/// its source stays visible and nothing retries on every keystroke. After that it may try again, in case the
/// failure was a timeout.
@MainActor
final class LivePreviewSnapshots {
    struct Key: Hashable {
        var kind: RenderedBlock.Kind
        var source: String
        /// A multiple of `widthStep`, so a small resize doesn't ask for a new picture.
        var width: Int
        var dark: Bool
        /// The preview settings the picture depends on, so a new style or custom CSS draws it again.
        var look: Int = 0
    }

    /// A rendered picture. `baseline` is the distance from its top to the text baseline, which only inline math has.
    struct Picture {
        var image: PlatformImage
        var baseline: CGFloat = 0
    }

    typealias Render = @MainActor (Key) async -> Picture?
    /// Renders several formulas in one go. The pictures come back in the order of the keys.
    typealias RenderBatch = @MainActor ([Key]) async -> [Picture?]

    static let widthStep: CGFloat = 40
    static let maxSourceLength = 20000
    /// Inline math is laid out at one fixed width, so a resize never asks for a new picture.
    static let inlineWidth = 800
    static let maxInlineLength = 500
    /// Most formulas drawn in one offscreen web view.
    static let maxBatch = 32

    /// Tests swap this for a stub.
    static var shared = LivePreviewSnapshots(
        kinds: { enabledKinds() },
        render: { key in await LivePreviewWebSnapshot.render(key, preferences: .shared) },
        renderFormulas: { keys in await LivePreviewWebSnapshot.renderFormulas(keys, preferences: .shared) }
    )

    /// Which kinds of block are drawn as pictures right now.
    let kinds: @MainActor () -> Set<RenderedBlock.Kind>
    private let render: Render
    private let renderBatch: RenderBatch
    private let limit: Int
    /// How many inline formulas stay cached. They are small, and a note can hold many.
    private let inlineLimit: Int
    private var cache: [Key: Picture] = [:]
    private var recent: [Key] = []
    private var failed: [Key: ContinuousClock.Instant] = [:]
    private let retryAfter: Duration
    private var queue: [Key] = []
    private var waiting: [Key: [ObjectIdentifier: @MainActor () -> Void]] = [:]
    private var isRunning = false

    init(
        limit: Int = 32, inlineLimit: Int = 512, retryAfter: Duration = .seconds(60),
        kinds: @escaping @MainActor () -> Set<RenderedBlock.Kind>, render: @escaping Render,
        renderFormulas: RenderBatch? = nil
    ) {
        self.retryAfter = retryAfter
        renderBatch = renderFormulas ?? { keys in
            var pictures: [Picture?] = []
            for key in keys {
                await pictures.append(render(key))
            }
            return pictures
        }
        self.limit = limit
        self.inlineLimit = inlineLimit
        self.kinds = kinds
        self.render = render
    }

    /// For renderers that draw only a picture.
    convenience init(
        limit: Int = 32, inlineLimit: Int = 512, retryAfter: Duration = .seconds(60),
        kinds: @escaping @MainActor () -> Set<RenderedBlock.Kind>,
        render: @escaping @MainActor (Key) async -> PlatformImage?
    ) {
        self.init(limit: limit, inlineLimit: inlineLimit, retryAfter: retryAfter, kinds: kinds) { key in
            await render(key).map { Picture(image: $0) }
        }
    }

    /// The kinds the preview settings turn on. A block whose renderer is off stays source, as in the preview.
    static func enabledKinds(_ preferences: Preferences = .shared) -> Set<RenderedBlock.Kind> {
        var kinds: Set<RenderedBlock.Kind> = []
        if preferences.htmlMermaid {
            kinds.insert(.mermaid)
        }
        if preferences.htmlMathJax {
            kinds.insert(.math)
            kinds.insert(.inlineMath)
        }
        if preferences.htmlGeoJSONMaps {
            kinds.insert(.map)
        }
        return kinds
    }

    /// The width a picture is rendered at for a column `columnWidth` wide: the column, rounded down to a step.
    static func pictureWidth(forColumn columnWidth: CGFloat) -> Int {
        Int(max((columnWidth / widthStep).rounded(.down), 4) * widthStep)
    }

    /// A number that changes when a preview setting that changes a picture changes.
    static func look(_ preferences: Preferences) -> Int {
        var hasher = Hasher()
        hasher.combine(preferences.htmlStyleName)
        hasher.combine(preferences.fontSize)
        hasher.combine(preferences.customCSSEnabled ? preferences.customCSS : "")
        return hasher.finalize()
    }

    /// The inline math delimiters to look for: none when math is off, `$ $` only when the preview reads them.
    static func mathDelimiters(
        _ kinds: Set<RenderedBlock.Kind>, preferences: Preferences = .shared
    ) -> LivePreviewEditing.MathDelimiters {
        guard kinds.contains(.inlineMath) else { return [] }
        return preferences.htmlMathJaxInlineDollar ? [.parentheses, .dollars] : .parentheses
    }

    /// The key of the formula `source`, delimiters included.
    static func key(
        forFormula source: String, background: PlatformColor, preferences: Preferences = .shared
    ) -> Key? {
        guard source.count <= maxInlineLength else { return nil }
        return Key(
            kind: .inlineMath,
            source: source,
            width: inlineWidth,
            dark: LivePreviewBlockStyle.luminance(of: background) < 0.5,
            look: look(preferences)
        )
    }

    static func key(
        for block: RenderedBlock, columnWidth: CGFloat, background: PlatformColor, preferences: Preferences = .shared
    ) -> Key? {
        guard block.source.count <= maxSourceLength else { return nil }
        return Key(
            kind: block.kind,
            source: block.source,
            width: pictureWidth(forColumn: columnWidth),
            dark: LivePreviewBlockStyle.luminance(of: background) < 0.5,
            look: look(preferences)
        )
    }

    func image(for key: Key) -> PlatformImage? {
        picture(for: key)?.image
    }

    func picture(for key: Key) -> Picture? {
        guard let picture = cache[key] else { return nil }
        recent.removeAll { $0 == key }
        recent.append(key)
        return picture
    }

    /// The newest picture of the same block at another width or look, with the same light or dark. It stands in
    /// while `key` renders, so a resize or a style change doesn't flash the source.
    func standIn(for key: Key) -> Picture? {
        guard let match = recent.last(where: {
            $0.kind == key.kind && $0.source == key.source && $0.dark == key.dark
        }) else { return nil }
        return cache[match]
    }

    /// The picture for `key` if there is one, or an older picture of the same source that stands in. A missing
    /// picture is requested, and `onReady` runs when it arrives. `nil` means the source stays as it is.
    func resolve(_ key: Key, owner: AnyObject, onReady: @escaping @MainActor () -> Void) -> Picture? {
        if let cached = picture(for: key) {
            return cached
        }
        request(key, owner: owner, onReady: onReady)
        return standIn(for: key)
    }

    /// Whether `key` failed lately. A failure older than `retryAfter` doesn't count.
    func hasFailed(_ key: Key) -> Bool {
        guard let when = failed[key] else { return false }
        if ContinuousClock.now - when >= retryAfter {
            failed[key] = nil
            return false
        }
        return true
    }

    /// Renders `key` unless it is cached, failed or already queued. `onReady` runs once when the picture is
    /// cached, and never for a failure. One callback per `owner` and key: asking again replaces the earlier one.
    func request(_ key: Key, owner: AnyObject, onReady: @escaping @MainActor () -> Void) {
        guard cache[key] == nil, !hasFailed(key) else { return }
        let isNew = waiting[key] == nil
        waiting[key, default: [:]][ObjectIdentifier(owner)] = onReady
        if isNew {
            queue.append(key)
            pump()
        }
    }

    private func pump() {
        guard !isRunning, !queue.isEmpty else { return }
        isRunning = true
        let key = queue.removeFirst()
        var batch = [key]
        if key.kind == .inlineMath {
            // Formulas with the same look share one web view.
            let mates = queue
                .filter { $0.kind == .inlineMath && $0.dark == key.dark && $0.look == key.look }
                .prefix(Self.maxBatch - 1)
            batch += mates
            queue.removeAll { mates.contains($0) }
        }
        let keys = batch
        Task { @MainActor in
            let pictures = await key.kind == .inlineMath ? await renderBatch(keys) : [render(key)]
            isRunning = false
            // One callback per owner, however many of its pictures arrived, so a batch restyles once.
            var callbacks: [ObjectIdentifier: @MainActor () -> Void] = [:]
            for (index, key) in keys.enumerated() {
                let owners = waiting.removeValue(forKey: key) ?? [:]
                if index < pictures.count, let picture = pictures[index],
                   picture.image.size.width > 0, picture.image.size.height > 0 {
                    cache[key] = picture
                    recent.append(key)
                    callbacks.merge(owners) { first, _ in first }
                } else {
                    failed[key] = .now
                }
            }
            evict(inline: key.kind == .inlineMath)
            for callback in callbacks.values {
                callback()
            }
            pump()
        }
    }

    /// Drops the oldest pictures of one class (blocks or formulas) beyond its limit.
    private func evict(inline: Bool) {
        let cap = inline ? inlineLimit : limit
        var count = recent.filter { ($0.kind == .inlineMath) == inline }.count
        while count > cap, let oldest = recent.firstIndex(where: { ($0.kind == .inlineMath) == inline }) {
            cache[recent.remove(at: oldest)] = nil
            count -= 1
        }
    }
}
