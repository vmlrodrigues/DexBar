import SwiftUI
import DexBarCore

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs = Preferences.shared
    let continueAction: () -> Void
    let openTerminal: () -> Void

    var body: some View {
        VStack(spacing: 17) {
            AppMark(size: 58)
            VStack(spacing: 5) {
                Text("Your Codex allowance, one glance away.")
                    .font(.system(size: 18, weight: .semibold))
                Text("DexBar keeps your weekly allowance visible and only surfaces other windows while they are active.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Image(systemName: connectionSymbol)
                    .font(.system(size: 20))
                    .foregroundStyle(connectionColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connectionTitle).font(.system(size: 12, weight: .medium))
                    Text(connectionDetail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small) }
                else if model.snapshot == nil {
                    Button("Open Terminal", action: openTerminal).controlSize(.small)
                }
            }
            .padding(13)
            .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))

            Toggle(isOn: $prefs.notificationsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Warn me before I run out")
                    Text("Notifications at 80%, 95%, and when the weekly projection crosses the limit.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            Button("Add DexBar to the menu bar") {
                if prefs.notificationsEnabled { model.notifier.requestAuthorization() }
                prefs.completedOnboarding = true
                continueAction()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Independent and unofficial. Not made or endorsed by OpenAI.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 470)
    }

    private var connectionTitle: String {
        if model.snapshot != nil { return "Codex is connected" }
        switch model.state {
        case .loading: return "Checking Codex"
        case .needsAuthentication: return "Codex sign-in needed"
        case .cliUnavailable: return "Codex CLI not found"
        default: return "Couldn’t check Codex"
        }
    }

    private var connectionDetail: String {
        if let plan = displayPlan(model.snapshot?.planType) { return "Signed in with ChatGPT \(plan)" }
        switch model.state {
        case .loading: return "This takes a moment."
        case .needsAuthentication: return "Run codex login in Terminal, then refresh."
        case .cliUnavailable: return "Install Codex, then sign in with ChatGPT."
        case .failed(let message), .stale(let message): return message
        default: return "Uses your existing Codex CLI sign-in."
        }
    }

    private var connectionSymbol: String {
        model.snapshot == nil ? "exclamationmark.circle" : "checkmark.circle.fill"
    }

    private var connectionColor: Color {
        model.snapshot == nil ? .orange : .green
    }
}
