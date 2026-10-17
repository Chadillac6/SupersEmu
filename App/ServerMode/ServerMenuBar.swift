#if os(macOS)
import AppKit
import Observation
import ServiceManagement
import SupersEmuKit
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
                if !monitor.pairRequestEntries.isEmpty {
                    Text("\(monitor.pairRequestEntries.count)").font(.caption2.bold())
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
    private var lastRemoteAccessRefreshAt: Date?
    private(set) var pairRequestsBySource: [ServerModeModel.Source: [PendingPairRequest]] = [:]
    private(set) var adminUsersBySource: [ServerModeModel.Source: [UserInfo]] = [:]

    private var rawPairRequestsBySource: [String: [PendingPairRequest]] {
        Dictionary(uniqueKeysWithValues: pairRequestsBySource.map { ($0.key.rawValue, $0.value) })
    }
    var pairRequestEntries: [PairRequestSourceEntry] {
        PairRequestSourceGrouping.entries(from: rawPairRequestsBySource)
    }
    var hasPairRequestsFromBothSources: Bool {
        PairRequestSourceGrouping.hasMultipleSourcesWithRequests(in: rawPairRequestsBySource)
    }

    func pairRequests(for source: ServerModeModel.Source) -> [PendingPairRequest] {
        PairRequestSourceGrouping.requests(for: source.rawValue, in: rawPairRequestsBySource)
    }

    func adminUsers(for source: ServerModeModel.Source) -> [UserInfo] {
        adminUsersBySource[source] ?? []
    }

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
        if UserDefaults.standard.bool(forKey: Self.showIconDefaultsKey) { startPolling() }
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let statusRefreshIsDue = ServerPollingCadence.shouldRefreshStatus(
                    lastRefreshAt: self.lastStatusRefreshAt, now: Date())
                if self.model.health == nil || statusRefreshIsDue {
                    await refresh()
                }
                if self.lastRemoteAccessRefreshAt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
                    await RemoteAccessModel.shared.refresh()
                    self.lastRemoteAccessRefreshAt = Date()
                }
                await refreshPairRequests()
                do {
                    try await Task.sleep(for: .seconds(ServerPollingCadence.pairRequestRefreshInterval))
                } catch {
                    return
                }
            }
        }
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        if visible {
            startPolling()
        } else {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    private func refresh() async {
        await model.refresh()
        let desiredSource: ServerModeModel.Source = model.daemonStatus == .enabled ? .daemon : .session
        if model.source != desiredSource {
            model.source = desiredSource
            await model.refresh()
        }
        lastStatusRefreshAt = Date()
    }

    func refreshPairRequests() async {
        for source in [ServerModeModel.Source.daemon, .session] {
            let result = await model.loadPairRequests(for: source)
            pairRequestsBySource[source] = result.requests
            adminUsersBySource[source] = result.users
        }
    }

    func approvePairRequest(_ id: UUID, source: ServerModeModel.Source, userID: String? = nil) async {
        await model.approvePairRequest(id, source: source, userID: userID)
        let result = await model.loadPairRequests(for: source)
        pairRequestsBySource[source] = result.requests
        adminUsersBySource[source] = result.users
    }

    func denyPairRequest(_ id: UUID, source: ServerModeModel.Source) async {
        await model.denyPairRequest(id, source: source)
        let result = await model.loadPairRequests(for: source)
        pairRequestsBySource[source] = result.requests
        adminUsersBySource[source] = result.users
    }
}

@MainActor @Observable
final class ServerModeNavigation {
    static let shared = ServerModeNavigation()
    var requested: ServerModeSection?
    var requestedSource: ServerModeModel.Source?
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
        Text("Remote: \(RemoteAccessModel.shared.isOn ? "On · \(RemoteAccessModel.shared.host)" : RemoteAccessModel.shared.summary)").disabled(true)
        if monitor.model.lanReachability == .blocked {
            Text("Other devices can't reach this server.")
            Button("Allow in Firewall…") { Task { await monitor.model.allowInFirewall() } }
        }
        Divider()
        Button("Open Server Window…") { openServerWindow() }
        Button("Pair a Device…") { openServerWindow(section: .server, generatePairingCode: true) }
        ForEach(monitor.pairRequestEntries) { entry in
            let request = entry.request
            let source = ServerModeModel.Source(rawValue: entry.source) ?? .session
            let sourceLabel = monitor.hasPairRequestsFromBothSources ? " · \(source == .daemon ? "Boot server" : "This session")" : ""
            Text("\(request.deviceName) (\(request.platform)) wants to connect · Code \(request.matchCode)\(sourceLabel)")
            Button("Approve \(request.deviceName)\(sourceLabel)") {
                Task { await monitor.approvePairRequest(request.id, source: source) }
            }
            Button("Deny \(request.deviceName)\(sourceLabel)") {
                Task { await monitor.denyPairRequest(request.id, source: source) }
            }
        }
        Button("Remote Access…") { openServerWindow(section: .remote) }
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
