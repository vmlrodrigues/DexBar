import AppKit
import Combine
import SwiftUI
import UserNotifications
import Darwin
import DexBarCore

final class EscapeClosableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: StatusItemController!
    private var scheduler: PollScheduler!
    private var activityMonitor: ActivityMonitor?
    private var popover: NSPopover?
    private var popoverTeardown: DispatchWorkItem?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var displayTimer: DispatchSourceTimer?
    private var debugPopoverSignal: DispatchSourceSignal?
    private var debugSettingsSignal: DispatchSourceSignal?
    private var appliedHotKey: HotKeyBinding?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        statusItem = StatusItemController(model: model)
        statusItem.onClick = { [weak self] in self?.togglePopover() }

        scheduler = PollScheduler { [weak self] in await self?.model.refresh() }
        scheduler.worstPercent = { [weak self] in self?.model.worstPercent ?? 0 }
        activityMonitor = ActivityMonitor { [weak self] in
            Task { @MainActor in self?.scheduler.reschedule() }
        }
        scheduler.idleFor = { [weak self] in self?.activityMonitor?.idleFor ?? .infinity }

        model.onChange = { [weak self] in
            self?.statusItem.update()
            self?.scheduler.reschedule()
        }
        Preferences.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                DispatchQueue.main.async {
                    self?.statusItem.forceRedraw()
                    self?.applyHotKey()
                }
            }
            .store(in: &cancellables)

        HotKeyCenter.shared.setHandler { [weak self] in self?.togglePopoverFromHotKey() }
        applyHotKey()

        registerSleepWake()
        registerAppearanceChanges()
        startDisplayTicker()
        installDebugSignals()
        statusItem.update()

        let skipOnboarding = ProcessInfo.processInfo.environment["DEXBAR_SKIP_ONBOARDING"] == "1"
        if !Preferences.shared.completedOnboarding && !skipOnboarding {
            // Give a deliberately hidden launch time to settle before deciding
            // whether to surface first-run UI. Normal Finder launches remain visible.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard !NSRunningApplication.current.isHidden else { return }
                self?.showOnboarding()
            }
        }
        Task {
            await model.refresh()
            scheduler.reschedule()
        }
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit DexBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    private func togglePopover() {
        if popover?.isShown == true {
            popover?.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        popoverTeardown?.cancel()
        popoverTeardown = nil

        let popover = self.popover ?? makePopover()
        self.popover = popover
        if let hosting = popover.contentViewController {
            hosting.view.layoutSubtreeIfNeeded()
            let fitting = hosting.view.fittingSize
            if fitting.width > 0, fitting.height > 0 { popover.contentSize = fitting }
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { await model.refresh() }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    private func applyHotKey() {
        let prefs = Preferences.shared
        let wanted: HotKeyBinding?
        if prefs.popoverHotKeyEnabled,
           prefs.popoverHotKeyModifiers != DefaultHotKey.unsetModifiers,
           prefs.popoverHotKeyCode != DefaultHotKey.unsetKeyCode {
            wanted = HotKeyBinding(
                keyCode: prefs.popoverHotKeyCode,
                modifiers: prefs.popoverHotKeyModifiers
            )
        } else {
            wanted = nil
        }

        guard wanted != appliedHotKey else { return }
        appliedHotKey = wanted
        if let wanted {
            HotKeyCenter.shared.register(
                keyCode: wanted.keyCode,
                carbonModifiers: wanted.modifiers
            )
        } else {
            HotKeyCenter.shared.unregister()
        }
    }

    /// A status-item click activates an accessory app implicitly; a global shortcut does
    /// not. Activate only when opening so the popover becomes key, never when closing.
    private func togglePopoverFromHotKey() {
        if popover?.isShown != true { NSApp.activate() }
        togglePopover()
    }

    private func makePopover() -> NSPopover {
        let view = PopoverView(
            model: model,
            openSettings: { [weak self] in
                self?.popover?.performClose(nil)
                self?.showSettings()
            },
            openSignIn: { [weak self] in self?.openTerminalForSignIn() },
            quit: { NSApp.terminate(nil) }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.layoutSubtreeIfNeeded()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = hosting
        popover.contentSize = hosting.view.fittingSize
        return popover
    }

    private func showSettings() {
        if let settingsWindow { raise(settingsWindow); return }
        let view = SettingsView(model: model, openSignIn: { [weak self] in self?.openTerminalForSignIn() })
        settingsWindow = presentWindow(title: "DexBar Settings", view: view)
    }

    private func showOnboarding() {
        if let onboardingWindow { raise(onboardingWindow); return }
        let view = OnboardingView(
            model: model,
            continueAction: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            },
            openTerminal: { [weak self] in self?.openTerminalForSignIn() }
        )
        onboardingWindow = presentWindow(title: "Welcome to DexBar", view: view)
    }

    private func presentWindow<Content: View>(title: String, view: Content) -> NSWindow {
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        let fitting = controller.view.fittingSize
        let window = EscapeClosableWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        if fitting.width > 0, fitting.height > 0 { window.setContentSize(fitting) }
        window.level = .floating
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.hidesOnDeactivate = false
        window.delegate = self
        raise(window)
        return window
    }

    private func raise(_ window: NSWindow) {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        } else {
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func openTerminalForSignIn() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("codex login", forType: .string)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    private func registerSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.suspend() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduler.resume()
                Task { await self?.model.refresh() }
            }
        }
    }

    private func registerAppearanceChanges() {
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                StatusSymbolCache.invalidate()
                self?.statusItem.forceRedraw()
            }
        }
    }

    private func startDisplayTicker() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.statusItem.update() }
        }
        timer.resume()
        displayTimer = timer
    }

    private func installDebugSignals() {
        guard ProcessInfo.processInfo.environment["DEXBAR_DEBUG"] == "1" else { return }
        signal(SIGUSR1, SIG_IGN)
        let popoverSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        popoverSignal.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.togglePopover() }
        }
        popoverSignal.resume()
        debugPopoverSignal = popoverSignal

        signal(SIGINFO, SIG_IGN)
        let settingsSignal = DispatchSource.makeSignalSource(signal: SIGINFO, queue: .main)
        settingsSignal.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.showSettings() }
        }
        settingsSignal.resume()
        debugSettingsSignal = settingsSignal
    }

    func applicationWillTerminate(_ notification: Notification) {
        displayTimer?.cancel()
        scheduler?.suspend()
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popoverTeardown?.cancel()
        let teardown = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.popover?.isShown != true else { return }
                self.popover?.contentViewController = nil
                self.popover = nil
            }
        }
        popoverTeardown = teardown
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: teardown)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        (notification.object as? NSWindow)?.level = .normal
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow { settingsWindow = nil }
        if window === onboardingWindow { onboardingWindow = nil }
    }
}
