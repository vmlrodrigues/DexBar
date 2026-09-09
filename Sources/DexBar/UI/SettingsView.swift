import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import DexBarCore

struct SettingsView: View {
    private enum Typography {
        static let sidebarTitle = Font.system(size: 16, weight: .semibold)
        static let sidebarItem = Font.system(size: 15, weight: .regular)
        static let sidebarItemSelected = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 14)
        static let detail = Font.system(size: 12)
        static let detailEmphasis = Font.system(size: 12, weight: .medium)
    }

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case menuBar = "Menu Bar"
        case alerts = "Alerts"
        case privacy = "Data & Privacy"
        case about = "About"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .menuBar: return "menubar.rectangle"
            case .alerts: return "bell"
            case .privacy: return "checkmark.shield"
            case .about: return "info.circle"
            }
        }
    }

    @ObservedObject var model: AppModel
    @ObservedObject var updater: UpdaterController
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var hotKeys = HotKeyCenter.shared
    let openSignIn: () -> Void

    @State private var selected: Pane = .general
    @State private var launchAtLogin = CurrentBuild.loginItemChangesEnabled
        && SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var clearedHistory = false

    init(
        model: AppModel,
        updater: UpdaterController,
        initialPane: Pane = .general,
        openSignIn: @escaping () -> Void
    ) {
        self.model = model
        self.updater = updater
        self.openSignIn = openSignIn
        _selected = State(initialValue: initialPane)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            pane
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 620, height: 420)
        .task {
            // UserNotifications requires a real .app bundle. Headless layout renders run
            // from the SwiftPM product directory and deliberately skip this live query.
            guard !CommandLine.arguments.contains("--render-settings") else { return }
            notificationStatus = await model.notifier.authorizationStatus()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DexBar")
                .font(Typography.sidebarTitle)
                .padding(.horizontal, 11)
                .padding(.bottom, 10)
            ForEach(Pane.allCases) { item in
                Button {
                    selected = item
                } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .font(selected == item ? Typography.sidebarItemSelected : Typography.sidebarItem)
                        .imageScale(.large)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            selected == item ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .focusable(false)
                .focusEffectDisabled()
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 184)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var pane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(selected.rawValue).font(.title2.weight(.semibold))
            switch selected {
            case .general: general
            case .menuBar: menuBar
            case .alerts: alerts
            case .privacy: privacy
            case .about: about
            }
        }
        .font(Typography.body)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 14) {
            group {
                if CurrentBuild.isDevelopment {
                    settingsRow(
                        title: "Launch DexBar at login",
                        detail: "Managed by the installed release build."
                    ) {
                        Text("Disabled").foregroundStyle(.secondary)
                    }
                } else {
                    Toggle("Launch DexBar at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, wanted in
                            do {
                                if wanted { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                                launchError = nil
                            } catch {
                                launchError = error.localizedDescription
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                    }
                    if let launchError {
                        Text(launchError).font(Typography.detail).foregroundStyle(.orange)
                    }
                }
            }
            group {
                settingsRow(title: "Refresh", detail: "After Codex activity, when opened or waking, plus a quiet idle check") {
                    Text("Adaptive").foregroundStyle(.secondary)
                }
                Divider()
                settingsRow(title: "Current account", detail: accountDetail) {
                    Label(accountStatus, systemImage: accountSymbol)
                        .foregroundStyle(accountColor)
                }
                if model.state == .needsAuthentication || model.state == .cliUnavailable {
                    Button("Open Terminal…", action: openSignIn).controlSize(.small)
                }
            }
            group {
                settingsRow(
                    title: "Software updates",
                    detail: CurrentBuild.isDevelopment
                        ? "Disabled in development builds."
                        : "Checks once a day and asks before installing."
                ) {
                    Button("Check Now") { updater.checkForUpdates() }
                        .controlSize(.small)
                        .disabled(!updater.canCheck)
                }
            }
        }
    }

    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            group {
                settingsRow(
                    title: "Display",
                    detail: "Weekly by default. An active, more urgent window is surfaced automatically."
                ) {
                    Text("Automatic").foregroundStyle(.secondary)
                }
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Format")
                        Text("Preview: 44% · 6d 23h")
                            .font(Typography.detail).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $prefs.barFormat) {
                        ForEach(BarFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
            group {
                Toggle("Show the popover with a keyboard shortcut", isOn: $prefs.popoverHotKeyEnabled)
                ShortcutRecorder(
                    keyCode: $prefs.popoverHotKeyCode,
                    modifiers: $prefs.popoverHotKeyModifiers,
                    isEnabled: prefs.popoverHotKeyEnabled
                )
                shortcutStatus
                Text("Works from any app. No Accessibility permission needed.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var shortcutStatus: some View {
        if !prefs.popoverHotKeyEnabled {
            Text("Off").font(Typography.detail).foregroundStyle(.secondary)
        } else if prefs.popoverHotKeyModifiers == DefaultHotKey.unsetModifiers {
            Label("Choose a shortcut above.", systemImage: "keyboard")
                .font(Typography.detail)
                .foregroundStyle(.secondary)
        } else if hotKeys.isRegistered {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(Typography.detail)
                .foregroundStyle(.green)
        } else {
            Label("Unavailable—another app may already use that combination.", systemImage: "exclamationmark.triangle.fill")
                .font(Typography.detail)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: 12) {
            group {
                Toggle("Warn before I run out", isOn: $prefs.notificationsEnabled)
                    .onChange(of: prefs.notificationsEnabled) { _, enabled in
                        guard enabled else { return }
                        model.notifier.requestAuthorization()
                        Task { notificationStatus = await model.notifier.authorizationStatus() }
                    }
                Text("Notifications fire at 80%, 95%, and when the weekly projection crosses the limit.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                if notificationStatus == .denied {
                    Label("Notifications are disabled for DexBar in System Settings.", systemImage: "exclamationmark.triangle")
                        .font(Typography.detail)
                        .foregroundStyle(.orange)
                }
            }
            Text("Each threshold fires once per crossing and resets with the usage window.")
                .font(Typography.detail)
                .foregroundStyle(.secondary)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("No prompt is sent to check usage").fontWeight(.medium)
                    Text("The read-only Codex check does not consume allowance or start a window.")
                        .font(Typography.detail).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

            group {
                settingsRow(
                    title: "Credential handling",
                    detail: "Uses the current Codex sign-in. DexBar never copies a token into its own files or logs."
                ) { EmptyView() }
                Divider()
                settingsRow(
                    title: "History on this Mac",
                    detail: "Stores projection samples for eight days and daily usage history for thirteen weeks; no prompts, code, or account identifiers."
                ) {
                    Button(clearedHistory ? "Cleared" : "Clear") {
                        model.clearHistory()
                        clearedHistory = true
                    }
                    .controlSize(.small)
                    .disabled(clearedHistory)
                }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AppMark(size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        "DexBar \(bundleVersionString())"
                            + (CurrentBuild.isDevelopment ? " Development" : "")
                    )
                    .font(.headline)
                    Text("OpenAI usage in your menu bar.").foregroundStyle(.secondary)
                }
            }
            group {
                Text("DexBar is an independent, unofficial tool. It is not made or endorsed by OpenAI.")
                Text("It uses the local Codex app-server interface. That interface and the returned account limits may change or stop working at any time.")
                    .foregroundStyle(.secondary)
            }
            .font(.body)
        }
    }

    private var accountDetail: String {
        switch model.state {
        case .needsAuthentication: return "Codex needs you to sign in again."
        case .cliUnavailable: return "Codex CLI was not found."
        case .failed(let message): return message
        default:
            if let mode = model.snapshot?.serviceTier?.displayName {
                return "Uses the existing Codex CLI sign-in. Default service mode: \(mode)."
            }
            return "Uses the existing Codex CLI sign-in."
        }
    }

    private var accountStatus: String {
        switch model.state {
        case .needsAuthentication: return "Sign-in needed"
        case .cliUnavailable: return "Not installed"
        default:
            if let plan = displayPlan(model.snapshot?.planType) { return "ChatGPT \(plan)" }
            return "Connected"
        }
    }

    private var accountSymbol: String {
        switch model.state {
        case .needsAuthentication, .cliUnavailable: return "exclamationmark.circle"
        default: return model.snapshot == nil ? "exclamationmark.circle" : "checkmark.circle.fill"
        }
    }

    private var accountColor: Color {
        switch model.state {
        case .needsAuthentication, .cliUnavailable: return .orange
        default: return model.snapshot == nil ? .orange : .green
        }
    }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private func settingsRow<Trailing: View>(
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(Typography.detail).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
                .font(Typography.detailEmphasis)
        }
    }
}
