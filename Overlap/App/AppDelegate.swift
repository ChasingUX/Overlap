import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let shared = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = shared
        app.mainMenu = MainMenu.make()
        app.run()
    }

    /// Unit tests launch the app as their host; they don't need an empty project window.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        DebugSnapshot.runIfRequested()
        #endif
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !isRunningTests
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
