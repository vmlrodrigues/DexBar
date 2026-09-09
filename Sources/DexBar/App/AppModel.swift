import Foundation
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
    private let usageHistoryStore: UsageHistoryStore
    private var usesPreviewProjection = false
    private var previewProjection: Projection?

    init(
        client: CodexAppServerClient = CodexAppServerClient(),
        projectionStore: ProjectionStore? = nil,
        usageHistoryStore: UsageHistoryStore? = nil
    ) {
        self.client = client
        self.projectionStore = projectionStore ?? ProjectionStore()
        self.usageHistoryStore = usageHistoryStore ?? UsageHistoryStore()
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
            usageHistoryStore.backfill(
                samples: projectionStore.recordedSamples(for: fresh.weekly.id),
                for: fresh.weekly
            )
            usageHistoryStore.record(fresh)
            projectionStore.record(fresh)
            usageHistoryWindows = usageHistoryStore.windows(for: fresh.weekly.id)
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

    func clearHistory() {
        projectionStore.clear()
        usageHistoryStore.clear()
        usageHistoryWindows = []
        onChange?()
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
