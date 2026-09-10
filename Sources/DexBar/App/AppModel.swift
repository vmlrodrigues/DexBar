import Foundation
import Combine
import DexBarCore

enum LoadState: Equatable {
    case loading
    case ok
    case stale(String)
    case needsAuthentication
    case cliUnavailable
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var usageHistoryWindows: [UsageHistoryWindow] = []
    @Published private(set) var state: LoadState = .loading
    @Published private(set) var isRefreshing = false

    var onChange: (() -> Void)?
    let notifier = Notifier()

    private let client: CodexAppServerClient
    private let projectionStore: ProjectionStore
    private let historyWorker: UsageHistoryWorker
    private var usesPreviewProjection = false
    private var previewProjection: Projection?
    private var timeZoneObserver: AnyCancellable?
    private var historyRevision = 0
    private var historyGeneration = 0

    init(
        client: CodexAppServerClient = CodexAppServerClient(),
        projectionStore: ProjectionStore? = nil,
        usageHistoryStore: UsageHistoryStore? = nil
    ) {
        self.client = client
        self.projectionStore = projectionStore ?? ProjectionStore()
        self.historyWorker = UsageHistoryWorker(store: usageHistoryStore)
        timeZoneObserver = NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                NSTimeZone.resetSystemTimeZone()
                self?.refreshHistoryPresentation()
            }
    }

    var weeklyProjection: Projection? {
        guard let weekly = snapshot?.weekly else { return nil }
        return projection(for: weekly)
    }

    func projection(for window: UsageWindow) -> Projection? {
        if usesPreviewProjection {
            return window.id == snapshot?.weekly.id ? previewProjection : nil
        }
        guard let snapshot else { return nil }
        return projectionStore.projection(for: window, now: snapshot.fetchedAt)
    }

    var worstPercent: Int { snapshot?.worstPercent ?? 0 }

    func usageHistory(for window: UsageWindow) -> [UsageHistoryWindow] {
        usageHistoryWindows.filter { $0.windowID == window.id }
    }

    func refreshHistoryPresentation() {
        guard !usesPreviewProjection, let snapshot else { return }
        historyRevision += 1
        let revision = historyRevision
        let generation = historyGeneration
        let calendar = Calendar.current
        Task {
            let windows = await historyWorker.presentation(for: snapshot.weekly.id, calendar: calendar, generation: generation)
            guard historyRevision == revision else { return }
            usageHistoryWindows = windows
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        onChange?()
        defer {
            isRefreshing = false
            onChange?()
        }

        do {
            let fresh = try await client.fetch()
            snapshot = fresh
            state = .ok
            historyRevision += 1
            let revision = historyRevision
            let generation = historyGeneration
            let samples = projectionStore.recordedSamples(for: fresh.weekly.id)
            projectionStore.record(fresh)
            let result = await historyWorker.update(fresh,
                projectionSamples: samples, calendar: Calendar.current, generation: generation)
            if historyRevision == revision {
                usageHistoryWindows = result.windows
            }
            if historyGeneration == generation, let error = result.persistenceError { state = .stale(error) }
            notifier.evaluate(snapshot: fresh, projection: weeklyProjection)
        } catch let error as CodexClientError {
            switch error {
            case .cliUnavailable:
                state = .cliUnavailable
            case .authenticationRequired:
                state = .needsAuthentication
            default:
                state = snapshot == nil
                    ? .failed(error.localizedDescription)
                    : .stale(error.localizedDescription)
            }
        } catch {
            state = snapshot == nil
                ? .failed(error.localizedDescription)
                : .stale(error.localizedDescription)
        }
    }

    func clearHistory() async -> Bool {
        projectionStore.clear()
        historyRevision += 1
        historyGeneration += 1
        let generation = historyGeneration
        let revision = historyRevision
        usageHistoryWindows = []
        onChange?()
        let error = await historyWorker.clear(generation: generation)
        if historyRevision == revision {
            if let error { state = .stale(error) }
            onChange?()
        }
        return error == nil
    }

    static func preview(
        snapshot: UsageSnapshot?,
        state: LoadState = .ok,
        projection: Projection? = nil,
        usageHistoryWindows: [UsageHistoryWindow] = []
    ) -> AppModel {
        let model = AppModel(
            projectionStore: .inMemory(),
            usageHistoryStore: .inMemory()
        )
        model.snapshot = snapshot
        model.state = state
        model.usesPreviewProjection = true
        model.previewProjection = projection
        model.usageHistoryWindows = usageHistoryWindows
        return model
    }
}
