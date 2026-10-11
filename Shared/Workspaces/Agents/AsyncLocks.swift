import Foundation

/// A first-in, first-out lock per key, for code that awaits while it holds the lock. Two writes to
/// the same agent branch must not interleave their read, plan and commit steps.
@MainActor
final class AsyncLocks {
    private var held: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    func run<T>(_ key: String, _ body: () async throws -> T) async rethrows -> T {
        if held.contains(key) {
            await withCheckedContinuation { waiting[key, default: []].append($0) }
        } else {
            held.insert(key)
        }
        defer { release(key) }
        return try await body()
    }

    /// Hands the lock to the next waiter, or frees it.
    private func release(_ key: String) {
        guard var queue = waiting[key], !queue.isEmpty else {
            held.remove(key)
            return
        }
        let next = queue.removeFirst()
        waiting[key] = queue.isEmpty ? nil : queue
        next.resume()
    }
}
