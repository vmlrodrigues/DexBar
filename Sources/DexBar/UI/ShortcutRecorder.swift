import SwiftUI
import Carbon.HIToolbox

/// A local, settings-window-only key recorder. It never observes keyboard input while
/// DexBar is in the background and therefore needs no Accessibility permission.
struct ShortcutRecorder: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    let isEnabled: Bool

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejection: String?

    private var label: String {
        if isRecording { return "Press keys…" }
        if modifiers == 0 { return "Not set" }
        return HotKeyFormatting.display(keyCode: keyCode, carbonModifiers: modifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button { isRecording ? stop() : start() } label: {
                    Text(label)
                        .font(.body.weight(.medium))
                        .fontDesign(.rounded)
                        .frame(minWidth: 84)
                        .padding(.vertical, 2)
                }
                .controlSize(.regular)
                .disabled(!isEnabled)
                .help("Click, then press the combination you want")

                if isRecording {
                    Text("⎋ to cancel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Clear") {
                        keyCode = DefaultHotKey.unsetKeyCode
                        modifiers = DefaultHotKey.unsetModifiers
                        rejection = nil
                    }
                    .controlSize(.small)
                    .disabled(!isEnabled || modifiers == 0)
                }
            }

            if let rejection {
                Text(rejection)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if isRecording { stop() }
        }
    }

    private func start() {
        guard monitor == nil else { return }
        isRecording = true
        rejection = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stop()
                return nil
            }

            let pressedModifiers = HotKeyFormatting.carbonModifiers(from: event.modifierFlags)
            let safeAnchor = pressedModifiers & (Int(controlKey) | Int(optionKey))
            guard safeAnchor != 0 else {
                rejection = "Include ⌃ Control or ⌥ Option so the shortcut cannot override the frontmost app's normal commands."
                return nil
            }

            keyCode = Int(event.keyCode)
            modifiers = pressedModifiers
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
