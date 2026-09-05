import Foundation
import DexBarCore

enum CurrentBuild {
    static let channel = BuildChannel(
        plistValue: Bundle.main.object(forInfoDictionaryKey: "DexBarBuildChannel")
    )
    static let sourceRevision = Bundle.main.object(
        forInfoDictionaryKey: "DexBarSourceRevision"
    ) as? String ?? "unknown"

    static var isDevelopment: Bool { channel == .development }
    static var automaticUpdatesEnabled: Bool { channel.automaticUpdatesEnabled }
    static var loginItemChangesEnabled: Bool { channel.loginItemChangesEnabled }
}
