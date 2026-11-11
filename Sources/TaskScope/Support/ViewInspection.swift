import Combine

/// Lets a test inspect a view while SwiftUI has it installed, so flows driven
/// by `@State`, `@FocusState` or the environment can be tested (L15-6). The
/// view forwards `notice` to `visit(_:_:)`; the tests' inspection library sends
/// the notices. Nothing in the app sends one, so in the app this does nothing.
@MainActor
final class Inspection<V> {
    let notice = PassthroughSubject<UInt, Never>()
    var callbacks: [UInt: (V) -> Void] = [:]

    func visit(_ view: V, _ line: UInt) {
        if let callback = callbacks.removeValue(forKey: line) {
            callback(view)
        }
    }
}
