import SwiftUI
import DexBarCore

struct PopoverView: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    let openSignIn: () -> Void
    let quit: () -> Void

    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 330)
        .onReceive(ticker) { now = $0 }
    }

    private var header: some View {
        HStack(spacing: 9) {
            AppMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("DexBar")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize()
                    if let accountBadge {
                        Text(accountBadge)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                            .help("ChatGPT plan and Codex default service mode reported by the local app server.")
                            .fixedSize()
                    }
                }
                Text("Codex usage").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isRefreshing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.plain)
            .help("Refresh usage")
            .disabled(model.isRefreshing)
            .mouseOnlyPopoverControl()
        }
        .padding(14)
    }

    private var accountBadge: String? {
        let plan = displayPlan(model.snapshot?.planType)
        let speed = model.snapshot?.serviceTier?.displayName
        return [plan, speed].compactMap { $0 }.isEmpty
            ? nil
            : [plan, speed].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = model.snapshot {
            VStack(spacing: 0) {
                if case .needsAuthentication = model.state {
                    recoveryBanner(
                        "Codex needs you to sign in again.",
                        symbol: "person.crop.circle.badge.exclamationmark",
                        button: "Sign In",
                        action: openSignIn
                    )
                } else if case .cliUnavailable = model.state {
                    recoveryBanner(
                        "Codex CLI was not found. The last reading is shown below.",
                        symbol: "exclamationmark.triangle",
                        button: "Open Terminal",
                        action: openSignIn
                    )
                } else if case .stale(let message) = model.state {
                    stateBanner(message, symbol: "wifi.exclamationmark", color: .orange)
                }
                VStack(spacing: 14) {
                    UsageWindowRow(
                        window: snapshot.weekly,
                        projection: model.weeklyProjection,
                        now: now
                    )
                    ForEach(snapshot.supplementary) { window in
                        Divider()
                        UsageWindowRow(
                            window: window,
                            projection: model.projection(for: window),
                            showContext: true,
                            now: now
                        )
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)

                if let credits = snapshot.credits, credits.isWorthShowing {
                    Divider()
                    HStack {
                        Label("Usage credits", systemImage: "wallet.bifold")
                        Spacer()
                        Text(credits.unlimited ? "Unlimited" : (credits.balance ?? "Available"))
                            .fontWeight(.medium)
                    }
                    .font(.system(size: 10))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        } else {
            switch model.state {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Checking Codex usage…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(30)
            case .needsAuthentication:
                setupPanel(
                    title: "Sign in to Codex",
                    message: "DexBar uses the ChatGPT account already connected to the Codex CLI.",
                    button: "Open Terminal",
                    action: openSignIn
                )
            case .cliUnavailable:
                setupPanel(
                    title: "Codex CLI not found",
                    message: "Install Codex and sign in with ChatGPT, then refresh DexBar.",
                    button: "Open Terminal",
                    action: openSignIn
                )
            case .failed(let message), .stale(let message):
                setupPanel(title: "Couldn’t read usage", message: message, button: "Try Again") {
                    Task { await model.refresh() }
                }
            case .ok:
                EmptyView()
            }
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                Circle()
                    .fill(freshnessColor)
                    .frame(width: 5, height: 5)
                Text(freshnessText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer()
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .help("Settings")
                .mouseOnlyPopoverControl()
            Button(action: quit) { Image(systemName: "power") }
                .buttonStyle(.plain)
                .help("Quit DexBar")
                .mouseOnlyPopoverControl()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var freshnessText: String {
        switch model.state {
        case .needsAuthentication: return "Sign-in needed"
        case .cliUnavailable: return "Codex not found"
        default: break
        }
        guard let fetched = model.snapshot?.fetchedAt else { return "Not connected" }
        let age = now.timeIntervalSince(fetched)
        return age < 60 ? "Updated just now" : "Updated \(shortDuration(age)) ago"
    }

    private var freshnessColor: Color {
        switch model.state {
        case .stale, .needsAuthentication, .cliUnavailable, .failed: return .orange
        default: break
        }
        return model.snapshot == nil ? .secondary : .green
    }

    private func stateBanner(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(color.opacity(0.10))
    }

    private func recoveryBanner(
        _ text: String,
        symbol: String,
        button: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Label(text, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(button, action: action)
                .controlSize(.small)
                .mouseOnlyPopoverControl()
        }
        .font(.system(size: 10))
        .foregroundStyle(.orange)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.10))
    }

    private func setupPanel(title: String, message: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 25))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(button, action: action)
                .controlSize(.small)
                .mouseOnlyPopoverControl()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

private extension View {
    /// The popover is a pointer surface. Keep its icon buttons out of the Tab loop and
    /// suppress the keyboard focus plate while retaining their normal accessibility actions.
    func mouseOnlyPopoverControl() -> some View {
        focusable(false)
            .focusEffectDisabled()
    }
}
