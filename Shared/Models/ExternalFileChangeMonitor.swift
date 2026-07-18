import Foundation

/// Watches one document's on-disk file for changes made outside Fen's own coordinated save path
/// (issue #20). `NSFilePresenter`'s contract is what makes this distinction possible: it is not
/// notified of a change made through its own coordinated write, only of changes coordinated (or
/// made) by someone else -- exactly the "was this my own save" question a raw file-system watcher
/// would otherwise have to answer by hand.
public final class ExternalFileChangeMonitor: NSObject, NSFilePresenter, @unchecked Sendable {
    public let presentedItemURL: URL?
    public let presentedItemOperationQueue: OperationQueue = .main

    private let onExternalChange: () -> Void
    private let onExternalDeletion: () -> Void

    /// Registers a new presenter for `fileURL` immediately -- call `stop()` when the document
    /// closes or its `fileURL` changes, or this presenter (and the file coordination machinery
    /// backing it) leaks for the process lifetime.
    public init(
        fileURL: URL,
        onExternalChange: @escaping () -> Void,
        onExternalDeletion: @escaping () -> Void
    ) {
        presentedItemURL = fileURL
        self.onExternalChange = onExternalChange
        self.onExternalDeletion = onExternalDeletion
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        // addFilePresenter registers asynchronously -- a change made immediately after this call
        // returns can otherwise race that registration and go unnoticed. A coordinated read
        // against this same presenter forces a round-trip through the coordination server,
        // which only completes once the presenter is actually registered.
        let coordinator = NSFileCoordinator(filePresenter: self)
        var error: NSError?
        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &error) { _ in }
    }

    public func stop() {
        NSFileCoordinator.removeFilePresenter(self)
    }

    public func presentedItemDidChange() {
        onExternalChange()
    }

    public func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        onExternalDeletion()
        completionHandler(nil)
    }
}
