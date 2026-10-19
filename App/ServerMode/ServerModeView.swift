#if os(macOS)
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import SupersEmuKit

struct ServerModeScene: Scene {
    static let windowID = "server-mode"

    var body: some Scene {
        Window("SupersEmu Server", id: Self.windowID) {
            ServerModeView()
        }
        .defaultSize(width: 980, height: 820)
        .commands { ServerModeCommands() }
    }
}

/// Applied to the main window: opens Server mode at launch when requested (`--server-mode` or the toggle).
struct ServerModeLaunchHook: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            if ServerModeLaunch.consumeRequest() { openWindow(id: ServerModeScene.windowID) }
        }
    }
}

extension View {
    func serverModeLaunchHook() -> some View { modifier(ServerModeLaunchHook()) }
}

struct ServerModeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Server Mode") { openWindow(id: ServerModeScene.windowID) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

/// Sidebar sections of the Server Mode window. Each is a self-contained view; add a case to add a section.
enum ServerModeSection: String, CaseIterable, Identifiable {
    case server, remote, users, library, review, bios, storage
    var id: String { rawValue }
    var title: String {
        switch self {
        case .server: return "Server"
        case .remote: return "Remote Access"
        case .users: return "Users & Games"
        case .library: return "Add Games"
        case .review: return "Review Needed"
        case .bios: return "BIOS"
        case .storage: return "Storage"
        }
    }
    var systemImage: String {
        switch self {
        case .server: return "server.rack"
        case .remote: return "globe"
        case .users: return "person.2"
        case .library: return "square.and.arrow.down.on.square"
        case .review: return "exclamationmark.bubble"
        case .bios: return "cpu"
        case .storage: return "externaldrive"
        }
    }

    /// Debug builds: `SUPERSEMU_DEBUG_SERVER_SECTION=remote` opens that section first (for screenshots).
    static var debugInitial: ServerModeSection? {
        #if DEBUG
        ProcessInfo.processInfo.environment["SUPERSEMU_DEBUG_SERVER_SECTION"].flatMap(ServerModeSection.init(rawValue:))
        #else
        nil
        #endif
    }
}

struct ServerModeView: View {
    @State private var model = ServerModeModel()
    @State private var library: LibraryManagerModel?
    @State private var usersGames: UsersGamesModel?
    @State private var section: ServerModeSection? = ServerModeSection.debugInitial ?? .server
    @State private var remoteAccess = RemoteAccessModel.shared
    @State private var navigation = ServerModeNavigation.shared
    @State private var selectedPairingUserID: String?
    @AppStorage(ServerModeLaunch.defaultsKey) private var openAtLaunch = false
    @AppStorage(ServerStatusMonitor.showIconDefaultsKey) private var showServerMenuBarIcon = false

    var body: some View {
        NavigationSplitView {
            List(ServerModeSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.systemImage)
                    .badge(item == .review ? library?.issues.count ?? 0 : 0)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            detail
                .frame(minWidth: 620, minHeight: 600)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let library, !urls.isEmpty, library.canImport else { return false }
            if section != .bios { section = .library }
            Task { await library.importItems(urls) }
            return true
        }
        .task {
            remoteAccess.attach(serverMode: model)
            if library == nil { library = LibraryManagerModel(server: model) }
            if usersGames == nil { usersGames = UsersGamesModel(server: model) }
            await library?.refreshStorage()
            await usersGames?.refresh()
        }
        .onChange(of: model.source) {
            library?.reset()
            usersGames?.reset()
            selectedPairingUserID = nil
            Task { await model.refresh(); await library?.refreshAll(); await usersGames?.refresh() }
        }
        .onAppear {
            remoteAccess.attach(serverMode: model)
            consumeNavigationRequest()
        }
        .onChange(of: navigation.requested) { _, _ in consumeNavigationRequest() }
        .onChange(of: showServerMenuBarIcon) { _, visible in
            ServerStatusMonitor.shared.setMenuBarIconVisible(visible)
        }
    }

    @ViewBuilder private var detail: some View {
        switch (section ?? .server, library, usersGames) {
        case (.remote, _, _): RemoteAccessView(model: remoteAccess, serverMode: model)
        case (.users, _, let usersGames?): UsersGamesView(model: usersGames)
        case (.library, let library?, _): LibraryImportView(model: library, onReview: { section = .review })
        case (.review, let library?, _): ReviewNeededView(model: library)
        case (.bios, let library?, _): BIOSView(model: library)
        case (.storage, let library?, _): StorageView(model: library)
        default: overview
        }
    }

    private var pairingRequestsModel: ServerModeModel {
        ServerStatusMonitor.shared.model
    }

    private var overview: some View {
        Form {
            serverSection
            if model.isLocal {
                daemonSection
                pairingSection
                devicesSection
            }
            BackupsSection(model: model)
        }
        .formStyle(.grouped)
        .task {
            remoteAccess.attach(serverMode: model)
            await model.refresh()
            await remoteAccess.refresh()
            var nextRemoteRefresh = Date().addingTimeInterval(30)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                await model.refresh()
                if Date() >= nextRemoteRefresh {
                    await remoteAccess.refresh()
                    nextRemoteRefresh = Date().addingTimeInterval(30)
                }
            }
        }
    }

    private var serverSection: some View {
        Section("Server") {
            Picker("Server", selection: $model.source) {
                ForEach(model.sources) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: model.source) { Task { await model.refresh() } }

            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(model.health != nil ? Color.green : Color.red).frame(width: 9, height: 9)
                    if let health = model.health {
                        Text("Running: \(health.serverName) v\(health.serverVersion)")
                    } else {
                        Text(model.statusError ?? "Checking…").foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Address", value: model.serverURL.absoluteString)
            if model.isLocal {
                LabeledContent("Remote Access") {
                    HStack(spacing: 8) {
                        Text(remoteAccess.isOn ? "On — \(remoteAccess.publicURLText)" : remoteAccess.summary)
                            .foregroundStyle(remoteAccess.isOn ? Color.green : Color.secondary)
                        Button(remoteAccess.isOn ? "Manage…" : "Set Up…") { section = .remote }
                            .controlSize(.small)
                    }
                }
            }
            if model.lanReachability == .blocked {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Other devices can't reach this server.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if model.firewallBlocksServer == true {
                        Text("macOS Firewall is blocking SupersEmu Server.")
                    } else {
                        Text("The macOS Firewall status is unknown.")
                    }
                    Button("Allow in Firewall…") { Task { await model.allowInFirewall() } }
                }
                .padding(.vertical, 4)
            }
            if model.isLocal {
                LabeledContent("Data folder") {
                    Text(model.dataDirectory.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
            }
            if let pin = model.certificateSHA256 {
                LabeledContent("Certificate SHA-256") {
                    Text(pin.prefix(16) + "…").font(.system(.body, design: .monospaced)).help(pin).textSelection(.enabled)
                }
            }
            if model.source == .session {
                HStack {
                    if model.sessionRunning {
                        Button("Stop Server") { Task { await model.stopSession() } }
                    } else {
                        Button("Start Server for This Session") { Task { await model.startSession() } }
                            .disabled(model.busy || model.serverBinary == nil)
                    }
                    if model.busy { ProgressView().controlSize(.small) }
                }
            }
            if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            Toggle("Open Server mode when SupersEmu launches", isOn: $openAtLaunch)
            Toggle("Show server status in the menu bar", isOn: $showServerMenuBarIcon)
        }
    }

    private func consumeNavigationRequest() {
        if let requestedSource = navigation.requestedSource {
            model.source = requestedSource
            navigation.requestedSource = nil
        }
        if let requested = navigation.requested {
            section = requested
            navigation.requested = nil
        }
        if navigation.generatePairingCode {
            navigation.generatePairingCode = false
            Task {
                await model.refresh()
                let localSource = model.preferredLocalSource
                if model.source != localSource {
                    model.source = localSource
                }
                await model.refresh()
                if model.health == nil, model.source == .daemon {
                    model.source = .session
                    await model.refresh()
                }
                guard model.health != nil else { return }
                await model.createPairingCode()
            }
        }
    }

    private var daemonSection: some View {
        Section {
            LabeledContent("Launch daemon", value: model.daemonStatusText)
            HStack {
                if model.daemonStatus == .enabled || model.daemonStatus == .requiresApproval {
                    Button("Unregister") { Task { await model.unregisterDaemon() } }
                } else {
                    Button("Register Boot Daemon") { Task { await model.registerDaemon() } }
                }
                Button("Open Login Items Settings") { model.openLoginItems() }
            }
        } header: {
            Text("Start at boot")
        } footer: {
            Text("Runs supersemu-server as a launch daemon so the library is available after a restart with no one logged in. macOS asks an administrator to approve it once in System Settings › General › Login Items.")
        }
    }

    private var pairingSection: some View {
        let requestSource = model.source
        let requests = ServerStatusMonitor.shared.pairRequests(for: requestSource)
        let users = ServerStatusMonitor.shared.adminUsers(for: requestSource)
        return Section("Pair a device") {
            HStack {
                Button(model.pairing == nil ? "New Pairing Code" : "New Code") { Task { await model.createPairingCode() } }
                    .disabled(model.health == nil)
                Spacer()
            }
            if let error = model.pairingError ?? pairingRequestsModel.pairingError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if let pairing = model.pairing {
                PairingCodePanel(pairing: pairing, serverCertificateSHA256: model.certificateSHA256, style: .regular)
                    .padding(.vertical, 6)
            }
            ForEach(requests) { request in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(request.deviceName) (\(request.platform)) wants to connect · Code \(request.matchCode)")
                    if users.count > 1 {
                        Picker("Assign to", selection: Binding(
                            get: { selectedPairingUserID ?? users.first?.id ?? "" },
                            set: { selectedPairingUserID = $0 }
                        )) {
                            ForEach(users) { user in
                                Text(user.displayName).tag(user.id)
                            }
                        }
                        Button("Approve") {
                            Task {
                                await ServerStatusMonitor.shared.approvePairRequest(
                                    request.id, source: requestSource, userID: selectedPairingUserID ?? users.first?.id)
                            }
                        }
                    } else {
                        Button("Approve") {
                            Task { await ServerStatusMonitor.shared.approvePairRequest(request.id, source: requestSource) }
                        }
                    }
                    Button("Deny", role: .destructive) {
                        Task { await ServerStatusMonitor.shared.denyPairRequest(request.id, source: requestSource) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var devicesSection: some View {
        Section("Paired devices") {
            if let error = model.devicesError {
                Text(error).foregroundStyle(.secondary).font(.callout)
            } else if model.devices.isEmpty {
                Text(model.health == nil ? "Start the server to see devices." : "No devices paired yet.").foregroundStyle(.secondary)
            }
            ForEach(model.devices) { device in
                LabeledContent {
                    if device.revokedAt != nil {
                        Text("Revoked").foregroundStyle(.red)
                    } else if let seen = device.lastSeenAt {
                        Text("Seen \(seen.formatted(.relative(presentation: .named)))")
                    } else {
                        Text("Paired \(device.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                } label: {
                    Text(device.name)
                }
            }
        }
    }

    static func grouped(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}

/// QR code rendered with CoreImage's generator, scaled with nearest-neighbour so it stays sharp.
/// QR code, grouped code, server fingerprint, countdown and addresses for a one-time pairing code.
struct PairingCodePanel: View {
    enum Style {
        case regular, compact

        var qrSize: CGFloat { self == .regular ? 220 : 190 }
        var spacing: CGFloat { self == .regular ? 24 : 20 }
        var textSpacing: CGFloat { self == .regular ? 10 : 12 }
        var codeSize: CGFloat { self == .regular ? 40 : 36 }
    }

    let pairing: PairingCode
    let serverCertificateSHA256: String?
    let style: Style

    var body: some View {
        HStack(alignment: .top, spacing: style.spacing) {
            QRCodeImage(text: pairing.qrURL).frame(width: style.qrSize, height: style.qrSize)
            VStack(alignment: .leading, spacing: style.textSpacing) {
                Text("Scan with the SupersEmu app, or enter the code:").foregroundStyle(.secondary)
                Text(ServerModeView.grouped(pairing.code))
                    .font(.system(size: style.codeSize, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                if let pin = pairing.payload.certificateSHA256 ?? serverCertificateSHA256,
                   let fingerprint = PairingFingerprint.short(certificateSHA256: pin) {
                    Text("Server fingerprint: \(fingerprint)").font(.callout.monospaced())
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(pairing.expiresAt.timeIntervalSince(context.date)))
                    Text(remaining > 0 ? "Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60)) · one-time use" : "Expired")
                        .foregroundStyle(remaining > 0 ? Color.secondary : Color.red)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Addresses in this code").font(.caption).foregroundStyle(.secondary)
                    ForEach(pairing.payload.urls, id: \.self) { Text($0.absoluteString).font(.caption.monospaced()) }
                }
            }
        }
    }
}

struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                .padding(10).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Pairing QR code")
        } else {
            Text("QR unavailable")
        }
    }

    static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
#endif
