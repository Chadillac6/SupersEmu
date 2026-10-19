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
    /// Fixed installed paths only: no feed data or user-controlled paths are passed to the privileged shell.
    private static let restartServerShellCommand = [
        "set -e",
        PrivilegedCommand.shellCommand(["/usr/bin/codesign", "--verify", "--deep", "--strict", LocalServerConstants.installedAppPath]),
        "if \(PrivilegedCommand.shellCommand([Firewall.socketFilterPath, "--getglobalstate"])) | /usr/bin/grep -qi enabled; then "
            + Firewall.allowShellCommand(binaryPath: LocalServerConstants.installedServerBinaryPath) + " || exit 1; fi",
        PrivilegedCommand.shellCommand(["/bin/launchctl", "kickstart", "-k", "system/\(LocalServerConstants.daemonLabel)"]),
    ].joined(separator: "; ")
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isConfigured = false
    @Published private(set) var serverRestartPending = false
    @Published private(set) var status: UpdateStatus = .notConfigured
    private var controller: SPUStandardUpdaterController!
    private var observation: AnyCancellable?
    private var immediateInstallationBlock: (() -> Void)?

    private override init() {
        super.init()
        serverRestartPending = Bundle.main.bundleURL.path == LocalServerConstants.installedAppPath
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
        status = UpdateStatus.initial(
            isDebugBuild: _isDebugAssertConfiguration(),
            isConfigured: isConfigured,
            lastCheckDate: controller.updater.lastUpdateCheckDate
        )
        #if DEBUG
        if let preview = UpdateStatus.preview(arguments: ProcessInfo.processInfo.arguments) {
            status = preview
        }
        #endif
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
        if isConfigured {
            status = .checking
            controller.checkForUpdates(nil)
        }
        else {
            status = .notConfigured
            let alert = NSAlert()
            alert.messageText = "Update signing is not configured"
            alert.informativeText = "Install a release built with the update signing public key."
            alert.runModal()
        }
        #endif
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        UpdateNoticeStore.save(
            version: item.displayVersionString,
            build: item.versionString,
            notes: UpdateNoticeStore.plainTextNotes(item.itemDescription, format: item.itemDescriptionFormat)
        )
        let daemon = SMAppService.daemon(plistName: LocalServerConstants.daemonPlistName)
        if daemon.status == .enabled {
            UserDefaults.standard.set(item.versionString, forKey: Self.pendingServerVersionKey)
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .available(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status = .upToDate(checkedAt: Date())
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        status = .readyToInstall(version: item.displayVersionString)
        self.immediateInstallationBlock = immediateInstallationBlock
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let updateError = error as NSError
        guard updateError.code != Int(SUError.noUpdateError.rawValue) else { return }
        status = .failed(message: updateError.localizedDescription, checkedAt: updater.lastUpdateCheckDate)
    }

    var versionLabel: String { UpdateStatusPresentation.currentVersionLabel }

    func installNow() {
        immediateInstallationBlock?()
    }

    func consumePendingUpdateNotice() -> PendingUpdateNotice? {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return UpdateNoticeStore.consume(forRunningBuild: build)
    }

    func finishServerUpdateIfNeeded() {
        guard Bundle.main.bundleURL.path == LocalServerConstants.installedAppPath,
              let pending = UserDefaults.standard.string(forKey: Self.pendingServerVersionKey),
              pending == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Restart the updated SupersEmu Server?"
        alert.informativeText = "The app has updated. Restart the boot server to use the new version. macOS will ask for administrator approval; connected devices may briefly disconnect."
        alert.addButton(withTitle: "Restart Server")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let script = PrivilegedCommand.appleScriptSource(shellCommand: Self.restartServerShellCommand)
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
        UpdateStatusRows(updater: updater)
        Divider()
        UpdateActionRows(updater: updater)
    }
}

/// Version, update status and "Restart and Install", shared by the app menu and the menu bar.
struct UpdateStatusRows: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Text(updater.versionLabel).disabled(true)
        Text(UpdateStatusPresentation.menuText(for: updater.status)).disabled(true)
        if case .readyToInstall(let version) = updater.status {
            Button("Restart and Install \(version)") { updater.installNow() }
        }
    }
}

/// "Check for Updates…" and "Restart Updated Server…", shared by the app menu and the menu bar.
struct UpdateActionRows: View {
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
