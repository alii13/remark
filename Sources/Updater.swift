import Foundation
import Sparkle

// Auto-update through Sparkle. The updater reads its feed URL and public key from Info.plist,
// checks on a schedule, and verifies each update's EdDSA signature before installing.
@MainActor
final class Updater {
    static let shared = Updater()
    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() { controller.updater.checkForUpdates() }
}
