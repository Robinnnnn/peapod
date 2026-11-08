import Foundation

/// Display-ready images outlive recycled rows, but never their encrypted session.
/// Active shared loads survive row cancellation; abandoned queued loads do not.
@MainActor
final class SessionPhotoImageCache<Key: Hashable & Sendable, Image> {
    @MainActor private final class Entry {
        let image: Image
        let cost: Int
        var lastUse: UInt64
        init(image: Image, cost: Int, lastUse: UInt64 = 0) {
            self.image = image; self.cost = cost; self.lastUse = lastUse
        }
    }

    @MainActor private final class Job {
        let id = UUID()
        var task: Task<Entry, Error>?
        var consumers: Set<UUID> = []
        var isRunning = false
        var isPrefetch: Bool
        init(isPrefetch: Bool) { self.isPrefetch = isPrefetch }
    }

    private let maximumCost: Int
    private let maximumCount: Int
    private let maximumConcurrentLoads: Int
    private let cost: @MainActor (Image) -> Int
    private var entries: [Key: Entry] = [:]
    private var loads: [Key: Job] = [:]
    private var waiters: [(job: Job, continuation: CheckedContinuation<Void, Error>)] = []
    private var activeLoads = 0
    private var totalCost = 0
    private var clock: UInt64 = 0
    private var invalidated = false

    init(maximumCost: Int, maximumCount: Int = 80, maximumConcurrentLoads: Int = 3,
         cost: @escaping @MainActor (Image) -> Int) {
        self.maximumCost = maximumCost
        self.maximumCount = maximumCount
        self.maximumConcurrentLoads = maximumConcurrentLoads
        self.cost = cost
    }

    /// Pending distinct loads, excluding downloads/decodes already in progress.
    var queuedLoadCount: Int { waiters.count }

    func image(for key: Key) -> Image? {
        guard !invalidated, let entry = entries[key] else { return nil }
        clock &+= 1; entry.lastUse = clock
        return entry.image
    }

    func load(for key: Key, prefetch: Bool = false,
              loader: @escaping @MainActor () async throws -> Image) async throws -> Image {
        try Task.checkCancellation()
        guard !invalidated else { throw CancellationError() }
        if let image = image(for: key) { return image }
        let job: Job
        if let existing = loads[key] {
            job = existing
            if !prefetch { job.isPrefetch = false }
        } else {
            job = Job(isPrefetch: prefetch)
            loads[key] = job
            job.task = Task { @MainActor in
                defer {
                    if self.loads[key]?.id == job.id { self.loads[key] = nil }
                    job.task = nil
                }
                try await self.acquireSlot(job)
                defer { self.releaseSlot() }
                let image = try await loader()
                try Task.checkCancellation()
                guard !self.invalidated else { throw CancellationError() }
                let entry = Entry(image: image, cost: max(1, self.cost(image)))
                self.store(entry, for: key)
                return entry
            }
        }
        let consumer = UUID()
        job.consumers.insert(consumer)
        guard let task = job.task else { throw CancellationError() }
        defer { releaseConsumer(consumer, job: job, key: key) }
        return try await withTaskCancellationHandler {
            let entry = try await task.value
            try Task.checkCancellation()
            guard !invalidated else { throw CancellationError() }
            return entry.image
        } onCancel: {
            Task { @MainActor in self.releaseConsumer(consumer, job: job, key: key) }
        }
    }

    func invalidate() {
        invalidated = true
        entries.removeAll(); totalCost = 0
        loads.values.forEach { $0.task?.cancel() }
        let queued = waiters; waiters.removeAll()
        queued.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }

    private func releaseConsumer(_ consumer: UUID, job: Job, key: Key) {
        guard job.consumers.remove(consumer) != nil,
              job.consumers.isEmpty, !job.isRunning else { return }
        job.task?.cancel()
        if loads[key]?.id == job.id { loads[key] = nil }
        if let index = waiters.firstIndex(where: { $0.job.id == job.id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func store(_ entry: Entry, for key: Key) {
        guard entry.cost <= maximumCost, maximumCount > 0 else { return }
        while totalCost + entry.cost > maximumCost || entries.count >= maximumCount {
            guard let victim = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key,
                  let removed = entries.removeValue(forKey: victim) else { break }
            totalCost -= removed.cost
        }
        clock &+= 1; entry.lastUse = clock
        entries[key] = entry; totalCost += entry.cost
    }

    private func acquireSlot(_ job: Job) async throws {
        try Task.checkCancellation()
        guard !invalidated else { throw CancellationError() }
        if activeLoads < maximumConcurrentLoads {
            activeLoads += 1; job.isRunning = true
            return
        }
        try await withCheckedThrowingContinuation { waiters.append((job, $0)) }
        do { try Task.checkCancellation() }
        catch {
            // A transferred slot still belongs to us if invalidation raced the resume.
            if job.isRunning { releaseSlot() }
            throw error
        }
    }

    private func releaseSlot() {
        guard !waiters.isEmpty else { activeLoads -= 1; return }
        // A visible row can upgrade a queued prefetch by joining the same job.
        let index = waiters.firstIndex(where: { !$0.job.isPrefetch }) ?? 0
        let next = waiters.remove(at: index)
        next.job.isRunning = true
        next.continuation.resume()
    }
}
