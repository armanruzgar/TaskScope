import Foundation

final class LifecycleTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0

    var now: TimeInterval { lock.withLock { elapsed } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { elapsed += seconds }
    }
}
