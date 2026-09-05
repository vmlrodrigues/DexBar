import AppKit
import Carbon.HIToolbox
import Darwin
import SwiftUI
import DexBarCore

enum Retainer {
    @MainActor static var delegate: AppDelegate?
}

@main
enum DexBarMain {
    static func main() {
        if CommandLine.arguments.contains("--version") {
            print(
                "DexBar \(bundleVersionString()) "
                    + "[\(CurrentBuild.channel.rawValue), \(CurrentBuild.sourceRevision)]"
            )
            return
        }
        if CommandLine.arguments.contains("--probe") {
            runProbe()
            return
        }
        if CommandLine.arguments.contains("--dates") {
            let now = Date()
            for offset in [7_200.0, 28_800, 50_400, 259_200, 518_400, 777_600] {
                let date = now.addingTimeInterval(offset)
                print("resets \(resetDescription(date, relativeTo: now)) · in \(shortDuration(offset))")
            }
            return
        }
        if CommandLine.arguments.contains("--hotkey-check") {
            requireUnbundledHeadlessAppKit()
            MainActor.assumeIsolated {
                prepareHeadlessRendering()
                let center = HotKeyCenter.shared
                center.setHandler {}
                let registered = center.register(
                    keyCode: Int(kVK_F12),
                    carbonModifiers: Int(controlKey | optionKey | shiftKey | cmdKey)
                )
                print("global shortcut registration: \(registered ? "ok" : "failed")")
                center.unregister()
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-popover") {
            requireUnbundledHeadlessAppKit()
            let path = argument(after: index, fallback: "/tmp/dexbar-popover.png")
            let state = argument(after: index + 1, fallback: "current")
            MainActor.assumeIsolated {
                prepareHeadlessRendering()
                renderPopover(path: path, state: state)
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-settings") {
            requireUnbundledHeadlessAppKit()
            let path = argument(after: index, fallback: "/tmp/dexbar-settings.png")
            MainActor.assumeIsolated {
                prepareHeadlessRendering()
                let model = AppModel.preview(snapshot: previewSnapshot(state: "current"))
                let pane: SettingsView.Pane
                if CommandLine.arguments.contains("--menu-bar") { pane = .menuBar }
                else if CommandLine.arguments.contains("--alerts") { pane = .alerts }
                else if CommandLine.arguments.contains("--privacy") { pane = .privacy }
                else if CommandLine.arguments.contains("--about") { pane = .about }
                else { pane = .general }
                render(
                    view: SettingsView(
                        model: model,
                        updater: UpdaterController(),
                        initialPane: pane,
                        openSignIn: {}
                    ),
                    path: path
                )
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-onboarding") {
            requireUnbundledHeadlessAppKit()
            let path = argument(after: index, fallback: "/tmp/dexbar-onboarding.png")
            MainActor.assumeIsolated {
                prepareHeadlessRendering()
                let model = AppModel.preview(snapshot: previewSnapshot(state: "current"))
                render(view: OnboardingView(model: model, continueAction: {}, openTerminal: {}), path: path)
            }
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let delegate = AppDelegate()
            Retainer.delegate = delegate
            application.delegate = delegate
        }
        application.run()
    }

    private static func argument(after index: Int, fallback: String) -> String {
        let valueIndex = index + 1
        return valueIndex < CommandLine.arguments.count ? CommandLine.arguments[valueIndex] : fallback
    }

    /// LaunchServices registers a packaged application before AppKit is available. Running
    /// that bundle executable directly from a shell aborts on current macOS; the SwiftPM
    /// product has the same rendering code without pretending to be an application launch.
    private static func requireUnbundledHeadlessAppKit() {
        if Bundle.main.bundleURL.pathExtension == "app" {
            FileHandle.standardError.write(Data(
                "Headless checks must use .build/release/DexBar, not the packaged app executable.\n".utf8
            ))
            exit(64)
        }
    }

    private static func runProbe() {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            defer { semaphore.signal() }
            do {
                let snapshot = try await CodexAppServerClient().fetch()
                print("plan: \(displayPlan(snapshot.planType) ?? "unknown")")
                print("service mode: \(snapshot.serviceTier?.displayName ?? "unknown")")
                print("weekly: \(snapshot.weekly.usedPercent)% / \(snapshot.weekly.durationMinutes) min")
                print("weekly reset: \(Int(snapshot.weekly.resetsAt.timeIntervalSince1970))")
                print("visible supplementary windows: \(snapshot.supplementary.count)")
                for window in snapshot.supplementary {
                    print("- \(window.bucketName): \(window.usedPercent)% / \(window.durationMinutes) min")
                }
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            }
        }
        semaphore.wait()
    }

    @MainActor
    private static func renderPopover(path: String, state: String) {
        let snapshot = state == "auth" ? nil : previewSnapshot(state: state)
        let loadState: LoadState
        switch state {
        case "auth", "auth-retained": loadState = .needsAuthentication
        case "cli-retained": loadState = .cliUnavailable
        case "stale": loadState = .stale("Offline — showing the last reading.")
        default: loadState = .ok
        }
        let projection: Projection?
        switch state {
        case "warning": projection = Projection(projectedPercent: 109, pointsPerDay: 5.0, daysRemaining: 6.95, outlook: .mayRunOut, limitReachedAt: Date().addingTimeInterval(5.2 * 86_400))
        case "critical": projection = Projection(projectedPercent: 118, pointsPerDay: 3.2, daysRemaining: 6.95, outlook: .likelyToRunOut, limitReachedAt: Date().addingTimeInterval(1.25 * 86_400))
        case "current": projection = nil
        default: projection = Projection(projectedPercent: 74, pointsPerDay: 4.3, daysRemaining: 6.95, outlook: .onTrack, limitReachedAt: nil)
        }
        let model = AppModel.preview(snapshot: snapshot, state: loadState, projection: projection)
        render(
            view: PopoverView(model: model, openSettings: {}, openSignIn: {}, quit: {}),
            path: path
        )
    }

    @MainActor
    private static func previewSnapshot(state: String) -> UsageSnapshot {
        let now = Date()
        let weeklyPercent: Double
        switch state {
        case "warning": weeklyPercent = 74
        case "critical": weeklyPercent = 96
        case "stale": weeklyPercent = 58
        default: weeklyPercent = state == "current" ? 1 : 44
        }
        let weekly = UsageWindow(
            id: "codex.primary",
            bucketID: "codex",
            bucketName: "General",
            usedPercent: weeklyPercent,
            durationMinutes: 10_080,
            resetsAt: now.addingTimeInterval(6 * 86_400 + 23 * 3_600)
        )
        let supplementary: [UsageWindow]
        if state == "active" {
            supplementary = [UsageWindow(
                id: "codex_bengalfox.primary",
                bucketID: "codex_bengalfox",
                bucketName: "GPT-5.3-Codex-Spark",
                usedPercent: 68,
                durationMinutes: 300,
                resetsAt: now.addingTimeInterval(5_520)
            )]
        } else {
            supplementary = []
        }
        return UsageSnapshot(
            weekly: weekly,
            supplementary: supplementary,
            planType: "pro",
            serviceTier: .fast,
            credits: UsageCredits(hasCredits: false, unlimited: false, balance: "0"),
            resetCreditsAvailable: 0,
            fetchedAt: state == "stale" ? now.addingTimeInterval(-720) : now
        )
    }

    @MainActor
    private static func prepareHeadlessRendering() {
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    @MainActor
    private static func render<Content: View>(view: Content, path: String) {
        let dark = CommandLine.arguments.contains("--dark")
        let renderer = ImageRenderer(
            content: view
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(dark ? Color.black : Color.white)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            print("render failed")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        } catch {
            print("render failed: \(error.localizedDescription)")
        }
    }
}
