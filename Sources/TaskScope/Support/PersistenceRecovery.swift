import Foundation

enum PersistenceRecovery {
    /// Number of recovery slots per base key: `<base>`, `<base>.2`, … .
    static let maximumBackupSlots = 10

    /// Preserves `data` without ever replacing an earlier backup. The first
    /// slot keeps the oldest payload; a later, different payload goes to the
    /// next free numbered slot so a second corruption is not lost on reset.
    /// Returns the slot that holds these exact bytes, or nil when every slot is
    /// occupied by other payloads and nothing could be preserved.
    static func preserveBackup(
        _ data: Data,
        in userDefaults: UserDefaults,
        baseKey: String
    ) -> String? {
        var firstFreeKey: String?
        for slot in 1...maximumBackupSlots {
            let key = slot == 1 ? baseKey : "\(baseKey).\(slot)"
            guard let existing = userDefaults.object(forKey: key) else {
                if firstFreeKey == nil { firstFreeKey = key }
                continue
            }
            if let existing = existing as? Data, existing == data { return key }
        }
        guard let firstFreeKey else { return nil }
        userDefaults.set(data, forKey: firstFreeKey)
        return firstFreeKey
    }

    static func unreadableDataMessage(backupKey: String, isPreserved: Bool) -> String {
        isPreserved
            ? "Unreadable data was backed up as \(backupKey)."
            : "Unreadable data was not backed up: every recovery slot starting at \(backupKey) already preserves an earlier payload, and the current payload remains at its primary key."
    }

    static func preservedPayloadDescription(backupKey: String, isPreserved: Bool) -> String {
        isPreserved
            ? "The payload is preserved as \(backupKey)"
            : "The payload could not be backed up because every recovery slot starting at \(backupKey) is occupied"
    }
}

struct PartiallyDecodedArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var rejectedCount = 0

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            let elementDecoder = try container.superDecoder()
            do {
                elements.append(try Element(from: elementDecoder))
            } catch {
                rejectedCount += 1
            }
        }
    }
}

struct RecoveringCodableStorage<Value: Codable> {
    struct LoadOutcome {
        var value: Value?
        var backupKey: String?
        /// True when a recovery slot holds these exact bytes, whether this load
        /// wrote it or an earlier launch did. False with a non-nil `backupKey`
        /// means every slot was occupied by other payloads.
        var isBackupPreserved: Bool
        var rejectedCount = 0
        /// The value decoded, but the payload also holds JSON this build cannot
        /// parse back (an unknown field with a number such as 1e400 or a lone
        /// surrogate), so a save could not keep it. Stores apply the value but
        /// stay read-only; the bytes are backed up as for an unreadable payload.
        var isDecodedButUnrewritable = false

        /// The second half of a store's recovery message for such a payload.
        var unrewritableDataDescription: String? {
            guard isDecodedButUnrewritable, let backupKey else { return nil }
            return "contains a value this build cannot write back without losing it. "
                + PersistenceRecovery.preservedPayloadDescription(backupKey: backupKey, isPreserved: isBackupPreserved)
                + "; reset to rewrite only the fields this build knows."
        }
    }

    private let snapshot = StoredJSONSnapshot()
    let userDefaults: UserDefaults
    let key: String

    func load(
        decode: (Data) throws -> Value = { try JSONDecoder().decode(Value.self, from: $0) }
    ) -> LoadOutcome {
        guard let object = userDefaults.object(forKey: key) else {
            return LoadOutcome(value: nil, backupKey: nil, isBackupPreserved: false)
        }
        guard let data = object as? Data else {
            // A present property-list object of another type is unreadable, not
            // an absent preference. Archive its value before allowing a reset.
            return unreadableOutcome(data: archivedPayload(object))
        }
        do {
            let value = try decodeAndRemember(data, decode: decode)
            guard snapshot.raw != nil else {
                // JSONDecoder skips the values of keys it does not decode, while
                // the raw snapshot must parse all of them. Keep the readable value
                // instead of discarding it as corrupt, but back the bytes up: a
                // save would silently drop the field the snapshot could not hold.
                var outcome = unreadableOutcome(data: data)
                outcome.value = value
                outcome.isDecodedButUnrewritable = true
                return outcome
            }
            return LoadOutcome(value: value, backupKey: nil, isBackupPreserved: false)
        } catch {
            return unreadableOutcome(data: data)
        }
    }

    private func unreadableOutcome(data: Data?) -> LoadOutcome {
        let baseKey = "\(key).corruptBackup"
        let preservedKey = data.flatMap {
            PersistenceRecovery.preserveBackup($0, in: userDefaults, baseKey: baseKey)
        }
        return LoadOutcome(value: nil, backupKey: preservedKey ?? baseKey,
                           isBackupPreserved: preservedKey != nil)
    }

    private func archivedPayload(_ object: Any) -> Data? {
        if let data = object as? Data { return data }
        return try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    func loadRecoveringElements<Element: Codable>() -> LoadOutcome where Value == [Element] {
        var rejectedCount = 0
        var outcome = load { data in
            let decoded = try JSONDecoder().decode(PartiallyDecodedArray<Element>.self, from: data)
            rejectedCount = decoded.rejectedCount
            return decoded.elements
        }
        outcome.rejectedCount = rejectedCount
        if rejectedCount > 0, let array = snapshot.raw as? [Any] {
            snapshot.raw = array.filter { element in
                guard let data = try? JSONSerialization.data(withJSONObject: element, options: .fragmentsAllowed) else {
                    return false
                }
                return (try? JSONDecoder().decode(Element.self, from: data)) != nil
            }
        }
        return outcome
    }

    private func decodeAndRemember(_ data: Data, decode: (Data) throws -> Value) throws -> Value {
        let value = try decode(data)
        snapshot.raw = try? JSONSerialization.jsonObject(with: data)
        snapshot.baseline = snapshot.raw == nil
            ? nil : try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return value
    }

    /// The JSON a save of `value` would write: this build's changes merged into
    /// the stored payload, so fields this build does not model are kept.
    func mergedJSONObject(_ value: Value) throws -> Any {
        let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return StoredJSONSnapshot.merge(raw: snapshot.raw, baseline: snapshot.baseline, current: current)
    }

    /// Apply only changes this build made to the decoded value. Unknown fields
    /// and values that decoded to a fallback keep their original JSON shape.
    @discardableResult
    func savePreservingUnknownFields(_ value: Value) -> Bool {
        guard let encoded = try? JSONEncoder().encode(value),
              let current = try? JSONSerialization.jsonObject(with: encoded) else { return false }
        let merged = StoredJSONSnapshot.merge(raw: snapshot.raw, baseline: snapshot.baseline, current: current)
        guard let data = try? JSONSerialization.data(withJSONObject: merged) else { return false }
        userDefaults.set(data, forKey: key)
        snapshot.raw = merged
        snapshot.baseline = current
        return true
    }

    var hasStoredValue: Bool {
        userDefaults.object(forKey: key) != nil
    }

    var rawData: Data? {
        userDefaults.data(forKey: key)
    }

    @discardableResult
    func save(_ value: Value) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        userDefaults.set(data, forKey: key)
        return true
    }

    func preserveCurrentPayload(suffix: String) -> (key: String, isPreserved: Bool)? {
        guard let object = userDefaults.object(forKey: key),
              let data = archivedPayload(object) else { return nil }
        let baseKey = "\(key).\(suffix)"
        let preservedKey = PersistenceRecovery.preserveBackup(data, in: userDefaults, baseKey: baseKey)
        return (preservedKey ?? baseKey, preservedKey != nil)
    }
}

/// The baseline and raw arrays have the same order, including entries whose
/// legacy decoder supplied an ID. Later saves match those entries by that ID.
private final class StoredJSONSnapshot {
    var raw: Any?
    var baseline: Any?

    static func merge(raw: Any?, baseline: Any?, current: Any) -> Any {
        guard let raw, let baseline else { return current }
        if let old = baseline as? NSObject, old.isEqual(current) { return raw }
        if let old = baseline as? [String: Any],
           let new = current as? [String: Any],
           var result = raw as? [String: Any] {
            for key in Set(old.keys).union(new.keys) {
                if let value = new[key] {
                    result[key] = merge(raw: result[key], baseline: old[key], current: value)
                } else {
                    result.removeValue(forKey: key)
                }
            }
            return result
        }
        if let old = baseline as? [Any], let new = current as? [Any], let stored = raw as? [Any] {
            var used: Set<Int> = []
            return new.map { value in
                guard let identity = identity(value),
                      let index = old.indices.first(where: {
                          !used.contains($0) && self.identity(old[$0]) == identity
                      }), stored.indices.contains(index) else { return value }
                used.insert(index)
                return merge(raw: stored[index], baseline: old[index], current: value)
            }
        }
        return current
    }

    private static func identity(_ value: Any) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        if let id = object["id"] as? String { return "id:" + id }
        if let label = object["label"] as? String { return "label:" + label }
        if let pid = object["pid"] as? Int, let command = object["command"] as? String {
            return "process:\(pid):\(command)"
        }
        return nil
    }
}
