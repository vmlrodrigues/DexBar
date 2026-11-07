import Foundation

/// Owns the mutable store on a background actor. JSON encoding, file writes and
/// calendar replay never run on the application's main actor.
public actor UsageHistoryWorker {
    public struct Result: Sendable {
        public let windows: [UsageHistoryWindow]
        public let persistenceError: String?
        public let creditForecast: CreditForecast
        public let weeklyProjection: Projection?
    }

    private var store: UsageHistoryStore?
    private var creditStore: CreditHistoryStore?
    private var generation = 0

    /// An injected store transfers ownership to this worker; do not access it again
    /// from another executor. The default store is opened lazily on this actor.
    public init(store: UsageHistoryStore? = nil, creditStore: CreditHistoryStore? = nil) {
        self.store = store
        // Injected/test history stores must never open the user's credit file.
        self.creditStore = creditStore ?? (store == nil ? nil : CreditHistoryStore(url: nil))
    }

    private func resolvedCredits() -> CreditHistoryStore {
        if let creditStore { return creditStore }
        let created = CreditHistoryStore.persistent()
        creditStore = created
        return created
    }

    private var persistenceError: String? {
        [resolvedStore().persistenceError, resolvedCredits().persistenceError]
            .compactMap { $0 }.first
    }

    private func resolvedStore() -> UsageHistoryStore {
        if let store { return store }
        let created = UsageHistoryStore()
        store = created
        return created
    }

    public func update(_ snapshot: UsageSnapshot, projectionSamples: [ProjectionSample], calendar: Calendar,
                       generation requestedGeneration: Int? = nil) -> Result {
        let store = resolvedStore()
        // A clear may overtake queued work. Older updates must not resurrect the
        // deleted history, and newer updates must clear before starting fresh.
        if let requestedGeneration, requestedGeneration > generation {
            store.clear()
            resolvedCredits().clear()
            generation = requestedGeneration
        }
        if let requestedGeneration, requestedGeneration < generation {
            return Result(windows: store.windows(for: snapshot.weekly.id, calendar: calendar),
                          persistenceError: persistenceError, creditForecast: resolvedCredits().forecast,
                          weeklyProjection: nil)
        }
        store.backfill(samples: projectionSamples, for: snapshot.weekly)
        store.record(snapshot)
        resolvedCredits().record(snapshot)
        return Result(windows: store.windows(for: snapshot.weekly.id, calendar: calendar),
                      persistenceError: persistenceError, creditForecast: resolvedCredits().forecast,
                      weeklyProjection: store.weeklyProjection(for: snapshot))
    }

    public func presentation(for windowID: String, calendar: Calendar,
                             generation requestedGeneration: Int? = nil) -> [UsageHistoryWindow] {
        let store = resolvedStore()
        if let requestedGeneration, requestedGeneration > generation {
            store.clear()
            resolvedCredits().clear()
            generation = requestedGeneration
        }
        return store.windows(for: windowID, calendar: calendar)
    }

    public func clear(generation requestedGeneration: Int? = nil) -> String? {
        let store = resolvedStore()
        if let requestedGeneration, requestedGeneration <= generation { return persistenceError }
        generation = requestedGeneration ?? (generation + 1)
        store.clear()
        resolvedCredits().clear()
        return persistenceError
    }
}
