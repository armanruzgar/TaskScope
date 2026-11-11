import Foundation

/// UserDefaults for tests. Each instance is its own in-memory domain and
/// nothing reaches cfprefsd, so test processes running at the same time cannot
/// overwrite each other's fixtures and no test leaves a preferences file
/// behind. Values are kept as the property-list copies cfprefsd would hand
/// back, and a value that is not a property list stops the test, as it would
/// stop the app. Not final, so a test can observe writes (Batch08FixTests).
class InMemoryUserDefaults: UserDefaults {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Any] = [:]
    }

    private let domainName: String
    private let storage = Storage()

    /// Reads this domain for code that takes a reader instead of a
    /// UserDefaults instance (WatchedPresetCatalog).
    var objectReader: @Sendable (String) -> Any? {
        let storage = storage
        return { key in storage.lock.withLock { storage.values[key] } }
    }

    override init?(suiteName: String?) {
        guard let suiteName else { return nil }
        domainName = suiteName
        super.init(suiteName: suiteName)
    }

    override func object(forKey defaultName: String) -> Any? {
        storage.lock.withLock { storage.values[defaultName] }
    }

    override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    override func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }

    override func bool(forKey defaultName: String) -> Bool {
        object(forKey: defaultName) as? Bool ?? false
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        let copy = value.map(Self.propertyListCopy)
        storage.lock.withLock { storage.values[defaultName] = copy }
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        set(value as Any, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        set(nil as Any?, forKey: defaultName)
    }

    override func dictionaryRepresentation() -> [String: Any] {
        storage.lock.withLock { storage.values }
    }

    override func persistentDomain(forName domainName: String) -> [String: Any]? {
        domainName == self.domainName ? dictionaryRepresentation() : nil
    }

    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        guard domainName == self.domainName else { return }
        let copy = domain.mapValues(Self.propertyListCopy)
        storage.lock.withLock { storage.values = copy }
    }

    override func removePersistentDomain(forName domainName: String) {
        guard domainName == self.domainName else { return }
        storage.lock.withLock { storage.values.removeAll() }
    }

    private static func propertyListCopy(_ value: Any) -> Any {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            return try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            preconditionFailure("UserDefaults can store only property-list values: \(error)")
        }
    }
}
