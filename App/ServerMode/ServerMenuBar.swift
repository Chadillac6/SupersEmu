#if os(macOS)
import AppKit
import Observation
import ServiceManagement
import SwiftUI

struct ServerMenuBar: Scene {
    @AppStorage(ServerStatusMonitor.showIconDefaultsKey) private var showIcon = false
    @State private var monitor = ServerStatusMonitor.shared

    var body: some Scene {
        MenuBarExtra(isInserted: insertionBinding) {
            ServerMenuBarContent(monitor: monitor, showIcon: $showIcon)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: monitor.status.symbolName)
                if !monitor.model.pairRequests.isEmpty {
                    Text("\(monitor.model.pairRequests.count)").font(.caption2.bold())
                }
            }
                .accessibilityLabel(monitor.status.title)
        }
        .menuBarExtraStyle(.menu)
    }

    private var insertionBinding: Binding<Bool> {
        Binding(
            get: { showIcon },
            set: {
                showIcon = $0
                monitor.setMenuBarIconVisible($0)
            }
        )
    }
}

@MainActor @Observable
final class ServerStatusMonitor {
    static let shared = ServerStatusMonitor()
    static let showIconDefaultsKey = "showServerMenuBarIcon"

    let model: ServerModeModel
    private var pollingTask: Task<Void, Never>?
    private var lastStatusRefreshAt: Date?

    var status: ServerMenuStatus {
        ServerMenuStatus(
            daemonStatus: model.daemonStatus,
            sessionRunning: model.sessionRunning,
            health: model.health,
            deviceCount: model.devices.count,
            sessionStoppedUnexpectedly: model.sessionStoppedUnexpectedly
        )
    }

    private init() {
        model = ServerModeModel()
        if UserDefaults.standard.object(forKey: Self.showIconDefaultsKey) == nil {
            let daemonIsRegistered = model.daemonStatus == .enabled || model.daemonStatus == .requiresApproval
            UserDefaults.standard.set(daemonIsRegistered, forKey: Self.showIconDefaultsKey)
        }
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let showIcon = UserDefaults.standard.bool(forKey: Self.showIconDefaultsKey)
                let statusRefreshIsDue = self.lastStatusRefreshAt.map {
                    Date().timeIntervalSince($0) >= 10
                } ?? true
                if self.model.health == nil || (showIcon && statusRefreshIsDue) {
                    await refresh()
                }
                if model.isLocal && model.health != nil {
                    await model.refreshPairRequests()
                }
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
            }
        }
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        if visible { Task { await refresh() } }
    }

    func setLocalSource(_ source: ServerModeModel.Source) {
        guard source != .paired, model.source != source else { return }
        model.source = source
        Task { await refresh() }
    }

    private func refresh() async {
        await model.refresh()
        lastStatusRefreshAt = Date()
    }
}

@MainActor @Observable
final class ServerModeNavigation {
    static let shared = ServerModeNavigation()
    var requested: ServerModeSection?
    var generatePairingCode = false

    private init() {}
}

private struct ServerMenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let monitor: ServerStatusMonitor
    @Binding var showIcon: Bool

    @ViewBuilder
    var body: some View {
        let status = monitor.status
        Text(status.title).disabled(true)
        Text(status.detail).disabled(true)
        if monitor.model.lanReachability == .blocked {
            Text("Other devices can't reach this server.")
            Button("Allow in Firewall…") { Task { await monitor.model.allowInFirewall() } }
        }
        Divider()
        Button("Open Server Window…") { openServerWindow() }
        Button("Pair a Device…") { openServerWindow(section: .server, generatePairingCode: true) }
        ForEach(monitor.model.pairRequests) { request in
            Text("\(request.deviceName) (\(request.platform)) wants to connect · Code \(request.matchCode)")
            Button("Approve \(request.deviceName)") { Task { await monitor.model.approvePairRequest(request.id) } }
            Button("Deny \(request.deviceName)") { Task { await monitor.model.denyPairRequest(request.id) } }
        }
        Button("Add Games…") { openServerWindow(section: .library) }
        Button("Review Needed…") { openServerWindow(section: .review) }
        Button("BIOS…") { openServerWindow(section: .bios) }
        Button("Storage…") { openServerWindow(section: .storage) }
        Divider()
        if status.state == .off || status.sessionStoppedUnexpectedly {
            Button("Start Server for This Session") {
                Task { await monitor.model.startSession() }
            }
        } else if status.state == .needsApproval {
            Button("Open Login Items Settings…") { monitor.model.openLoginItems() }
        }
        Toggle("Open SupersEmu at Login", isOn: loginItemBinding)
        Button("Hide Menu Bar Icon") { showIcon = false }
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                Task { @MainActor in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try await SMAppService.mainApp.unregister()
                        }
                    } catch {}
                }
            }
        )
    }

    private func openServerWindow(section: ServerModeSection? = nil) {
        if let section { ServerModeNavigation.shared.requested = section }
        openWindow(id: ServerModeScene.windowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openServerWindow(section: ServerModeSection, generatePairingCode: Bool) {
        ServerModeNavigation.shared.requested = section
        ServerModeNavigation.shared.generatePairingCode = generatePairingCode
        openWindow(id: ServerModeScene.windowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
