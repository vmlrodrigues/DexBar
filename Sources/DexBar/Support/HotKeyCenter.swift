import AppKit
import Carbon.HIToolbox

struct HotKeyBinding: Equatable {
    let keyCode: Int
    let modifiers: Int
}

enum DefaultHotKey {
    // New global shortcuts ship unbound. There is no modifier combination that is
    // reliably free on a Mac we cannot see, so choosing one would be an intrusion.
    static let unsetKeyCode = -1
    static let unsetModifiers = 0
}

/// Registers one system-wide shortcut through Carbon. Unlike a global NSEvent monitor,
/// RegisterEventHotKey needs no Accessibility permission and cannot observe other keys.
@MainActor
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    @Published private(set) var isRegistered = false

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?

    private init() {}

    func setHandler(_ block: @escaping () -> Void) {
        handler = block
    }

    @discardableResult
    func register(keyCode: Int, carbonModifiers: Int) -> Bool {
        unregister()
        guard carbonModifiers != 0, keyCode >= 0 else { return false }
        installHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x4458_4252), id: 1) // 'DXBR'
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(carbonModifiers),
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status == noErr, let reference {
            hotKeyRef = reference
            isRegistered = true
            return true
        }

        FileHandle.standardError.write(Data(
            "DexBar: shortcut registration failed (OSStatus \(status)) for \(HotKeyFormatting.display(keyCode: keyCode, carbonModifiers: carbonModifiers))\n".utf8
        ))
        return false
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        isRegistered = false
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr, identifier.id == 1 else { return noErr }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { center.handler?() }
                }
                return noErr
            },
            1,
            &specification,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}

enum HotKeyFormatting {
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.control) { result |= Int(controlKey) }
        if flags.contains(.option) { result |= Int(optionKey) }
        if flags.contains(.shift) { result |= Int(shiftKey) }
        if flags.contains(.command) { result |= Int(cmdKey) }
        return result
    }

    static func display(keyCode: Int, carbonModifiers: Int) -> String {
        var result = ""
        if carbonModifiers & Int(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & Int(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & Int(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & Int(cmdKey) != 0 { result += "⌘" }
        return result + keyName(keyCode)
    }

    static func keyName(_ keyCode: Int) -> String {
        if let named = specialKeys[keyCode] { return named }
        if let character = characterKeys[keyCode] { return character }
        return "?"
    }

    private static let characterKeys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`",
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
