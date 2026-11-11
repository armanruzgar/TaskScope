import Foundation

/// Per-second network and disk rates from the cumulative counters of
/// consecutive inventories, averaged over the time between them. A process's
/// first sample has no rate. Samples closer together than `minimumInterval`
/// (a read shared from the inventory cache, or a second read right after the
/// first) keep the previous rates rather than dividing by almost nothing.
struct ProcessIORateTracker {
    var minimumInterval: TimeInterval = 1

    private struct Baseline {
        var values: (Double, Double)
        var time: Date
    }

    private var network: [ProcessIdentity: Baseline] = [:]
    private var disk: [ProcessIdentity: Baseline] = [:]
    private var networkRates: [ProcessIdentity: (Double, Double)] = [:]
    private var diskRates: [ProcessIdentity: (Double, Double)] = [:]

    mutating func apply(to inventory: [AppProcess], at time: Date) -> [AppProcess] {
        var result = inventory
        var live = Set<ProcessIdentity>()
        for index in result.indices {
            let identity = result[index].identity
            live.insert(identity)
            let net = Self.pair(result[index].netInKB, result[index].netOutKB)
            let rates = Self.update(&network, &networkRates, identity, net, time, minimumInterval)
            result[index].netInRateKBps = rates?.0
            result[index].netOutRateKBps = rates?.1
            let io = Self.pair(result[index].diskReadBytes, result[index].diskWriteBytes)
            let diskRate = Self.update(&disk, &diskRates, identity, io, time, minimumInterval)
            result[index].diskReadRateBytesPerSecond = diskRate?.0
            result[index].diskWriteRateBytesPerSecond = diskRate?.1
        }
        network = network.filter { live.contains($0.key) }
        disk = disk.filter { live.contains($0.key) }
        networkRates = networkRates.filter { live.contains($0.key) }
        diskRates = diskRates.filter { live.contains($0.key) }
        return result
    }

    private static func pair(_ first: Double?, _ second: Double?) -> (Double, Double)? {
        guard let first, let second else { return nil }
        return (first, second)
    }

    /// The rates for one counter pair, updating its baseline.
    private static func update(
        _ baselines: inout [ProcessIdentity: Baseline],
        _ rates: inout [ProcessIdentity: (Double, Double)],
        _ identity: ProcessIdentity,
        _ values: (Double, Double)?,
        _ time: Date,
        _ minimumInterval: TimeInterval
    ) -> (Double, Double)? {
        guard let values else {
            // No counters in this read: nothing to show, but the baseline stays
            // for the next read that has them.
            return nil
        }
        guard let baseline = baselines[identity] else {
            baselines[identity] = Baseline(values: values, time: time)
            rates[identity] = nil
            return nil
        }
        let interval = time.timeIntervalSince(baseline.time)
        guard interval >= 0 else {
            // The clock went back: start again from this sample.
            baselines[identity] = Baseline(values: values, time: time)
            rates[identity] = nil
            return nil
        }
        guard interval >= minimumInterval else { return rates[identity] }
        baselines[identity] = Baseline(values: values, time: time)
        let first = values.0 - baseline.values.0
        let second = values.1 - baseline.values.1
        guard first >= 0, second >= 0 else {
            // A counter went backwards: the old sample says nothing about now.
            rates[identity] = nil
            return nil
        }
        let rate = (first / interval, second / interval)
        rates[identity] = rate
        return rate
    }
}
