#if os(macOS)
import AppKit
import Combine
import ServiceManagement
import Sparkle
import SwiftUI

/// Sparkle owns download verification and app replacement; the boot daemon is refreshed after relaunch.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    private static let pendingServerVersionKey = "updates.pendingServerVersion"
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isConfigured = false
    @Published private(set) var serverRestartPending = false
    private var controller: SPUStandardUpdaterController!
    private var observation: AnyCancellable?

    private override init() {
        super.init()
        serverRestartPending = Bundle.main.bundleURL.path == "/Applications/SupersEmu.app"
            && UserDefaults.standard.string(forKey: Self.pendingServerVersionKey) != nil
            && UserDefaults.standard.string(forKey: Self.pendingServerVersionKey)
                == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        isConfigured = Data(base64Encoded: key)?.count == 32 && URL(string: feed)?.scheme == "https"
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
        // Source builds are for live iteration. They must never replace themselves with a published release.
        #if !DEBUG
        if isConfigured { controller.startUpdater() }
        #endif
    }

    func checkForUpdates() {
        #if DEBUG
        let alert = NSAlert()
        alert.messageText = "Updates are disabled in development builds"
        alert.informativeText = "The installed release app checks for signed updates automatically. This source build stays available for local testing."
        alert.runModal()
        #else
        if isConfigured { controller.checkForUpdates(nil) }
        else {
            let alert = NSAlert()
            alert.messageText = "Update signing is not configured"
            alert.informativeText = "Install a release built with the update signing public key."
            alert.runModal()
        }
        #endif
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let daemon = SMAppService.daemon(plistName: "com.chadillac6.supersemu.server.plist")
        if daemon.status == .enabled {
            UserDefaults.standard.set(item.versionString, forKey: Self.pendingServerVersionKey)
        }
    }

    func finishServerUpdateIfNeeded() {
        guard Bundle.main.bundleURL.path == "/Applications/SupersEmu.app",
              let pending = UserDefaults.standard.string(forKey: Self.pendingServerVersionKey),
              pending == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Restart the updated SupersEmu Server?"
        alert.informativeText = "The app has updated. Restart the boot server to use the new version. macOS will ask for administrator approval; connected devices may briefly disconnect."
        alert.addButton(withTitle: "Restart Server")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Fixed installed paths only: no feed data or user-controlled paths are passed to the privileged shell.
        let script = """
        do shell script "set -e; /usr/bin/codesign --verify --deep --strict /Applications/SupersEmu.app; if /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate | /usr/bin/grep -qi enabled; then /usr/libexec/ApplicationFirewall/socketfilterfw --add /Applications/SupersEmu.app/Contents/MacOS/supersemu-server && /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /Applications/SupersEmu.app/Contents/MacOS/supersemu-server || exit 1; fi; /bin/launchctl kickstart -k system/com.chadillac6.supersemu.server" with administrator privileges
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if result != nil && error == nil {
            UserDefaults.standard.removeObject(forKey: Self.pendingServerVersionKey)
            serverRestartPending = false
        } else {
            let failure = NSAlert()
            failure.messageText = "Server restart did not complete"
            failure.informativeText = "The update is installed, but the server still needs a restart. Choose Restart Updated Server from the SupersEmu menu to try again."
            failure.runModal()
        }
    }
}

struct UpdateMenu: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
        #if !DEBUG
            .disabled(updater.isConfigured && !updater.canCheckForUpdates)
        #endif
        Button("Restart Updated Server…") { updater.finishServerUpdateIfNeeded() }
            .disabled(!updater.serverRestartPending)
    }
}
#endif
