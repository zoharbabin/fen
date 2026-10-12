import Foundation

/// Reports which paths changed under a workspace folder (issue #5).
///
/// - macOS: one FSEvents stream per workspace. Events are batched, then delivered as paths
///   relative to the folder. An empty path means "list the whole folder again".
/// - iOS: there is no live watch. `start()` does nothing, and the library refreshes when the
///   app returns to the foreground.
public final class WorkspaceChangeWatcher: @unchecked Sendable {
    private let root: URL
    private let latency: TimeInterval
    private let onChange: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "app.fen.workspace-watcher", qos: .utility)

    #if os(macOS)
        private var stream: FSEventStreamRef?
    #endif

    public init(root: URL, latency: TimeInterval = 0.3, onChange: @escaping @Sendable ([String]) -> Void) {
        self.root = PathGate.canonicalURL(of: root) ?? root
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    #if os(macOS)
        public static let isLive = true

        public func start() {
            queue.sync {
                guard stream == nil else { return }
                var context = FSEventStreamContext(
                    version: 0,
                    info: Unmanaged.passUnretained(self).toOpaque(),
                    retain: nil,
                    release: nil,
                    copyDescription: nil
                )
                let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                    guard let info else { return }
                    let watcher = Unmanaged<WorkspaceChangeWatcher>.fromOpaque(info).takeUnretainedValue()
                    let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                    let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
                    watcher.deliver(list, flags: flagList)
                }
                let created = FSEventStreamCreate(
                    nil,
                    callback,
                    &context,
                    [root.path] as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                    latency,
                    FSEventStreamCreateFlags(
                        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                            | kFSEventStreamCreateFlagWatchRoot
                    )
                )
                guard let created else { return }
                FSEventStreamSetDispatchQueue(created, queue)
                FSEventStreamStart(created)
                stream = created
            }
        }

        public func stop() {
            queue.sync {
                guard let current = stream else { return }
                FSEventStreamStop(current)
                FSEventStreamInvalidate(current)
                FSEventStreamRelease(current)
                stream = nil
            }
        }

        private func deliver(_ absolutePaths: [String], flags: [FSEventStreamEventFlags]) {
            let rescan = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                    | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            )
            if flags.contains(where: { $0 & rescan != 0 }) {
                onChange([""])
                return
            }
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            let relative = absolutePaths.compactMap { path -> String? in
                path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
            }
            if !relative.isEmpty {
                onChange(Array(Set(relative)).sorted())
            }
        }
    #else
        public static let isLive = false

        public func start() {}

        public func stop() {}
    #endif
}
