import Foundation

/// CPU and memory history of every observed process, for the main window's
/// header charts. It lives as long as the app, so reopening the window shows
/// the samples still inside the time window; it samples only while a chart is
/// visible.
@MainActor
final class ProcessHistory: ObservableObject {
    typealias Sleeper = @Sendable (TimeInterval) async -> Bool

    struct Sample: Equatable {
        /// When the read finished; the charts place samples by it.
        var timestamp: Date
        /// The sum of %CPU over the observed processes (100 is one core).
        var observedProcessCPU: Double
        /// The sum of resident memory over the observed processes. Shared
        /// pages count once per process, so it can exceed physical memory.
        var observedProcessMemoryMB: Double
        /// How many processes the sums cover.
        var processCount: Int
        var startsNewSegment = false
    }

    enum SamplingState: Equatable {
        case paused
        case sampling
        case unavailable(String)

        var label: String {
            switch self {
            case .paused: "Paused"
            case .sampling: "Live"
            case .unavailable: "Unavailable"
            }
        }
    }

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var state: SamplingState = .paused
    /// The sampling interval the charts are read at, the watched-status interval.
    @Published private(set) var cadence: TimeInterval = 10

    private let inventory: any ProcessInventoryProviding
    private let now: () -> Date
    private let sleep: Sleeper
    private let maxSamples: Int
    private var hasGap = false
    private var samplingTask: Task<Void, Never>?
    private var samplingGeneration = 0
    private var consumerCount = 0
    /// Set while ProcessManager polls: its scheduled reads then supply the
    /// samples, so the history's own timer stands down instead of reading the
    /// inventory again at an unrelated phase.
    private var pollingActive = false

    init(
        inventory: any ProcessInventoryProviding = SystemProcessInventory(),
        maxSamples: Int = 60,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping Sleeper = { interval in
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                return true
            } catch {
                return false
            }
        }
    ) {
        self.inventory = inventory
        self.maxSamples = max(2, maxSamples)
        self.now = now
        self.sleep = sleep
    }

    deinit {
        samplingTask?.cancel()
    }

    func start(cadence: TimeInterval, sampleImmediately: Bool = true) {
        let previousState = state
        stop()
        // Without an immediate read, nothing new is known yet: keep reporting a
        // failed last read instead of claiming "Live" for a whole interval.
        if !sampleImmediately, case .unavailable = previousState {
            state = previousState
        } else {
            state = .sampling
        }
        let interval = max(2, cadence)
        let generation = samplingGeneration
        let sleep = self.sleep
        samplingTask = Task { [weak self] in
            if sampleImmediately {
                await self?.sampleNow(for: generation)
            }
            // The loop ends once polling is active, after any read already in
            // flight, so the first sample of a just-opened window is kept.
            while !Task.isCancelled, self?.pollingActive == false {
                guard await sleep(interval),
                      !Task.isCancelled,
                      self?.pollingActive == false else { break }
                await self?.sampleNow(for: generation)
            }
        }
    }

    /// The time the charts cover: the buffer's sample count at the current
    /// cadence, for example 10 minutes at the default 10 s.
    var windowDuration: TimeInterval {
        Double(maxSamples) * cadence
    }

    func beginSampling(cadence: TimeInterval) {
        consumerCount += 1
        self.cadence = max(2, cadence)
        guard consumerCount == 1 else { return }
        // Resuming from zero consumers keeps the samples still inside the time
        // window, so a reopened window shows them. Nothing was read while
        // paused, so the next sample starts a new segment instead of being
        // drawn joined to them as if contiguous.
        pruneSamples(olderThan: now().addingTimeInterval(-windowDuration))
        hasGap = !samples.isEmpty
        // Read once now even while polling, so a window opened between polls
        // does not wait up to a whole interval for its first sample.
        start(cadence: self.cadence)
    }

    func endSampling() {
        consumerCount = max(0, consumerCount - 1)
        if consumerCount == 0 {
            stop()
        }
    }

    func updateConsumerCadence(_ cadence: TimeInterval) {
        self.cadence = max(2, cadence)
        if consumerCount > 0, !pollingActive {
            start(cadence: self.cadence, sampleImmediately: false)
        }
    }

    /// Visible consumers share the manager's scheduled reads. The independent
    /// sampler is only needed when the manager is not polling.
    func setPollingActive(_ active: Bool) {
        guard pollingActive != active else { return }
        pollingActive = active
        // Becoming active needs no action here: a running loop ends by itself.
        guard !active, consumerCount > 0 else { return }
        start(cadence: cadence)
    }

    /// Records a read made by the manager's poll tick while a consumer is
    /// visible; this is how the history samples while the manager polls.
    func receivePolledInventory(_ result: Result<[AppProcess], ProcessInventoryError>) {
        guard pollingActive, consumerCount > 0, !Task.isCancelled else { return }
        if case .failure(.cancelled) = result { return }
        apply(result)
    }

    func stop() {
        samplingGeneration &+= 1
        samplingTask?.cancel()
        samplingTask = nil
        state = .paused
    }

    func sampleNow() async {
        await sampleNow(for: samplingGeneration)
    }

    private func sampleNow(for generation: Int) async {
        let result = await inventory.load(fetchExtendedStats: false)
        guard generation == samplingGeneration, !Task.isCancelled else { return }

        apply(result)
    }

    private func apply(_ result: Result<[AppProcess], ProcessInventoryError>) {
        switch result {
        case .failure(let error):
            hasGap = true
            state = .unavailable(error.localizedDescription)
        case .success(let processes):
            record(processes: processes)
            state = .sampling
        }
    }

    func record(processes: [AppProcess]) {
        let cpu = processes.reduce(0.0) { $0 + $1.cpu }
        let memory = processes.reduce(0.0) { $0 + $1.memoryMB }
        let timestamp = now()
        samples.append(
            Sample(
                timestamp: timestamp,
                observedProcessCPU: cpu,
                observedProcessMemoryMB: memory,
                processCount: processes.count,
                startsNewSegment: hasGap
            )
        )
        hasGap = false
        pruneSamples(olderThan: timestamp.addingTimeInterval(-windowDuration))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    /// Drops samples the charts' time window no longer reaches.
    private func pruneSamples(olderThan cutoff: Date) {
        guard let first = samples.firstIndex(where: { $0.timestamp >= cutoff }) else {
            samples.removeAll()
            return
        }
        if first > 0 { samples.removeFirst(first) }
    }
}
