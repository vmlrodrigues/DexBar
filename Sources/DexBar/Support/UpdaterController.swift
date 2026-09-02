import AppKit
import Combine
import Sparkle

/// Sparkle's standard update UI needs explicit activation because DexBar is a dockless
/// accessory app. Without it, an update prompt opened by a scheduled check can appear
/// behind the user's current application.
private final class UpdaterUIDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillShowModalAlert() {
        NSApp.activate()
    }
}

@MainActor
final class UpdaterController: ObservableObject {
    private let uiDelegate: UpdaterUIDelegate
    private let controller: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var canCheck = false

    init() {
        let delegate = UpdaterUIDelegate()
        uiDelegate = delegate
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: delegate
        )

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheck = value }
            .store(in: &cancellables)

        controller.startUpdater()
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.updater.checkForUpdates()
    }
}
