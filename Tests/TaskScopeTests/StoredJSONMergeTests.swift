import XCTest
@testable import TaskScope

/// `StoredJSONSnapshot.merge` keeps the fields a newer build wrote while this
/// build saves its own changes. It used to find each array element's stored
/// copy by scanning the stored array from the start; it now indexes the
/// stored array once.
final class StoredJSONMergeTests: XCTestCase {
    /// The indexed merge gives exactly the result of the scan it replaced, on
    /// payloads with repeated, missing and mixed identities, stored arrays
    /// shorter than the baseline, reordered and new elements, and nested arrays.
    func testIndexedMergeGivesTheSameResultAsTheScanItReplaced() throws {
        var generator = SeededGenerator(seed: 0x5EED_0F_A11_75)
        for round in 0..<400 {
            let baseline = Self.array(count: Int.random(in: 0...24, using: &generator), using: &generator)
            let raw = Self.stored(from: baseline, using: &generator)
            let current = Self.edited(baseline, using: &generator)
            let (rawJSON, baselineJSON, currentJSON) = try (Self.json(raw), Self.json(baseline), Self.json(current))

            let merged = StoredJSONSnapshot.merge(raw: rawJSON, baseline: baselineJSON, current: currentJSON)
            let expected = Self.scanningMerge(raw: rawJSON, baseline: baselineJSON, current: currentJSON)

            XCTAssertEqual(try Self.canonical(merged), try Self.canonical(expected), "round \(round)")
        }
    }

    /// The merge of a 10,000-event log identifies each element once: every
    /// stored element when the index is built and every current element when
    /// it is looked up. The scan identified, for each element, every unused
    /// stored element before its match, about 50 million times for a reversed
    /// log of this size. Every event keeps the field a newer build wrote.
    func testMergingTenThousandEventsIdentifiesEachElementOnce() throws {
        let count = 10_000
        let baseline: [[String: Any]] = (0..<count).map { index in
            [
                "id": UUID().uuidString,
                "timestamp": 700_000_000 + Double(index),
                "processName": "Example",
                "pid": 4_000 + index,
                "ruleID": "B0B0B0B0-0000-0000-0000-000000000000",
                "outcome": "logged",
                "detail": "Runtime threshold reached.",
            ]
        }
        let raw: [[String: Any]] = baseline.map { $0.merging(["futureField": "kept"]) { current, _ in current } }
        // Newest first, reversed: the order the scan handled worst.
        var current = Array(baseline.reversed())
        current[0]["detail"] = "Edited by this build."
        let (rawJSON, baselineJSON, currentJSON) = try (Self.json(raw), Self.json(baseline), Self.json(current))

        var identifications = 0
        let started = ContinuousClock.now
        let merged = StoredJSONSnapshot.merge(raw: rawJSON, baseline: baselineJSON, current: currentJSON) { value in
            identifications += 1
            return StoredJSONSnapshot.identity(of: value)
        }
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(identifications, 2 * count, "each stored and each current element is identified once")
        let events = try XCTUnwrap(merged as? [[String: Any]])
        XCTAssertEqual(events.count, count)
        XCTAssertTrue(events.allSatisfy { $0["futureField"] as? String == "kept" }, "no event loses the newer build's field")
        XCTAssertEqual(events.first?["detail"] as? String, "Edited by this build.")
        XCTAssertEqual(events.map { $0["id"] as? String }, current.map { $0["id"] as? String })
        // Measured in a debug build: about 0.04 s here, against 2.8 s for only
        // 2,000 reversed events with the scan (about 70 s for 10,000). The
        // limit leaves room for a slow machine and still catches quadratic work.
        XCTAssertLessThan(elapsed, .seconds(10), "merging \(count) events took \(elapsed)")
    }

    // MARK: - The replaced scan, kept as the reference

    private static func scanningMerge(raw: Any?, baseline: Any?, current: Any) -> Any {
        guard let raw, let baseline else { return current }
        if let old = baseline as? NSObject, old.isEqual(current) { return raw }
        if let old = baseline as? [String: Any],
           let new = current as? [String: Any],
           var result = raw as? [String: Any] {
            for key in Set(old.keys).union(new.keys) {
                if let value = new[key] {
                    result[key] = scanningMerge(raw: result[key], baseline: old[key], current: value)
                } else {
                    result.removeValue(forKey: key)
                }
            }
            return result
        }
        if let old = baseline as? [Any], let new = current as? [Any], let stored = raw as? [Any] {
            var used: Set<Int> = []
            return new.map { value in
                guard let identity = StoredJSONSnapshot.identity(of: value),
                      let index = old.indices.first(where: {
                          !used.contains($0) && StoredJSONSnapshot.identity(of: old[$0]) == identity
                      }), stored.indices.contains(index) else { return value }
                used.insert(index)
                return scanningMerge(raw: stored[index], baseline: old[index], current: value)
            }
        }
        return current
    }

    // MARK: - Payloads

    private static func element(using generator: inout SeededGenerator) -> Any {
        var object: [String: Any] = ["value": Int.random(in: 0...3, using: &generator)]
        switch Int.random(in: 0..<10, using: &generator) {
        case 0..<5: object["id"] = "id-\(Int.random(in: 0..<6, using: &generator))"
        case 5: object["label"] = "label-\(Int.random(in: 0..<3, using: &generator))"
        case 6:
            object["pid"] = Int.random(in: 1...3, using: &generator)
            object["command"] = "command-\(Int.random(in: 0..<2, using: &generator))"
        case 7: return Int.random(in: 0...9, using: &generator)
        default: break
        }
        if Int.random(in: 0..<4, using: &generator) == 0 {
            object["children"] = (0..<Int.random(in: 0...3, using: &generator)).map { child in
                ["id": "child-\(child % 2)", "value": Int.random(in: 0...2, using: &generator)] as [String: Any]
            }
        }
        return object
    }

    private static func array(count: Int, using generator: inout SeededGenerator) -> [Any] {
        (0..<count).map { _ in element(using: &generator) }
    }

    /// What a newer build stored: the baseline plus fields this build does not
    /// know, sometimes a different value, and sometimes fewer elements.
    private static func stored(from baseline: [Any], using generator: inout SeededGenerator) -> [Any] {
        var stored = baseline.map { element -> Any in
            guard var object = element as? [String: Any] else { return element }
            object["future"] = "kept-\(Int.random(in: 0...1, using: &generator))"
            if Int.random(in: 0..<5, using: &generator) == 0 { object["value"] = 99 }
            if var children = object["children"] as? [[String: Any]] {
                for index in children.indices { children[index]["future"] = "child-kept" }
                object["children"] = children
            }
            return object
        }
        if Int.random(in: 0..<4, using: &generator) == 0, !stored.isEmpty {
            stored.removeLast(Int.random(in: 1...stored.count, using: &generator))
        }
        return stored
    }

    /// What this build encodes now: the baseline shuffled, with edits,
    /// removals, repeats and new elements.
    private static func edited(_ baseline: [Any], using generator: inout SeededGenerator) -> [Any] {
        var current = baseline.shuffled(using: &generator).compactMap { element -> Any? in
            switch Int.random(in: 0..<8, using: &generator) {
            case 0: return nil
            case 1:
                guard var object = element as? [String: Any] else { return element }
                object["value"] = Int.random(in: 4...6, using: &generator)
                return object
            default: return element
            }
        }
        for _ in 0..<Int.random(in: 0...3, using: &generator) {
            current.insert(
                Bool.random(using: &generator) && !baseline.isEmpty
                    ? baseline[Int.random(in: 0..<baseline.count, using: &generator)]
                    : element(using: &generator),
                at: Int.random(in: 0...current.count, using: &generator)
            )
        }
        return current
    }

    /// The JSON objects a save works with, as `JSONSerialization` returns them.
    private static func json(_ value: Any) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value))
    }

    private static func canonical(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// A small deterministic generator (SplitMix64), so a failure reproduces.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
