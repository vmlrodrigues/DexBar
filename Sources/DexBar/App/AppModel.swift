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
    private struct Presentation {
        var snapshot: UsageSnapshot?
        var creditForecast: CreditForecast = .unavailable
        var weeklyProjection: Projection?
        var historyWindows: [UsageHistoryWindow] = []
        var state: LoadState = .loading
    }

    @Published private var presentation = Presentation()
    @Published private(set) var isRefreshing = false

    var snapshot: UsageSnapshot? { presentation.snapshot }
    var creditForecast: CreditForecast { presentation.creditForecast }
    var state: LoadState { presentation.state }

    var onChange: (() -> Void)?
    let notifier = Notifier()

    private let client: CodexAppServerClient
    private let projectionStore: ProjectionStore
    private let historyWorker: UsageHistoryWorker
    private var usesPreviewProjection = false
    private var isPreparingReading = false
    private var timeZoneObserver: AnyCancellable?
    private var historyRevision = 0
    private var historyGeneration = 0
    private var historyClearError: String?

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
            return window.id == snapshot?.weekly.id ? presentation.weeklyProjection : nil
        }
        guard let snapshot else { return nil }
        if window.id == snapshot.weekly.id, window.isWeekly { return presentation.weeklyProjection }
        return projectionStore.projection(for: window, now: snapshot.fetchedAt)
    }

    var worstPercent: Int { snapshot?.worstPercent ?? 0 }

    func usageHistory(for window: UsageWindow) -> [UsageHistoryWindow] {
        presentation.historyWindows.filter { $0.windowID == window.id }
    }

    func refreshHistoryPresentation() {
        guard !usesPreviewProjection, isPreparingReading || snapshot != nil else { return }
        historyRevision += 1
        // The pending reading will replay history for its own window and time zone.
        guard !isPreparingReading, let snapshot else { return }
        let revision = historyRevision
        let generation = historyGeneration
        let calendar = Calendar.current
        Task {
            let windows = await historyWorker.presentation(for: snapshot.weekly.id, calendar: calendar, generation: generation)
            guard historyRevision == revision else { return }
            presentation.historyWindows = windows
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
            isPreparingReading = true
            defer { isPreparingReading = false }
            historyRevision += 1
            var revision = historyRevision
            let generation = historyGeneration
            let samples = projectionStore.recordedSamples(for: fresh.weekly.id)
            let result = await historyWorker.update(fresh,
                projectionSamples: samples, calendar: Calendar.current, generation: generation)
            var windows = result.windows
            while historyGeneration == generation, historyRevision != revision {
                revision = historyRevision
                windows = await historyWorker.presentation(for: fresh.weekly.id,
                    calendar: Calendar.current, generation: generation)
            }
            // Keep the last complete reading visible until its replacement is ready.
            if historyGeneration == generation {
                projectionStore.record(fresh)
                presentation = Presentation(snapshot: fresh, creditForecast: result.creditForecast,
                    weeklyProjection: result.weeklyProjection, historyWindows: windows,
                    state: result.persistenceError.map(LoadState.stale) ?? .ok)
            } else {
                // Clear History superseded the derived data, but the usage reading is valid.
                presentation = Presentation(snapshot: fresh, state: historyClearError.map(LoadState.stale) ?? .ok)
            }
            notifier.evaluate(snapshot: fresh, projection: weeklyProjection)
        } catch let error as CodexClientError {
            switch error {
            case .cliUnavailable:
                presentation.state = .cliUnavailable
            case .authenticationRequired:
                presentation.state = .needsAuthentication
            default:
                presentation.state = snapshot == nil
                    ? .failed(error.localizedDescription)
                    : .stale(error.localizedDescription)
            }
        } catch {
            presentation.state = snapshot == nil
                ? .failed(error.localizedDescription)
                : .stale(error.localizedDescription)
        }
    }

    func clearHistory() async -> Bool {
        projectionStore.clear()
        historyRevision += 1
        historyGeneration += 1
        historyClearError = nil
        let generation = historyGeneration
        let revision = historyRevision
        var cleared = presentation
        cleared.historyWindows = []
        cleared.creditForecast = .unavailable
        cleared.weeklyProjection = nil
        presentation = cleared
        onChange?()
        let error = await historyWorker.clear(generation: generation)
        if historyRevision == revision {
            historyClearError = error
            if let error { presentation.state = .stale(error) }
            onChange?()
        }
        return error == nil
    }

    static func preview(
        snapshot: UsageSnapshot?,
        state: LoadState = .ok,
        projection: Projection? = nil,
        usageHistoryWindows: [UsageHistoryWindow] = [],
        creditForecast: CreditForecast = .unavailable
    ) -> AppModel {
        let model = AppModel(
            projectionStore: .inMemory(),
            usageHistoryStore: .inMemory()
        )
        model.presentation = Presentation(snapshot: snapshot, creditForecast: creditForecast,
            weeklyProjection: projection, historyWindows: usageHistoryWindows, state: state)
        model.usesPreviewProjection = true
        return model
    }
}
