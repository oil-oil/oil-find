import Foundation

/// Main-queue scheduling state. Repeated writes cannot move a queued provider ahead of its peers.
struct AITopicSyncQueue {
    private var metadata = Set<AITopicProvider>()
    private var history: [AITopicProvider] = []
    private var inProgress = Set<AITopicProvider>()
    private var needsReplay = Set<AITopicProvider>()
    var isEmpty: Bool { history.isEmpty }

    mutating func enqueue(_ providers: Set<AITopicProvider>) {
        metadata.formUnion(providers)
        for provider in AITopicProvider.allCases where providers.contains(provider) { resume(provider) }
    }
    mutating func resume(_ provider: AITopicProvider) {
        if !history.contains(provider) { history.append(provider) }
    }
    mutating func complete(_ provider: AITopicProvider) {
        inProgress.remove(provider)
        if needsReplay.remove(provider) != nil { resume(provider) }
    }
    mutating func next() -> (metadata: Set<AITopicProvider>, history: AITopicProvider)? {
        guard !history.isEmpty else { return nil }
        let job = (metadata, history.removeFirst())
        // An event merged into a queued continuation still needs a fresh pass after that frozen plan.
        needsReplay.formUnion(metadata.intersection(inProgress))
        inProgress.insert(job.1)
        metadata.removeAll(keepingCapacity: true)
        return job
    }
}
