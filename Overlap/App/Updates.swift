import AppKit
import Sparkle

/// Keeps Overlap up to date with Sparkle. It checks the update feed once a day, says when there's a new version,
/// and installs it on request. Updates are signed with the release key and checked against `SUPublicEDKey`, so
/// nothing from Apple is needed. Development builds leave it off, so a release never replaces one, unless
/// they're given a feed to try.
///
/// To try a release against a local feed, launch it with `OVERLAP_FEED_URL` set to that feed. With
/// `OVERLAP_UPDATE_NOW=1` as well, it checks at once and installs what it finds without asking, then relaunches.
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController?

    nonisolated private static let environment = ProcessInfo.processInfo.environment

    /// The feed set for this launch, which wins over the one in Info.plist.
    nonisolated private static var feedOverride: String? { environment["OVERLAP_FEED_URL"] }

    nonisolated private static var installsAtOnce: Bool { environment["OVERLAP_UPDATE_NOW"] != nil }

    private static var feedURL: String? {
        feedOverride ?? (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
    }

    func start() {
        // Unit tests launch the app as their host, and have nothing to update.
        guard controller == nil, Self.environment["XCTestConfigurationFilePath"] == nil,
              let feed = Self.feedURL, !feed.isEmpty else { return }
        #if DEBUG
        guard Self.feedOverride != nil else { return }
        #endif
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        if Self.installsAtOnce {
            controller.updater.automaticallyDownloadsUpdates = true
            controller.updater.checkForUpdatesInBackground()
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedOverride
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard Self.installsAtOnce else { return false }
        immediateInstallHandler()
        return true
    }
}
